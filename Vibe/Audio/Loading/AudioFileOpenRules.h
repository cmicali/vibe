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

// One spelling of a file path for single-flight ownership. Symlinks are
// deliberately not resolved: that would stat the target, which is one of the
// operations this key exists to keep inside a bounded worker.
// TRAP: it is still not free. URLByStandardizingPath stats the path to decide
// whether a /private prefix can go, and every iOS cloud path has one, so keep
// it off per-row and per-frame paths (CloudTransferRegistry's entryForURL:).
static inline NSString *VibeStandardizedAudioOpenPath(NSURL *url) {
    if (url.isFileURL) {
        return url.URLByStandardizingPath.path ?: url.path ?: @"";
    }
    return url.absoluteString ?: @"";
}

NS_ASSUME_NONNULL_END
