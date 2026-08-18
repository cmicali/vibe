//
//  AudioFileOpenCoordinatorInternal.h
//  Vibe
//

#import "AudioFileOpenCoordinator.h"

@class AudioWorkScheduler;
@class AudioFileMaterializationCoordinator;

NS_ASSUME_NONNULL_BEGIN

typedef AVAudioFile * _Nullable (^VibeAudioFileOpener)(
        NSURL *url, NSError * _Nullable __autoreleasing * _Nullable error);

@interface AudioFileOpenCoordinator (Internal)

- (instancetype)initWithStateQueue:(dispatch_queue_t)stateQueue
                  playbackScheduler:(AudioWorkScheduler *)playbackScheduler
                backgroundScheduler:(AudioWorkScheduler *)backgroundScheduler;

- (instancetype)initWithStateQueue:(dispatch_queue_t)stateQueue
                  playbackScheduler:(AudioWorkScheduler *)playbackScheduler
                backgroundScheduler:(AudioWorkScheduler *)backgroundScheduler
         materializationCoordinator:(AudioFileMaterializationCoordinator *)materializationCoordinator;

- (instancetype)initWithStateQueue:(dispatch_queue_t)stateQueue
                  playbackScheduler:(AudioWorkScheduler *)playbackScheduler
                backgroundScheduler:(AudioWorkScheduler *)backgroundScheduler
         materializationCoordinator:(AudioFileMaterializationCoordinator *)materializationCoordinator
                         fileOpener:(VibeAudioFileOpener)fileOpener;

@end

NS_ASSUME_NONNULL_END
