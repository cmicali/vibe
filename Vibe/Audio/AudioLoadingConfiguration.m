//
//  AudioLoadingConfiguration.m
//  Vibe
//

#import "AudioLoadingConfiguration.h"

#include <math.h>

NSString * const VibeAudioLoadingConfigurationErrorDomain =
        @"com.vibe.audio-loading-configuration";

static const NSUInteger kMaximumSafeBackgroundMaterializations = 4;
static const NSUInteger kMaximumSafeLocalMetadataParseConcurrency = 16;
static const NSUInteger kMaximumDiagnosticInteractiveMaterializations = 64;
static const NSUInteger kMaximumTunablePendingCount = 1024;
static const NSUInteger kMaximumTunablePrefetchDepth = 1;
static const NSUInteger kMaximumTunableRetryCount = 64;
static const NSTimeInterval kMaximumTunableDuration = 24.0 * 60.0 * 60.0;

VibeAudioLoadingConfigurationValues VibeAudioLoadingProductionConfigurationValues(void) {
    VibeAudioLoadingConfigurationValues values;
    values.maximumBackgroundMaterializations = 1;
    values.localMetadataParseConcurrency = 4;
    values.prefetchDepth = 1;
    // Handle-run admission is independent (spec J8); changing foreground
    // transfer concurrency would be a separate policy decision.
    values.maximumInteractiveMaterializations = 3;
    values.maximumInteractivePendingMaterializations = 1;
    values.maximumBackgroundPendingMaterializations = 6;
    values.interactiveAdmissionGrace = 5.0;
    values.backgroundAdmissionGrace = 10.0;
    values.metadataRetryCount = 2;
    values.openTimeouts = VibeAudioOpenDefaultTimeoutConfiguration();
    return values;
}

static NSError *VibeInvalidConfigurationValue(NSString *field, NSNumber *value) {
    return [NSError errorWithDomain:VibeAudioLoadingConfigurationErrorDomain
                               code:VibeAudioLoadingConfigurationErrorInvalidValue
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"Invalid audio loading configuration value for %@", field],
        @"field": field,
        @"value": value,
    }];
}

@implementation AudioLoadingConfiguration

+ (instancetype)productionConfiguration {
    NSError *error = nil;
    AudioLoadingConfiguration *configuration = [[self alloc]
            initWithValues:VibeAudioLoadingProductionConfigurationValues()
                       error:&error];
    NSAssert(configuration != nil, @"Production audio loading configuration is invalid: %@", error);
    return configuration;
}

- (instancetype)initWithValues:(VibeAudioLoadingConfigurationValues)values
                          error:(NSError *__autoreleasing *)error {
#define VIBE_VALIDATE_COUNT(field, minimum, maximum) \
    if (values.field < (minimum) || values.field > (maximum)) { \
        if (error) *error = VibeInvalidConfigurationValue(@#field, @(values.field)); \
        return nil; \
    }
#define VIBE_VALIDATE_DURATION(field) \
    if (!isfinite(values.field) || values.field <= 0 || values.field > kMaximumTunableDuration) { \
        if (error) *error = VibeInvalidConfigurationValue(@#field, @(values.field)); \
        return nil; \
    }

    VIBE_VALIDATE_COUNT(maximumBackgroundMaterializations, 1,
                        kMaximumSafeBackgroundMaterializations);
    VIBE_VALIDATE_COUNT(localMetadataParseConcurrency, 1,
                        kMaximumSafeLocalMetadataParseConcurrency);
    VIBE_VALIDATE_COUNT(prefetchDepth, 0, kMaximumTunablePrefetchDepth);
    VIBE_VALIDATE_COUNT(maximumInteractiveMaterializations, 1,
                        kMaximumDiagnosticInteractiveMaterializations);
    VIBE_VALIDATE_COUNT(maximumInteractivePendingMaterializations, 0,
                        kMaximumTunablePendingCount);
    VIBE_VALIDATE_COUNT(maximumBackgroundPendingMaterializations, 1,
                        kMaximumTunablePendingCount);
    VIBE_VALIDATE_DURATION(interactiveAdmissionGrace);
    VIBE_VALIDATE_DURATION(backgroundAdmissionGrace);
    VIBE_VALIDATE_COUNT(metadataRetryCount, 0, kMaximumTunableRetryCount);
    if (!isfinite(values.openTimeouts.noProgressSeconds)
            || values.openTimeouts.noProgressSeconds <= 0
            || values.openTimeouts.noProgressSeconds > kMaximumTunableDuration) {
        if (error) {
            *error = VibeInvalidConfigurationValue(@"openTimeouts.noProgressSeconds",
                                                    @(values.openTimeouts.noProgressSeconds));
        }
        return nil;
    }
    if (!isfinite(values.openTimeouts.progressSilenceSeconds)
            || values.openTimeouts.progressSilenceSeconds <= 0
            || values.openTimeouts.progressSilenceSeconds > kMaximumTunableDuration) {
        if (error) {
            *error = VibeInvalidConfigurationValue(@"openTimeouts.progressSilenceSeconds",
                                                    @(values.openTimeouts.progressSilenceSeconds));
        }
        return nil;
    }

#undef VIBE_VALIDATE_COUNT
#undef VIBE_VALIDATE_DURATION

    self = [super init];
    if (self) {
        _maximumBackgroundMaterializations = values.maximumBackgroundMaterializations;
        _localMetadataParseConcurrency = values.localMetadataParseConcurrency;
        _prefetchDepth = values.prefetchDepth;
        _maximumInteractiveMaterializations = values.maximumInteractiveMaterializations;
        _maximumInteractivePendingMaterializations =
                values.maximumInteractivePendingMaterializations;
        _maximumBackgroundPendingMaterializations =
                values.maximumBackgroundPendingMaterializations;
        _interactiveAdmissionGrace = values.interactiveAdmissionGrace;
        _backgroundAdmissionGrace = values.backgroundAdmissionGrace;
        _metadataRetryCount = values.metadataRetryCount;
        _openTimeouts = values.openTimeouts;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (VibeAudioLoadingConfigurationValues)values {
    VibeAudioLoadingConfigurationValues values;
    values.maximumBackgroundMaterializations = _maximumBackgroundMaterializations;
    values.localMetadataParseConcurrency = _localMetadataParseConcurrency;
    values.prefetchDepth = _prefetchDepth;
    values.maximumInteractiveMaterializations = _maximumInteractiveMaterializations;
    values.maximumInteractivePendingMaterializations =
            _maximumInteractivePendingMaterializations;
    values.maximumBackgroundPendingMaterializations =
            _maximumBackgroundPendingMaterializations;
    values.interactiveAdmissionGrace = _interactiveAdmissionGrace;
    values.backgroundAdmissionGrace = _backgroundAdmissionGrace;
    values.metadataRetryCount = _metadataRetryCount;
    values.openTimeouts = _openTimeouts;
    return values;
}

@end
