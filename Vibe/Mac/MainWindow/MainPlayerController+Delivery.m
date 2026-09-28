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

- (void)audioWaveformView:(AudioWaveformView *)waveformView didResolvePlayedColor:(NSColor *)color {
    [self.playerContentView applyVolumeTint];
}

// The cache cancels only when the next load starts, so between a slow track's
// didBeginLoading: and its start the outgoing decode still streams; unmatched,
// it would draw under the new track's shimmer.
- (void)audioWaveform:(CodableAudioWaveform *)waveform
          didLoadData:(float)percentLoaded
               forURL:(NSURL *)url {
    if (![[self.playlistController currentTrack].url isEqual:url]) {
        return;
    }
    // Not the URL alone: a late snapshot must not repaint over the error
    // state of the same, still-current track.
    if ([self displayState] == TrackDisplayStateError) {
        return;
    }
    [self.trackDisplay showWaveform:waveform];
}

// A late delivery can land after next: has advanced the playlist; the playlist
// stamps every row holding the URL and says whether one is on display. The
// BPM and the key share the label line, so both refresh here.
- (void)stampTracksWithURL:(NSURL *)url usingBlock:(void (NS_NOESCAPE ^)(AudioTrack *track))stamp {
    if ([self.playlistController stampTracksWithURL:url usingBlock:stamp]) {
        [self effectiveTempoDidChange];
    }
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forURL:(NSURL *)url {
    [self stampTracksWithURL:url usingBlock:^(AudioTrack *track) {
        track.detectedBPM = bpm;
    }];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectKey:(NSInteger)key forURL:(NSURL *)url {
    [self stampTracksWithURL:url usingBlock:^(AudioTrack *track) {
        track.detectedKey = key;
    }];
}

@end
