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
        // A sentinel, forcing the first updateProgress: to paint every layer's
        // played or unplayed color rather than only the boundary delta.
        self.lastProgressBoundary = -1;
        _hoverHighlightX = -1;
    }
    return self;
}

- (CGFloat)hoverHighlightX {
    return _hoverHighlightX;
}

// Subclasses override this to paint, and call super to record the position.
- (void)setHoverHighlightX:(CGFloat)x {
    _hoverHighlightX = x;
}

- (void)setNormalizesLevels:(BOOL)normalizes {
    if (normalizes == _normalizesLevels) {
        return;
    }
    _normalizesLevels = normalizes;
    [self levelMappingDidChange];
}

- (void)setGainDB:(float)gainDB {
    if (gainDB == _gainDB) {
        return;
    }
    _gainDB = gainDB;
    [self levelMappingDidChange];
}

- (void)levelMappingDidChange {
    [_morph invalidateTarget];
}

- (void)fillEnergyLevels:(float *)out count:(NSUInteger)count stride:(NSUInteger)stride
               waveform:(AudioWaveform *)waveform {
    float fullScaleRMS = VibeWaveformFullScaleRMSForWaveform(waveform, self.normalizesLevels);
    float gainDB = self.gainDB;
    for (NSUInteger i = 0; i < count; i++) {
        out[i * stride] = VibeWaveformBarLevel(
                VibeWaveformEnergyColumnForBar(waveform, i, count).getMeanSquare(),
                fullScaleRMS, gainDB);
    }
}

// Abstract. Both are declared nonnull, and styleIdentifier is used as a
// dictionary key by AudioWaveformView's registry, so a subclass that forgets
// to override would otherwise raise deep inside -setup with nothing naming the
// culprit. Assert here, where the class is known, and return a marker that
// keeps a Release build registering something rather than crashing.
+ (NSString *)styleIdentifier {
    NSAssert(NO, @"%@ must override +styleIdentifier", NSStringFromClass(self));
    return NSStringFromClass(self);
}

+ (NSString *)displayName {
    NSAssert(NO, @"%@ must override +displayName", NSStringFromClass(self));
    return NSStringFromClass(self);
}

- (void)updateColors:(BOOL)isDark {
    self.isDark = isDark;
    // The colors have changed, so the cached played and unplayed colors on
    // every layer are stale. Force the next updateProgress: to repaint
    // everything.
    self.lastProgressBoundary = -1;
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

@end
