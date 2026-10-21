//
//  AudioFileOpenDeliveryRules.h
//  Vibe
//
//  An open token's one delivery (AudioFileMaterializationTokens.m).
//

#import <Foundation/Foundation.h>

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
