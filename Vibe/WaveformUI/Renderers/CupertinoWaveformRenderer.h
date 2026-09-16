//
//  CupertinoWaveformRenderer.h
//  Vibe
//

#import "BasicAudioWaveformRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// The two Apple looks, one file, the way the oversampling variants share
// theirs.

// Cupertino: the Apple Podcasts waveform — one-point bars at Basic's pitch,
// each mirrored about the midline at its energy level. Basic's block
// quantization is the point of the inheritance: a bar a point wide is a
// device pixel or two, so a continuous fill or a thin hover column would
// light a pixel of one or nothing, and both advance a whole bar at a time.
// Only the bar width, the envelope and the ramp are its own.
@interface CupertinoWaveformRenderer : BasicAudioWaveformRenderer

@end

// Cupertino Basic: the Apple Music pill, a rounded-capsule track with a
// continuous played fill. The one style that never reads the waveform's
// samples — the geometry is the scrubber, not the envelope — so it sits
// outside the morph engine, the convert sweep has nothing here to dip, and
// having a waveform at all only decides whether the pill shows.
@interface CupertinoBasicWaveformRenderer : AudioWaveformRenderer

@end

NS_ASSUME_NONNULL_END
