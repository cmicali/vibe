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
    // The request never entered its next stage: materialization admission or
    // the fixed live handle-run ceiling was exhausted.
    VibeAudioFileOpenErrorAdmissionExhausted = 1,
    // A run that produced no file because it had been abandoned, delivered to a
    // waiter that bound afterwards. It says nothing about the file; the caller
    // may retry. Backstop only — the coordinator restarts such a claim rather
    // than reporting it — so it exists to keep "a completion always carries a
    // file or a reason" true by construction.
    VibeAudioFileOpenErrorAbandoned,
    // The central path-wide materialization request stood down. Playback and
    // prefetch do not normally yield, but the outer completion remains total
    // if a role policy changes.
    VibeAudioFileOpenErrorMaterializationYielded,
    // The central path-wide request failed before AVAudioFile was attempted.
    VibeAudioFileOpenErrorMaterializationFailed,
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
// not begun and detaches its path-wide materialization waiter. An AVAudioFile
// open which has already begun is not cancellable: its purpose-keyed claim
// stays registered until the call returns, so a same-purpose/path retry binds
// to it rather than multiplying an uncancellable handle open.
//
// There is deliberately no detach-without-cancel variant. Cancellation is also
// what marks the run abandoned, which is how a claim whose waiter left and came
// back knows to give the new waiter a fresh run instead of handing it the
// abandoned one's empty result.
- (void)cancel;

@end

// The coordinator behind these types is AudioFileMaterializationCoordinator:
// the handle open is stage 2 of the same path-keyed claim whose stage 1 is
// the provider transfer, so one object owns the whole journey from dataless
// placeholder to usable AVAudioFile. openURL:purpose:… is declared there.

NS_ASSUME_NONNULL_END
