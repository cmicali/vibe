//
//  NowPlayingController.m
//  Vibe
//

#import "NowPlayingController.h"
#import "AudioTrack.h"
#import "NowPlayingRules.h"
#import <MediaPlayer/MediaPlayer.h>

_Static_assert(VibeRepeatModeOff == (NSInteger)MPRepeatTypeOff, "VibeRepeatMode casts to MPRepeatType");
_Static_assert(VibeRepeatModeOne == (NSInteger)MPRepeatTypeOne, "VibeRepeatMode casts to MPRepeatType");
_Static_assert(VibeRepeatModeAll == (NSInteger)MPRepeatTypeAll, "VibeRepeatMode casts to MPRepeatType");
#if TARGET_OS_OSX
#import "NSImage+Util.h"
#endif

// TRAP: this must run on main, and its result must be the only thing the
// request handler returns. The handler runs on MediaPlayer's threads, and
// `artwork` is the live NSImage the UI is drawing; NSImage is not safe to draw
// from two threads at once. Capped at 512px: the handler's result is
// serialized to the media daemon on every publish.
static VibeImage *_Nullable VibeArtworkForPublishing(VibeImage *artwork) {
#if TARGET_OS_OSX
    NSCAssert(NSThread.isMainThread, @"Now Playing artwork must be rasterized on main");
    static const CGFloat kPublishedArtworkMaxSide = 512;
    CGSize source = artwork.size;
    if (source.width <= 0 || source.height <= 0) {
        // Drawing may still recover a rep whose logical size is bad.
        return [artwork resizedImage:NSMakeSize(1, 1)];
    }
    CGFloat scale = MIN(1.0, MIN(kPublishedArtworkMaxSide / source.width,
                                kPublishedArtworkMaxSide / source.height));
    // Always redrawn, even when small: the private copy is the boundary.
    return [artwork resizedImage:NSMakeSize(round(source.width * scale),
                                            round(source.height * scale))];
#else
    return artwork;
#endif
}

@implementation NowPlayingController {
    __weak id<NowPlayingControllerDelegate> _delegate;
#if DEBUG
    BOOL _suppressed;
#endif

    // Publishing even a cleared or paused state before the first play would
    // evict the user's current Now Playing app.
    BOOL _hasPublished;
    NSTimeInterval (^_clock)(void);
    void (^_publish)(NSDictionary *, NowPlayingPlaybackState);
    void (^_commandAvailability)(BOOL, BOOL);

    // The dirty check's snapshot: the track's sourceKey, so a cue row of the
    // same file is a change. nil is cleared or never published.
    NSString *_publishedSource;
    NSString *_publishedTitle;
    NSString *_publishedArtist;
    NowPlayingPlaybackState _publishedState;
    double _publishedRate;
    NSTimeInterval _publishedDuration;
    NSTimeInterval _publishedPosition;
    CFAbsoluteTime _publishedAt;

    // Written to MPRemoteCommand only on a change.
    BOOL _publishedHasNext;
    BOOL _publishedHasPrevious;
    // The command center's shuffle and repeat state is written only once the
    // commands are registered, which the tests' initializer never does.
    BOOL _commandsRegistered;

    // Reused while the caller hands back the same image.
    VibeImage *_publishedArtworkImage;
    MPMediaItemArtwork *_publishedArtworkWrapper;
}

- (instancetype)initWithDelegate:(id<NowPlayingControllerDelegate>)delegate {
    self = [self initWithClock:^{ return CFAbsoluteTimeGetCurrent(); }
                      publish:^(NSDictionary *info, NowPlayingPlaybackState state) {
        MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
        center.nowPlayingInfo = info;
#if TARGET_OS_OSX
        switch (state) {
            case NowPlayingPlaybackStatePlaying: center.playbackState = MPNowPlayingPlaybackStatePlaying; break;
            case NowPlayingPlaybackStatePaused: center.playbackState = MPNowPlayingPlaybackStatePaused; break;
            case NowPlayingPlaybackStateStopped: center.playbackState = MPNowPlayingPlaybackStateStopped; break;
        }
#endif
    } commandAvailability:^(BOOL next, BOOL previous) {
        MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
        center.nextTrackCommand.enabled = next;
        center.previousTrackCommand.enabled = previous;
    }];
    if (self) {
        _delegate = delegate;
#if DEBUG
        // TRAP: see the header. --no-now-playing suppresses this alone,
        // keeping hardware rendering for loopback tests.
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        _suppressed = [arguments containsObject:@"--no-audio-hw"]
                || [arguments containsObject:@"--no-now-playing"];
        if (_suppressed) {
            LogInfo(@"NowPlayingController: system Now Playing suppressed for this debug launch");
            return self;
        }
#endif
        [self registerCommands];
    }
    return self;
}

- (instancetype)initWithClock:(NSTimeInterval (^)(void))clock
                      publish:(void (^)(NSDictionary *, NowPlayingPlaybackState))publish
          commandAvailability:(void (^)(BOOL, BOOL))commandAvailability {
    self = [super init];
    if (self) {
        _clock = [clock copy];
        _publish = [publish copy];
        _commandAvailability = [commandAvailability copy];
        _publishedHasNext = YES;
        _publishedHasPrevious = YES;
    }
    return self;
}

#pragma mark - Remote commands

// MediaPlayer documents no delivery queue for command handlers, so every
// delivery hops to main.
- (MPRemoteCommandHandlerStatus)deliverRemoteCommand:(NSString *)name
        to:(void (^)(id<NowPlayingControllerDelegate> delegate))delivery {
#if VIBE_VERBOSE_LOGGING
    LogInfo(@"Callback: remote command %@", name);
#endif
    id<NowPlayingControllerDelegate> delegate = _delegate;
    if (!delegate) {
        return MPRemoteCommandHandlerStatusCommandFailed;
    }
    if (NSThread.isMainThread) {
        delivery(delegate);
    }
    else {
        run_on_main_thread({
            delivery(delegate);
        });
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

// The handlers are retained process-wide and can outlive this controller; the
// strongSelf nil checks are load-bearing, since `nil->_delegate` dereferences
// NULL plus an offset.
- (void)registerCommands {
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    __weak NowPlayingController *weakSelf = self;
    _commandsRegistered = YES;

    // TRAP: the command center is process-global — lock screen, Control
    // Center, CarPlay, AirPods and the mac's media keys share it — and the
    // system picks which enabled commands fill the compact transport. These
    // two leave next/previous there (the lock screen and Control Center show
    // no shuffle or repeat at all); the skip-interval pair takes their place.
    // Check any further command on a device first.
    // State follows updateShuffleEnabled:repeatMode:; a request only asks.
    center.changeShuffleModeCommand.enabled = YES;
    [center.changeShuffleModeCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        // Items and Collections are both on: there is no album-level shuffle,
        // and the state written back says which the system got.
        BOOL enabled = ((MPChangeShuffleModeCommandEvent *)event).shuffleType != MPShuffleTypeOff;
        return [strongSelf deliverRemoteCommand:@"change shuffle mode" to:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingController:strongSelf setShuffleEnabled:enabled];
        }];
    }];

    center.changeRepeatModeCommand.enabled = YES;
    [center.changeRepeatModeCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        VibeRepeatMode mode = (VibeRepeatMode)((MPChangeRepeatModeCommandEvent *)event).repeatType;
        return [strongSelf deliverRemoteCommand:@"change repeat mode" to:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingController:strongSelf setRepeatMode:mode];
        }];
    }];

    center.playCommand.enabled = YES;
    [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        return [strongSelf deliverRemoteCommand:@"play" to:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingControllerPlay:strongSelf];
        }];
    }];

    center.pauseCommand.enabled = YES;
    [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        return [strongSelf deliverRemoteCommand:@"pause" to:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingControllerPause:strongSelf];
        }];
    }];

    center.togglePlayPauseCommand.enabled = YES;
    [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        return [strongSelf deliverRemoteCommand:@"toggle play/pause" to:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingControllerTogglePlayPause:strongSelf];
        }];
    }];

    // Enabled until updateWithTrack: tracks the playlist's boundaries.
    center.nextTrackCommand.enabled = YES;
    _publishedHasNext = YES;
    [center.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        return [strongSelf deliverRemoteCommand:@"next track" to:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingControllerNextTrack:strongSelf];
        }];
    }];

    center.previousTrackCommand.enabled = YES;
    _publishedHasPrevious = YES;
    [center.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        return [strongSelf deliverRemoteCommand:@"previous track" to:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingControllerPreviousTrack:strongSelf];
        }];
    }];

    center.changePlaybackPositionCommand.enabled = YES;
    [center.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        MPChangePlaybackPositionCommandEvent *positionEvent = (MPChangePlaybackPositionCommandEvent *)event;
        NSTimeInterval position = positionEvent.positionTime;
        return [strongSelf deliverRemoteCommand:@"change playback position" to:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingController:strongSelf seekToPosition:position];
        }];
    }];

    // Off, so the system offers only controls the app handles.
    NSArray<MPRemoteCommand *> *unsupported = @[
        center.stopCommand,
        center.seekForwardCommand,
        center.seekBackwardCommand,
        center.skipForwardCommand,
        center.skipBackwardCommand,
        center.changePlaybackRateCommand,
        center.ratingCommand,
        center.likeCommand,
        center.dislikeCommand,
        center.bookmarkCommand,
    ];
    for (MPRemoteCommand *command in unsupported) {
        command.enabled = NO;
    }
}

- (void)updateShuffleEnabled:(BOOL)shuffleEnabled repeatMode:(VibeRepeatMode)repeatMode {
    if (!_commandsRegistered) {
        return;
    }
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    center.changeShuffleModeCommand.currentShuffleType = shuffleEnabled ? MPShuffleTypeItems : MPShuffleTypeOff;
    center.changeRepeatModeCommand.currentRepeatType = (MPRepeatType)repeatMode;
}

#pragma mark - Now Playing info

- (void)updateWithTrack:(AudioTrack *)track
         placeholderArt:(VibeImage *)placeholderArt
               position:(NSTimeInterval)position
               duration:(NSTimeInterval)duration
                  state:(NowPlayingPlaybackState)state
                   rate:(double)rate
                hasNext:(BOOL)hasNext
            hasPrevious:(BOOL)hasPrevious {
#if DEBUG
    if (_suppressed) {
        return;
    }
#endif
    // Before the first publish too: enabling a command claims nothing.
    if (hasNext != _publishedHasNext || hasPrevious != _publishedHasPrevious) {
        _commandAvailability(hasNext, hasPrevious);
        _publishedHasNext = hasNext;
        _publishedHasPrevious = hasPrevious;
    }

    if (!_hasPublished && state != NowPlayingPlaybackStatePlaying) {
        return;
    }

    if (!track) {
        if (_publishedSource == nil) {
            return;
        }
        _publish(nil, NowPlayingPlaybackStateStopped);
        _publishedSource = nil;
        _publishedArtworkImage = nil;
        _publishedArtworkWrapper = nil;
        return;
    }

    NSString *title = track.displayTitle ?: @"";
    NSString *artist = track.displayArtist;
    // Non-blocking. The thumbnail covers the gap until full art decodes, or
    // the card would show the placeholder beside a window showing a cover;
    // the identity check promotes whichever arrives. The placeholder must
    // already match the app's appearance: the drawing appearance here is the
    // system's.
    VibeImage *artwork = track.cachedArt ?: track.cachedThumbnail ?: placeholderArt;

    if (_publishedSource != nil) {
        BOOL unchanged = [_publishedSource isEqualToString:track.sourceKey]
                && [title isEqualToString:_publishedTitle]
                && VibeNowPlayingStringsEqual(artist, _publishedArtist)
                && state == _publishedState
                && rate == _publishedRate
                && duration == _publishedDuration
                && artwork == _publishedArtworkImage
                && !VibeNowPlayingPositionIsDirty(_publishedPosition, _publishedAt, _publishedRate,
                                                  _publishedState == NowPlayingPlaybackStatePlaying,
                                                  position, _clock(),
                                                  kVibeNowPlayingRepublishTolerance);
        if (unchanged) {
            return;
        }
    }

    NSMutableDictionary<NSString *, id> *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = title;
    if (artist) {
        info[MPMediaItemPropertyArtist] = artist;
    }
    if (duration > 0) {
        info[MPMediaItemPropertyPlaybackDuration] = @(duration);
    }
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(MAX(0.0, position));
    // How fast `position` advances in real time; 0 freezes the system's
    // interpolation.
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(state == NowPlayingPlaybackStatePlaying ? rate : 0.0);
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @(1.0);

    if (artwork) {
        if (artwork != _publishedArtworkImage || _publishedArtworkWrapper == nil) {
            // The handler draws nothing (VibeArtworkForPublishing): the same
            // image at any requested size, and boundsSize says what it is.
            VibeImage *published = VibeArtworkForPublishing(artwork);
            if (published) {
                _publishedArtworkWrapper =
                    [[MPMediaItemArtwork alloc] initWithBoundsSize:published.size
                                                    requestHandler:^VibeImage *(CGSize size) {
                                                        return published;
                                                    }];
            }
            else {
                _publishedArtworkWrapper = nil;
            }
        }
        if (_publishedArtworkWrapper) {
            info[MPMediaItemPropertyArtwork] = _publishedArtworkWrapper;
        }
    }
    else {
        _publishedArtworkWrapper = nil;
    }
    // A failed rasterization is retryable on the next publish pass.
    _publishedArtworkImage = _publishedArtworkWrapper ? artwork : nil;

    _publish(info, state);
    _hasPublished = YES;
    _publishedSource = track.sourceKey;
    _publishedTitle = title;
    _publishedArtist = artist;
    _publishedState = state;
    _publishedRate = rate;
    _publishedDuration = duration;
    _publishedPosition = position;
    _publishedAt = _clock();
}

@end

#if DEBUG
#import "NowPlayingController+Debug.h"

@implementation NowPlayingController (Debug)

- (VibeImage *)debugPublishedArtwork {
    return _publishedArtworkImage;
}

@end
#endif

