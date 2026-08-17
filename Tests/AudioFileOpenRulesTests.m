//
// Standardized-path identity for bounded audio-open claims.
//

#import <XCTest/XCTest.h>

#import "AudioFileOpenRules.h"

@interface AudioFileOpenRulesTests : XCTestCase
@end

@implementation AudioFileOpenRulesTests

- (void)testEquivalentFilePathsShareOneClaimSpelling {
    NSURL *direct = [NSURL fileURLWithPath:@"/tmp/vibe/audio.flac"];
    NSURL *lexicalAlias = [NSURL fileURLWithPath:@"/tmp/vibe/part/../audio.flac"];
    XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(direct),
                          VibeStandardizedAudioOpenPath(lexicalAlias));
}

- (void)testNonFileURLUsesItsAbsoluteIdentity {
    NSURL *url = [NSURL URLWithString:@"https://example.com/audio.flac?take=2"];
    XCTAssertEqualObjects(VibeStandardizedAudioOpenPath(url), url.absoluteString);
}

- (void)testDetachWinsBeforeQueuedDeliveryBegins {
    VibeAudioFileOpenDeliveryState state = VibeAudioFileOpenDeliveryWaiting;
    XCTAssertTrue(VibeAudioFileOpenDetachDelivery(&state));
    XCTAssertFalse(VibeAudioFileOpenBeginDelivery(&state));
    XCTAssertEqual(state, VibeAudioFileOpenDeliveryDetached);
}

- (void)testDeliveryAlreadyRunningCannotBeRetracted {
    VibeAudioFileOpenDeliveryState state = VibeAudioFileOpenDeliveryWaiting;
    XCTAssertTrue(VibeAudioFileOpenBeginDelivery(&state));
    XCTAssertFalse(VibeAudioFileOpenDetachDelivery(&state));
    XCTAssertEqual(state, VibeAudioFileOpenDeliveryRunning);
}

#pragma mark - The open's abandon deadline

- (void)testNoProgressGetsTheWholeBaseline {
    CFAbsoluteTime submitted = 1000;
    XCTAssertEqual(VibeAudioOpenEffectiveDeadline(submitted, 0),
                   submitted + kOpenNoProgressBudgetSeconds);
}

- (void)testAnEarlySampleCannotShortenTheBaseline {
    // One sample at t+1 and silence after: the deadline is still the full
    // baseline, never t+1 plus the stall budget. This is the max()'s whole
    // point — a sparse or one-shot progress source degrades to no-progress,
    // and feeding a sample is always safe.
    CFAbsoluteTime submitted = 1000;
    XCTAssertEqual(VibeAudioOpenEffectiveDeadline(submitted, submitted + 1),
                   submitted + kOpenNoProgressBudgetSeconds);
}

- (void)testLateProgressExtendsPastTheBaseline {
    // A sample near the baseline's edge pushes the deadline out by the stall
    // budget: a healthy transfer that keeps moving is never abandoned merely
    // for being long.
    CFAbsoluteTime submitted = 1000;
    CFAbsoluteTime sample = submitted + kOpenNoProgressBudgetSeconds - 1;
    XCTAssertEqual(VibeAudioOpenEffectiveDeadline(submitted, sample),
                   sample + kOpenStallBudgetSeconds);
}

- (void)testAStalledTransferRunsOutOfItsStallBudget {
    // Progress that stops after the baseline: the deadline is the last
    // sample plus the stall budget, and nothing extends it further.
    CFAbsoluteTime submitted = 1000;
    CFAbsoluteTime lastSample = submitted + kOpenNoProgressBudgetSeconds + 30;
    CFAbsoluteTime deadline = VibeAudioOpenEffectiveDeadline(submitted, lastSample);
    XCTAssertEqual(deadline, lastSample + kOpenStallBudgetSeconds);
}

@end
