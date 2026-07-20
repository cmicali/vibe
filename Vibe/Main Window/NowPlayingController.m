//
//  NowPlayingController.m
//  Vibe
//

#import "NowPlayingController.h"
#import "AudioTrack.h"
#import <MediaPlayer/MediaPlayer.h>

// A published position more than this far from what the system's own
// extrapolation predicts is a jump (seek, pitch rescale) and must be
// republished; anything inside it is natural playback advance, which the
// system tracks without a republish.
static const NSTimeInterval kPositionRepublishTolerance = 1.0;

@implementation NowPlayingController {
    __weak id<NowPlayingControllerDelegate> _delegate;

    // Vibe must not claim the system Now Playing slot at launch: updateUI
    // runs (with no track) before anything has played, and publishing even a
    // cleared state would evict the user's current Now Playing app.
    BOOL _hasPublished;

    // Last-published snapshot for the dirty check in updateWithTrack:...
    // (updateUI runs several times back-to-back on a track transition; only
    // the first pass with new content should touch MPNowPlayingInfoCenter).
    // _publishedURL nil means cleared (or never published).
    NSString *_publishedURL;
    NSString *_publishedTitle;
    NSString *_publishedArtist;
    NowPlayingPlaybackState _publishedState;
    double _publishedRate;
    NSTimeInterval _publishedDuration;
    NSTimeInterval _publishedPosition;
    CFAbsoluteTime _publishedAt;

    // Last-applied command availability (registerCommands enables both), so
    // the MPRemoteCommand .enabled properties are only written on change.
    BOOL _publishedHasNext;
    BOOL _publishedHasPrevious;

    // The MPMediaItemArtwork wrapper is reused as long as the caller hands
    // back the same decoded NSImage; the wrapper's request handler retains
    // the image either way, so caching it here adds no lifetime.
    NSImage *_publishedArtworkImage;
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

// Enable the transport commands we implement (this is what routes the hardware
// media keys, Control Center, and Bluetooth remotes to us) and disable the
// rest so the system doesn't offer controls we can't service.
// The handler blocks are retained process-wide by MPRemoteCommandCenter, so
// each one must tolerate outliving this controller: the strongSelf nil checks
// are load-bearing (`nil->_delegate` is a NULL+offset dereference, not a
// harmless nil-message send).
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

    // Enabled here so a command is never registered-but-dead; every
    // updateWithTrack: retracks them against the playlist boundaries.
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

    // Commands the app doesn't model — keep them off so the transport UI shows
    // only the controls we handle.
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

    // Applied before every early return below: command availability tracks
    // the playlist boundaries even when the now-playing info itself is
    // unchanged (or not yet published).
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
        // Silent until the first track plays (see _hasPublished); after that,
        // a nil track clears the published state exactly once.
        if (!_hasPublished || _publishedURL == nil) {
            return;
        }
        center.nowPlayingInfo = nil;
        center.playbackState = MPNowPlayingPlaybackStateStopped;
        _publishedURL = nil;
        _publishedArtworkImage = nil;
        _publishedArtworkWrapper = nil;
        return;
    }

    // Same string the in-app header shows for an untagged file — cleaned-up
    // filename, not the raw title-with-extension.
    NSString *title = track.singleLineTitle ?: @"";
    NSString *artist = track.artist.length > 0 ? track.artist : nil;
    // albumArt is the already-decoded image or nil — never blocks (no file
    // read, no decode). When it's still nil the caller refreshes once art
    // resolves, so the card fills in a moment later rather than stalling here.
    NSImage *artwork = track.albumArt;

    // Elapsed time is never republished at 3 Hz — the system extrapolates it
    // from the last publish at the published rate — so natural advance since
    // that publish must not count as dirty. Compare against the same
    // extrapolation the system runs: only a jump beyond it (seek, pitch
    // rescale) forces a republish.
    if (_publishedURL != nil) {
        double extrapolationRate = _publishedState == NowPlayingPlaybackStatePlaying ? _publishedRate : 0.0;
        NSTimeInterval predicted = _publishedPosition + (CFAbsoluteTimeGetCurrent() - _publishedAt) * extrapolationRate;
        BOOL unchanged = [_publishedURL isEqualToString:track.url.absoluteString]
                && [title isEqualToString:_publishedTitle]
                && (artist == _publishedArtist || [artist isEqualToString:_publishedArtist])
                && state == _publishedState
                && rate == _publishedRate
                && duration == _publishedDuration
                && artwork == _publishedArtworkImage
                && fabs(position - predicted) <= kPositionRepublishTolerance;
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
    // Rate is how fast `position` advances in real time — it drives the
    // system's between-update interpolation of the progress bar, and 0 (paused
    // or stopped) freezes it. The caller chooses position's time base and the
    // matching rate (Vibe reports wall-clock time, which advances at 1x).
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(state == NowPlayingPlaybackStatePlaying ? rate : 0.0);
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @(1.0);

    if (artwork) {
        if (artwork != _publishedArtworkImage || _publishedArtworkWrapper == nil) {
            _publishedArtworkWrapper =
                [[MPMediaItemArtwork alloc] initWithBoundsSize:artwork.size
                                                requestHandler:^NSImage *(CGSize size) {
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
}

@end
