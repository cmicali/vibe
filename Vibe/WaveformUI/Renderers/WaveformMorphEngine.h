//
//  WaveformMorphEngine.h
//  Vibe
//

#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>

#include <vector>

NS_ASSUME_NONNULL_BEGIN

// The morph engine both renderer families share: the sample vectors, the 60 Hz
// ease and the retarget decision tree. Renderers keep only the fill and the
// geometry. Do not duplicate it per family. C++: .mm importers only.
//
// An exponential approach (~0.2s), so a new target mid-morph bends the motion
// rather than restarting it.
@interface WaveformMorphEngine : NSObject

// vscale maps view height to pixels per sample unit, for the frame-skip
// heuristic. rebuild redraws the caller's layers from displayedSamples;
// capture the renderer weakly in it.
- (instancetype)initWithVScale:(CGFloat (^)(CGFloat height))vscale
                       rebuild:(void (^)(void))rebuild;

// updateWaveform:'s one target entry point. identity is the waveform pointer
// (NULL: the collapsed all-zero target), compare-only: it cannot false-match
// because the view retains the old waveform while a new one is allocated.
//
// Same identity and count skip the fill; only a geometry change rebuilds.
// Otherwise fill() runs synchronously on a reused buffer. Then: rebuild
// instantly on a geometry change. A nil/non-nil flip with unchanged samples
// also rebuilds: silent tracks need hairlines. Changed content eases.
// A settled waveform's count change installs at once. A resize mid-morph
// resamples the displayed bars and keeps easing.
- (void)updateTargetForSize:(CGSize)size
                   identity:(const void * _Nullable)identity
                      count:(NSUInteger)count
                       fill:(void (^)(std::vector<float> &target))fill;

// For a target input outside the identity (normalize, gain): the next update
// refills rather than taking the fast path.
- (void)invalidateTarget;

// Samples per drawn bar: 1 by default, 2 for the Detailed family's [min, max]
// pairs. The dip rounds outward to it.
@property (nonatomic) NSUInteger samplesPerBar;

// Zeroes the displayed samples in the span and eases them back to the
// unchanged target. No-op without a waveform.
- (void)dipDisplayedSamplesFromFraction:(double)from toFraction:(double)to;

// For a change the fast path cannot see, like a backing-scale flip.
- (void)rebuildNow;

// Lands on the target in one rebuild. Use for unseen renderers to avoid
// repeatedly rebuilding a full-view path.
- (void)settleImmediately;

// For the rebuild callback. Detailed pixel-rounds only when settled: mid-morph
// it would quantize the motion into visible steps.
- (const std::vector<float> &)displayedSamples;
@property (nonatomic, readonly) CGSize size;
// 1 with a waveform (silent and unloaded chunks draw a hairline), 0 without
// (collapsed bars vanish). Here so both families agree.
@property (nonatomic, readonly) CGFloat barMinHeight;
@property (nonatomic, readonly, getter=isSettled) BOOL settled;

@end

NS_ASSUME_NONNULL_END
