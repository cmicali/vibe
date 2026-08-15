//
// See WaveformRendererRegistry.h.
//

#import "WaveformRendererRegistry.h"
#import "AudioWaveformRenderer.h"
#import "DetailedAudioWaveformRenderer.h"
#import "SonicCirrusWaveformRenderer.h"
#import "BasicAudioWaveformRenderer.h"
#import "OversamplingDetailedAudioWaveformRenderer.h"

@implementation WaveformRendererRegistry

+ (NSDictionary<NSString *, Class> *)renderersByIdentifier {
    static NSDictionary<NSString *, Class> *renderers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableDictionary<NSString *, Class> *registry = [NSMutableDictionary new];
        for (Class renderer in @[BasicAudioWaveformRenderer.class,
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
        renderers = registry;
    });
    return renderers;
}

+ (NSArray<NSString *> *)availableIdentifiers {
    return [self renderersByIdentifier].allKeys;
}

+ (Class)rendererClassForIdentifier:(NSString *)identifier {
    return identifier.length ? [self renderersByIdentifier][identifier] : nil;
}

+ (NSString *)displayNameForIdentifier:(NSString *)identifier {
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
