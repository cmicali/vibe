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
#import "WaveformLevelMath.h"

NS_ASSUME_NONNULL_BEGIN

// One shared fallback for the backing scale before a real answer exists, as
// for a view not yet in a window or a layer whose contentsScale is still
// unset. 2 means Retina, which is overwhelmingly the common case.
static const CGFloat kVibeDefaultBackingScale = 2;

// The rendering layer's scale sources — the mac view's window, the iOS view's
// trait collection, and a layer a renderer has already stamped — all go
// through the one clamp below, so the fallback cannot drift between sites,
// which is the whole reason they live together.
static inline CGFloat VibeBackingScaleOrDefault(CGFloat scale) {
    return scale > 0 ? scale : kVibeDefaultBackingScale;
}
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
    return clampRange(index, (NSInteger)0, count - 1);
}
static inline NSInteger VibeBlockBoundaryForProgress(CGFloat progress, NSInteger count) {
    NSInteger boundary = (NSInteger)llround((double)count * progress);
    return clampRange(boundary, (NSInteger)0, count);
}

// The level a bar draws at is VibeWaveformBarLevel (WaveformLevelMath.h):
// its energy column's RMS against the fill's full-scale reference
// (VibeWaveformFullScaleRMSForWaveform below), through the renderer's gainDB.
//
// The level's energy is averaged over a column no finer than 1/1024 of the
// track — 8 source chunks, ~0.4s of a typical track, the momentary-loudness
// scale — however fine the bars. RMS over a window shorter than a beat
// converges back to peak, which re-pegged the fixed-count oversampling
// styles: their bars cover as little as one ~50ms chunk, so every kick read
// as a full-height bar and the upper envelope was the old solid block again.
// Only the level is floored; the min/max shape keeps per-bar resolution.
static const NSUInteger kVibeWaveformEnergyColumns = 1024;

// Which energy column bar i of count belongs to. Split from the accessor
// below because a renderer caching per column keys on the index and must not
// re-derive it: the two spellings would drift, and a bar scaled by its
// neighbour's level looks like nothing in particular.
static inline NSUInteger VibeWaveformEnergyColumnIndexForBar(NSUInteger i, NSUInteger count) {
    return count > kVibeWaveformEnergyColumns
            ? i * kVibeWaveformEnergyColumns / count : i;
}

// The energy column bar i of count draws its level from. Every bar-level
// consumer maps through this rather than reading its own chunk's energy, so
// a renderer with bars finer than the column cannot re-peg to sub-beat RMS —
// nothing at a call site otherwise hints at the floor.
static inline AudioWaveformCacheChunk VibeWaveformEnergyColumnForBar(AudioWaveform *waveform,
                                                                     NSUInteger i,
                                                                     NSUInteger count) {
    return count > kVibeWaveformEnergyColumns
            ? waveform->getChunkAtIndex(VibeWaveformEnergyColumnIndexForBar(i, count),
                                        kVibeWaveformEnergyColumns)
            : waveform->getChunkAtIndex(i, count);
}

// The full-scale reference for one fill: the fixed -9 dBFS RMS, or with
// Normalize on the track's loudest energy column at the floored resolution,
// so that column draws full height whatever the master's level. The
// resolution is the fixed column count rather than the bar count, so a
// resize cannot move the reference. A silent or still-empty waveform falls
// back to the constant rather than dividing by zero; its bars are zero
// either way.
static inline float VibeWaveformFullScaleRMSForWaveform(AudioWaveform * _Nullable waveform,
                                                        BOOL normalize) {
    float loudest = (normalize && waveform)
            ? sqrtf(waveform->getMaxMeanSquare(kVibeWaveformEnergyColumns)) : 0;
    return loudest > 0 ? loudest : kVibeWaveformFullScaleRMS;
}

// Snap a hover/seek column to the device-pixel grid. A fractional origin or
// width leaves half-lit edge pixels, and the column is supposed to be the
// crispest thing in the waveform. x and the returned rect are in the caller's
// local (bounds-relative) space; x may overshoot either edge — the clamp
// keeps the column inside.
static inline CGRect VibeSnappedColumnRect(CGFloat x, CGFloat columnWidth,
                                           CGFloat boundsWidth, CGFloat height, CGFloat scale) {
    CGFloat width = MAX(round(columnWidth * scale), 1) / scale;
    CGFloat left = floor((x - width / 2) * scale) / scale;
    left = clampRange(left, 0, MAX(0, boundsWidth - width));
    return CGRectMake(left, 0, width, height);
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

// Settings > Appearance > Waveform's Normalize and Gain, handed over by the
// view as the theme is; the init defaults — off, 0 dB — are the plain
// mapping. Every fill measures its bars against
// VibeWaveformFullScaleRMSForWaveform and passes the gain to
// VibeWaveformBarLevel. Either setter reaches levelMappingDidChange, which
// the bar families forward to their morph engine's invalidateTarget, so a
// change refills from the same waveform and the bars ease to their new
// heights rather than staying where the last fill put them.
@property (nonatomic) BOOL normalizesLevels;
@property (nonatomic) float gainDB;
- (void)levelMappingDidChange;

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
