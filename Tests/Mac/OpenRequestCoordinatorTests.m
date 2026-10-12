//
// Open expansion may finish out of order, or never: burst ordering,
// replacement supersession, and giving up on a straggler.
//

#import <XCTest/XCTest.h>

#import "AudioTrack.h"
#import "OpenRequestCoordinator.h"

@interface OpenRequestCoordinatorTests : XCTestCase
@end

@implementation OpenRequestCoordinatorTests {
    OpenRequestCoordinator *_coordinator;
    NSMutableArray<NSString *> *_deliveries;
}

- (void)setUp {
    [super setUp];
    _deliveries = [NSMutableArray array];
    _coordinator = [[OpenRequestCoordinator alloc] init];
}

// Records deliveries so assertions read as the playlist-facing sequence.
- (OpenRequestToken *)beginAppending:(BOOL)append tagged:(NSString *)tag {
    NSMutableArray<NSString *> *deliveries = _deliveries;
    return [_coordinator beginRequestAppending:append
                                      delivery:^(NSArray<AudioTrack *> *rows, NSUInteger folders, BOOL appending) {
        [deliveries addObject:[NSString stringWithFormat:@"%@:%@:%lu:%lu", tag,
                appending ? @"append" : @"replace",
                (unsigned long)rows.count, (unsigned long)folders]];
    }];
}

static NSArray<AudioTrack *> *OpenRows(NSUInteger count) {
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [rows addObject:[AudioTrack withURL:[NSURL fileURLWithPath:
                [NSString stringWithFormat:@"/private/tmp/open-%lu.mp3", (unsigned long)i]]]];
    }
    return rows;
}

- (void)testAppendWaitsForEarlierReplacement {
    OpenRequestToken *replacement = [self beginAppending:NO tagged:@"first"];
    OpenRequestToken *append = [self beginAppending:YES tagged:@"second"];
    [_coordinator finishRequest:append rows:OpenRows(1) folderCount:0];
    XCTAssertEqual(_deliveries.count, 0u);
    [_coordinator finishRequest:replacement rows:OpenRows(2) folderCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"first:replace:2:1", @"second:append:1:0"]));
}

- (void)testNewReplacementSupersedesAStalledGeneration {
    OpenRequestToken *stalled = [self beginAppending:NO tagged:@"stalled"];
    OpenRequestToken *stalledAppend = [self beginAppending:YES tagged:@"stalledAppend"];
    OpenRequestToken *replacement = [self beginAppending:NO tagged:@"replacement"];
    XCTAssertFalse([_coordinator isRequestCurrent:stalled]);
    XCTAssertFalse([_coordinator isRequestCurrent:stalledAppend]);
    XCTAssertTrue([_coordinator isRequestCurrent:replacement]);

    [_coordinator finishRequest:replacement rows:OpenRows(1) folderCount:0];
    [_coordinator finishRequest:stalled rows:OpenRows(3) folderCount:1];
    [_coordinator finishRequest:stalledAppend rows:OpenRows(2) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"replacement:replace:1:0"]));
}

- (void)testEmptyResultStillUnblocksFollowingAppend {
    OpenRequestToken *replacement = [self beginAppending:NO tagged:@"first"];
    OpenRequestToken *append = [self beginAppending:YES tagged:@"second"];
    [_coordinator finishRequest:append rows:OpenRows(1) folderCount:0];
    [_coordinator finishRequest:replacement rows:@[] folderCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"first:replace:0:1", @"second:append:1:0"]));
}

- (void)testCloseDropsPendingAndBufferedOpensAndAllowsANewAppend {
    OpenRequestToken *walking = [self beginAppending:NO tagged:@"walking"];
    OpenRequestToken *buffered = [self beginAppending:YES tagged:@"buffered"];
    [_coordinator finishRequest:buffered rows:OpenRows(1) folderCount:0];
    [_coordinator invalidate];
    XCTAssertFalse([_coordinator isRequestCurrent:walking]);
    XCTAssertFalse([_coordinator isRequestCurrent:buffered]);
    [_coordinator finishRequest:walking rows:OpenRows(2) folderCount:1];
    [_coordinator abandonStalledRequests];
    XCTAssertEqual(_deliveries.count, 0u);

    OpenRequestToken *fresh = [self beginAppending:YES tagged:@"fresh"];
    [_coordinator finishRequest:fresh rows:OpenRows(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"fresh:append:1:0"]));
}

// The first batch's walk hangs on a mount that never answers; without the
// deadline every later batch in the burst would buffer unseen.
- (void)testAStragglerIsAbandonedRatherThanHoldingItsBurst {
    OpenRequestToken *wedged = [self beginAppending:NO tagged:@"wedged"];
    OpenRequestToken *second = [self beginAppending:YES tagged:@"second"];
    OpenRequestToken *third = [self beginAppending:YES tagged:@"third"];
    [_coordinator finishRequest:third rows:OpenRows(3) folderCount:0];
    [_coordinator finishRequest:second rows:OpenRows(2) folderCount:0];
    XCTAssertEqual(_deliveries.count, 0u);

    [_coordinator abandonStalledRequests];
    XCTAssertEqualObjects(_deliveries, (@[@"second:append:2:0", @"third:append:3:0"]));

    // A late answer is dropped rather than reordering the playlist.
    [_coordinator finishRequest:wedged rows:OpenRows(9) folderCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"second:append:2:0", @"third:append:3:0"]));
}

- (void)testASlowWalkBehindAWedgedOneStillDelivers {
    OpenRequestToken *wedged = [self beginAppending:NO tagged:@"wedged"];
    OpenRequestToken *slow = [self beginAppending:YES tagged:@"slow"];
    OpenRequestToken *third = [self beginAppending:YES tagged:@"third"];
    [_coordinator finishRequest:third rows:OpenRows(3) folderCount:0];

    [_coordinator abandonStalledRequests];
    XCTAssertEqual(_deliveries.count, 0u);

    [_coordinator finishRequest:slow rows:OpenRows(2) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"slow:append:2:0", @"third:append:3:0"]));

    [_coordinator finishRequest:wedged rows:OpenRows(9) folderCount:1];
    XCTAssertEqual(_deliveries.count, 2u);
}

// Once the first gap is abandoned, the second wedged walk is a gap of its own
// that only a re-armed deadline frees.
- (void)testASecondStragglerGetsItsOwnDeadline {
    _coordinator.stragglerDeadline = 0.02;
    OpenRequestToken *wedged = [self beginAppending:NO tagged:@"wedged"];
    OpenRequestToken *second = [self beginAppending:YES tagged:@"second"];
    [self beginAppending:YES tagged:@"alsoWedged"];
    OpenRequestToken *fourth = [self beginAppending:YES tagged:@"fourth"];
    [_coordinator finishRequest:second rows:OpenRows(2) folderCount:0];
    [_coordinator finishRequest:fourth rows:OpenRows(4) folderCount:0];

    [self waitForDeliveryCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"second:append:2:0"]));

    [self waitForDeliveryCount:2];
    XCTAssertEqualObjects(_deliveries, (@[@"second:append:2:0", @"fourth:append:4:0"]));

    [_coordinator finishRequest:wedged rows:OpenRows(9) folderCount:1];
    XCTAssertEqual(_deliveries.count, 2u);
}

// The older timer exits on the generation mismatch, so a replacement that
// inherited its arming would wait for a deadline that never comes.
- (void)testAReplacementGetsItsOwnDeadlineWhileAnOlderOneIsArmed {
    _coordinator.stragglerDeadline = 0.02;
    [self beginAppending:NO tagged:@"oldWedged"];
    OpenRequestToken *oldSecond = [self beginAppending:YES tagged:@"oldSecond"];
    [_coordinator finishRequest:oldSecond rows:OpenRows(2) folderCount:0];

    [self beginAppending:NO tagged:@"newWedged"];
    OpenRequestToken *newSecond = [self beginAppending:YES tagged:@"newSecond"];
    [_coordinator finishRequest:newSecond rows:OpenRows(5) folderCount:0];

    [self waitForDeliveryCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"newSecond:append:5:0"]));
}

// A gap that drains before its deadline leaves the old timer in flight.
- (void)testALaterGapDoesNotInheritADrainedGapsDeadline {
    _coordinator.stragglerDeadline = 0.3;
    OpenRequestToken *first = [self beginAppending:NO tagged:@"first"];
    OpenRequestToken *firstAppend = [self beginAppending:YES tagged:@"firstAppend"];
    [_coordinator finishRequest:firstAppend rows:OpenRows(2) folderCount:0];

    [self spinRunLoopFor:0.2];
    XCTAssertEqual(_deliveries.count, 0u);
    [_coordinator finishRequest:first rows:OpenRows(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"first:replace:1:0", @"firstAppend:append:2:0"]));

    OpenRequestToken *laterWedged = [self beginAppending:YES tagged:@"laterWedged"];
    OpenRequestToken *laterAppend = [self beginAppending:YES tagged:@"laterAppend"];
    NSDate *laterGapStarted = [NSDate date];
    [_coordinator finishRequest:laterAppend rows:OpenRows(4) folderCount:0];

    [self waitForDeliveryCount:3];
    XCTAssertGreaterThanOrEqual([[NSDate date] timeIntervalSinceDate:laterGapStarted], 0.2);
    XCTAssertEqualObjects(_deliveries, (@[
        @"first:replace:1:0",
        @"firstAppend:append:2:0",
        @"laterAppend:append:4:0",
    ]));

    [_coordinator finishRequest:laterWedged rows:OpenRows(9) folderCount:1];
    XCTAssertEqual(_deliveries.count, 3u);
}

// A dropped link still resolving is held. A later append that finishes first
// waits for it, and the deadline gives up on nothing.
- (void)testAHeldRequestIsNeverAbandoned {
    _coordinator.stragglerDeadline = 0.02;
    OpenRequestToken *links = [self beginAppending:YES tagged:@"links"];
    [_coordinator holdRequest:links];
    OpenRequestToken *files = [self beginAppending:YES tagged:@"files"];
    [_coordinator finishRequest:files rows:OpenRows(2) folderCount:0];

    [self spinRunLoopFor:0.1];
    [_coordinator abandonStalledRequests];
    XCTAssertEqual(_deliveries.count, 0u);

    [_coordinator releaseRequest:links];
    [_coordinator finishRequest:links rows:OpenRows(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"links:append:1:0", @"files:append:2:0"]));
}

// The release starts a whole deadline for what the head opens next, and that
// deadline still frees a head whose expansion then wedges.
- (void)testAReleasedRequestGetsAFullDeadline {
    _coordinator.stragglerDeadline = 0.3;
    OpenRequestToken *links = [self beginAppending:YES tagged:@"links"];
    [_coordinator holdRequest:links];
    OpenRequestToken *files = [self beginAppending:YES tagged:@"files"];
    [_coordinator finishRequest:files rows:OpenRows(2) folderCount:0];

    [self spinRunLoopFor:0.2];
    NSDate *released = [NSDate date];
    [_coordinator releaseRequest:links];
    [self waitForDeliveryCount:1];
    XCTAssertGreaterThanOrEqual([[NSDate date] timeIntervalSinceDate:released], 0.2,
                                @"not the deadline armed before the release");
    XCTAssertEqualObjects(_deliveries, (@[@"files:append:2:0"]));

    [_coordinator finishRequest:links rows:OpenRows(1) folderCount:0];
    XCTAssertEqual(_deliveries.count, 1u);
}

// A hold belongs to its generation. A replacement drops it, and a release of
// the superseded token holds nothing up.
- (void)testAReplacementDropsAHold {
    OpenRequestToken *links = [self beginAppending:NO tagged:@"links"];
    [_coordinator holdRequest:links];
    OpenRequestToken *wedged = [self beginAppending:NO tagged:@"wedged"];
    OpenRequestToken *files = [self beginAppending:YES tagged:@"files"];
    [_coordinator finishRequest:files rows:OpenRows(2) folderCount:0];
    [_coordinator releaseRequest:links];

    [_coordinator abandonStalledRequests];
    XCTAssertEqualObjects(_deliveries, (@[@"files:append:2:0"]));
    [_coordinator finishRequest:wedged rows:OpenRows(9) folderCount:0];
    XCTAssertEqual(_deliveries.count, 1u);
}

// Spins the run loop rather than sleeping, because the deadline fires on main.
- (void)waitForDeliveryCount:(NSUInteger)count {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (_deliveries.count < count && limit.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertEqual(_deliveries.count, count);
}

- (void)spinRunLoopFor:(NSTimeInterval)duration {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:duration];
    while (limit.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
}

- (void)testAbandonIsANoOpWithNothingWaiting {
    OpenRequestToken *only = [self beginAppending:NO tagged:@"only"];
    [_coordinator abandonStalledRequests];
    XCTAssertEqual(_deliveries.count, 0u);
    [_coordinator finishRequest:only rows:OpenRows(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"only:replace:1:0"]));
}

- (void)testAFirstAppendIsNotRewrittenIntoAReplacement {
    OpenRequestToken *append = [self beginAppending:YES tagged:@"first"];
    [_coordinator finishRequest:append rows:OpenRows(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"first:append:1:0"]));
}

@end
