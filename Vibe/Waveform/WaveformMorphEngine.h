//
//  WaveformMorphEngine.h
//  Vibe
//

#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>

#include <vector>

NS_ASSUME_NONNULL_BEGIN

// The morph engine shared by both renderer families: owns the
// displayed/target/scratch sample vectors and the 60Hz easing timer, and runs
// the retarget decision tree — renderers keep only what differs (building a
// target from the waveform, turning displayed samples into layer geometry).
// Extracted because the two copies were ~90 near-identical lines, the classic
// silently-diverging pair.
//
// C++ types in this header: import from .mm renderers only.
//
// Easing: exponential approach toward the target, settling (~95%) in ~3τ ≈
// 0.2s. Unlike a keyframed from→to animation it retargets seamlessly — a new
// target mid-morph just bends the in-flight motion. Sample units are the
// renderer's own; the convergence epsilon is well under a device pixel in
// both.
@interface WaveformMorphEngine : NSObject

// vscale maps view height to the caller's normalized→pixels factor, used by
// the frame-skip heuristic (rebuilds are full-view repaints, so mid-morph
// frames are skipped until the fastest bar has moved ~a quarter pixel).
// rebuild redraws the caller's layers from displayedSamples; runs on geometry
// changes, morph frames, and the final settle. Capture the renderer weakly in
// it.
- (instancetype)initWithVScale:(CGFloat (^)(CGFloat height))vscale
                       rebuild:(void (^)(void))rebuild;

// The reusable target buffer, resized to count, for the caller to fill with
// the new target samples (all-zero = collapsed/empty). Reused because
// updateWaveform: runs on every loader tick and live-resize frame.
- (std::vector<float> &)targetScratchWithCount:(NSUInteger)count;

// The decision tree: skip a no-op redraw; rebuild instantly on geometry
// changes (a live resize must track the window, not ease after it) and on a
// bare hasWaveform flip (a silent track's all-zero waveform is
// sample-identical to the collapsed target but draws hairlines, not nothing);
// start the morph timer when the target moved. First draw starts collapsed so
// the waveform grows out of the midline.
- (void)commitTargetForSize:(CGSize)size hasWaveform:(BOOL)hasWaveform;

// For the rebuild callback. settled is YES when no morph is running — the
// Detailed family pixel-rounds only then (mid-morph it would quantize the
// motion into visible 1px steps).
- (const std::vector<float> &)displayedSamples;
@property (nonatomic, readonly) CGSize size;
@property (nonatomic, readonly) BOOL hasWaveform;
@property (nonatomic, readonly, getter=isSettled) BOOL settled;

@end

NS_ASSUME_NONNULL_END
