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
