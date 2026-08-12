//
//  NowPlayingController.m
//  Vibe
//

#import "NowPlayingController.h"
#import "AudioTrack.h"
#import "NowPlayingMath.h"
#import <MediaPlayer/MediaPlayer.h>

@implementation NowPlayingController {
    __weak id<NowPlayingControllerDelegate> _delegate;

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
        [self registerCommands];
    }
    return self;
}

#pragma mark - Remote commands

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
        [strongSelf->_delegate nowPlayingControllerPlay:strongSelf];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    center.pauseCommand.enabled = YES;
    [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        [strongSelf->_delegate nowPlayingControllerPause:strongSelf];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    center.togglePlayPauseCommand.enabled = YES;
    [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        [strongSelf->_delegate nowPlayingControllerTogglePlayPause:strongSelf];
        return MPRemoteCommandHandlerStatusSuccess;
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
        [strongSelf->_delegate nowPlayingControllerNextTrack:strongSelf];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    center.previousTrackCommand.enabled = YES;
    _publishedHasPrevious = YES;
    [center.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        [strongSelf->_delegate nowPlayingControllerPreviousTrack:strongSelf];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    center.changePlaybackPositionCommand.enabled = YES;
    [center.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        if (!strongSelf) {
            return MPRemoteCommandHandlerStatusCommandFailed;
        }
        MPChangePlaybackPositionCommandEvent *positionEvent = (MPChangePlaybackPositionCommandEvent *)event;
        [strongSelf->_delegate nowPlayingController:strongSelf seekToPosition:positionEvent.positionTime];
        return MPRemoteCommandHandlerStatusSuccess;
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
    // albumArt is the already-decoded image, or nil, and never blocks: it does
    // no file read and no decode. While it is still nil the caller refreshes
    // once the art resolves, so the card fills in a moment later rather than
    // stalling here.
    VibeImage *artwork = track.albumArt;

    // The elapsed time is never republished at 3 Hz, because the system
    // extrapolates it from the last publish at the published rate. Natural
    // advance since that publish must therefore not count as dirty; the rule
    // is VibeNowPlayingPositionIsDirty in NowPlayingMath.h.
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
            _publishedArtworkWrapper =
                [[MPMediaItemArtwork alloc] initWithBoundsSize:artwork.size
                                                requestHandler:^VibeImage *(CGSize size) {
                                                    return artwork;
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
