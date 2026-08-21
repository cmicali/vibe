//
//  WaveformMorphEngine.h
//  Vibe
//

#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>

#include <vector>

NS_ASSUME_NONNULL_BEGIN

// The morph engine shared by both renderer families. It owns the displayed,
// target and scratch sample vectors and the 60Hz easing timer, and runs the
// retarget decision tree. Renderers keep only what differs: building a target
// from the waveform, and turning displayed samples into layer geometry. Do not
// duplicate it per family — near-identical copies silently diverge.
//
// This header carries C++ types, so import it from .mm renderers only.
//
// The easing is an exponential approach toward the target, settling to about
// 95% in roughly 3τ, or 0.2s. Unlike a keyframed from-to animation it
// retargets seamlessly: a new target mid-morph simply bends the in-flight
// motion. The sample units are the renderer's own, and the convergence epsilon
// is well under a device pixel in both.
@interface WaveformMorphEngine : NSObject

// vscale maps view height to the caller's normalized-to-pixels factor, and the
// frame-skip heuristic uses it: rebuilds are full-view repaints, so mid-morph
// frames are skipped until the fastest bar has moved about a quarter of a
// pixel. rebuild redraws the caller's layers from displayedSamples, and runs on
// geometry changes, morph frames and the final settle. Capture the renderer
// weakly in it.
- (instancetype)initWithVScale:(CGFloat (^)(CGFloat height))vscale
                       rebuild:(void (^)(void))rebuild;

// The single entry point for updateWaveform:'s target maintenance. identity is
// what the target derives from: the waveform pointer, where NULL means none
// and gives the collapsed all-zero target. It is compare-only and never
// dereferenced, and a dangling value cannot false-match, because a new waveform
// is allocated while the current one is still retained by the view.
//
// When identity and count both match the last build — a live-resize frame
// that kept the bar count, since targets are normalized and
// geometry-independent — the fill pass is skipped, and only a geometry change
// triggers a rebuild. Otherwise fill() runs synchronously on the reusable
// target buffer, resized to count, and reused because this runs on every
// loader tick.
//
// The retarget decision tree then follows. Skip a no-op redraw. Rebuild
// instantly on a geometry change, because a live resize must track the window
// rather than ease after it, and on a bare identity flip between nil and
// non-nil, because a silent track's all-zero waveform is sample-identical to
// the collapsed target but draws hairlines rather than nothing. Start the morph
// timer when the target has moved. The first build starts collapsed, so the
// waveform grows out of the midline; a later bar-count change — a resize,
// since the renderers derive their count from the width — resamples the
// displayed bars to the new count instead, so a live resize never collapses
// the picture.
- (void)updateTargetForSize:(CGSize)size
                   identity:(const void * _Nullable)identity
                      count:(NSUInteger)count
                       fill:(void (^)(std::vector<float> &target))fill;

// The number of consecutive samples that make up one drawn bar: 1, the
// default, for Sonic Cirrus, 2 for the Detailed family's interleaved
// [min, max] pairs. The dip rounds its span outward to this stride, so an
// edge bar is never half-zeroed.
@property (nonatomic) NSUInteger samplesPerBar;

// The Convert to FLAC sweep: zeroes the displayed samples in the x-fraction
// span and ensures the ease is running, so they grow back toward the
// unchanged target. Samples run left to right in both families, so the
// fraction maps to the array linearly. A no-op without a waveform.
- (void)dipDisplayedSamplesFromFraction:(double)from toFraction:(double)to;

// Redraws the caller's layers from the current displayed samples, for a change
// the updateTargetForSize: fast path cannot see: a backing-scale flip leaves
// size, identity and count untouched but re-snaps settled pixel rounding.
- (void)rebuildNow;

// Lands the in-flight morph on its target NOW, in one rebuild, instead of
// easing there over ~0.2s. For content whose ease nobody can see but whose
// per-frame rebuilds everybody pays for — a pager cell recycled or scrolled
// into view. Every morph frame is a full-view repaint (for the Detailed family
// a 4,096-rect path rebuilt and re-rasterized as a mask), so a couple of cells
// easing at once is enough to blow a scroll's frame budget. A no-op when
// already settled on the target.
- (void)settleImmediately;

// For the rebuild callback. settled is YES when no morph is running, and the
// Detailed family pixel-rounds only then: mid-morph it would quantize the
// motion into visible one-pixel steps.
- (const std::vector<float> &)displayedSamples;
@property (nonatomic, readonly) CGSize size;
// The bar-height floor for the caller's rebuild. It is 1 when a waveform
// exists, so that silent and not-yet-loaded chunks draw as a hairline, matching
// the settled look mid-load, and 0 when there is none, so that collapsed bars
// vanish entirely rather than leaving a hairline row. The policy lives here, so
// that both renderer families agree.
@property (nonatomic, readonly) CGFloat barMinHeight;
@property (nonatomic, readonly, getter=isSettled) BOOL settled;

@end

NS_ASSUME_NONNULL_END
