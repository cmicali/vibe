//
//  AudioFileOpenCoordinator.h
//  Vibe
//
//  Bounded, single-flight AVAudioFile opens. A token owns delivery, not the
//  underlying claim: detaching or cancelling a waiter never erases a path
//  whose stat/open may still be blocked in the OS.
//

#import <Foundation/Foundation.h>

@class AVAudioFile;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VibeAudioFileOpenErrorDomain;

typedef NS_ENUM(NSInteger, VibeAudioFileOpenErrorCode) {
    // The request never entered file materialization/open: every fixed worker
    // slot remained occupied and its bounded pending admission was exhausted.
    VibeAudioFileOpenErrorAdmissionExhausted = 1,
    // A run that produced no file because it had been abandoned, delivered to a
    // waiter that bound afterwards. It says nothing about the file; the caller
    // may retry. Backstop only — the coordinator restarts such a claim rather
    // than reporting it — so it exists to keep "a completion always carries a
    // file or a reason" true by construction.
    VibeAudioFileOpenErrorAbandoned,
};

typedef NS_ENUM(NSInteger, VibeAudioFileOpenPurpose) {
    VibeAudioFileOpenPurposePlayback = 0,
    VibeAudioFileOpenPurposePrefetch,
    VibeAudioFileOpenPurposeGapless,
};

typedef void (^VibeAudioFileOpenCompletion)(AVAudioFile * _Nullable file,
                                             NSError * _Nullable error,
                                             NSTimeInterval elapsed);

@interface AudioFileOpenToken : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Stops this request from receiving a result whose completion-queue block has
// not begun, and cancels any still-abortable cloud materialization. An open
// which has already entered AVAudioFile is not cancellable: its path claim
// stays registered until the call returns, so a same-path retry binds to it
// rather than multiplying an uncancellable open.
//
// There is deliberately no detach-without-cancel variant. Cancellation is also
// what marks the run abandoned, which is how a claim whose waiter left and came
// back knows to give the new waiter a fresh run instead of handing it the
// abandoned one's empty result.
- (void)cancel;

@end

@interface AudioFileOpenCoordinator : NSObject

+ (instancetype)sharedCoordinator;

// One current waiter per purpose and standardized path. A later request for
// that key replaces the delivery binding without starting another operation.
// Completions run on completionQueue. An admission failure uses
// VibeAudioFileOpenErrorAdmissionExhausted, distinct from a file open which
// began and hit the player's ordinary per-file timeout.
- (AudioFileOpenToken *)openURL:(NSURL *)url
                         purpose:(VibeAudioFileOpenPurpose)purpose
                 completionQueue:(dispatch_queue_t)completionQueue
                      completion:(VibeAudioFileOpenCompletion)completion;

// openURL: plus an acknowledgement, fired once on completionQueue when the
// request's claim is registered or joined — the point after which any
// same-path query observes it. Registration, never admission: a parked
// admission cannot delay it. This is what lets a caller order work after
// "the claim exists" without polling.
- (AudioFileOpenToken *)openURL:(NSURL *)url
                         purpose:(VibeAudioFileOpenPurpose)purpose
                 completionQueue:(dispatch_queue_t)completionQueue
                         claimed:(nullable dispatch_block_t)claimed
                      completion:(VibeAudioFileOpenCompletion)completion;

// Whether a live claim, any purpose, is materializing this standardized path
// right now. An advisory answer for scheduling — the metadata lane skips a
// pending download whose bytes the player or its prefetch is already moving —
// never proof of ownership: a claim can appear or settle the moment after it
// answers, so a caller must tolerate both directions, and the lane does, by
// re-asking when it picks and by standing a running parse aside.
- (BOOL)isMaterializingURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
