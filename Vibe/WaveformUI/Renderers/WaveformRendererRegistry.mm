//
// See WaveformRendererRegistry.h.
//

#import "WaveformRendererRegistry.h"
#import "AppSettings.h"
#import "AudioWaveformRenderer.h"
#import "DetailedAudioWaveformRenderer.h"
#import "SonicCirrusWaveformRenderer.h"
#import "BasicAudioWaveformRenderer.h"
#import "CupertinoWaveformRenderer.h"
#import "OversamplingDetailedAudioWaveformRenderer.h"
#import "ThreeBandWaveformRenderer.h"
#import "VibeStrings.h"

static NSString *const kWiggleIdentifier = SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE;
static NSString *const kCupertinoBasicIdentifier = @"cupertino_basic";
static NSString *const kSpectrumIdentifier = @"spectrum";

// Fine transients, so the Detailed family's sampling differences survive a
// thumbnail. The bands keep a mix's measured balance — lows near the whole,
// mids ~12 dB and highs ~17 dB under — each drifting on its own, so 3-Band's
// thumbnail shows every ring.
static AudioWaveform *VibePreviewWaveform(void) {
    static AudioWaveform *waveform;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        waveform = new AudioWaveform(true);
        NSUInteger chunks = waveform->getNumChunks();
        for (NSUInteger i = 0; i < chunks; i++) {
            float x = (float)i / (float)chunks;
            float envelope = 0.08f + 0.48f * powf(fabsf(sinf(x * 23)), 2)
                    + 0.16f * fabsf(sinf(x * 109));
            float level = envelope * (0.25f + 0.75f * fabsf(sinf(i * 0.73f) * sinf(i * 0.19f)));
            float meanSquare = level * level * 0.5f;
            AudioWaveformCacheChunk chunk;
            chunk.set(-level * (0.6f + 0.4f * fabsf(sinf(x * 17))), level, meanSquare, 1);
            waveform->setChunkAtIndex(chunk, i);
            float bands[kAudioWaveformBandCount] = {
                meanSquare * (0.2f + 0.8f * powf(fabsf(sinf(x * 31)), 2)),
                meanSquare * 0.06f * (0.2f + 0.8f * fabsf(sinf(x * 13 + 1))),
                meanSquare * 0.02f * (0.1f + 0.9f * fabsf(sinf(i * 0.37f))),
            };
            waveform->setBandSumSquaresAtIndex(bands, i);
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
        for (Class renderer in @[BasicAudioWaveformRenderer.class,
                                 CupertinoWaveformRenderer.class,
                                 CupertinoBasicWaveformRenderer.class,
                                 SonicCirrusWaveformRenderer.class,
                                 DetailedAudioWaveformRenderer.class,
                                 x2OversamplingDetailedAudioWaveformRenderer.class,
                                 x4OversamplingDetailedAudioWaveformRenderer.class,
                                 x8OversamplingDetailedAudioWaveformRenderer.class,
                                 ThreeBandWaveformRenderer.class]) {
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
        registry[kWiggleIdentifier] = DetailedAudioWaveformRenderer.class;
        registry[kSpectrumIdentifier] = ThreeBandWaveformRenderer.class;
        renderers = registry;
    });
    return renderers;
}

+ (NSArray<NSString *> *)availableIdentifiers {
    return [self renderersByIdentifier].allKeys;
}

+ (BOOL)supportsBarDensityForIdentifier:(NSString *)identifier {
    return [identifier isEqualToString:@"basic"] || [identifier isEqualToString:@"cupertino"] ||
           [identifier isEqualToString:@"sonic_cirrus"] || [identifier isEqualToString:kWiggleIdentifier];
}

+ (BOOL)supportsCenteringForIdentifier:(NSString *)identifier {
    return ![identifier isEqualToString:@"sonic_cirrus"] && ![identifier isEqualToString:kCupertinoBasicIdentifier];
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

+ (BOOL)usesBandPaletteForIdentifier:(NSString *)identifier {
    return [identifier isEqualToString:[ThreeBandWaveformRenderer styleIdentifier]];
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
    AudioWaveformRenderer *renderer = [self rendererForResolvedIdentifier:identifier
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

+ (AudioWaveformRenderer *)rendererForResolvedIdentifier:(NSString *)identifier
                                         layer:(CALayer *)layer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    Class renderer = [self renderersByIdentifier][identifier];
    NSAssert(renderer, @"Resolve the waveform style before constructing its renderer");
    if ([identifier isEqualToString:kWiggleIdentifier]) {
        return [[renderer alloc] initWithLayer:layer bounds:bounds isDark:isDark wiggle:YES];
    }
    if ([identifier isEqualToString:kSpectrumIdentifier]) {
        return [[renderer alloc] initWithLayer:layer bounds:bounds isDark:isDark spectrum:YES];
    }
    return [[renderer alloc] initWithLayer:layer bounds:bounds isDark:isDark];
}

+ (NSString *)displayNameForIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:kWiggleIdentifier]) return STR_WAVEFORM_STYLE_WIGGLE;
    if ([identifier isEqualToString:kSpectrumIdentifier]) return STR_WAVEFORM_STYLE_SPECTRUM;
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
