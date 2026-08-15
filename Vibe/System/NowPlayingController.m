//
//  NowPlayingController.m
//  Vibe
//

#import "NowPlayingController.h"
#import "AudioTrack.h"
#import "NowPlayingRules.h"
#import <MediaPlayer/MediaPlayer.h>
#if TARGET_OS_OSX
#import "NSImage+Util.h"
#endif

// Whatever the artwork request handler returns is serialized to the media
// daemon, so handing back the full 1024px original ships megabytes on every
// publish and the card visibly fills in after the window has. This is the side
// the system actually draws — Control Center, the lock screen, the mini player
// — with room to spare.

// TRAP: this must run on the main thread, and its result must be the ONLY
// thing the request handler hands back. The handler is invoked on the media
// daemon's threads, and `artwork` is the live NSImage the header, the dock
// tile and the playlist cells are drawing from — NSImage is not safe to draw
// concurrently from two threads, so scaling inside the handler races the UI.
// Scaling once, here, also costs one redraw per track rather than one per
// surface the system asks about.
static VibeImage *VibeArtworkForPublishing(VibeImage *artwork) {
#if TARGET_OS_OSX
    static const CGFloat kPublishedArtworkMaxSide = 512;
    CGSize source = artwork.size;
    if (source.width <= 0 || source.height <= 0) {
        return artwork;
    }
    CGFloat scale = MIN(kPublishedArtworkMaxSide / source.width,
                        kPublishedArtworkMaxSide / source.height);
    // Already small enough — the 128px thumbnail stand-in takes this path.
    if (scale >= 1.0) {
        return artwork;
    }
    // Aspect preserved, so a non-square cover is not stretched. A failed
    // redraw falls back to the original: oversized beats artwork-less.
    return [artwork resizedImage:NSMakeSize(round(source.width * scale),
                                            round(source.height * scale))] ?: artwork;
#else
    return artwork;
#endif
}

@implementation NowPlayingController {
    __weak id<NowPlayingControllerDelegate> _delegate;
#if DEBUG
    // --no-audio-hw: publish nothing to the system. See the initializer.
    BOOL _suppressed;
#endif

    // Vibe must not claim the system Now Playing slot at launch. updateUI runs
    // with no track before anything has played, and publishing even a cleared
    // state would evict the user's current Now Playing app.
    BOOL _hasPublished;

    // The last published snapshot, for the dirty check in updateWithTrack:....
    // updateUI runs several times back to back on a track transition, and only
    // the first pass with new content should touch MPNowPlayingInfoCenter. A
    // nil _publishedURL means cleared, or never published.
    NSString *_publishedURL;
    NSString *_publishedTitle;
    NSString *_publishedArtist;
    NowPlayingPlaybackState _publishedState;
    double _publishedRate;
    NSTimeInterval _publishedDuration;
    NSTimeInterval _publishedPosition;
    CFAbsoluteTime _publishedAt;

    // The last applied command availability, which registerCommands enables
    // for both, so that the MPRemoteCommand .enabled properties are written
    // only on a change.
    BOOL _publishedHasNext;
    BOOL _publishedHasPrevious;

    // The MPMediaItemArtwork wrapper is reused for as long as the caller hands
    // back the same decoded image. The wrapper's request handler retains the
    // image either way, so caching it here adds no lifetime.
    VibeImage *_publishedArtworkImage;
    MPMediaItemArtwork *_publishedArtworkWrapper;
}

- (instancetype)initWithDelegate:(id<NowPlayingControllerDelegate>)delegate {
    self = [super init];
    if (self) {
        _delegate = delegate;
#if DEBUG
        // --no-audio-hw exists so a test run leaves the system's audio
        // routing alone, and publishing Now Playing defeats that on its own:
        // registering as the active media app is enough for macOS to pull
        // auto-switching AirPods over from another device, with no output
        // device ever opened. Suppressing the publish keeps the flag's
        // promise. Testing Now Playing itself therefore needs a launch
        // without it (VIBE_AUDIBLE=1 for launch.sh).
        _suppressed = [NSProcessInfo.processInfo.arguments containsObject:@"--no-audio-hw"];
        if (_suppressed) {
            LogInfo(@"NowPlayingController: --no-audio-hw, system Now Playing not published");
            return self;
        }
#endif
        [self registerCommands];
    }
    return self;
}

#pragma mark - Remote commands

// MediaPlayer does not document a delivery queue for command handlers.
// Capture the weak delegate while the command is accepted, then put every
// controller/UI mutation behind the main queue contract.
- (MPRemoteCommandHandlerStatus)deliverRemoteCommand:
        (void (^)(id<NowPlayingControllerDelegate> delegate))delivery {
    id<NowPlayingControllerDelegate> delegate = _delegate;
    if (!delegate) {
        return MPRemoteCommandHandlerStatusCommandFailed;
    }
    if (NSThread.isMainThread) {
        delivery(delegate);
    }
    else {
        dispatch_async(dispatch_get_main_queue(), ^{
            delivery(delegate);
        });
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

// Enables the transport commands we implement, which is what routes the
// hardware media keys, Control Center and Bluetooth remotes to us, and
// disables the rest, so that the system does not offer controls we cannot
// service.
//
// MPRemoteCommandCenter retains the handler blocks process-wide, so each one
// must tolerate outliving this controller. The strongSelf nil checks are
// load-bearing: `nil->_delegate` is a NULL-plus-offset dereference, not a
// harmless nil-message send.
- (void)registerCommands {
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    __weak NowPlayingController *weakSelf = self;

    center.playCommand.enabled = YES;
    [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        return [strongSelf deliverRemoteCommand:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingControllerPlay:strongSelf];
        }];
    }];

    center.pauseCommand.enabled = YES;
    [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        return [strongSelf deliverRemoteCommand:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingControllerPause:strongSelf];
        }];
    }];

    center.togglePlayPauseCommand.enabled = YES;
    [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        return [strongSelf deliverRemoteCommand:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingControllerTogglePlayPause:strongSelf];
        }];
    }];

    // Enabled here, so that a command is never registered but dead. Every
    // updateWithTrack: re-tracks them against the playlist boundaries.
    center.nextTrackCommand.enabled = YES;
    _publishedHasNext = YES;
    [center.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        return [strongSelf deliverRemoteCommand:^(id<NowPlayingControllerDelegate> delegate) {
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
        return [strongSelf deliverRemoteCommand:^(id<NowPlayingControllerDelegate> delegate) {
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
        return [strongSelf deliverRemoteCommand:^(id<NowPlayingControllerDelegate> delegate) {
            [delegate nowPlayingController:strongSelf seekToPosition:position];
        }];
    }];

    // Commands the app does not model. Keep them off, so that the transport UI
    // shows only the controls we handle.
    NSArray<MPRemoteCommand *> *unsupported = @[
        center.stopCommand,
        center.seekForwardCommand,
        center.seekBackwardCommand,
        center.skipForwardCommand,
        center.skipBackwardCommand,
        center.changeRepeatModeCommand,
        center.changeShuffleModeCommand,
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

#pragma mark - Now Playing info

- (void)updateWithTrack:(AudioTrack *)track
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
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];

    // Applied before every early return below, so that command availability
    // tracks the playlist boundaries even when the now-playing info itself is
    // unchanged, or not yet published.
    MPRemoteCommandCenter *commands = [MPRemoteCommandCenter sharedCommandCenter];
    if (hasNext != _publishedHasNext) {
        commands.nextTrackCommand.enabled = hasNext;
        _publishedHasNext = hasNext;
    }
    if (hasPrevious != _publishedHasPrevious) {
        commands.previousTrackCommand.enabled = hasPrevious;
        _publishedHasPrevious = hasPrevious;
    }

    if (!track) {
        // Silent until the first track plays; see _hasPublished. After that, a
        // nil track clears the published state exactly once.
        if (!_hasPublished || _publishedURL == nil) {
            return;
        }
        center.nowPlayingInfo = nil;
#if TARGET_OS_OSX
        // playbackState is macOS-only; iOS derives it from the audio session
        // and the published rate.
        center.playbackState = MPNowPlayingPlaybackStateStopped;
#endif
        _publishedURL = nil;
        _publishedArtworkImage = nil;
        _publishedArtworkWrapper = nil;
        return;
    }

    // The same string the in-app header shows for an untagged file: the
    // cleaned-up filename, not the raw title with its extension.
    NSString *title = track.singleLineTitle ?: @"";
    NSString *artist = track.artist.length > 0 ? track.artist : nil;
    // cachedArt is the already-decoded image, or nil, and never blocks: it does
    // no file read and no decode. While it is still nil the caller refreshes
    // once the art resolves, so the card fills in a moment later rather than
    // stalling here.
    //
    // The 128px thumbnail stands in for that gap. It is decoded on the metadata
    // worker before the track publishes — a whole background round trip ahead
    // of the full-resolution art, which re-reads the audio file — and reading
    // it here never blocks either, since it decodes only from bytes already in
    // memory. Without it the card shows the app icon while the window shows a
    // cover, which reads as Now Playing lagging the app when both are in fact
    // published in the same pass. The identity check below promotes the full
    // art the moment it lands.
    VibeImage *artwork = track.cachedArt ?: track.cachedThumbnail;

    // The elapsed time is never republished at 3 Hz, because the system
    // extrapolates it from the last publish at the published rate. Natural
    // advance since that publish must therefore not count as dirty; the rule
    // is VibeNowPlayingPositionIsDirty in NowPlayingRules.h.
    if (_publishedURL != nil) {
        BOOL unchanged = [_publishedURL isEqualToString:track.url.absoluteString]
                && [title isEqualToString:_publishedTitle]
                && (artist == _publishedArtist || [artist isEqualToString:_publishedArtist])
                && state == _publishedState
                && rate == _publishedRate
                && duration == _publishedDuration
                && artwork == _publishedArtworkImage
                && !VibeNowPlayingPositionIsDirty(_publishedPosition, _publishedAt, _publishedRate,
                                                  _publishedState == NowPlayingPlaybackStatePlaying,
                                                  position, CFAbsoluteTimeGetCurrent(),
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
    // The rate is how fast `position` advances in real time. It drives the
    // system's between-update interpolation of the progress bar, and 0, when
    // paused or stopped, freezes it. The caller chooses position's time base
    // and the matching rate; Vibe reports wall-clock time, which advances at
    // 1x.
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(state == NowPlayingPlaybackStatePlaying ? rate : 0.0);
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @(1.0);

    if (artwork) {
        if (artwork != _publishedArtworkImage || _publishedArtworkWrapper == nil) {
            // Scaled once, here on the main thread, and captured. The handler
            // itself must do no drawing — see VibeArtworkForPublishing — so it
            // returns the same image whatever size the system asks for, which
            // MediaPlayer scales on its side. boundsSize advertises what that
            // image actually is, so nothing asks for more than exists.
            VibeImage *published = VibeArtworkForPublishing(artwork);
            _publishedArtworkWrapper =
                [[MPMediaItemArtwork alloc] initWithBoundsSize:published.size
                                                requestHandler:^VibeImage *(CGSize size) {
                                                    return published;
                                                }];
        }
        info[MPMediaItemPropertyArtwork] = _publishedArtworkWrapper;
    }
    else {
        _publishedArtworkWrapper = nil;
    }
    _publishedArtworkImage = artwork;

    center.nowPlayingInfo = info;
    _hasPublished = YES;
    _publishedURL = track.url.absoluteString ?: @"";
    _publishedTitle = title;
    _publishedArtist = artist;
    _publishedState = state;
    _publishedRate = rate;
    _publishedDuration = duration;
    _publishedPosition = position;
    _publishedAt = CFAbsoluteTimeGetCurrent();
#if TARGET_OS_OSX
    switch (state) {
        case NowPlayingPlaybackStatePlaying:
            center.playbackState = MPNowPlayingPlaybackStatePlaying;
            break;
        case NowPlayingPlaybackStatePaused:
            center.playbackState = MPNowPlayingPlaybackStatePaused;
            break;
        case NowPlayingPlaybackStateStopped:
            center.playbackState = MPNowPlayingPlaybackStateStopped;
            break;
    }
#endif
}

@end
