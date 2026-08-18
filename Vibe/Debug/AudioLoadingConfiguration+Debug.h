//
//  AudioLoadingConfiguration+Debug.h
//  Vibe
//

#if DEBUG

#import "AudioLoadingConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioLoadingConfiguration (Debug)

@property (nonatomic, readonly) NSDictionary<NSString *, id> *debugDictionary;

+ (NSDictionary<NSString *, id> *)debugConsumerDictionaryWithMaterialization:
        (AudioLoadingConfiguration *)materialization
        player:(AudioLoadingConfiguration *)player
        metadata:(AudioLoadingConfiguration *)metadata;

+ (nullable instancetype)debugConfigurationByApplyingArguments:(NSArray<NSString *> *)arguments
                                               toConfiguration:(AudioLoadingConfiguration *)configuration
                                                         error:(NSError *__autoreleasing _Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

#endif
