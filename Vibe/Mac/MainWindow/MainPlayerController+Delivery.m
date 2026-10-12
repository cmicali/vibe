//
//  MainPlayerController+Delivery.m
//  Vibe
//

#import "MainPlayerController+Delivery.h"
#import "MainPlayerControllerInternal.h"

#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "PlaylistController.h"
#import "TrackDisplayController.h"
#import "MainPlayerContentView.h"

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

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage {
    [self.audioPlayer seekToPosition:self.audioPlayer.duration * percentage];
}

- (void)audioWaveformViewDidResolveTheme:(AudioWaveformView *)waveformView {
    [self.playerContentView applyVolumeColors];
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

@end
