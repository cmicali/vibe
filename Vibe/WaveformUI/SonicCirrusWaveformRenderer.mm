//
//  SonicCirrusWaveformRenderer.mm
//  Vibe
//

#import "SonicCirrusWaveformRenderer.h"
#import "WaveformMorphEngine.h"
#import "VibeStrings.h"
#import "PlatformColor.h"

#include <vector>
#include <cmath>

// Each bar is drawn with two layers: layers[i*2] is the top bar, and
// layers[i*2 + 1] the mirrored bottom bar.
//
// 128 bars across the 512pt design-width waveform: a designed pitch of 4pt,
// and the count follows the width at that pitch, so a resize adds or removes
// bars at their designed size rather than stretching the pitch. The cap
// bounds the layer count — two CALayers per bar is the expensive layout here,
// unlike the Detailed family's one shared mask path.
static const CGFloat kBarPitch = 4;
static const NSUInteger kMaxBarCount = 1024;

// The geometry constants shared by the morph engine's frame-skip heuristic,
// through the vscale block handed to it in init, by rebuildLayerFrames, and by
// the seek hit band in seekHitBandForBounds:, so that they cannot disagree on
// the normalized-to-pixels scale.
static const CGFloat kBarAmplitudeOfHeight = 0.75;  // full bar height as a fraction of the view height
static const CGFloat kTopLineRatio = 0.70;          // top bar's share of the height; the mirror gets the rest
static const CGFloat kBlockWidthRatio = 0.75;       // bar width as a fraction of the bar pitch
static const CGFloat kBottomBarSpacing = 2;         // gap between the top baseline and the mirror bars

@implementation SonicCirrusWaveformRenderer {
    // This is the only renderer that draws with a flat array of bar layers,
    // since the Detailed family draws gradient and mask layers, so the layer
    // machinery lives here rather than in the base class.
    NSArray<CALayer*>* _layers;

    VibeColor* _playedColorTop;
    VibeColor* _unPlayedColorTop;
    VibeColor* _playedColorBottom;
    VibeColor* _unPlayedColorBottom;

    VibeColor* _hoverColor;

    // The bar index lit by the hover affordance, or -1. Bars here are discrete
    // layers with gaps between them, so the highlight snaps to a whole bar,
    // because a fixed-width column at the cursor could land in a gap and light
    // nothing. It recolors that bar's two layers rather than overlaying them.
    NSInteger _hoverBarIndex;

    // The samples are one normalized height per bar, and rebuildLayerFrames is
    // the rebuild callback.
    WaveformMorphEngine *_morph;
}

+ (NSString *)styleIdentifier {
    return @"sonic_cirrus";
}

+ (NSString *)displayName {
    return STR_WAVEFORM_STYLE_SONIC_CIRRUS;
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super initWithLayer:parentLayer bounds:bounds isDark:isDark];
    if (self) {

        _hoverBarIndex = -1;

        __weak __typeof__(self) weakSelf = self;
        _morph = [[WaveformMorphEngine alloc]
                initWithVScale:^CGFloat(CGFloat height) { return height * kBarAmplitudeOfHeight * kTopLineRatio; }
                       rebuild:^{ [weakSelf rebuildLayerFrames]; }];

        // The same derivation as a light-dark switch uses: one source of truth
        // for the palette.
        [self updateColors:isDark];

        // updateWaveform: builds the bar layers for this width through
        // reconcileBarCount:.
        [self updateWaveform:bounds progress:0 waveform:nil];
        [self updateProgress:0 waveform:nil];
    }
    return self;
}

- (void)dealloc {
    for (CALayer *layer in _layers) {
        [layer removeFromSuperlayer];
    }
}

// The fraction of the way toward white the bottom mirror bars sit from the
// played hue: the blend that reproduces this style's historical hardcoded
// pair — bottom (1, 0.75, 0.585) from top (1, 0.45, 0) — to within rounding.
static const CGFloat kPlayedBottomBlendTowardWhite = 0.576;

// The mirror bars' share of each side's resting level — the ratios of the
// historical pairs (played 0.8/1.0, unplayed 0.55/0.89). The levels
// themselves are the theme colors' alphas: the colored themes' unplayed
// carries this style's historical 0.89, so the Orange theme on these bars is
// the pre-theme Sonic Cirrus exactly.
static const CGFloat kPlayedBottomAlphaRatio = 0.8;
static const CGFloat kUnplayedBottomAlphaRatio = 0.618;

- (void)updateColors:(BOOL)isDark {
    // super sets lastProgressBoundary to -1, so that the next updateProgress:
    // repaints every bar with the new colors.
    [super updateColors:isDark];
    // Tops are the theme colors as-is; each bottom is its paler mirror — the
    // played one blended toward white, both at their ratio of the side's
    // level.
    VibeColor *played = self.theme.playedColor;
    VibeColor *unplayed = self.theme.unplayedColor;
    _playedColorTop = played;
    _playedColorBottom = VibeColorAtRampFraction(
            [VibeColorBlended(played, [VibeColor whiteColor], kPlayedBottomBlendTowardWhite)
                    colorWithAlphaComponent:CGColorGetAlpha(played.CGColor)],
            kPlayedBottomAlphaRatio);
    _unPlayedColorTop = unplayed;
    _unPlayedColorBottom = VibeColorAtRampFraction(unplayed, kUnplayedBottomAlphaRatio);
    _hoverColor = self.theme.hoverColor;
}

// The played and unplayed pair a bar index should show right now, ignoring any
// hover.
- (VibeColor *)restingColorForBar:(NSInteger)index top:(BOOL)top {
    BOOL played = (self.lastProgressBoundary >= 0 && index < self.lastProgressBoundary);
    if (top) {
        return played ? _playedColorTop : _unPlayedColorTop;
    }
    return played ? _playedColorBottom : _unPlayedColorBottom;
}

- (void)setHoverHighlightX:(CGFloat)x {
    [super setHoverHighlightX:x];
    CGFloat width = self.parentLayer.bounds.size.width;
    NSInteger barCount = (NSInteger)(_layers.count / 2);
    NSInteger index = -1;
    if (x >= 0 && width > 0 && barCount > 0) {
        index = (NSInteger)(x / width * (CGFloat)barCount);
        index = MIN(MAX(index, 0), barCount - 1);
    }
    if (index == _hoverBarIndex) {
        return;
    }
    NSInteger previous = _hoverBarIndex;
    _hoverBarIndex = index;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (previous >= 0) {
        [self setLayerColor:[self restingColorForBar:previous top:YES] atIndex:(NSUInteger)(previous * 2)];
        [self setLayerColor:[self restingColorForBar:previous top:NO] atIndex:(NSUInteger)(previous * 2 + 1)];
    }
    if (index >= 0) {
        [self setLayerColor:_hoverColor atIndex:(NSUInteger)(index * 2)];
        [self setLayerColor:_hoverColor atIndex:(NSUInteger)(index * 2 + 1)];
    }
    [CATransaction commit];
}

- (NSUInteger)barCountForWidth:(CGFloat)width {
    NSUInteger count = (NSUInteger)llround(clampMin(width, 1) / kBarPitch);
    return MIN(MAX(count, (NSUInteger)2), kMaxBarCount);
}

// Matches the layer array to the bar count, two layers per bar, appending or
// removing at the tail. A count change moves every bar's index, so the
// progress boundary is rescaled to keep the played fraction — updateProgress:
// lands the exact one on its next call — and every bar is repainted.
- (void)reconcileBarCount:(NSUInteger)count {
    NSUInteger have = _layers.count / 2;
    if (have == count) {
        return;
    }
    if (self.lastProgressBoundary > 0 && have > 0) {
        NSInteger boundary = (NSInteger)llround(
                (double)self.lastProgressBoundary * (double)count / (double)have);
        self.lastProgressBoundary = MIN(MAX(boundary, 0), (NSInteger)count);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSMutableArray<CALayer *> *layers = [_layers mutableCopy] ?: [NSMutableArray new];
    while (layers.count > count * 2) {
        [layers.lastObject removeFromSuperlayer];
        [layers removeLastObject];
    }
    CGFloat scale = self.parentLayer.contentsScale;
    while (layers.count < count * 2) {
        CALayer *layer = [[CALayer alloc] init];
        layer.contentsScale = scale;
        [layers addObject:layer];
        [self.parentLayer addSublayer:layer];
    }
    _layers = layers;
    // The hover index is against the old count; updateWaveform: re-snaps it
    // from the kept x right after this.
    _hoverBarIndex = -1;
    for (NSUInteger i = 0; i < count; i++) {
        [self setLayerColor:[self restingColorForBar:(NSInteger)i top:YES] atIndex:i * 2];
        [self setLayerColor:[self restingColorForBar:(NSInteger)i top:NO] atIndex:i * 2 + 1];
    }
    [CATransaction commit];
}

- (void)setLayerColor:(VibeColor *)color atIndex:(NSUInteger)index {
    CGColorRef c = color.CGColor;
    CALayer *layer = _layers[index];
    if (!CGColorEqualToColor(layer.backgroundColor, c)) {
        layer.backgroundColor = c;
    }
}

// The full-amplitude extents come from the fixed geometry constants, not from
// the bars currently on screen, whose extents collapse to a sliver on a quiet
// track and would make the seek band impossible to hit.
- (CGRect)seekHitBandForBounds:(CGRect)bounds {
    CGFloat totalHeight = bounds.size.height;
    CGFloat topLineY = round(totalHeight * (1 - kTopLineRatio));
    CGFloat bottomLineY = topLineY - kBottomBarSpacing;
    CGFloat maxTopBarHeight = totalHeight * kBarAmplitudeOfHeight * kTopLineRatio;
    CGFloat topY = topLineY + maxTopBarHeight;
    CGFloat bottomY = bottomLineY - maxTopBarHeight * (1 - kTopLineRatio);
    return CGRectMake(bounds.origin.x, bottomY, bounds.size.width, topY - bottomY);
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    NSInteger count = (NSInteger)(_layers.count / 2);
    NSInteger newBoundary = (NSInteger)round((CGFloat)count * progress);
    if (newBoundary < 0) newBoundary = 0;
    if (newBoundary > count) newBoundary = count;

    NSInteger oldBoundary = self.lastProgressBoundary;
    NSInteger start, end;
    if (oldBoundary < 0) {
        // The sentinel after updateColors:, so repaint everything.
        start = 0;
        end = count;
    } else {
        start = MIN(oldBoundary, newBoundary);
        end = MAX(oldBoundary, newBoundary);
    }

    for (NSInteger i = start; i < end; i++) {
        BOOL played = (i < newBoundary);
        VibeColor *colorTop = played ? _playedColorTop : _unPlayedColorTop;
        VibeColor *colorBottom = played ? _playedColorBottom : _unPlayedColorBottom;
        [self setLayerColor:colorTop atIndex:(NSUInteger)(i * 2)];
        [self setLayerColor:colorBottom atIndex:(NSUInteger)(i * 2 + 1)];
    }
    self.lastProgressBoundary = newBoundary;
    // The playhead crossing the hovered bar, or a full repaint after
    // updateColors:, has just painted over the highlight. Restore it.
    if (_hoverBarIndex >= start && _hoverBarIndex < end) {
        [self setLayerColor:_hoverColor atIndex:(NSUInteger)(_hoverBarIndex * 2)];
        [self setLayerColor:_hoverColor atIndex:(NSUInteger)(_hoverBarIndex * 2 + 1)];
    }
}

- (void)updateWaveform:(CGRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {

    NSUInteger count = [self barCountForWidth:bounds.size.width];
    [self reconcileBarCount:count];

    // A resize changes which bar index sits under the kept x, so re-snap the
    // highlight. setHoverHighlightX: recomputes the index against the new
    // width and restores the previous bar's resting color.
    [self setHoverHighlightX:self.hoverHighlightX];

    // Build the morph target: each bar's normalized peak-to-peak height, or
    // all-zero when there is no waveform, so that a track change collapses the
    // old bars toward the baseline until the new waveform retargets them. The
    // engine owns the fast, collapsed and commit scaffold and skips this fill
    // on a live-resize frame, where the waveform identity and count are
    // unchanged. Only the sampling itself belongs to this family.
    [_morph updateTargetForSize:bounds.size identity:waveform count:count
                           fill:^(std::vector<float> &target) {
        for (NSUInteger i = 0; i < count; i++) {
            AudioWaveformCacheChunk m = waveform->getChunkAtIndex(i, count);
            target[i] = fabsf(m.getMax() - m.getMin()) / 2;
        }
    }];
}

- (void)dipBarsFromFraction:(double)from toFraction:(double)to {
    [_morph dipDisplayedSamplesFromFraction:from toFraction:to];
}

- (void)settleMorphImmediately {
    [_morph settleImmediately];
}

// Hover here is color-only and needs no re-place; the bar frames re-round to
// the new pixel grid.
- (void)backingScaleDidChange {
    [_morph rebuildNow];
}

// Lays the bar layers out for the currently displayed samples. It is the morph
// engine's rebuild callback. Heights round to the device-pixel grid on every
// draw, which keeps edges crisp, holds quantization to an imperceptible
// one-device-pixel step, and makes the settle draw identical to the last
// animation frame, so there is no end-of-morph shift.
- (void)rebuildLayerFrames {
    const std::vector<float> &samples = [_morph displayedSamples];
    // Always equal after updateWaveform:'s reconcile; the MIN only guards a
    // morph tick landing between a future reorder of the two.
    NSUInteger count = MIN(samples.size(), _layers.count / 2);
    if (count == 0) {
        return;
    }

    CGFloat totalHeight = _morph.size.height;
    CGFloat width = _morph.size.width;

    CGFloat vscale = totalHeight * kBarAmplitudeOfHeight;

    CGFloat barPitch = width / (CGFloat)count;
    CGFloat blockWidth = clampMin(barPitch * kBlockWidthRatio, 1);

    CGFloat topLineY = round(totalHeight * (1 - kTopLineRatio));
    CGFloat bottomLineY = topLineY - kBottomBarSpacing;

    // A hairline floor against collapsing to nothing. The policy lives on the
    // engine, shared with the Detailed family.
    CGFloat minHeight = _morph.barMinHeight;
    CGFloat scale = VibeBackingScaleForLayer(self.parentLayer);
    CGFloat pixel = 1 / scale;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < count; i++) {

        CGFloat x = barPitch * (CGFloat)i;

        // The top line.
        CGFloat height = samples[i] * vscale;
        CGFloat topBarHeight = round(height * kTopLineRatio / pixel) * pixel;
        topBarHeight = MAX(topBarHeight, minHeight);
        _layers[i * 2].frame = CGRectMake(x, topLineY, blockWidth, topBarHeight);

        // The mirror line.
        CGFloat bottomBarHeight = round(topBarHeight * (1 - kTopLineRatio) / pixel) * pixel;
        _layers[i * 2 + 1].frame = CGRectMake(x, bottomLineY - bottomBarHeight, blockWidth, bottomBarHeight);
    }
    [CATransaction commit];
}

@end
