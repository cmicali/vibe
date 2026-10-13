//
//  MainPlayerController+Delivery.m
//  Vibe
//

#import "MainPlayerController+Delivery.h"
#import "MainPlayerControllerInternal.h"

#import "AudioTrack.h"
#import "PlaylistController.h"
#import "TrackDisplayController.h"
#import "FolderArtResolver.h"

@implementation MainPlayerController (Delivery)

- (void)didLoadMetadata:(AudioTrack *)track {
    if ([self.playlistController isCurrentTrack:track]) {
        _lastReloadedTrack = nil;
        [self updateUI];
    }
    else {
        [self.playlistController reloadTrack:track];
    }
}

// The cache cancels only when the next load starts, so between a slow track's
// didBeginLoading: and its start the outgoing decode still streams; unmatched,
// it would draw under the new track's shimmer.
- (void)audioWaveform:(CodableAudioWaveform *)waveform
          didLoadData:(float)percentLoaded
             forTrack:(AudioTrack *)track {
    // By sourceKey: another row of the same file has a waveform of its own.
    if (![[self.playlistController currentTrack].sourceKey isEqualToString:track.sourceKey]) {
        return;
    }
    // Not the source alone: a late snapshot must not repaint over the error
    // state of the same, still-current track, or over a notice.
    TrackDisplayState header = [self headerState];
    if (header == TrackDisplayStateError || header == TrackDisplayStateNotice) {
        return;
    }
    [self.trackDisplay showWaveform:waveform];
}

// A late delivery can land after next: has advanced the playlist; the playlist
// stamps every row sounding the analyzed track and says whether one is on
// display. The BPM and the key share the label line, so both refresh here.
- (void)stampTracksSounding:(AudioTrack *)analyzed usingBlock:(void (NS_NOESCAPE ^)(AudioTrack *track))stamp {
    if ([self.playlistController stampTracksSounding:analyzed usingBlock:stamp]) {
        [self effectiveTempoDidChange];
    }
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forTrack:(AudioTrack *)analyzed {
    [self stampTracksSounding:analyzed usingBlock:^(AudioTrack *track) {
        track.detectedBPM = bpm;
    }];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectKey:(NSInteger)key forTrack:(AudioTrack *)analyzed {
    [self stampTracksSounding:analyzed usingBlock:^(AudioTrack *track) {
        track.detectedKey = key;
    }];
}

#pragma mark - Grants, folder art and thumbnails

// Forgets no-grant answers only; a known cover rechecks access on every read.
// A full wipe would discard the covers an open's walk just harvested, since the
// open's own grant lands a moment later.
- (void)grantedFoldersDidChange:(NSNotification *)notification {
    [FolderArtResolver.sharedInstance invalidateDirectoriesSettledWithoutGrant];
    [self.playlistController reloadAllTracks];
    [self updateUI];
}

- (void)thumbnailDidLoad:(NSNotification *)notification {
    AudioTrack *displayed = [self displayedTrack];
    if (displayed.metadata == notification.object) {
        [self updateUI];
    }
}

// Fired for "none" as well as a cover: the header holds the previous art until
// it hears. The resolver is serial, so consecutive folders land in different
// turns; a short delay coalesces where a per-turn gate would not.
static const NSTimeInterval kFolderArtRedrawDelay = 0.15;

- (void)folderArtDidResolve:(NSNotification *)notification {
    if (_folderArtRefreshScheduled) {
        return;
    }
    _folderArtRefreshScheduled = YES;
    __weak MainPlayerController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFolderArtRedrawDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        MainPlayerController *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_folderArtRefreshScheduled = NO;
        [strongSelf.playlistController reloadVisibleTracks];
        [strongSelf updateUI];
    });
}

@end
