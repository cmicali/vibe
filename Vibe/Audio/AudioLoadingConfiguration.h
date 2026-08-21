//
//  AudioLoadingConfiguration.h
//  Vibe
//

#import <Foundation/Foundation.h>

#import "AudioFileOpenTimeoutMath.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VibeAudioLoadingConfigurationErrorDomain;

typedef NS_ENUM(NSInteger, VibeAudioLoadingConfigurationErrorCode) {
    VibeAudioLoadingConfigurationErrorInvalidValue = 1,
};

typedef struct {
    // Safe tuning surface.
    NSUInteger maximumBackgroundMaterializations;
    NSUInteger localMetadataParseConcurrency;
    NSUInteger prefetchDepth;

    // Diagnostic tuning surface. Production callers normally leave these at
    // their defaults; tests and the debug command channel may replace them.
    NSUInteger maximumInteractiveMaterializations;
    NSUInteger maximumInteractivePendingMaterializations;
    NSUInteger maximumBackgroundPendingMaterializations;
    NSTimeInterval interactiveAdmissionGrace;
    NSTimeInterval backgroundAdmissionGrace;
    NSUInteger metadataRetryCount;
    VibeAudioOpenTimeoutConfiguration openTimeouts;
} VibeAudioLoadingConfigurationValues;

FOUNDATION_EXPORT VibeAudioLoadingConfigurationValues
VibeAudioLoadingProductionConfigurationValues(void);

@interface AudioLoadingConfiguration : NSObject <NSCopying>

@property (nonatomic, readonly) NSUInteger maximumBackgroundMaterializations;
@property (nonatomic, readonly) NSUInteger localMetadataParseConcurrency;
@property (nonatomic, readonly) NSUInteger prefetchDepth;

@property (nonatomic, readonly) NSUInteger maximumInteractiveMaterializations;
@property (nonatomic, readonly) NSUInteger maximumInteractivePendingMaterializations;
@property (nonatomic, readonly) NSUInteger maximumBackgroundPendingMaterializations;
@property (nonatomic, readonly) NSTimeInterval interactiveAdmissionGrace;
@property (nonatomic, readonly) NSTimeInterval backgroundAdmissionGrace;
@property (nonatomic, readonly) NSUInteger metadataRetryCount;
@property (nonatomic, readonly) VibeAudioOpenTimeoutConfiguration openTimeouts;
@property (nonatomic, readonly) VibeAudioLoadingConfigurationValues values;

+ (instancetype)productionConfiguration;

- (nullable instancetype)initWithValues:(VibeAudioLoadingConfigurationValues)values
                                  error:(NSError *__autoreleasing _Nullable *_Nullable)error
        NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
