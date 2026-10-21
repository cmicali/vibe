//
//  WaveformRenderer.mm
//  Vibe
//

#import "WaveformRenderer.h"
#import "WaveformMorphEngine.h"
#import "WaveformZoomMath.h"

#include <algorithm>
#include <climits>
#include <cstring>

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

void VibeStepPicture::releasePixels(void *info, const void *, size_t) {
    auto *pixels = static_cast<std::shared_ptr<Pixels> *>(info);
    (*pixels)->held.store(false, std::memory_order_release);
    delete pixels;
}

void VibeStepPicture::clear() {
    shown_.reset();
    spare_.reset();
    std::vector<float>().swap(samples_);
    stride_ = 0;
}

bool VibeStepPicture::begin(Frame &frame, const Look &look, const VibeRenderPixels &pixels,
                            const wavecore::StepWindow &window, size_t stride, const std::vector<float> &samples,
                            int inkTop, int inkBottom, float drawShare) {
    int x0 = pixels.x0, x1 = pixels.x1, width = pixels.width(), height = pixels.height;
    if (width <= 0 || height <= 0 || stride == 0) {
        clear();
        return false;
    }
    // The pixel columns to draw, from an x0 that counts pixels of the whole
    // bounds: the newly shown ones, and those whose samples changed.
    std::array<std::pair<int, int>, 8> &dirty = frame.dirty;
    size_t &dirtyCount = frame.dirtyCount;
    auto mark = [&](double a, double b) {
        int from = std::max(x0, (int)std::floor(a)), to = std::min(x1, (int)std::ceil(b));
        if (to > from && dirtyCount < dirty.size()) {
            dirty[dirtyCount++] = {from, to};
        }
    };
    int keep0 = std::max(x0, pixels_.x0), keep1 = std::min(x1, pixels_.x1);
    bool reuse = shown_ && look == look_ && look.framesPerPixel > 0 && stride == stride_ && keep1 > keep0 &&
                 samples_.size() == window_.columnCount() * stride && samples.size() == window.columnCount() * stride;
    if (reuse) {
        mark(x0, keep0);
        mark(keep1, x1);
        // A window's edges cut off the neighbours 3-Band reads between
        // column centers, so the pixels by either window's edges redraw.
        double edge = std::ceil(window.parts[1].framesPerColumn() / look.framesPerPixel) + 1;
        for (int at : {x0, x1, pixels_.x0, pixels_.x1}) {
            mark(at - edge, at + edge);
        }
        for (int p = 0; p < 2; p++) {
            const wavecore::StepPart &now = window.parts[p], &then = window_.parts[p];
            int64_t first = std::max(now.first, then.first);
            int64_t end = std::min(now.first + (int64_t)now.count, then.first + (int64_t)then.count);
            auto changed = [&](int64_t k) {
                const float *a = &samples[(window.offset(p) + size_t(k - now.first)) * stride];
                const float *b = &samples_[(window_.offset(p) + size_t(k - then.first)) * stride];
                for (size_t s = 0; s < stride; s++) {
                    if (a[s] != b[s]) {
                        return true;
                    }
                }
                return false;
            };
            // The first and the last column that changed, each scanned for
            // from its end, so a whole new picture costs two compares.
            int64_t changed0 = first, changed1 = end - 1;
            while (changed0 < end && !changed(changed0)) changed0++;
            while (changed1 > changed0 && !changed(changed1)) changed1--;
            // A column reaches the pixels over it, and read between centers
            // the pixels over its neighbours.
            if (changed0 < end) {
                double perPixel = now.framesPerColumn() / look.framesPerPixel;
                mark(double(changed0 - 1) * perPixel, double(changed1 + 2) * perPixel);
            }
        }
        std::sort(dirty.begin(), dirty.begin() + dirtyCount);
        size_t merged = 0;
        for (size_t i = 0; i < dirtyCount; i++) {
            if (merged > 0 && dirty[i].first <= dirty[merged - 1].second) {
                dirty[merged - 1].second = std::max(dirty[merged - 1].second, dirty[i].second);
            } else {
                dirty[merged++] = dirty[i];
            }
        }
        dirtyCount = merged;
        int drawn = 0;
        for (size_t i = 0; i < dirtyCount; i++) {
            drawn += dirty[i].second - dirty[i].first;
        }
        reuse = (float)drawn < drawShare * (float)width;
    }
    size_t size = size_t(width) * size_t(height);
    std::shared_ptr<Pixels> &target = frame.target;
    target = spare_ && !spare_->held.load(std::memory_order_acquire) ? spare_ : nullptr;
    if (!target || target->capacity < size) {
        target = std::make_shared<Pixels>();
        target->data.reset(static_cast<uint32_t *>(calloc(size, sizeof(uint32_t))));
        target->capacity = target->data ? size : 0;
        if (!target->data) {
            return false;
        }
    }
    uint32_t *out = target->data.get();
    // A recycled picture's ink goes, so every pixel starts at zero.
    std::memset(out + target->inkBegin, 0, (target->inkEnd - target->inkBegin) * sizeof(uint32_t));
    // The rows this picture may ink, in the buffer's order.
    int row0 = std::clamp(look.flipped ? height - inkBottom : inkTop, 0, height);
    int row1 = std::clamp(look.flipped ? height - inkTop : inkBottom, row0, height);
    if (reuse) {
        // Only the rows the last picture inked, which hold the same rows in
        // both, flipped or not.
        const uint32_t *before = shown_->data.get();
        size_t beforeWidth = size_t(pixels_.width());
        int from = int(shown_->inkBegin / beforeWidth), to = int((shown_->inkEnd + beforeWidth - 1) / beforeWidth);
        for (int row = from; row < std::min(to, height); row++) {
            uint32_t *line = out + size_t(row) * size_t(width);
            std::memcpy(line + (keep0 - x0), before + size_t(row) * beforeWidth + size_t(keep0 - pixels_.x0),
                        size_t(keep1 - keep0) * sizeof(uint32_t));
            for (size_t i = 0; i < dirtyCount; i++) {
                std::memset(line + (dirty[i].first - x0), 0, size_t(dirty[i].second - dirty[i].first) * sizeof(uint32_t));
            }
        }
        if (to > from) {
            row1 = std::max(row1, std::min(to, height));
            row0 = std::min(row0, from);
        }
    } else {
        dirty[0] = {x0, x1};
        dirtyCount = 1;
    }
    target->inkBegin = size_t(row0) * size_t(width);
    target->inkEnd = size_t(row1) * size_t(width);
    frame.top = look.flipped ? out + size_t(height - 1) * size_t(width) : out;
    frame.rowStride = look.flipped ? -(ptrdiff_t)width : (ptrdiff_t)width;
    return true;
}

CGImageRef VibeStepPicture::end(Frame &frame, const Look &look, const VibeRenderPixels &pixels,
                                const wavecore::StepWindow &window, size_t stride, const std::vector<float> &samples,
                                CGColorSpaceRef space, bool recycle) {
    std::shared_ptr<Pixels> &target = frame.target;
    int width = pixels.width(), height = pixels.height;
    size_t size = size_t(width) * size_t(height);
    uint32_t *out = target->data.get();
    target->held.store(true, std::memory_order_relaxed);
    CGDataProviderRef provider = CGDataProviderCreateWithData(new std::shared_ptr<Pixels>(target), out,
                                                              size * sizeof(uint32_t), releasePixels);
    CGImageRef image = CGImageCreate(size_t(width), size_t(height), 8, 32, size_t(width) * sizeof(uint32_t),
                                     VibePictureColorSpace(space),
                                     (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host,
                                     provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    spare_ = recycle ? shown_ : nullptr;
    shown_ = target;
    look_ = look;
    pixels_ = pixels;
    window_ = window;
    stride_ = stride;
    // Grown ahead, so a resize that widens the window frame by frame does
    // not reallocate them every frame.
    if (samples_.capacity() < samples.size()) {
        samples_.reserve(samples.size() + samples.size() / 2);
    }
    samples_.assign(samples.begin(), samples.end());
    return image;
}

// The block bars' pitch in points at bar density 1, and their cap.
static const CGFloat kBlockBarPitch = 4;
static const NSUInteger kMaxBlockBars = 1024;

@implementation WaveformRenderer {
    CGFloat _hoverHighlightX;
    // The detail's inserts the target was last filled after.
    uint64_t _detailInserts;
    // Where a remap builds the carried samples, kept so it allocates none.
    std::vector<float> _remapScratch;
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
    [_morph updateTargetForSize:size window:_pixels.window() identity:waveform relaid:!window.sameColumns(previous)
                          count:window.columnCount() * stride
                           fill:^(std::vector<float> &target) {
        for (int p = 0; p < 2; p++) {
            if (window.parts[p].count > 0) {
                fill(target.data() + window.offset(p) * stride, window.parts[p]);
            }
        }
    } remap:^(std::vector<float> &displayed, const std::vector<float> &target) {
        wavecore::RemapStepSamples(previous, window, stride, displayed, target, self->_remapScratch);
    }];
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
