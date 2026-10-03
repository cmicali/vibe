//
//  AudioWaveformRenderer.mm
//  Vibe
//

#import "AudioWaveformRenderer.h"
#import "WaveformMorphEngine.h"

@implementation AudioWaveformRenderer {
    CGFloat _hoverHighlightX;
}

- (instancetype)initWithLayer:(CALayer *)parentLayer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    self = [super init];
    if (self) {
        self.parentLayer = parentLayer;
        self.isDark = isDark;
        self.theme = [WaveformTheme monochromeThemeIsDark:isDark];
        _hoverHighlightX = -1;
        _barDensity = 1;
        _barWidthScale = 1;
    }
    return self;
}

- (CGFloat)hoverHighlightX {
    return _hoverHighlightX;
}

- (NSUInteger)blockBarCountForWidth:(CGFloat)width {
    NSUInteger count = (NSUInteger)llround(clampMin(width, 1) * self.barDensity / 4);
    return clampRange(count, (NSUInteger)2, (NSUInteger)1024);
}

- (void)setBarDensity:(CGFloat)density {
    if (_barDensity == density) return;
    _barDensity = density;
    // Stroke widths can change while the rounded count stays the same.
    [_morph rebuildNow];
}

- (void)setBarWidthScale:(CGFloat)scale {
    if (_barWidthScale == scale) return;
    _barWidthScale = scale;
    [_morph rebuildNow];
}

- (CGFloat)scaledBarWidth:(CGFloat)width pitch:(CGFloat)pitch {
    return MIN(width * self.barWidthScale, pitch);
}

// Subclasses paint and call super.
- (void)setHoverHighlightX:(CGFloat)x {
    _hoverHighlightX = x;
}

- (void)setNormalizesLevels:(BOOL)normalizes {
    if (normalizes == _normalizesLevels) {
        return;
    }
    _normalizesLevels = normalizes;
    [_morph invalidateTarget];
}

- (void)setGainDB:(float)gainDB {
    if (gainDB == _gainDB) {
        return;
    }
    _gainDB = gainDB;
    [_morph invalidateTarget];
}

- (std::vector<float>)energyColumnLevelsForBarCount:(NSUInteger)count waveform:(AudioWaveform *)waveform {
    // The reach is gone by the floor's 1,024 columns, which no resize moves.
    std::vector<float> levels(MIN(count, kVibeWaveformEnergyColumns));
    float reach = VibeWaveformWindowReach(levels.size(), kVibeWaveformEnergyColumns / 2);
    waveform->getBarMeanSquares(levels.size(), reach, levels.data(), NULL);
    float fullScaleRMS = VibeWaveformFullScaleRMSForColumns(waveform, self.normalizesLevels,
                                                            levels.data(), levels.size());
    float gainDB = self.gainDB;
    for (float &level : levels) {
        level = VibeWaveformBarLevel(level, fullScaleRMS, gainDB);
    }
    return levels;
}

- (void)fillEnergyLevels:(float *)out count:(NSUInteger)count stride:(NSUInteger)stride
               waveform:(AudioWaveform *)waveform {
    std::vector<float> levels = [self energyColumnLevelsForBarCount:count waveform:waveform];
    for (NSUInteger i = 0; i < count; i++) {
        out[i * stride] = levels[VibeWaveformEnergyColumnIndexForBar(i, count)];
    }
}

// Abstract: assert where the class is known, and return a nonnull marker so
// Release registers something rather than crashing.
+ (NSString *)styleIdentifier {
    NSAssert(NO, @"%@ must override +styleIdentifier", NSStringFromClass(self));
    return NSStringFromClass(self);
}

+ (NSString *)displayName {
    NSAssert(NO, @"%@ must override +displayName", NSStringFromClass(self));
    return NSStringFromClass(self);
}

+ (BOOL)readsBands {
    return NO;
}

- (void)updateColors:(BOOL)isDark {
    self.isDark = isDark;
}

- (CGRect)seekHitBandForBounds:(CGRect)bounds {
    NSAssert(NO, @"%@ must override seekHitBandForBounds:", NSStringFromClass(self.class));
    return bounds;
}

- (void)updateWaveform:(CGRect)bounds progress:(CGFloat)progress waveform:(AudioWaveform *)waveform {

}

- (void)updateProgress:(CGFloat)progress waveform:(AudioWaveform *__nullable)waveform {

}

- (void)dipBarsFromFraction:(double)from toFraction:(double)to {
    [_morph dipDisplayedSamplesFromFraction:from toFraction:to];
}

- (void)settleMorphImmediately {
    [_morph settleImmediately];
}

- (void)backingScaleDidChange {
    [_morph rebuildNow];
}

- (BOOL)supportsEnvelopeBake {
    return NO;
}

// Reached only through supportsEnvelopeBake, which answers NO here.
- (NSData *)envelopeSamplesForWaveform:(AudioWaveform *)waveform {
    return [NSData data];
}

- (CGImageRef)newEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples {
    return NULL;
}

- (CGImageRef)newUnplayedEnvelopeImageForSize:(CGSize)size scale:(CGFloat)scale samples:(NSData *)samples {
    return NULL;
}

- (CGFloat)unplayedOverPlayedOpacity {
    return 1;
}

// The energy columns' reference at the floor's 1,024, which every style but
// 3-Band reads its levels through (energyColumnLevelsForBarCount:waveform:).
- (CGFloat)normalizationGainForWaveform:(AudioWaveform *)waveform {
    if (!self.normalizesLevels || !waveform || !waveform->isComplete()) {
        return 1;
    }
    std::vector<float> meanSquares(kVibeWaveformEnergyColumns);
    waveform->getBarMeanSquares(meanSquares.size(),
                                VibeWaveformWindowReach(meanSquares.size(), kVibeWaveformEnergyColumns / 2),
                                meanSquares.data(), NULL);
    float reference = VibeWaveformFullScaleRMSForColumns(waveform, YES, meanSquares.data(),
                                                         meanSquares.size());
    return reference > 0 ? kVibeWaveformFullScaleRMS / reference : 1;
}

@end
