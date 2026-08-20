//
//  AudioFileMaterializationCoordinator.h
//  Vibe
//
//  Path-wide, role-aware ownership of the one operation that makes an audio
//  file's contents local. AVAudioFile handle opens remain separately owned.
//

#import <Foundation/Foundation.h>

#import "AudioLoadingConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VibeAudioFileMaterializationErrorDomain;

typedef NS_ENUM(NSInteger, VibeAudioFileMaterializationErrorCode) {
    VibeAudioFileMaterializationErrorAdmissionExhausted = 1,
    VibeAudioFileMaterializationErrorFailed,
};

typedef NS_ENUM(NSUInteger, VibeAudioFileMaterializationRole) {
    VibeAudioFileMaterializationRolePlayback = 0,
    VibeAudioFileMaterializationRolePrefetch,
    VibeAudioFileMaterializationRoleMetadataPriority,
    VibeAudioFileMaterializationRoleMetadataScan,
};

typedef NS_ENUM(NSUInteger, VibeAudioFileMaterializationResult) {
    VibeAudioFileMaterializationResultReady = 0,
    // The metadata request stood down for foreground work. This is not a file
    // failure and must not consume a caller's retry budget.
    VibeAudioFileMaterializationResultYielded,
    VibeAudioFileMaterializationResultAdmissionExhausted,
    VibeAudioFileMaterializationResultFailed,
};

typedef void (^VibeAudioFileMaterializationCompletion)(
        VibeAudioFileMaterializationResult result,
        NSError * _Nullable error,
        NSTimeInterval elapsed);

@interface AudioFileMaterializationRequestToken : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Detaches only this waiter. A same-path owner keeps running while any other
// waiter remains, and a completion already queued but not begun is suppressed.
- (void)cancel;

@end

@interface AudioFileMaterializationCoordinator : NSObject

// The coherent snapshot applied most recently. Materialization limits affect
// this coordinator immediately; other subsystems take their own snapshot at
// their next loader, prefetch decision, retry, or file-open boundary.
@property (nonatomic, copy, readonly) AudioLoadingConfiguration *currentConfiguration;

+ (instancetype)sharedCoordinator;

// Applies one immutable snapshot. Raising a running limit admits pending work
// immediately. Lowering a limit lets existing work drain and cancels nothing.
// Lower pending limits retain already-admitted claims; grace changes apply only
// to claims admitted afterwards.
- (void)applyConfiguration:(AudioLoadingConfiguration *)configuration;

// registered is delivered after this request has atomically joined or created
// its standardized-path claim. It is never delivered for rejected or yielded
// requests, and it returns before this request's completion can begin even
// when completionQueue is concurrent. All callbacks are asynchronous there.
- (AudioFileMaterializationRequestToken *)materializeURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role
                                         completionQueue:(dispatch_queue_t)completionQueue
                                              registered:(nullable dispatch_block_t)registered
                                              completion:(VibeAudioFileMaterializationCompletion)completion;

// YES while any live claim carries a playback or prefetch waiter whose
// materialization has not settled. This is the C1 rule's single source: the
// coordinator itself yields metadata-only dataless work while it reads YES —
// a foreground claim's registration preempts running metadata transfers, and
// its settlement is what reopens admission, so no external release edge
// exists to be missed or doubled. A metadata waiter may still join a
// same-path foreground claim because that starts no second transfer, and a
// claim for an already-local file passes entirely: the rule suspends provider
// transfers, which it never starts. Background pickers (the metadata sweep)
// read this before submitting dataless work; it is a snapshot the moment it
// returns, which is fine — a submission that races a rising edge is yielded
// at admission, spending nothing.
- (BOOL)isForegroundTransferActive;

@end

NS_ASSUME_NONNULL_END
