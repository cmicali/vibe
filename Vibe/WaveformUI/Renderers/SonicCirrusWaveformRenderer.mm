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

// layers[i*2] is bar i's top, layers[i*2 + 1] its mirror. The constants are
// shared by the morph's vscale, rebuildLayerFrames and the seek band, so they
// cannot disagree on the scale.
static const CGFloat kBarAmplitudeOfHeight = 0.75;  // full bar height as a fraction of the view height
static const CGFloat kTopLineRatio = 0.70;          // top bar's share of the height; the mirror gets the rest
static const CGFloat kBlockWidthRatio = 0.75;       // bar width as a fraction of the bar pitch
static const CGFloat kBottomBarSpacing = 2;         // gap between the top baseline and the mirror bars

@implementation SonicCirrusWaveformRenderer {
    NSMutableArray<CALayer*>* _layers;
    // Each layer's last-set frame: the frame getter is computed, and a morph
    // frame compares all 2,048.
    std::vector<CGRect> _layerFrames;
    NSInteger _lastProgressBoundary; // -1 forces a full repaint after a color change

    VibeColor* _playedColorTop;
    VibeColor* _unPlayedColorTop;
    VibeColor* _playedColorBottom;
    VibeColor* _unPlayedColorBottom;

    VibeColor* _hoverColor;

    // -1 when none. A whole bar, recolored: a column could land in a gap.
    NSInteger _hoverBarIndex;
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

        [self updateColors:isDark];

        [self updateWaveform:bounds progress:0 waveform:nil];
    }
    return self;
}

- (void)dealloc {
    for (CALayer *layer in _layers) {
        [layer removeFromSuperlayer];
    }
}

// The mirror bars: the played hue blended toward white, and each side at a
// share of its resting level.
static const CGFloat kPlayedBottomBlendTowardWhite = 0.576;
static const CGFloat kPlayedBottomAlphaRatio = 0.8;
static const CGFloat kUnplayedBottomAlphaRatio = 0.618;

- (void)updateColors:(BOOL)isDark {
    [super updateColors:isDark];
    _lastProgressBoundary = -1;
    VibeColor *played = self.theme.playedColor;
    VibeColor *unplayed = self.theme.unplayedColor;
    _playedColorTop = played;
    _unPlayedColorTop = unplayed;
    if (self.theme.flatFill) {
        _playedColorBottom = played;
        _unPlayedColorBottom = unplayed;
    } else {
        _playedColorBottom = VibeColorWithScaledAlpha(
                [VibeColorBlended(played, [VibeColor whiteColor], kPlayedBottomBlendTowardWhite)
                        colorWithAlphaComponent:CGColorGetAlpha(played.CGColor)],
                kPlayedBottomAlphaRatio);
        _unPlayedColorBottom = VibeColorWithScaledAlpha(unplayed, kUnplayedBottomAlphaRatio);
    }
    _hoverColor = self.theme.hoverColor;
}

// Ignoring any hover.
- (VibeColor *)restingColorForBar:(NSInteger)index top:(BOOL)top {
    BOOL played = (_lastProgressBoundary >= 0 && index < _lastProgressBoundary);
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
        index = VibeBlockIndexForX(x, width, barCount);
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

// A count change moves every bar's index, so the boundary is rescaled to keep
// the played fraction (updateProgress: lands the exact one next) and every
// bar is repainted.
- (void)reconcileBarCount:(NSUInteger)count {
    NSUInteger have = _layers.count / 2;
    if (have == count) {
        return;
    }
    VibeSignpostBegin(waveform_layers);
    if (_lastProgressBoundary > 0 && have > 0) {
        _lastProgressBoundary = VibeBlockBoundaryForProgress(
                (CGFloat)_lastProgressBoundary / (CGFloat)have, (NSInteger)count);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!_layers) _layers = [NSMutableArray new];
    while (_layers.count > count * 2) {
        [_layers.lastObject removeFromSuperlayer];
        [_layers removeLastObject];
    }
    CGFloat scale = self.parentLayer.contentsScale;
    while (_layers.count < count * 2) {
        CALayer *layer = [[CALayer alloc] init];
        layer.contentsScale = scale;
        [_layers addObject:layer];
        [self.parentLayer addSublayer:layer];
    }
    _layerFrames.resize(count * 2, CGRectZero);
    // The hover index is against the old count; updateWaveform: re-snaps it
    // from the kept x right after this.
    _hoverBarIndex = -1;
    for (NSUInteger i = 0; i < count; i++) {
        [self setLayerColor:[self restingColorForBar:(NSInteger)i top:YES] atIndex:i * 2];
        [self setLayerColor:[self restingColorForBar:(NSInteger)i top:NO] atIndex:i * 2 + 1];
    }
    [CATransaction commit];
    VibeSignpostEnd(waveform_layers);
}

- (void)setLayerColor:(VibeColor *)color atIndex:(NSUInteger)index {
    CGColorRef c = color.CGColor;
    CALayer *layer = _layers[index];
    if (!CGColorEqualToColor(layer.backgroundColor, c)) {
        layer.backgroundColor = c;
    }
}

- (void)setFrame:(CGRect)frame atIndex:(NSUInteger)index {
    if (!CGRectEqualToRect(_layerFrames[index], frame)) {
        _layers[index].frame = frame;
        _layerFrames[index] = frame;
    }
}

// From the full-amplitude constants, not the bars on screen, which collapse to
// a sliver on a quiet track.
- (CGRect)seekHitBandForBounds:(CGRect)bounds {
    CGFloat totalHeight = bounds.size.height;
    CGFloat topLineY = round(totalHeight * (1 - kTopLineRatio));
    CGFloat bottomLineY = topLineY - kBottomBarSpacing;
    CGFloat maxTopBarHeight = totalHeight * kBarAmplitudeOfHeight * kTopLineRatio;
    CGFloat topY = topLineY + maxTopBarHeight;
    CGFloat bottomY = bottomLineY - maxTopBarHeight * (1 - kTopLineRatio);
    return CGRectMake(bounds.origin.x, bottomY, bounds.size.width, topY - bottomY);
}

// The bars stand on a line below the center: the 1pt top bar over it, the
// mirror's sliver under the gap.
- (CGRect)restingBandForBounds:(CGRect)bounds {
    CGFloat bottomLineY = round(bounds.size.height * (1 - kTopLineRatio)) - kBottomBarSpacing;
    return CGRectMake(bounds.origin.x, bounds.origin.y + bottomLineY - 1,
                      bounds.size.width, kBottomBarSpacing + 2);
}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform*)waveform {
    NSInteger count = (NSInteger)(_layers.count / 2);
    NSInteger newBoundary = VibeBlockBoundaryForProgress(progress, count);

    NSInteger oldBoundary = _lastProgressBoundary;
    NSInteger start, end;
    if (oldBoundary < 0) {
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
    _lastProgressBoundary = newBoundary;
    // The playhead crossing the hovered bar, or a full repaint after
    // updateColors:, has just painted over the highlight. Restore it.
    if (_hoverBarIndex >= start && _hoverBarIndex < end) {
        [self setLayerColor:_hoverColor atIndex:(NSUInteger)(_hoverBarIndex * 2)];
        [self setLayerColor:_hoverColor atIndex:(NSUInteger)(_hoverBarIndex * 2 + 1)];
    }
}

- (void)updateWaveform:(CGRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform*)waveform {

    NSUInteger count = [self blockBarCountForWidth:bounds.size.width];
    [self reconcileBarCount:count];
    [self updateProgress:progress waveform:waveform];

    // A resize moves the bar under the kept x.
    [self setHoverHighlightX:self.hoverHighlightX];

    [_morph updateTargetForSize:bounds.size identity:waveform count:count
                           fill:^(std::vector<float> &target) {
        [self fillEnergyLevels:target.data() count:count stride:1 waveform:waveform];
    }];
}

// The morph's rebuild callback. Unlike Detailed, heights round to the pixel
// grid on every frame: the step is imperceptible here, and the settle then
// matches the last frame.
- (void)rebuildLayerFrames {
    VibeSignpostBegin(waveform_bars);
    const std::vector<float> &samples = [_morph displayedSamples];
    // Always equal after updateWaveform:'s reconcile; the MIN only guards a
    // morph tick landing between a future reorder of the two.
    NSUInteger count = MIN(samples.size(), _layers.count / 2);
    if (count == 0) {
        VibeSignpostEnd(waveform_bars);
        return;
    }

    CGFloat totalHeight = _morph.size.height;
    CGFloat width = _morph.size.width;

    CGFloat vscale = totalHeight * kBarAmplitudeOfHeight;

    CGFloat barPitch = width / (CGFloat)count;
    CGFloat blockWidth = [self scaledBarWidth:MAX(barPitch * kBlockWidthRatio,
            1 / MAX((CGFloat)1, self.barDensity)) pitch:barPitch];

    CGFloat topLineY = round(totalHeight * (1 - kTopLineRatio));
    CGFloat bottomLineY = topLineY - kBottomBarSpacing;

    CGFloat minHeight = _morph.barMinHeight;
    CGFloat scale = VibeBackingScaleForLayer(self.parentLayer);
    CGFloat pixel = 1 / scale;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSUInteger i = 0; i < count; i++) {

        CGFloat x = barPitch * (CGFloat)i;

        CGFloat height = samples[i] * vscale;
        CGFloat topBarHeight = round(height * kTopLineRatio / pixel) * pixel;
        topBarHeight = MAX(topBarHeight, minHeight);
        CGRect topFrame = CGRectMake(x, topLineY, blockWidth, topBarHeight);
        [self setFrame:topFrame atIndex:i * 2];

        CGFloat bottomBarHeight = round(topBarHeight * (1 - kTopLineRatio) / pixel) * pixel;
        [self setFrame:CGRectMake(x, bottomLineY - bottomBarHeight, blockWidth, bottomBarHeight) atIndex:i * 2 + 1];
    }
    [CATransaction commit];
    VibeSignpostEnd(waveform_bars);
}

@end
