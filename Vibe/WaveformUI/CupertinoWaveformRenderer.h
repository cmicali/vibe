//
//  CupertinoWaveformRenderer.h
//  Vibe
//

#import "AudioWaveformRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// The Apple Music pill: a rounded-capsule track with a continuous played
// fill. The one style that never reads the waveform's samples — the geometry
// is the scrubber, not the envelope — so it sits outside the morph engine,
// the convert sweep has nothing here to dip, and having a waveform at all
// only decides whether the pill shows.
@interface CupertinoWaveformRenderer : AudioWaveformRenderer

@end

NS_ASSUME_NONNULL_END
