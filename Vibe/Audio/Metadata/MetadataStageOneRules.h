//
//  MetadataStageOneRules.h
//  Vibe
//
//  The playlist scan's arrival barrier. Stage-one checks are discovered by a
//  setup operation while earlier checks may already be finishing, so a bare
//  outstanding count cannot distinguish "drained" from "more checks have not
//  been enumerated yet."
//

#import <Foundation/Foundation.h>

typedef struct {
    NSUInteger outstandingChecks;
    BOOL enumerationFinished;
    BOOL cancelled;
} VibeMetadataStageOneState;

static inline VibeMetadataStageOneState VibeMetadataStageOneStateMake(void) {
    return (VibeMetadataStageOneState){0, NO, NO};
}

static inline void VibeMetadataStageOneBeginCheck(VibeMetadataStageOneState *state) {
    if (!state->cancelled && !state->enumerationFinished) {
        state->outstandingChecks++;
    }
}

static inline void VibeMetadataStageOneFinishCheck(VibeMetadataStageOneState *state) {
    if (state->outstandingChecks > 0) {
        state->outstandingChecks--;
    }
}

static inline void VibeMetadataStageOneFinishEnumeration(VibeMetadataStageOneState *state) {
    state->enumerationFinished = YES;
}

static inline void VibeMetadataStageOneCancel(VibeMetadataStageOneState *state) {
    state->cancelled = YES;
    state->enumerationFinished = YES;
    state->outstandingChecks = 0;
}

static inline BOOL VibeMetadataStageTwoCanDispatch(
        VibeMetadataStageOneState state,
        NSUInteger pendingCount) {
    return !state.cancelled && state.enumerationFinished
            && state.outstandingChecks == 0 && pendingCount > 0;
}

