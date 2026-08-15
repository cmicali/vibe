//
//  MainPlayerController+Delivery.m
//  Vibe
//

#import "MainPlayerController+Delivery.h"
#import "MainPlayerControllerInternal.h"

#import "AudioPlayer.h"
#import "AudioPlayer+Seek.h"
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
    [self.trackDisplay showWaveform:waveform];
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectBPM:(float)bpm forURL:(NSURL *)url {
    // A delivery usually belongs to the current track, but a late one can land
    // after next: has advanced the playlist, and the same file can occupy more
    // than one row. The BPM is valid for every track owning that URL — the
    // first match alone would strand a duplicate row that happens to be the
    // one playing — so stamp them all, and refresh the label only when one of
    // them is on display.
    __block BOOL refresh = NO;
    [[self.playlistController indexesOfTracksWithURL:url]
            enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        AudioTrack *track = [self.playlistController trackAtIndex:index];
        track.detectedBPM = bpm;
        refresh |= [self.playlistController isCurrentTrack:track];
    }];
    if (refresh) {
        [self effectiveTempoDidChange];
    }
}

- (void)audioWaveformCache:(AudioWaveformCache *)cache didDetectKey:(NSInteger)key forURL:(NSURL *)url {
    // Same late-delivery and duplicate-row contract as didDetectBPM: above.
    __block BOOL refresh = NO;
    [[self.playlistController indexesOfTracksWithURL:url]
            enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        AudioTrack *track = [self.playlistController trackAtIndex:index];
        track.detectedKey = key;
        refresh |= [self.playlistController isCurrentTrack:track];
    }];
    if (refresh) {
        [self effectiveTempoDidChange];
    }
}

@end
