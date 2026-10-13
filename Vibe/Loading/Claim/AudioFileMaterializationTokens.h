//
//  AudioFileMaterializationTokens.h
//  Vibe
//
//  The coordinator's private side of its two tokens, and the call a request
//  token's cancel makes back into it. An open token's cancel calls
//  detachOpenToken:, which AudioFileMaterializationCoordinatorInternal.h
//  declares with the rest of stage 2.
//

#import "AudioFileMaterializationCoordinator.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioFileMaterializationRequestToken ()
- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator
                                path:(NSString *)path
                          identifier:(uint64_t)identifier
                     completionQueue:(dispatch_queue_t)completionQueue
                          completion:(VibeAudioFileMaterializationCompletion)completion;
@property (nonatomic, weak) AudioFileMaterializationCoordinator *coordinator;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) uint64_t identifier;
- (BOOL)isDetached;
- (void)settleWithResult:(VibeAudioFileMaterializationResult)result
                   error:(nullable NSError *)error
                 elapsed:(NSTimeInterval)elapsed;
- (void)runDelivery;
@end

@interface AudioFileOpenToken ()
- (instancetype)initWithCoordinator:(AudioFileMaterializationCoordinator *)coordinator
                                  key:(NSString *)key
                      completionQueue:(dispatch_queue_t)completionQueue
                           completion:(VibeAudioFileOpenCompletion)completion;
@property (nonatomic, weak) AudioFileMaterializationCoordinator *coordinator;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, strong) dispatch_queue_t completionQueue;
@property (nonatomic, copy, nullable) dispatch_block_t onDataless;
- (nullable VibeAudioFileOpenCompletion)takeCompletionForDelivery;
- (BOOL)deliveryStillWaiting;
@end

// The coordinator's side: what a token tells it. Implemented in the coordinator.
@interface AudioFileMaterializationCoordinator (Tokens)
- (void)detachRequestToken:(AudioFileMaterializationRequestToken *)token;
@end

NS_ASSUME_NONNULL_END
