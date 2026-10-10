//
//  AudioWorkScheduler.h
//  Vibe
//
//  Fixed-slot admission for OS calls with no cancellation point. Work is not
//  dispatched until it owns a slot, so a blocked worker cannot grow an
//  unbounded tail of cancelled blocks.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeAudioWorkAdmissionFailure) {
    VibeAudioWorkAdmissionFailurePendingLimit = 1,
    VibeAudioWorkAdmissionFailureWaitExpired,
};

@class AudioWorkScheduler;

@interface AudioWorkToken : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// YES: removed before dispatch, its captures released. NO: running, finished
// or rejected; a running call keeps its slot until it returns.
- (BOOL)cancelIfPending;

@end

@interface AudioWorkScheduler : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Pending work is held here, never submitted to libdispatch. Work that cannot
// start within pendingGrace fails admission, distinct from any per-file open
// timeout.
- (instancetype)initWithLabel:(NSString *)label
              qualityOfService:(qos_class_t)qualityOfService
            maximumRunningCount:(NSUInteger)maximumRunningCount
            maximumPendingCount:(NSUInteger)maximumPendingCount
                  pendingGrace:(NSTimeInterval)pendingGrace NS_DESIGNATED_INITIALIZER;

// Every admission failure, the pending limit at submission or the grace
// expiring later, is delivered asynchronously on failureQueue, so it cannot
// re-enter a caller's lock or serial queue. Rejection is decided
// synchronously and never waits behind a blocked worker.
- (AudioWorkToken *)submitWork:(dispatch_block_t)work
                   failureQueue:(dispatch_queue_t)failureQueue
              admissionFailure:(void (^)(VibeAudioWorkAdmissionFailure failure))admissionFailure;

@end

NS_ASSUME_NONNULL_END
