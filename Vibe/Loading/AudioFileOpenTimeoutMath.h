//
//  AudioFileOpenTimeoutMath.h
//  Vibe
//

#import <Foundation/Foundation.h>

#include <math.h>

typedef struct {
    NSTimeInterval noProgressSeconds;
    NSTimeInterval progressSilenceSeconds;
} VibeAudioOpenTimeoutConfiguration;

static const NSTimeInterval kVibeAudioOpenDefaultNoProgressSeconds = 60.0;
static const NSTimeInterval kVibeAudioOpenDefaultProgressSilenceSeconds = 60.0;

static inline VibeAudioOpenTimeoutConfiguration VibeAudioOpenTimeoutConfigurationMake(
        NSTimeInterval noProgressSeconds,
        NSTimeInterval progressSilenceSeconds) {
    VibeAudioOpenTimeoutConfiguration configuration;
    configuration.noProgressSeconds = isfinite(noProgressSeconds) && noProgressSeconds > 0
            ? noProgressSeconds : kVibeAudioOpenDefaultNoProgressSeconds;
    configuration.progressSilenceSeconds =
            isfinite(progressSilenceSeconds) && progressSilenceSeconds > 0
            ? progressSilenceSeconds : kVibeAudioOpenDefaultProgressSilenceSeconds;
    return configuration;
}

static inline VibeAudioOpenTimeoutConfiguration VibeAudioOpenDefaultTimeoutConfiguration(void) {
    return VibeAudioOpenTimeoutConfigurationMake(
            kVibeAudioOpenDefaultNoProgressSeconds,
            kVibeAudioOpenDefaultProgressSilenceSeconds);
}

// Times are monotonic uptime seconds. A positive movement can only extend the
// baseline; silence after movement gets the configured allowance of its own.
static inline NSTimeInterval VibeAudioOpenEffectiveDeadline(
        NSTimeInterval submittedUptime,
        NSTimeInterval lastPositiveMovementUptime,
        VibeAudioOpenTimeoutConfiguration configuration) {
    configuration = VibeAudioOpenTimeoutConfigurationMake(
            configuration.noProgressSeconds, configuration.progressSilenceSeconds);
    NSTimeInterval baseline = submittedUptime + configuration.noProgressSeconds;
    if (!isfinite(lastPositiveMovementUptime)
            || lastPositiveMovementUptime <= submittedUptime) {
        return baseline;
    }
    NSTimeInterval extended = lastPositiveMovementUptime
            + configuration.progressSilenceSeconds;
    return MAX(baseline, extended);
}

static inline NSTimeInterval VibeAudioOpenDeadlineRemaining(
        NSTimeInterval nowUptime,
        NSTimeInterval submittedUptime,
        NSTimeInterval lastPositiveMovementUptime,
        VibeAudioOpenTimeoutConfiguration configuration) {
    return MAX(0, VibeAudioOpenEffectiveDeadline(submittedUptime,
                                                  lastPositiveMovementUptime,
                                                  configuration) - nowUptime);
}
