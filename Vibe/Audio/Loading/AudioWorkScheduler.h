//
//  AudioWorkScheduler.h
//  Vibe
//
//  Fixed-slot admission for OS calls which have no cancellation point. Work
//  is not dispatched until it owns a slot, so a blocked worker cannot grow an
//  unbounded system-queue tail of cancelled blocks.
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

// YES means the work was removed before it was dispatched and its captured
// state has already been released. NO means it is running, finished, or was
// rejected; a running OS call remains one of the scheduler's occupied slots.
- (BOOL)cancelIfPending;

@end

@interface AudioWorkScheduler : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// maximumPendingCount is an application-memory bound, not a concurrency hint.
// Pending work is held here and is never submitted to libdispatch. A task
// which cannot start within pendingGrace fails admission distinctly from any
// per-file open timeout.
- (instancetype)initWithLabel:(NSString *)label
              qualityOfService:(qos_class_t)qualityOfService
            maximumRunningCount:(NSUInteger)maximumRunningCount
            maximumPendingCount:(NSUInteger)maximumPendingCount
                  pendingGrace:(NSTimeInterval)pendingGrace NS_DESIGNATED_INITIALIZER;

// Every admission failure is delivered on failureQueue, whichever way it was
// decided — the pending limit at submission, or the grace expiring later. One
// queue and one contract: a caller reasoning about what its failure block may
// touch never has to know which branch rejected it, and a rejection decided
// while the caller holds a lock or sits on a serial queue cannot re-enter it.
// Rejection is still decided synchronously, so it never queues behind a blocked
// worker. At most maximumRunningCount work bodies execute at once.
- (AudioWorkToken *)submitWork:(dispatch_block_t)work
                   failureQueue:(dispatch_queue_t)failureQueue
              admissionFailure:(void (^)(VibeAudioWorkAdmissionFailure failure))admissionFailure;

@end

NS_ASSUME_NONNULL_END
