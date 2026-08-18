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

- (void)testSuppressedAcknowledgementResumesAfterPlaySuccessAndSettlesOnceOnClaim {
    VibeAudioPrefetchAcknowledgementState state =
            VibeAudioPrefetchAcknowledgementStateMake();
    VibeAudioPrefetchAcknowledgementTransition transition =
            VibeAudioPrefetchAcknowledgementBegin(state, YES);
    state = transition.state;
    uint64_t requestIdentifier = state.currentRequestIdentifier;
    XCTAssertEqual(transition.action, VibeAudioPrefetchAcknowledgementActionNone);

    transition = VibeAudioPrefetchAcknowledgementSuppressBehindPlayback(
            state, requestIdentifier);
    state = transition.state;
    XCTAssertTrue(state.suppressedBehindPlayback);

    transition = VibeAudioPrefetchAcknowledgementPlaybackSucceeded(
            state, requestIdentifier);
    state = transition.state;
    XCTAssertEqual(transition.action, VibeAudioPrefetchAcknowledgementActionResume);
    XCTAssertTrue(state.requestActive);
    XCTAssertTrue(state.acknowledgementPending);

    transition = VibeAudioPrefetchAcknowledgementClaimSettled(
            state, requestIdentifier);
    state = transition.state;
    XCTAssertEqual(transition.action, VibeAudioPrefetchAcknowledgementActionDeliver);
    XCTAssertFalse(state.requestActive);

    transition = VibeAudioPrefetchAcknowledgementClaimSettled(
            state, requestIdentifier);
    XCTAssertEqual(transition.action, VibeAudioPrefetchAcknowledgementActionNone);
}

- (void)testSuppressedAcknowledgementSettlesOnceWhenPlaybackFails {
    VibeAudioPrefetchAcknowledgementState state =
            VibeAudioPrefetchAcknowledgementStateMake();
    state = VibeAudioPrefetchAcknowledgementBegin(state, YES).state;
    uint64_t requestIdentifier = state.currentRequestIdentifier;
    state = VibeAudioPrefetchAcknowledgementSuppressBehindPlayback(
            state, requestIdentifier).state;

    VibeAudioPrefetchAcknowledgementTransition transition =
            VibeAudioPrefetchAcknowledgementTerminallyRetired(
                    state, requestIdentifier);
    state = transition.state;
    XCTAssertEqual(transition.action, VibeAudioPrefetchAcknowledgementActionDeliver);
    transition = VibeAudioPrefetchAcknowledgementTerminallyRetired(
            state, requestIdentifier);
    XCTAssertEqual(transition.action, VibeAudioPrefetchAcknowledgementActionNone);
}

- (void)testSuppressedAcknowledgementSettlesOnceWhenPlayIsSuperseded {
    VibeAudioPrefetchAcknowledgementState state =
            VibeAudioPrefetchAcknowledgementStateMake();
    state = VibeAudioPrefetchAcknowledgementBegin(state, YES).state;
    uint64_t requestIdentifier = state.currentRequestIdentifier;
    state = VibeAudioPrefetchAcknowledgementSuppressBehindPlayback(
            state, requestIdentifier).state;

    VibeAudioPrefetchAcknowledgementTransition transition =
            VibeAudioPrefetchAcknowledgementTerminallyRetired(
                    state, requestIdentifier);
    XCTAssertEqual(transition.action, VibeAudioPrefetchAcknowledgementActionDeliver);
    XCTAssertFalse(transition.state.requestActive);
}

- (void)testSuppressedAcknowledgementSettlesOnceOnAbandonment {
    VibeAudioPrefetchAcknowledgementState state =
            VibeAudioPrefetchAcknowledgementStateMake();
    state = VibeAudioPrefetchAcknowledgementBegin(state, YES).state;
    uint64_t requestIdentifier = state.currentRequestIdentifier;
    state = VibeAudioPrefetchAcknowledgementSuppressBehindPlayback(
            state, requestIdentifier).state;

    VibeAudioPrefetchAcknowledgementTransition transition =
            VibeAudioPrefetchAcknowledgementTerminallyRetired(
                    state, requestIdentifier);
    state = transition.state;
    XCTAssertEqual(transition.action, VibeAudioPrefetchAcknowledgementActionDeliver);
    transition = VibeAudioPrefetchAcknowledgementClaimSettled(state, requestIdentifier);
    XCTAssertEqual(transition.action, VibeAudioPrefetchAcknowledgementActionNone);
}

- (void)testLaterPrefetchRetiresOlderWaiterAndUsesFreshRequestIdentity {
    VibeAudioPrefetchAcknowledgementState state =
            VibeAudioPrefetchAcknowledgementStateMake();
    state = VibeAudioPrefetchAcknowledgementBegin(state, YES).state;
    uint64_t firstIdentifier = state.currentRequestIdentifier;
    state = VibeAudioPrefetchAcknowledgementSuppressBehindPlayback(
            state, firstIdentifier).state;

    VibeAudioPrefetchAcknowledgementTransition replacement =
            VibeAudioPrefetchAcknowledgementBegin(state, YES);
    state = replacement.state;
    XCTAssertEqual(replacement.action, VibeAudioPrefetchAcknowledgementActionDeliver);
    XCTAssertNotEqual(state.currentRequestIdentifier, firstIdentifier);

    VibeAudioPrefetchAcknowledgementTransition stale =
            VibeAudioPrefetchAcknowledgementClaimSettled(state, firstIdentifier);
    XCTAssertEqual(stale.action, VibeAudioPrefetchAcknowledgementActionNone);
    VibeAudioPrefetchAcknowledgementTransition current =
            VibeAudioPrefetchAcknowledgementClaimSettled(
                    state, state.currentRequestIdentifier);
    XCTAssertEqual(current.action, VibeAudioPrefetchAcknowledgementActionDeliver);
}

@end
