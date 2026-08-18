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

@interface AudioFileMaterializationHoldToken : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Idempotent. The metadata gate reopens only after every live hold ends.
- (void)invalidate;

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

// Closes metadata admission synchronously before returning, and yields every
// metadata-only pending or running claim. A metadata waiter may still join a
// same-path playback or prefetch claim because that starts no second transfer.
- (AudioFileMaterializationHoldToken *)acquireMetadataHold;

@end

NS_ASSUME_NONNULL_END
