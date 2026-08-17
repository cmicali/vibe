//
//  AudioFileOpenRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VibeAudioFileOpenDeliveryState) {
    VibeAudioFileOpenDeliveryWaiting = 0,
    VibeAudioFileOpenDeliveryRunning,
    VibeAudioFileOpenDeliveryDetached,
};

// The caller serializes access to state. Delivery and detachment race for the
// one Waiting transition; whichever changes it first owns the outcome.
static inline BOOL VibeAudioFileOpenBeginDelivery(
        VibeAudioFileOpenDeliveryState *state) {
    if (*state != VibeAudioFileOpenDeliveryWaiting) {
        return NO;
    }
    *state = VibeAudioFileOpenDeliveryRunning;
    return YES;
}

static inline BOOL VibeAudioFileOpenDetachDelivery(
        VibeAudioFileOpenDeliveryState *state) {
    if (*state != VibeAudioFileOpenDeliveryWaiting) {
        return NO;
    }
    *state = VibeAudioFileOpenDeliveryDetached;
    return YES;
}

// One spelling of a file path for single-flight ownership. Standardization is
// deliberately lexical: resolving symlinks would stat the target, which is one
// of the operations this key exists to keep inside a bounded worker.
static inline NSString *VibeStandardizedAudioOpenPath(NSURL *url) {
    if (url.isFileURL) {
        return url.URLByStandardizingPath.path ?: url.path ?: @"";
    }
    return url.absoluteString ?: @"";
}

// The playback open's abandon deadline. A provider reporting no progress —
// and a sparse or one-shot sample degrades to exactly that — gets the whole
// no-progress budget; genuine movement extends the open by the stall budget
// past each sample. The max() is the contract: a sample can only ever extend,
// never abandon an open before its baseline, so feeding one is always safe.
// Both platforms share it — the baseline IS iOS's old flat timeout, and macOS
// was abandoning healthy 150-300MB transfers at a flat 20 seconds.
static const NSTimeInterval kOpenNoProgressBudgetSeconds = 60.0;
static const NSTimeInterval kOpenStallBudgetSeconds = 20.0;

// lastProgressAt is 0 when no sample has arrived; the baseline then stands.
static inline CFAbsoluteTime VibeAudioOpenEffectiveDeadline(CFAbsoluteTime submittedAt,
                                                            CFAbsoluteTime lastProgressAt) {
    CFAbsoluteTime baseline = submittedAt + kOpenNoProgressBudgetSeconds;
    CFAbsoluteTime extended = lastProgressAt + kOpenStallBudgetSeconds;
    return baseline > extended ? baseline : extended;
}

NS_ASSUME_NONNULL_END
