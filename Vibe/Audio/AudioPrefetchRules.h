//
//  AudioPrefetchRules.h
//  Vibe
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VibeAudioPrefetchRetirementPoint) {
    VibeAudioPrefetchAtPlaySubmission = 0,
    VibeAudioPrefetchAtPlaySettlement,
    VibeAudioPrefetchAtAbandonment,
};

typedef NS_ENUM(NSInteger, VibeAudioPrefetchDisposition) {
    VibeAudioPrefetchDispositionClear = 0,
    VibeAudioPrefetchDispositionReuseParked,
    VibeAudioPrefetchDispositionJoinPrefetchClaim,
    VibeAudioPrefetchDispositionJoinPlaybackClaim,
    VibeAudioPrefetchDispositionSuppressBehindPlayback,
    VibeAudioPrefetchDispositionStartClaim,
};

typedef NS_OPTIONS(NSUInteger, VibeAudioPrefetchAcknowledgementAction) {
    VibeAudioPrefetchAcknowledgementActionNone = 0,
    VibeAudioPrefetchAcknowledgementActionDeliver = 1 << 0,
    VibeAudioPrefetchAcknowledgementActionResume = 1 << 1,
};

typedef struct {
    uint64_t nextRequestIdentifier;
    uint64_t currentRequestIdentifier;
    BOOL requestActive;
    BOOL acknowledgementPending;
    BOOL suppressedBehindPlayback;
} VibeAudioPrefetchAcknowledgementState;

typedef struct {
    VibeAudioPrefetchAcknowledgementState state;
    VibeAudioPrefetchAcknowledgementAction action;
} VibeAudioPrefetchAcknowledgementTransition;

static inline VibeAudioPrefetchAcknowledgementState
VibeAudioPrefetchAcknowledgementStateMake(void) {
    VibeAudioPrefetchAcknowledgementState state = {0};
    return state;
}

static inline VibeAudioPrefetchAcknowledgementTransition
VibeAudioPrefetchAcknowledgementTransitionMake(
        VibeAudioPrefetchAcknowledgementState state,
        VibeAudioPrefetchAcknowledgementAction action) {
    VibeAudioPrefetchAcknowledgementTransition transition = {state, action};
    return transition;
}

static inline VibeAudioPrefetchAcknowledgementTransition
VibeAudioPrefetchAcknowledgementBegin(
        VibeAudioPrefetchAcknowledgementState state,
        BOOL hasAcknowledgement) {
    VibeAudioPrefetchAcknowledgementAction action = state.acknowledgementPending
            ? VibeAudioPrefetchAcknowledgementActionDeliver
            : VibeAudioPrefetchAcknowledgementActionNone;
    state.nextRequestIdentifier++;
    if (state.nextRequestIdentifier == 0) {
        state.nextRequestIdentifier++;
    }
    state.currentRequestIdentifier = state.nextRequestIdentifier;
    state.requestActive = YES;
    state.acknowledgementPending = hasAcknowledgement;
    state.suppressedBehindPlayback = NO;
    return VibeAudioPrefetchAcknowledgementTransitionMake(state, action);
}

static inline VibeAudioPrefetchAcknowledgementTransition
VibeAudioPrefetchAcknowledgementSuppressBehindPlayback(
        VibeAudioPrefetchAcknowledgementState state,
        uint64_t requestIdentifier) {
    if (state.requestActive && state.currentRequestIdentifier == requestIdentifier) {
        state.suppressedBehindPlayback = YES;
    }
    return VibeAudioPrefetchAcknowledgementTransitionMake(
            state, VibeAudioPrefetchAcknowledgementActionNone);
}

static inline VibeAudioPrefetchAcknowledgementTransition
VibeAudioPrefetchAcknowledgementFinish(
        VibeAudioPrefetchAcknowledgementState state,
        uint64_t requestIdentifier) {
    if (!state.requestActive || state.currentRequestIdentifier != requestIdentifier) {
        return VibeAudioPrefetchAcknowledgementTransitionMake(
                state, VibeAudioPrefetchAcknowledgementActionNone);
    }
    VibeAudioPrefetchAcknowledgementAction action = state.acknowledgementPending
            ? VibeAudioPrefetchAcknowledgementActionDeliver
            : VibeAudioPrefetchAcknowledgementActionNone;
    state.currentRequestIdentifier = 0;
    state.requestActive = NO;
    state.acknowledgementPending = NO;
    state.suppressedBehindPlayback = NO;
    return VibeAudioPrefetchAcknowledgementTransitionMake(state, action);
}

static inline VibeAudioPrefetchAcknowledgementTransition
VibeAudioPrefetchAcknowledgementClaimSettled(
        VibeAudioPrefetchAcknowledgementState state,
        uint64_t requestIdentifier) {
    return VibeAudioPrefetchAcknowledgementFinish(state, requestIdentifier);
}

static inline VibeAudioPrefetchAcknowledgementTransition
VibeAudioPrefetchAcknowledgementTerminallyRetired(
        VibeAudioPrefetchAcknowledgementState state,
        uint64_t requestIdentifier) {
    return VibeAudioPrefetchAcknowledgementFinish(state, requestIdentifier);
}

static inline VibeAudioPrefetchAcknowledgementTransition
VibeAudioPrefetchAcknowledgementPlaybackSucceeded(
        VibeAudioPrefetchAcknowledgementState state,
        uint64_t requestIdentifier) {
    if (!state.requestActive || state.currentRequestIdentifier != requestIdentifier) {
        return VibeAudioPrefetchAcknowledgementTransitionMake(
                state, VibeAudioPrefetchAcknowledgementActionNone);
    }
    if (!state.suppressedBehindPlayback) {
        return VibeAudioPrefetchAcknowledgementFinish(state, requestIdentifier);
    }
    state.suppressedBehindPlayback = NO;
    return VibeAudioPrefetchAcknowledgementTransitionMake(
            state, VibeAudioPrefetchAcknowledgementActionResume);
}

static inline BOOL VibeAudioPrefetchDepthAllowsSuccessor(NSUInteger prefetchDepth) {
    return prefetchDepth > 0;
}

static inline VibeAudioPrefetchDisposition VibeAudioPrefetchDispositionForState(
        NSString *requestedPath,
        NSString *prefetchedPath,
        BOOL prefetchedFileReady,
        BOOL prefetchClaimPresent,
        NSString *pendingPlaybackPath) {
    if (!requestedPath) {
        return VibeAudioPrefetchDispositionClear;
    }
    if ([requestedPath isEqualToString:prefetchedPath]) {
        if (prefetchedFileReady) {
            return VibeAudioPrefetchDispositionReuseParked;
        }
        if (prefetchClaimPresent) {
            return VibeAudioPrefetchDispositionJoinPrefetchClaim;
        }
    }
    if ([requestedPath isEqualToString:pendingPlaybackPath]) {
        return VibeAudioPrefetchDispositionJoinPlaybackClaim;
    }
    if (pendingPlaybackPath) {
        return VibeAudioPrefetchDispositionSuppressBehindPlayback;
    }
    return VibeAudioPrefetchDispositionStartClaim;
}

static inline BOOL VibeAudioPrefetchShouldRetire(
        VibeAudioPrefetchRetirementPoint point,
        NSString *prefetchedPath,
        NSString *playPath) {
    switch (point) {
        case VibeAudioPrefetchAtPlaySubmission:
            return prefetchedPath && ![prefetchedPath isEqualToString:playPath];
        case VibeAudioPrefetchAtPlaySettlement:
            return [prefetchedPath isEqualToString:playPath];
        case VibeAudioPrefetchAtAbandonment:
            return YES;
    }
    return YES;
}
