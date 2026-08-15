//
// The Now Playing republish position rule: natural playback advance must not
// count as dirty, because the system extrapolates elapsed time itself from
// the last publish; only a jump the extrapolation cannot explain — a seek, a
// pitch rescale — forces a republish.
//

#import <XCTest/XCTest.h>

#import "NowPlayingRules.h"

@interface NowPlayingRulesTests : XCTestCase
@end

@implementation NowPlayingRulesTests

// Published at t=1000, position 30s. All cases judge a candidate 10 seconds
// of wall-clock later.
static const CFAbsoluteTime kPublishedAt = 1000.0;
static const CFAbsoluteTime kNow = 1010.0;
static const NSTimeInterval kPublishedPosition = 30.0;

static BOOL Dirty(double publishedRate, BOOL wasPlaying, NSTimeInterval position) {
    return VibeNowPlayingPositionIsDirty(kPublishedPosition, kPublishedAt, publishedRate, wasPlaying,
                                         position, kNow, kVibeNowPlayingRepublishTolerance);
}

- (void)testNaturalAdvanceWhilePlayingIsNotDirty {
    // 10 wall-clock seconds at rate 1: the system predicts 40s on its own.
    XCTAssertFalse(Dirty(1.0, YES, 40.0));
    XCTAssertFalse(Dirty(1.0, YES, 40.9));   // inside the 1s tolerance
    XCTAssertFalse(Dirty(1.0, YES, 39.1));
}

- (void)testHoldWhilePausedIsNotDirty {
    // Paused extrapolates at 0 whatever rate was published with the pause.
    XCTAssertFalse(Dirty(1.0, NO, 30.0));
    XCTAssertFalse(Dirty(2.0, NO, 30.5));
}

- (void)testSeekWhilePlayingIsDirty {
    XCTAssertTrue(Dirty(1.0, YES, 100.0));   // forward jump
    XCTAssertTrue(Dirty(1.0, YES, 5.0));     // backward jump
}

- (void)testSeekWhilePausedIsDirty {
    // Paused predicts a held position, so any real movement is a jump.
    XCTAssertTrue(Dirty(1.0, NO, 40.0));
}

- (void)testPublishedRateScalesThePrediction {
    // Published while playing at rate 2: prediction is 30 + 10*2 = 50.
    XCTAssertFalse(Dirty(2.0, YES, 50.0));
    XCTAssertTrue(Dirty(2.0, YES, 40.0));    // rate-1 advance no longer explains it
}

- (void)testToleranceBoundary {
    // Exactly at the tolerance is still natural advance; beyond it is a jump.
    XCTAssertFalse(Dirty(1.0, YES, 41.0));
    XCTAssertTrue(Dirty(1.0, YES, 41.001));
}

@end
