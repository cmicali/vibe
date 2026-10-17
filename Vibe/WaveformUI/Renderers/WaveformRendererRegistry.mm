//
// See WaveformRendererRegistry.h.
//

#import "WaveformRendererRegistry.h"
#import "AppSettings.h"
#import "WaveformRenderer.h"
#import "DetailedWaveformRenderer.h"
#import "SonicCirrusWaveformRenderer.h"
#import "BasicWaveformRenderer.h"
#import "CupertinoWaveformRenderer.h"
#import "OversamplingDetailedWaveformRenderer.h"
#import "ThreeBandWaveformRenderer.h"
#import "VibeStrings.h"

static NSString *const kWiggleIdentifier = SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE;
static NSString *const kCupertinoBasicIdentifier = @"cupertino_basic";

// The Detailed family in its Type chooser's order.
static NSArray<NSString *> *DetailedTypeIdentifiers(void) {
    return @[DetailedWaveformRenderer.styleIdentifier,
             x2OversamplingDetailedWaveformRenderer.styleIdentifier,
             x4OversamplingDetailedWaveformRenderer.styleIdentifier,
             x8OversamplingDetailedWaveformRenderer.styleIdentifier];
}

// Choosing Detailed from another style lands on the 4x type.
static NSString *DetailedStyleIdentifier(void) {
    return x4OversamplingDetailedWaveformRenderer.styleIdentifier;
}

// Fine transients, so the Detailed family's sampling differences survive a
// thumbnail. The bands keep a mix's measured balance — lows near the whole,
// mids ~12 dB and highs ~17 dB under — each drifting on its own, so 3-Band's
// thumbnail shows every ring. Its loudest window sits under the fixed
// reference, near a typical master's, so Normalize visibly raises it.
static AudioWaveform *VibePreviewWaveform(void) {
    static AudioWaveform *waveform;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // One frame a bin: the preview's resolution is its bin count. A bin
        // lasts as long as a real summary's, so a loudest window spans three
        // bins as it does there. At 44.1 kHz it would span 882 and average
        // every hit away.
        const NSUInteger bins = 8192;
        waveform = new AudioWaveform(1, true, 44100.0 / wavecore::kBaseBinFrames);
        for (NSUInteger i = 0; i < bins; i++) {
            float x = (float)i / (float)bins;
            float envelope = 0.08f + 0.48f * powf(fabsf(sinf(x * 23)), 2)
                    + 0.16f * fabsf(sinf(x * 109));
            float level = 0.8f * envelope * (0.25f + 0.75f * fabsf(sinf(i * 0.73f) * sinf(i * 0.19f)));
            float meanSquare = level * level * 0.5f;
            float lo = -level * (0.6f + 0.4f * fabsf(sinf(x * 17))), hi = level;
            double bands[wavecore::kBandCount] = {
                meanSquare * (0.2f + 0.8f * powf(fabsf(sinf(x * 31)), 2)),
                meanSquare * 0.06f * (0.2f + 0.8f * fabsf(sinf(x * 13 + 1))),
                meanSquare * 0.02f * (0.1f + 0.9f * fabsf(sinf(i * 0.37f))),
            };
            waveform->appendBin(lo, hi, meanSquare, bands, 1);
        }
        waveform->markComplete();
    });
    return waveform;
}

@implementation WaveformRendererRegistry

+ (NSDictionary<NSString *, Class> *)renderersByIdentifier {
    static NSDictionary<NSString *, Class> *renderers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, Class> *registry = [NSMutableDictionary new];
        for (Class renderer in @[BasicWaveformRenderer.class,
                                 CupertinoWaveformRenderer.class,
                                 CupertinoBasicWaveformRenderer.class,
                                 SonicCirrusWaveformRenderer.class,
                                 DetailedWaveformRenderer.class,
                                 x2OversamplingDetailedWaveformRenderer.class,
                                 x4OversamplingDetailedWaveformRenderer.class,
                                 x8OversamplingDetailedWaveformRenderer.class,
                                 ThreeBandWaveformRenderer.class,
                                 SpectrumWaveformRenderer.class]) {
            // A nil key raises; in Release an unoverridden subclass costs one
            // style, not the registry.
            NSString *identifier = [renderer styleIdentifier];
            if (identifier.length == 0) {
                LogError(@"Waveform renderer %@ has no style identifier; not registering it",
                         NSStringFromClass(renderer));
                continue;
            }
            registry[identifier] = renderer;
        }
        registry[kWiggleIdentifier] = DetailedWaveformRenderer.class;
        renderers = registry;
    });
    return renderers;
}

+ (NSArray<NSString *> *)availableIdentifiers {
    return [self renderersByIdentifier].allKeys;
}

+ (NSArray<NSString *> *)styleIdentifiers {
    NSMutableSet<NSString *> *styles = [NSMutableSet set];
    for (NSString *identifier in [self availableIdentifiers]) {
        [styles addObject:[self styleIdentifierForIdentifier:identifier]];
    }
    return [styles.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [[self displayNameForIdentifier:a] localizedStandardCompare:[self displayNameForIdentifier:b]];
    }];
}

+ (NSString *)styleIdentifierForIdentifier:(NSString *)identifier {
    return [DetailedTypeIdentifiers() containsObject:identifier] ? DetailedStyleIdentifier() : identifier;
}

+ (NSArray<NSString *> *)typeIdentifiersForIdentifier:(NSString *)identifier {
    NSArray<NSString *> *types = DetailedTypeIdentifiers();
    return [types containsObject:identifier] ? types : @[];
}

// Three keys, not one format string, so each reaches the translator in
// context. Detailed's type is the style's own name.
+ (NSString *)typeDisplayNameForIdentifier:(NSString *)identifier {
    NSDictionary<NSString *, NSString *> *names = @{
        x2OversamplingDetailedWaveformRenderer.styleIdentifier: STR_WAVEFORM_TYPE_OVERSAMPLED_X2,
        x4OversamplingDetailedWaveformRenderer.styleIdentifier: STR_WAVEFORM_TYPE_OVERSAMPLED_X4,
        x8OversamplingDetailedWaveformRenderer.styleIdentifier: STR_WAVEFORM_TYPE_OVERSAMPLED_X8,
    };
    return names[identifier] ?: [self displayNameForIdentifier:identifier];
}

+ (BOOL)supportsBarDensityForIdentifier:(NSString *)identifier {
    return [identifier isEqualToString:@"basic"] || [identifier isEqualToString:@"cupertino"] ||
           [identifier isEqualToString:@"sonic_cirrus"] || [identifier isEqualToString:kWiggleIdentifier];
}

+ (BOOL)supportsCenteringForIdentifier:(NSString *)identifier {
    return ![identifier isEqualToString:@"sonic_cirrus"] && ![identifier isEqualToString:kCupertinoBasicIdentifier];
}

+ (BOOL)supportsGradientForIdentifier:(NSString *)identifier {
    return ![identifier isEqualToString:SpectrumWaveformRenderer.styleIdentifier] &&
           ![identifier isEqualToString:kCupertinoBasicIdentifier];
}

+ (BOOL)supportsBarWidthForIdentifier:(NSString *)identifier {
    return [identifier isEqualToString:kCupertinoBasicIdentifier] || [self supportsBarDensityForIdentifier:identifier];
}

+ (BOOL)supportsLevelsForIdentifier:(NSString *)identifier {
    return ![identifier isEqualToString:kCupertinoBasicIdentifier];
}

+ (BOOL)readsBandsForIdentifier:(NSString *)identifier {
    return identifier && [[self renderersByIdentifier][identifier] readsBands];
}

+ (VibeWaveformPaletteKind)paletteKindForIdentifier:(NSString *)identifier {
    Class renderer = identifier ? [self renderersByIdentifier][identifier] : nil;
    return renderer ? [renderer paletteKind] : VibeWaveformPaletteKindTheme;
}

+ (NSArray<VibeColor *> *)swatchColorsForIdentifier:(NSString *)identifier theme:(WaveformTheme *)theme {
    switch ([self paletteKindForIdentifier:identifier]) {
        case VibeWaveformPaletteKindBands:
            return [theme.bandColors subarrayWithRange:NSMakeRange(0, 3)];
        case VibeWaveformPaletteKindSpectrum:
            return theme.spectrumColors;
        case VibeWaveformPaletteKindTheme:
            return @[theme.playedColor, theme.playedColor, theme.playedColor];
    }
}

+ (BOOL)drawsPlayheadLineForIdentifier:(NSString *)identifier chosen:(NSNumber *)chosen {
    return chosen != nil ? chosen.boolValue : [self readsBandsForIdentifier:identifier];
}

// Hosts the REAL renderer in a detached layer, so the Settings preview and the
// widget strip cannot drift from what the views draw.
+ (CGImageRef)newBakedImageForWaveform:(AudioWaveform *)waveform
                            identifier:(NSString *)identifier
                             pointSize:(CGSize)size scale:(CGFloat)scale
                              progress:(CGFloat)progress dark:(BOOL)dark
                                 theme:(WaveformTheme *)theme
                            barDensity:(CGFloat)barDensity barWidth:(CGFloat)barWidth
                              centered:(BOOL)centered
                             normalize:(BOOL)normalize gainDB:(float)gainDB {
    if (size.width <= 0 || size.height <= 0 || scale <= 0) {
        return NULL;
    }
    CGRect bounds = CGRectMake(0, 0, size.width, size.height);
    CALayer *layer = [CALayer layer];
    layer.bounds = bounds;
    layer.contentsScale = scale;
    WaveformRenderer *renderer = [self rendererForResolvedIdentifier:identifier
            layer:layer bounds:bounds isDark:dark];
    renderer.theme = theme;
    renderer.barDensity = barDensity;
    renderer.barWidthScale = barWidth;
    renderer.centered = centered;
    renderer.normalizesLevels = normalize;
    renderer.gainDB = gainDB;
    [renderer updateColors:dark];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    VibeColor *playhead = theme.playheadColor;
    [renderer updateWaveform:bounds progress:playhead ? 1 : progress waveform:waveform];
    // No display link here to ease the bars to their targets.
    [renderer settleMorphImmediately];
    if (playhead) {
        // The line the views draw, where they draw it.
        CALayer *line = [CALayer layer];
        line.backgroundColor = playhead.CGColor;
        line.frame = VibePlayheadLineRect(progress * size.width, [renderer seekHitBandForBounds:bounds],
                                          size.width, scale);
        [layer addSublayer:line];
    }
    [CATransaction commit];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, (size_t)llround(size.width * scale),
            (size_t)llround(size.height * scale), 8, 0, space,
            kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    CGContextScaleCTM(context, scale, scale);
    [layer renderInContext:context];
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

+ (CGImageRef)newPreviewForIdentifier:(NSString *)identifier dark:(BOOL)dark
                              theme:(WaveformTheme *)theme barDensity:(CGFloat)barDensity
                           barWidth:(CGFloat)barWidth centered:(BOOL)centered
                          normalize:(BOOL)normalize gainDB:(float)gainDB {
    return [self newBakedImageForWaveform:VibePreviewWaveform() identifier:identifier
                                pointSize:CGSizeMake(360, 64) scale:2 progress:0.4
                                     dark:dark theme:theme barDensity:barDensity
                                 barWidth:barWidth centered:centered normalize:normalize gainDB:gainDB];
}

// The ObjC-safe door onto the bake: a plain .m caller cannot name the C++
// AudioWaveform, but can hold the Codable wrapper.
+ (CGImageRef)newImageForCodableWaveform:(CodableAudioWaveform *)waveform
                              identifier:(NSString *)identifier
                               pointSize:(CGSize)size scale:(CGFloat)scale
                                progress:(CGFloat)progress dark:(BOOL)dark
                                   theme:(WaveformTheme *)theme
                              barDensity:(CGFloat)barDensity barWidth:(CGFloat)barWidth
                                centered:(BOOL)centered
                               normalize:(BOOL)normalize gainDB:(float)gainDB {
    AudioWaveform *raw = waveform.waveform;
    return raw ? [self newBakedImageForWaveform:raw identifier:identifier pointSize:size
                                          scale:scale progress:progress dark:dark theme:theme
                                     barDensity:barDensity barWidth:barWidth centered:centered
                                      normalize:normalize gainDB:gainDB]
               : NULL;
}

+ (WaveformRenderer *)rendererForResolvedIdentifier:(NSString *)identifier
                                         layer:(CALayer *)layer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    Class renderer = [self renderersByIdentifier][identifier];
    NSAssert(renderer, @"Resolve the waveform style before constructing its renderer");
    if ([identifier isEqualToString:kWiggleIdentifier]) {
        return [[renderer alloc] initWithLayer:layer bounds:bounds isDark:isDark wiggle:YES];
    }
    return [[renderer alloc] initWithLayer:layer bounds:bounds isDark:isDark];
}

+ (NSString *)displayNameForIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:kWiggleIdentifier]) return STR_WAVEFORM_STYLE_WIGGLE;
    return [[self renderersByIdentifier][identifier] displayName] ?: identifier;
}

+ (NSString *)resolveStyleIdentifier:(NSString *)identifier {
    NSDictionary<NSString *, Class> *renderers = [self renderersByIdentifier];
    NSString *style = identifier;
    if (!style.length || !renderers[style]) {
        style = SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT;
    }
    if (!renderers[style]) {
        style = renderers.allKeys.firstObject;
    }
    return style;
}

@end
