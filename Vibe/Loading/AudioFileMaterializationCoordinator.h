//
//  AudioFileMaterializationCoordinator.h
//  Vibe
//
//  One path-keyed claim from dataless placeholder to AudioFileHandle: stage 1
//  makes the contents local, stage 2 is the purpose-keyed handle opens riding
//  it. A token owns delivery, not the claim: cancelling a waiter never erases
//  a path whose stat or open may still be blocked in the OS.
//

#import <Foundation/Foundation.h>

#import "AudioLoadingConfiguration.h"


@class AudioFileHandle;

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
    // Stood down for foreground work: not a file failure, spends no retry.
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

// Detaches only this waiter; the claim runs on while others remain. A
// completion queued but not begun is suppressed.
- (void)cancel;

@end

FOUNDATION_EXPORT NSString * const VibeAudioFileOpenErrorDomain;

typedef NS_ENUM(NSInteger, VibeAudioFileOpenErrorCode) {
    // Transfer admission or the handle-run ceiling refused it; the file never
    // began.
    VibeAudioFileOpenErrorAdmissionExhausted = 1,
    // Backstop: an abandoned run's empty result reached a later waiter. Says
    // nothing about the file. The coordinator restarts such a run instead, so
    // this only keeps "a completion carries a file or a reason" total.
    VibeAudioFileOpenErrorAbandoned,
    // Stage 1 yielded. Playback and prefetch do not yield today; this keeps
    // the completion total.
    VibeAudioFileOpenErrorMaterializationYielded,
    // Stage 1 failed; no handle open was attempted.
    VibeAudioFileOpenErrorMaterializationFailed,
};

typedef NS_ENUM(NSInteger, VibeAudioFileOpenPurpose) {
    VibeAudioFileOpenPurposePlayback = 0,
    VibeAudioFileOpenPurposePrefetch,
};

typedef void (^VibeAudioFileOpenCompletion)(AudioFileHandle * _Nullable file,
                                             NSError * _Nullable error,
                                             NSTimeInterval elapsed);

@interface AudioFileOpenToken : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Suppresses a result whose completion block has not begun and detaches the
// stage-1 waiter. A handle open already begun keeps its run registered until
// the call returns, so a same-purpose/path retry binds to it instead of
// starting another: a streaming open returns at once, its waits interrupted,
// and a whole-file open, which does no waits, cannot be stopped.
//
// No detach-without-cancel variant: cancelling also marks the run abandoned,
// which is how a rebound waiter gets a fresh run instead of the abandoned
// one's empty result.
- (void)cancel;

@end

@interface AudioFileMaterializationCoordinator : NSObject

// The last snapshot applied. Its limits apply here at once; other subsystems
// snapshot at their next loader, prefetch decision, retry or open.
@property (nonatomic, copy, readonly) AudioLoadingConfiguration *currentConfiguration;

+ (instancetype)sharedCoordinator;

// Raising a running limit admits pending work at once; lowering any limit
// cancels nothing. A grace change applies to claims admitted afterwards.
- (void)applyConfiguration:(AudioLoadingConfiguration *)configuration;

// The completion is asynchronous on completionQueue and always terminal.
// Joining a same-path claim and starting one look the same to the caller.
- (AudioFileMaterializationRequestToken *)materializeURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role
                                         completionQueue:(dispatch_queue_t)completionQueue
                                              completion:(VibeAudioFileMaterializationCompletion)completion;

// Stage 2: one current waiter per (purpose, standardized path); a later
// request for that key rebinds delivery without another handle open. Both
// purposes ride the path's stage-1 claim and open once it is Ready or, for a
// remote transfer, readable: the handle then reads the part file while the
// claim runs on, holding its lane until the transfer settles, and a stream no
// handle reads any more is cancelled. At most six handle runs live at once,
// purpose-blind: an existing
// key rebinds even at the ceiling, a seventh is refused before stage 1, so
// saturation can refuse playback. No queue, grace or configuration. Both
// refusals are VibeAudioFileOpenErrorAdmissionExhausted, distinct from the
// player's per-file open timeout.
// The accepted probe's dataless verdict, at most once on completionQueue
// while delivery is still waiting. Joining a classified claim also reports
// it; the caller need not probe the filesystem to show loading promptly.
- (AudioFileOpenToken *)openURL:(NSURL *)url
                         purpose:(VibeAudioFileOpenPurpose)purpose
                 completionQueue:(dispatch_queue_t)completionQueue
                      onDataless:(nullable dispatch_block_t)onDataless
                      completion:(VibeAudioFileOpenCompletion)completion;

// YES while any claim has a playback or prefetch waiter whose stage 1 has not
// settled, or a readable transfer still running under a live playback or
// prefetch handle: the C1 rule's single source. While YES the coordinator yields
// metadata-only dataless work itself, and settlement reopens admission, so
// there is no release edge to miss. A metadata waiter may still join a
// same-path foreground claim, and an already-local file is exempt. A snapshot:
// a submission racing a rising edge is yielded before any provider operation.
- (BOOL)isForegroundTransferActive;

@end

NS_ASSUME_NONNULL_END
