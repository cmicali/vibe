//
//  CupertinoWaveformRenderer.h
//  Vibe
//

#import "AudioWaveformRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// The Apple Music pill: a rounded-capsule track with a continuous played
// fill. The one style that ignores the waveform's samples entirely — the
// geometry is the scrubber, not the envelope — so it sits outside the morph
// engine, and the convert sweep has nothing here to dip.
@interface CupertinoWaveformRenderer : AudioWaveformRenderer

@end

NS_ASSUME_NONNULL_END
