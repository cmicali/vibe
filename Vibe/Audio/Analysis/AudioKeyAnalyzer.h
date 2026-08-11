//
//  AudioKeyAnalyzer.h
//  Vibe
//
//  A streaming musical-key estimator fed by the waveform loader's decode
//  pass, exactly like AudioBPMAnalyzer, so key detection never costs a second
//  full-file read. Feed it mono float32 buffers in file order, then call
//  finish once at end of file.
//
//  The method: a chromagram accumulates during streaming — a vDSP FFT over
//  ~0.75-second Hann frames at a half-frame hop, each bin's magnitude folded
//  onto the pitch class of its nearest semitone within the 55–3520 Hz band,
//  each frame normalized to one vote. finish() correlates the accumulated 12-bin
//  chroma against the 24 rotations of a major and a minor key profile
//  (Sha'ath's EDM-tuned revision of the Krumhansl-Schmuckler profiles) and
//  returns the best-correlated key, or VibeMusicalKeyNone when the best
//  correlation is too weak to trust — percussion, noise, speech, or heavy
//  atonality.
//

#import <Foundation/Foundation.h>
#import "MusicalKey.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioKeyAnalyzer : NSObject

- (instancetype)initWithSampleRate:(double)sampleRate;

// Mono float32; see AudioWaveformMonoMix. Any frame count per call.
- (void)appendMonoSamples:(const float *)samples frameCount:(NSUInteger)frameCount;

// The estimated key, or VibeMusicalKeyNone if undetectable. Call it once,
// after every sample has been fed in.
- (VibeMusicalKey)finish;

// Diagnostic, valid after finish: the magnitude-weighted mean distance of the
// analyzed content from equal temperament, in cents. A track produced at
// A=440 sits near 0; a large offset means the chroma is being folded onto the
// wrong semitones and the key estimate is unreliable. Measured before
// deciding whether per-track tuning correction is worth building — see
// Audio/CLAUDE.md.
@property (readonly) double tuningCents;

@end

NS_ASSUME_NONNULL_END
