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
#import "VibeStrings.h"

static NSString *const kWiggleMCIdentifier = @"wiggle";
static NSString *const kWiggleIdentifier = @"wiggle_centered";

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
                                 x8OversamplingDetailedAudioWaveformRenderer.class]) {
            // A nil key raises, so the registry never takes one: the base class
            // asserts on the missing override, and this keeps a Release build
            // with an unoverridden subclass down to one missing style.
            NSString *identifier = [renderer styleIdentifier];
            if (identifier.length == 0) {
                LogError(@"Waveform renderer %@ has no style identifier; not registering it",
                         NSStringFromClass(renderer));
                continue;
            }
            registry[identifier] = renderer;
        }
        registry[kWiggleMCIdentifier] = DetailedAudioWaveformRenderer.class;
        registry[kWiggleIdentifier] = DetailedAudioWaveformRenderer.class;
        renderers = registry;
    });
    return renderers;
}

+ (NSArray<NSString *> *)availableIdentifiers {
    return [self renderersByIdentifier].allKeys;
}

+ (BOOL)supportsBarDensityForIdentifier:(NSString *)identifier {
    return [identifier isEqualToString:@"basic"] || [identifier isEqualToString:@"cupertino"] ||
           [identifier isEqualToString:@"sonic_cirrus"] ||
           [identifier isEqualToString:kWiggleIdentifier] || [identifier isEqualToString:kWiggleMCIdentifier];
}

+ (BOOL)supportsBarWidthForIdentifier:(NSString *)identifier {
    return [identifier isEqualToString:@"cupertino_basic"] || [self supportsBarDensityForIdentifier:identifier];
}

+ (BOOL)supportsLevelsForIdentifier:(NSString *)identifier {
    return ![identifier isEqualToString:@"cupertino_basic"];
}

+ (CGImageRef)newPreviewForIdentifier:(NSString *)identifier dark:(BOOL)dark
                              theme:(WaveformTheme *)theme barDensity:(CGFloat)barDensity
                           barWidth:(CGFloat)barWidth
                          normalize:(BOOL)normalize gainDB:(float)gainDB {
    CGRect bounds = CGRectMake(0, 0, 360, 64);
    CALayer *layer = [CALayer layer];
    layer.bounds = bounds;
    layer.contentsScale = 2;
    AudioWaveform waveform;
    for (NSUInteger i = 0; i < waveform.getNumChunks(); i++) {
        float x = (float)i / (float)waveform.getNumChunks();
        float envelope = 0.08f + 0.48f * powf(fabsf(sinf(x * 23)), 2)
                + 0.16f * fabsf(sinf(x * 109));
        // Fine transients keep the higher-resolution styles visible in a thumbnail.
        float level = envelope * (0.25f + 0.75f * fabsf(sinf(i * 0.73f) * sinf(i * 0.19f)));
        AudioWaveformCacheChunk chunk;
        chunk.set(-level * (0.6f + 0.4f * fabsf(sinf(x * 17))), level, level * level * 0.5f, 1);
        waveform.setChunkAtIndex(chunk, i);
    }
    AudioWaveformRenderer *renderer = [self rendererForResolvedIdentifier:identifier
            layer:layer bounds:bounds isDark:dark];
    renderer.theme = theme;
    renderer.barDensity = barDensity;
    renderer.barWidthScale = barWidth;
    renderer.normalizesLevels = normalize;
    renderer.gainDB = gainDB;
    [renderer updateColors:dark];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [renderer updateWaveform:bounds progress:0.4 waveform:&waveform];
    [renderer settleMorphImmediately];
    [CATransaction commit];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, 720, 128, 8, 0, space,
            kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    CGContextScaleCTM(context, 2, 2);
    [layer renderInContext:context];
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

+ (AudioWaveformRenderer *)rendererForResolvedIdentifier:(NSString *)identifier
                                         layer:(CALayer *)layer bounds:(CGRect)bounds isDark:(BOOL)isDark {
    Class renderer = [self renderersByIdentifier][identifier];
    NSAssert(renderer, @"Resolve the waveform style before constructing its renderer");
    BOOL centered = [identifier isEqualToString:kWiggleIdentifier];
    if (centered || [identifier isEqualToString:kWiggleMCIdentifier]) {
        return [[renderer alloc] initWithLayer:layer bounds:bounds isDark:isDark wiggle:YES centered:centered];
    }
    return [[renderer alloc] initWithLayer:layer bounds:bounds isDark:isDark];
}

+ (NSString *)displayNameForIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:kWiggleMCIdentifier]) return STR_WAVEFORM_STYLE_WIGGLE;
    if ([identifier isEqualToString:kWiggleIdentifier]) return STR_WAVEFORM_STYLE_WIGGLE_CENTERED;
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
