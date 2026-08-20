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

// The prefetch request's own lifecycle: identity (a late callback for a
// superseded request must change nothing) and the one stateful behavior —
// a different-path prefetch requested while playback is still opening is
// retained but SUPPRESSED, and the play's success resumes that exact target.
// The acknowledgement half this state machine once carried is gone: the
// foreground/background rule derives from the materialization coordinator's
// claim table, so nothing waits on "the successor's claim is registered".
typedef NS_OPTIONS(NSUInteger, VibeAudioPrefetchRequestAction) {
    VibeAudioPrefetchRequestActionNone = 0,
    VibeAudioPrefetchRequestActionResume = 1 << 0,
};

typedef struct {
    uint64_t nextRequestIdentifier;
    uint64_t currentRequestIdentifier;
    BOOL requestActive;
    BOOL suppressedBehindPlayback;
} VibeAudioPrefetchRequestState;

typedef struct {
    VibeAudioPrefetchRequestState state;
    VibeAudioPrefetchRequestAction action;
} VibeAudioPrefetchRequestTransition;

static inline VibeAudioPrefetchRequestState
VibeAudioPrefetchRequestStateMake(void) {
    VibeAudioPrefetchRequestState state = {0};
    return state;
}

static inline VibeAudioPrefetchRequestTransition
VibeAudioPrefetchRequestTransitionMake(
        VibeAudioPrefetchRequestState state,
        VibeAudioPrefetchRequestAction action) {
    VibeAudioPrefetchRequestTransition transition = {state, action};
    return transition;
}

static inline VibeAudioPrefetchRequestTransition
VibeAudioPrefetchRequestBegin(VibeAudioPrefetchRequestState state) {
    state.nextRequestIdentifier++;
    if (state.nextRequestIdentifier == 0) {
        state.nextRequestIdentifier++;
    }
    state.currentRequestIdentifier = state.nextRequestIdentifier;
    state.requestActive = YES;
    state.suppressedBehindPlayback = NO;
    return VibeAudioPrefetchRequestTransitionMake(
            state, VibeAudioPrefetchRequestActionNone);
}

static inline VibeAudioPrefetchRequestTransition
VibeAudioPrefetchRequestSuppressBehindPlayback(
        VibeAudioPrefetchRequestState state,
        uint64_t requestIdentifier) {
    if (state.requestActive && state.currentRequestIdentifier == requestIdentifier) {
        state.suppressedBehindPlayback = YES;
    }
    return VibeAudioPrefetchRequestTransitionMake(
            state, VibeAudioPrefetchRequestActionNone);
}

static inline VibeAudioPrefetchRequestTransition
VibeAudioPrefetchRequestFinish(
        VibeAudioPrefetchRequestState state,
        uint64_t requestIdentifier) {
    if (!state.requestActive || state.currentRequestIdentifier != requestIdentifier) {
        return VibeAudioPrefetchRequestTransitionMake(
                state, VibeAudioPrefetchRequestActionNone);
    }
    state.currentRequestIdentifier = 0;
    state.requestActive = NO;
    state.suppressedBehindPlayback = NO;
    return VibeAudioPrefetchRequestTransitionMake(
            state, VibeAudioPrefetchRequestActionNone);
}

static inline VibeAudioPrefetchRequestTransition
VibeAudioPrefetchRequestPlaybackSucceeded(
        VibeAudioPrefetchRequestState state,
        uint64_t requestIdentifier) {
    if (!state.requestActive || state.currentRequestIdentifier != requestIdentifier) {
        return VibeAudioPrefetchRequestTransitionMake(
                state, VibeAudioPrefetchRequestActionNone);
    }
    if (!state.suppressedBehindPlayback) {
        return VibeAudioPrefetchRequestFinish(state, requestIdentifier);
    }
    state.suppressedBehindPlayback = NO;
    return VibeAudioPrefetchRequestTransitionMake(
            state, VibeAudioPrefetchRequestActionResume);
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
