//
//  WaveformRenderer.mm
//  Vibe
//

#import "WaveformRenderer.h"
#import "WaveformMorphEngine.h"
#import "WaveformZoomMath.h"

CGColorSpaceRef VibePictureColorSpace(CGColorSpaceRef space) {
    static CGColorSpaceRef sRGB = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    return space ?: sRGB;
}

CGImageRef VibeNewImageWithPixels(NSMutableData *pixels, size_t width, size_t height, CGColorSpaceRef space) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGImageRef image = CGImageCreate(width, height, 8, 32, width * sizeof(uint32_t), VibePictureColorSpace(space),
                                     (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

// The block bars' pitch in points at bar density 1, and their cap.
static const CGFloat kBlockBarPitch = 4;
static const NSUInteger kMaxBlockBars = 1024;

@implementation WaveformRenderer {
    CGFloat _hoverHighlightX;
    // The detail's inserts the target was last filled after.
    uint64_t _detailInserts;
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
                columnsPerPixel:(double)columnsPerPixel
                           fill:(void (^)(float *out, const wavecore::StepPart &part))fill {
    int64_t total = waveform ? waveform->totalFrames() : _window.totalFrames;
    double pixels = size.width * _pixels.scale;
    wavecore::StepWindow window = wavecore::StepWindowForPixels(total, pixels > 0 ? (double)total / pixels : 0,
                                                                columnsPerPixel, _pixels.x0, _pixels.x1);
    wavecore::StepWindow previous = _window;
    _window = window;
    uint64_t inserts = waveform ? waveform->detail().insertCount() : _detailInserts;
    if (inserts != _detailInserts) {
        _detailInserts = inserts;
        [_morph invalidateTarget];
    }
    NSUInteger stride = _morph.samplesPerBar;
    [_morph updateTargetForSize:size identity:waveform relaid:!window.sameColumns(previous)
                          count:window.columnCount() * stride
                           fill:^(std::vector<float> &target) {
        for (int p = 0; p < 2; p++) {
            if (window.parts[p].count > 0) {
                fill(target.data() + window.offset(p) * stride, window.parts[p]);
            }
        }
    } remap:^(std::vector<float> &displayed, const std::vector<float> &target) {
        wavecore::RemapStepSamples(previous, window, stride, displayed, target);
    }];
}

- (void)rebuildIfWindowMoved {
    if (!(_drawnPixels == _pixels)) {
        [_morph rebuildNow];
    }
}

- (double)minimumFramesPerPointForWaveform:(AudioWaveform *)waveform {
    // Wider, blockBarCountForWidth: only widens its bars.
    double barsWidth = kMaxBlockBars * kBlockBarPitch / clampMin(self.barDensity, 0.01);
    return fmax(VibeWaveformMinimumFramesPerPoint(waveform->binFrames()), (double)waveform->totalFrames() / barsWidth);
}

- (double)framesPerPixel {
    double pixels = [_morph size].width * _pixels.scale;
    return pixels > 0 ? (double)_window.totalFrames / pixels : 0;
}


- (CGFloat)hoverHighlightX {
    return _hoverHighlightX;
}

- (NSUInteger)blockBarCountForWidth:(CGFloat)width {
    NSUInteger count = (NSUInteger)llround(clampMin(width, 1) * self.barDensity / kBlockBarPitch);
    return clampRange(count, (NSUInteger)2, kMaxBlockBars);
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

- (void)fillLevels:(float *)out stride:(NSUInteger)stride framesPerColumn:(double)frames
             first:(int64_t)first count:(NSUInteger)count waveform:(AudioWaveform *)waveform {
    _fillColumns.resize(count);
    waveform->columns(frames, first, count, _fillColumns.data());
    [self fillLevels:out stride:stride columns:_fillColumns.data() count:count waveform:waveform];
}

- (void)fillLevels:(float *)out stride:(NSUInteger)stride columns:(const wavecore::Column *)columns
             count:(NSUInteger)count waveform:(AudioWaveform *)waveform {
    float fullScaleRMS = VibeWaveformFullScaleRMSForWaveform(waveform, self.normalizesLevels);
    float gainDB = self.gainDB;
    for (NSUInteger i = 0; i < count; i++) {
        out[i * stride] = VibeWaveformBarLevel(columns[i].loudest, fullScaleRMS, gainDB);
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
    if (_window.columnCount() == 0) {
        [_morph dipDisplayedSamplesFromFraction:from toFraction:to];
        return;
    }
    std::vector<std::pair<size_t, size_t>> ranges;
    double total = (double)_window.totalFrames;
    size_t stride = _morph.samplesPerBar;
    for (int p = 0; p < 2; p++) {
        const wavecore::StepPart &part = _window.parts[p];
        double frames = part.framesPerColumn(), count = (double)part.count;
        // Outward to whole columns.
        double begin = clampRange(floor(from * total / frames) - (double)part.first, 0.0, count);
        double end = clampRange(ceil(to * total / frames) - (double)part.first, 0.0, count);
        if (end > begin) {
            ranges.push_back({(_window.offset(p) + (size_t)begin) * stride, (_window.offset(p) + (size_t)end) * stride});
        }
    }
    [_morph dipDisplayedSampleRanges:ranges];
}

- (void)settleMorphImmediately {
    [_morph settleImmediately];
}

- (void)backingScaleDidChange {
    _pixels = [self renderPixelsForSize:[_morph size]];
    [_morph rebuildNow];
}

- (BOOL)isSettled {
    return !_morph || _morph.isSettled;
}

@end
