//
//  NowPlayingController.m
//  Vibe
//

#import "NowPlayingController.h"
#import "AudioTrack.h"
#import <MediaPlayer/MediaPlayer.h>

@implementation NowPlayingController {
    __weak id<NowPlayingControllerDelegate> _delegate;
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
- (void)registerCommands {
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    __weak NowPlayingController *weakSelf = self;

    center.playCommand.enabled = YES;
    [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        [strongSelf->_delegate nowPlayingControllerPlay:strongSelf];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    center.pauseCommand.enabled = YES;
    [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        [strongSelf->_delegate nowPlayingControllerPause:strongSelf];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    center.togglePlayPauseCommand.enabled = YES;
    [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        [strongSelf->_delegate nowPlayingControllerTogglePlayPause:strongSelf];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    center.nextTrackCommand.enabled = YES;
    [center.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        [strongSelf->_delegate nowPlayingControllerNextTrack:strongSelf];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    center.previousTrackCommand.enabled = YES;
    [center.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
        [strongSelf->_delegate nowPlayingControllerPreviousTrack:strongSelf];
        return MPRemoteCommandHandlerStatusSuccess;
    }];

    center.changePlaybackPositionCommand.enabled = YES;
    [center.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        NowPlayingController *strongSelf = weakSelf;
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
                   rate:(double)rate {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];

    if (!track) {
        center.nowPlayingInfo = nil;
        center.playbackState = MPNowPlayingPlaybackStateStopped;
        return;
    }

    NSMutableDictionary<NSString *, id> *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = track.title ?: @"";
    if (track.artist.length > 0) {
        info[MPMediaItemPropertyArtist] = track.artist;
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

    // albumArt is the already-decoded image or nil — never blocks (no file
    // read, no decode). When it's still nil the caller refreshes once art
    // resolves, so the card fills in a moment later rather than stalling here.
    NSImage *artwork = track.albumArt;
    if (artwork) {
        info[MPMediaItemPropertyArtwork] =
            [[MPMediaItemArtwork alloc] initWithBoundsSize:artwork.size
                                            requestHandler:^NSImage *(CGSize size) {
                                                return artwork;
                                            }];
    }

    center.nowPlayingInfo = info;
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
