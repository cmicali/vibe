//
// Prefetch retirement across play races and abandonment.
//

#import <XCTest/XCTest.h>

#import "AudioPrefetchRules.h"

@interface AudioPrefetchRulesTests : XCTestCase
@end

@implementation AudioPrefetchRulesTests

- (void)testConfiguredPrefetchDepthZeroDisablesTheSuccessor {
    XCTAssertFalse(VibeAudioPrefetchDepthAllowsSuccessor(0));
    XCTAssertTrue(VibeAudioPrefetchDepthAllowsSuccessor(1));
}

- (void)testPlaySubmissionCancelsOnlyAnUnrelatedOldPrefetch {
    XCTAssertTrue(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtPlaySubmission, @"/next.flac", @"/picked.flac"));
    XCTAssertFalse(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtPlaySubmission, @"/picked.flac", @"/picked.flac"));
}

- (void)testSettledPlayRetiresItsSamePathPrefetchRacer {
    XCTAssertTrue(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtPlaySettlement, @"/picked.flac", @"/picked.flac"));
    XCTAssertFalse(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtPlaySettlement, @"/later.flac", @"/picked.flac"));
}

- (void)testStopAndFailureAlwaysRetireTheWholePark {
    XCTAssertTrue(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtAbandonment, @"/next.flac", nil));
    XCTAssertTrue(VibeAudioPrefetchShouldRetire(
            VibeAudioPrefetchAtAbandonment, nil, nil));
}

- (void)testDifferentPathPrefetchIsSuppressedBehindPendingPlayback {
    XCTAssertEqual(VibeAudioPrefetchDispositionForState(@"/next.flac", nil, NO, NO,
                                                        @"/picked.flac"),
                   VibeAudioPrefetchDispositionSuppressBehindPlayback);
}

- (void)testSuppressionDoesNotDependOnAnExistingPark {
    XCTAssertEqual(VibeAudioPrefetchDispositionForState(@"/next.flac", @"/old.flac",
                                                        YES, YES, @"/picked.flac"),
                   VibeAudioPrefetchDispositionSuppressBehindPlayback);
}

- (void)testSamePathPrefetchJoinsPlaybackClaim {
    XCTAssertEqual(VibeAudioPrefetchDispositionForState(@"/picked.flac", nil, NO, NO,
                                                        @"/picked.flac"),
                   VibeAudioPrefetchDispositionJoinPlaybackClaim);
}

- (void)testSamePathInFlightPrefetchJoinsItsClaim {
    XCTAssertEqual(VibeAudioPrefetchDispositionForState(@"/next.flac", @"/next.flac",
                                                        NO, YES, nil),
                   VibeAudioPrefetchDispositionJoinPrefetchClaim);
}

- (void)testSamePathParkedFileIsReused {
    XCTAssertEqual(VibeAudioPrefetchDispositionForState(@"/next.flac", @"/next.flac",
                                                        YES, NO, nil),
                   VibeAudioPrefetchDispositionReuseParked);
}

- (void)testNilRequestClearsEvenWhilePlaybackIsPending {
    XCTAssertEqual(VibeAudioPrefetchDispositionForState(nil, @"/next.flac", YES, NO,
                                                        @"/picked.flac"),
                   VibeAudioPrefetchDispositionClear);
}

- (void)testNewTargetStartsAfterPlaybackSettles {
    XCTAssertEqual(VibeAudioPrefetchDispositionForState(@"/next.flac", nil, NO, NO, nil),
                   VibeAudioPrefetchDispositionStartClaim);
}

// The request lifecycle that outlived the acknowledgement machinery: identity
// (a stale identifier changes nothing) and suppression-resume (a different-
// path prefetch requested mid-open is retained; the play's success resumes
// that exact target, its failure or supersession drops it).
- (void)testSuppressedRequestResumesAfterPlaySuccess {
    VibeAudioPrefetchRequestState state = VibeAudioPrefetchRequestStateMake();
    state = VibeAudioPrefetchRequestBegin(state).state;
    uint64_t requestIdentifier = state.currentRequestIdentifier;

    state = VibeAudioPrefetchRequestSuppressBehindPlayback(
            state, requestIdentifier).state;
    XCTAssertTrue(state.suppressedBehindPlayback);

    VibeAudioPrefetchRequestTransition transition =
            VibeAudioPrefetchRequestPlaybackSucceeded(state, requestIdentifier);
    XCTAssertEqual(transition.action, VibeAudioPrefetchRequestActionResume);
    XCTAssertTrue(transition.state.requestActive);
    XCTAssertFalse(transition.state.suppressedBehindPlayback);
}

- (void)testUnsuppressedRequestFinishesOnPlaySuccess {
    VibeAudioPrefetchRequestState state = VibeAudioPrefetchRequestStateMake();
    state = VibeAudioPrefetchRequestBegin(state).state;
    uint64_t requestIdentifier = state.currentRequestIdentifier;

    VibeAudioPrefetchRequestTransition transition =
            VibeAudioPrefetchRequestPlaybackSucceeded(state, requestIdentifier);
    XCTAssertEqual(transition.action, VibeAudioPrefetchRequestActionNone);
    XCTAssertFalse(transition.state.requestActive);
}

- (void)testSuppressedRequestDropsWhenTerminallyRetired {
    VibeAudioPrefetchRequestState state = VibeAudioPrefetchRequestStateMake();
    state = VibeAudioPrefetchRequestBegin(state).state;
    uint64_t requestIdentifier = state.currentRequestIdentifier;
    state = VibeAudioPrefetchRequestSuppressBehindPlayback(
            state, requestIdentifier).state;

    VibeAudioPrefetchRequestTransition transition =
            VibeAudioPrefetchRequestFinish(state, requestIdentifier);
    XCTAssertFalse(transition.state.requestActive);
    XCTAssertFalse(transition.state.suppressedBehindPlayback);
    // Finished is terminal: a repeat of the same identifier changes nothing.
    transition = VibeAudioPrefetchRequestFinish(transition.state, requestIdentifier);
    XCTAssertEqual(transition.action, VibeAudioPrefetchRequestActionNone);
}

- (void)testLaterPrefetchUsesFreshRequestIdentity {
    VibeAudioPrefetchRequestState state = VibeAudioPrefetchRequestStateMake();
    state = VibeAudioPrefetchRequestBegin(state).state;
    uint64_t firstIdentifier = state.currentRequestIdentifier;
    state = VibeAudioPrefetchRequestSuppressBehindPlayback(
            state, firstIdentifier).state;

    state = VibeAudioPrefetchRequestBegin(state).state;
    XCTAssertNotEqual(state.currentRequestIdentifier, firstIdentifier);
    XCTAssertFalse(state.suppressedBehindPlayback);

    // A stale identifier's edges change nothing for the fresh request.
    VibeAudioPrefetchRequestTransition stale =
            VibeAudioPrefetchRequestFinish(state, firstIdentifier);
    XCTAssertTrue(stale.state.requestActive);
    VibeAudioPrefetchRequestTransition current =
            VibeAudioPrefetchRequestFinish(state, state.currentRequestIdentifier);
    XCTAssertFalse(current.state.requestActive);
}

@end
