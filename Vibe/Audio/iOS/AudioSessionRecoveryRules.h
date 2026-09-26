//
//  AudioSessionRecoveryRules.h
//  Vibe (iOS)
//


#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, VibeAudioSessionOutputRouteKind) {
    VibeAudioSessionOutputRouteNone,
    VibeAudioSessionOutputRouteBuiltIn,
    VibeAudioSessionOutputRouteExternal,
};

typedef NS_ENUM(NSUInteger, VibeAudioSessionConfigurationAction) {
    VibeAudioSessionConfigurationActionIgnore,
    VibeAudioSessionConfigurationActionPause,
    VibeAudioSessionConfigurationActionRecover,
};

// A route change's reason does not always name the loss: the route
// transition itself decides whether this is an ordinary recovery on the new
// route or disappearing output that must park playback. Existing
// interruption, route-loss and reset ownership always wins.
static inline VibeAudioSessionConfigurationAction
VibeAudioSessionConfigurationActionForRoutes(
        VibeAudioSessionOutputRouteKind previousRoute,
        VibeAudioSessionOutputRouteKind currentRoute,
        BOOL interruptionActive,
        BOOL routeLossActive,
        BOOL mediaServicesResetActive) {
    if (interruptionActive || routeLossActive || mediaServicesResetActive) {
        return VibeAudioSessionConfigurationActionIgnore;
    }
    BOOL outputDisappeared = previousRoute != VibeAudioSessionOutputRouteNone
            && currentRoute == VibeAudioSessionOutputRouteNone;
    BOOL externalOutputFellBackToBuiltIn =
            previousRoute == VibeAudioSessionOutputRouteExternal
            && currentRoute == VibeAudioSessionOutputRouteBuiltIn;
    if (outputDisappeared || externalOutputFellBackToBuiltIn) {
        return VibeAudioSessionConfigurationActionPause;
    }
    return VibeAudioSessionConfigurationActionRecover;
}

// A later route change coalesces an earlier ordinary recovery; any safety
// verdict received before main delivery blocks it.
static inline BOOL VibeAudioSessionMayDeliverConfigurationRecovery(
        uint64_t owningConfigurationRecoveryGeneration,
        uint64_t newestConfigurationRecoveryGeneration,
        BOOL interruptionActive,
        BOOL routeLossActive,
        BOOL mediaServicesResetActive) {
    return owningConfigurationRecoveryGeneration == newestConfigurationRecoveryGeneration
            && !interruptionActive
            && !routeLossActive
            && !mediaServicesResetActive;
}

// Interruption-ended is a system suggestion, not a fresh user play. It may
// reclaim the session only while no newer safety verdict owns the output.
static inline BOOL VibeAudioSessionMayAutomaticallyResume(
        BOOL interruptionActive,
        BOOL routeLossActive,
        BOOL mediaServicesResetActive) {
    return !interruptionActive && !routeLossActive
            && !mediaServicesResetActive;
}

NS_ASSUME_NONNULL_END
