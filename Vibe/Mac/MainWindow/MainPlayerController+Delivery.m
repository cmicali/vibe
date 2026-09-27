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

// The progressive snapshots and the final waveform, on the main thread. The
// view simply renders what it is handed. The cache filters out cancelled
// loads, but it cancels only when the next load starts, at didStartPlaying:,
// so between a slow track's didBeginLoading: and its start the outgoing
// decode is still streaming: without the match its waveform would draw under
// the new track's loading shimmer.
- (void)audioWaveform:(CodableAudioWaveform *)waveform
          didLoadData:(float)percentLoaded
               forURL:(NSURL *)url {
    if (![[self.playlistController currentTrack].url isEqual:url]) {
        return;
    }
    // The URL match alone is not enough: a hard mid-play error masks the
    // still-current track behind the error placeholder, and a late snapshot of
    // that same track must not repaint over it. Same resolution the header
    // renders through; a retry's didBeginLoading: clears the mask first.
    if ([self displayState] == TrackDisplayStateError) {
        return;
    }
    [self.trackDisplay showWaveform:waveform];
}

// A delivery usually belongs to the current track, but a late one can land
// after next: has advanced the playlist, so the playlist stamps every row
// holding the URL and says whether one of them is on display, which is when
// the label refreshes. The BPM and the key share the label line, so both
// refresh through effectiveTempoDidChange.
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
