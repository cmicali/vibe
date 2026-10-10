//
//  AudioWorkAdmissionRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VibeAudioWorkAdmissionDecision) {
    VibeAudioWorkAdmissionStart = 0,
    VibeAudioWorkAdmissionPark,
    VibeAudioWorkAdmissionExhausted,
};

static inline VibeAudioWorkAdmissionDecision VibeAudioWorkAdmission(
        NSUInteger runningCount, NSUInteger maximumRunningCount,
        NSUInteger pendingCount, NSUInteger maximumPendingCount) {
    if (runningCount < maximumRunningCount) {
        return VibeAudioWorkAdmissionStart;
    }
    if (pendingCount < maximumPendingCount) {
        return VibeAudioWorkAdmissionPark;
    }
    return VibeAudioWorkAdmissionExhausted;
}

static inline BOOL VibeAudioWorkAdmissionExpired(NSTimeInterval now,
                                                  NSTimeInterval deadline) {
    return now >= deadline;
}
