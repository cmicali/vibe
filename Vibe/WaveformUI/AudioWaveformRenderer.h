//
//  AudioWaveformRenderer.h
//  Vibe
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "PlatformTypes.h"
// AudioWaveform.h brings C++ types in, so import this header from .mm files
// only.
#import "AudioWaveform.h"
#import "WaveformTheme.h"

NS_ASSUME_NONNULL_BEGIN

// One shared fallback for the backing scale before a real answer exists, as
// for a view not yet in a window or a layer whose contentsScale is still
// unset. 2 means Retina, which is overwhelmingly the common case.
static const CGFloat kVibeDefaultBackingScale = 2;

// The rendering layer's scale sources. The mac view asks its window, the
// authority on what the scale should be; the iOS view asks its trait
// collection; and renderers ask a layer they have already stamped. All of them
// go through the one clamp below, so the fallback cannot drift between sites —
// which is the whole reason they live together.
static inline CGFloat VibeBackingScaleOrDefault(CGFloat scale) {
    return scale > 0 ? scale : kVibeDefaultBackingScale;
}
#if TARGET_OS_OSX
static inline CGFloat VibeBackingScaleForWindow(NSWindow * _Nullable window) {
    return window ? VibeBackingScaleOrDefault(window.backingScaleFactor)
                  : kVibeDefaultBackingScale;
}
#endif
static inline CGFloat VibeBackingScaleForLayer(CALayer * _Nullable layer) {
    return VibeBackingScaleOrDefault(layer.contentsScale);
}

// The block-quantization rules shared by the discrete-block styles — Sonic
// Cirrus's bar layers and Basic's blocks: which block sits under a view x,
// and how many whole blocks a progress fraction fills, each block flipping at
// its midpoint. Presentation only — the seek a hover or click reports stays
// continuous.
static inline NSInteger VibeBlockIndexForX(CGFloat x, CGFloat width, NSInteger count) {
    NSInteger index = (NSInteger)(x / width * (CGFloat)count);
    return MIN(MAX(index, (NSInteger)0), count - 1);
}
static inline NSInteger VibeBlockBoundaryForProgress(CGFloat progress, NSInteger count) {
    NSInteger boundary = (NSInteger)llround((double)count * progress);
    return MIN(MAX(boundary, (NSInteger)0), count);
}

// A ramp stop: the color at `fraction` of its own alpha. The theme colors
// carry each side's resting level in their alpha (WaveformTheme.h), so
// renderers own only their ramp shapes and scale every stop relative to that
// level through this.
static inline VibeColor *VibeColorAtRampFraction(VibeColor *color, CGFloat fraction) {
    return [color colorWithAlphaComponent:CGColorGetAlpha(color.CGColor) * fraction];
}

// Re-stamps a manually built layer tree at a new backing scale, masks and all.
// Both views own their trees rather than letting the framework manage them, so
// both need this on a display change; it lives here rather than twice.
static inline void VibeApplyContentsScale(CALayer * _Nullable layer, CGFloat scale) {
    if (!layer) {
        return;
    }
    layer.contentsScale = scale;
    VibeApplyContentsScale(layer.mask, scale);
    for (CALayer *sublayer in layer.sublayers) {
        VibeApplyContentsScale(sublayer, scale);
    }
}

@interface AudioWaveformRenderer : NSObject

@property (assign) BOOL isDark;

// The palette the family derives its gradient alphas from. The view resolves
// it (settings + appearance + artwork color) and must call updateColors:
// after setting it; init defaults it to the monochrome White answer for
// isDark, so a view that never resolves — the pre-theme call sites — draws
// exactly what it always drew. isDark stays separate because renderers still
// branch on it for non-palette decisions.
@property (strong) WaveformTheme *theme;

// The last played bar index that updateProgress: painted. Layer-array
// renderers — SonicCirrusWaveformRenderer, which owns the bar-layer machinery
// — use it to repaint only the bars between the old and new progress boundary
// rather than every bar. Set it to -1 to force a full repaint, as after the
// played and unplayed colors change in updateColors:.
@property (assign) NSInteger lastProgressBoundary;

@property (strong) CALayer* parentLayer;

// Stable, never-localized key for this renderer: the NSUserDefaults value, the
// AudioWaveformView registry key, and the stem of the menu item's identifier.
// displayName is the localized name and must never be used as a key.
+ (NSString *)styleIdentifier;

// Localized, user-visible name. Display only.
+ (NSString *)displayName;

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark;

- (void)updateColors:(BOOL)isDark;

// The vertical band, in view coordinates, a click must land in to count as a
// seek. AudioWaveformView queries it on mouseDown, and it is computed from the
// given bounds alone: a pure function rather than per-draw mutable state, so
// each renderer has exactly one band definition, derived from its drawn
// extent. Every renderer must override it; the base only asserts.
- (CGRect)seekHitBandForBounds:(CGRect)bounds;

- (void)updateWaveform:(CGRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;
- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform* __nullable)waveform;

// The window moved to a display with a different backing scale. The base does
// nothing; the families rebuild their settled geometry, whose device-pixel
// snapping baked in the old scale and which a same-size updateWaveform: pass
// skips.
- (void)backingScaleDidChange;

// The Convert to FLAC sweep: collapse the bars in the x-fraction span
// [from, to) to the midline and let the shared morph ease them back. The base
// does nothing; the families forward to their morph engine.
- (void)dipBarsFromFraction:(double)from toFraction:(double)to;

// Land the in-flight morph on its target in one rebuild rather than easing
// there — see WaveformMorphEngine.settleImmediately for when that is worth
// doing. The base does nothing; the families forward to their morph engine.
- (void)settleMorphImmediately;

// The hover scrubbing affordance: light the waveform's own column at view x to
// full brightness. No separate playhead is drawn, because the waveform is the
// affordance. A negative x clears it. Renderers keep the x, so that a resize
// or a morph rebuild can reposition the highlight; the base implementation
// stores it and does nothing else.
- (void)setHoverHighlightX:(CGFloat)x;
@property (readonly) CGFloat hoverHighlightX; // < 0 when not hovering

// Whether the settled envelope can be baked into a bitmap pixel-identical to
// this renderer's live tree (the Detailed family's envelope-image API, used by
// the iOS scrubber's fast path). The base answers NO; a subclass that changes
// its gradient aim or played-fill quantization must answer for its own bake —
// which is why Basic overrides this back to NO despite subclassing Detailed.
@property (readonly) BOOL supportsEnvelopeBake;

@end

NS_ASSUME_NONNULL_END
