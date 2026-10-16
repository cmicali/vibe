//
//  WaveformRenderer.mm
//  Vibe
//

#import "WaveformRenderer.h"
#import "WaveformMorphEngine.h"

CGImageRef VibeNewImageWithPixels(NSMutableData *pixels, size_t width, size_t height) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * sizeof(uint32_t), space,
                                     (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    return image;
}

@implementation WaveformRenderer {
    CGFloat _hoverHighlightX;
    // Bumped whenever _window's columns change, for the morph's layout key.
    NSUInteger _windowGeneration;
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
        _centered = YES;
        _renderRect = CGRectNull;
    }
    return self;
}

- (VibeRenderPixels)renderPixelsForSize:(CGSize)size {
    VibeRenderPixels pixels;
    pixels.scale = VibeBackingScaleForLayer(self.parentLayer);
    CGRect drawn = CGRectMake(0, 0, size.width, size.height);
    if (!CGRectIsNull(_renderRect)) {
        drawn = CGRectIntersection(drawn, _renderRect);
    }
    if (CGRectIsNull(drawn) || drawn.size.width <= 0 || size.height <= 0) {
        return pixels;
    }
    pixels.x0 = (int)floor(CGRectGetMinX(drawn) * pixels.scale);
    pixels.x1 = (int)ceil(CGRectGetMaxX(drawn) * pixels.scale);
    pixels.height = (int)lround(size.height * pixels.scale);
    return pixels;
}

- (void)updateStepTargetForSize:(CGSize)size waveform:(AudioWaveform *)waveform
                columnsPerPixel:(double)columnsPerPixel stride:(NSUInteger)stride
                           fill:(void (^)(float *out, const wavecore::StepPart &part))fill {
    int64_t total = waveform ? waveform->totalFrames() : _window.totalFrames;
    double pixels = size.width * _pixels.scale;
    _framesPerPixel = pixels > 0 ? (double)total / pixels : 0;
    wavecore::StepWindow window = wavecore::StepWindowForPixels(total, _framesPerPixel, columnsPerPixel,
                                                                _pixels.x0, _pixels.x1);
    wavecore::StepWindow previous = _window;
    if (!window.sameColumns(previous)) {
        _windowGeneration++;
    }
    _window = window;
    [_morph updateTargetForSize:size identity:waveform layout:_windowGeneration
                          count:window.columnCount() * stride
                           fill:^(std::vector<float> &target) {
        float *out = target.data();
        for (const wavecore::StepPart &part : window.parts) {
            if (part.count > 0) {
                fill(out, part);
            }
            out += part.count * stride;
        }
    } remap:^(std::vector<float> &displayed, const std::vector<float> &target) {
        wavecore::RemapStepSamples(previous, window, stride, displayed, target);
    }];
}

- (void)dipStepColumnsFromFraction:(double)from toFraction:(double)to stride:(NSUInteger)stride {
    std::vector<std::pair<size_t, size_t>> ranges;
    double total = (double)_window.totalFrames;
    size_t offset = 0;
    for (const wavecore::StepPart &part : _window.parts) {
        double frames = part.framesPerColumn(), count = (double)part.count;
        // Outward to whole columns.
        double begin = clampRange(floor(from * total / frames) - (double)part.first, 0.0, count);
        double end = clampRange(ceil(to * total / frames) - (double)part.first, 0.0, count);
        if (end > begin) {
            ranges.push_back({(offset + (size_t)begin) * stride, (offset + (size_t)end) * stride});
        }
        offset += part.count;
    }
    [_morph dipDisplayedSampleRanges:ranges];
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

- (void)setCentered:(BOOL)centered {
    if (_centered == centered) return;
    _centered = centered;
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

- (void)fillEnergyLevels:(float *)out stride:(NSUInteger)stride framesPerColumn:(double)frames
                   first:(int64_t)first count:(NSUInteger)count waveform:(AudioWaveform *)waveform {
    std::vector<float> meanSquares(count);
    // The reach is gone by the floor's 1,024 columns across the track.
    double columns = frames > 0 ? (double)waveform->totalFrames() / frames : 0;
    float reach = VibeWaveformWindowReach((NSUInteger)llround(columns), kVibeWaveformEnergyColumns / 2);
    waveform->meanSquares(frames, first, count, reach, meanSquares.data(), NULL);
    float fullScaleRMS = VibeWaveformFullScaleRMSForWaveform(waveform, self.normalizesLevels);
    float gainDB = self.gainDB;
    for (NSUInteger i = 0; i < count; i++) {
        out[i * stride] = VibeWaveformBarLevel(meanSquares[i], fullScaleRMS, gainDB);
    }
}

- (void)fillEnergyLevels:(float *)out count:(NSUInteger)count stride:(NSUInteger)stride
               waveform:(AudioWaveform *)waveform {
    [self fillEnergyLevels:out stride:stride framesPerColumn:(double)waveform->totalFrames() / (double)count
                     first:0 count:count waveform:waveform];
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
    return [self paletteKind] != VibeWaveformPaletteKindTheme;
}

+ (VibeWaveformPaletteKind)paletteKind {
    return VibeWaveformPaletteKindTheme;
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

// The energy columns' reference at the floor's 1,024, which every style but
// 3-Band and Spectrum reads its levels through.
- (CGFloat)normalizationGainForWaveform:(AudioWaveform *)waveform {
    if (!self.normalizesLevels || !waveform || !waveform->isComplete()) {
        return 1;
    }
    float reference = VibeWaveformFullScaleRMSForWaveform(waveform, YES);
    return reference > 0 ? kVibeWaveformFullScaleRMS / reference : 1;
}

@end
