//
// Asynchronous open expansion may finish out of order, and may not finish at
// all. These tests pin the coordinator's burst ordering, its
// replacement-supersession rule, and how it gives up on a straggler.
//

#import <XCTest/XCTest.h>

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

// Every request records what it delivered, so the assertions read as the
// playlist-facing sequence rather than as coordinator internals.
- (OpenRequestToken *)beginAppending:(BOOL)append tagged:(NSString *)tag {
    NSMutableArray<NSString *> *deliveries = _deliveries;
    return [_coordinator beginRequestAppending:append
                                      delivery:^(NSArray<NSURL *> *files, NSUInteger folders, BOOL appending) {
        [deliveries addObject:[NSString stringWithFormat:@"%@:%@:%lu:%lu", tag,
                appending ? @"append" : @"replace",
                (unsigned long)files.count, (unsigned long)folders]];
    }];
}

static NSArray<NSURL *> *OpenFiles(NSUInteger count) {
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [files addObject:[NSURL fileURLWithPath:
                [NSString stringWithFormat:@"/private/tmp/open-%lu.mp3", (unsigned long)i]]];
    }
    return files;
}

- (void)testAppendWaitsForEarlierReplacement {
    OpenRequestToken *replacement = [self beginAppending:NO tagged:@"first"];
    OpenRequestToken *append = [self beginAppending:YES tagged:@"second"];
    [_coordinator finishRequest:append files:OpenFiles(1) folderCount:0];
    XCTAssertEqual(_deliveries.count, 0u);
    [_coordinator finishRequest:replacement files:OpenFiles(2) folderCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"first:replace:2:1", @"second:append:1:0"]));
}

- (void)testNewReplacementSupersedesAStalledGeneration {
    OpenRequestToken *stalled = [self beginAppending:NO tagged:@"stalled"];
    OpenRequestToken *stalledAppend = [self beginAppending:YES tagged:@"stalledAppend"];
    OpenRequestToken *replacement = [self beginAppending:NO tagged:@"replacement"];
    XCTAssertFalse([_coordinator isRequestCurrent:stalled]);
    XCTAssertFalse([_coordinator isRequestCurrent:stalledAppend]);
    XCTAssertTrue([_coordinator isRequestCurrent:replacement]);

    [_coordinator finishRequest:replacement files:OpenFiles(1) folderCount:0];
    [_coordinator finishRequest:stalled files:OpenFiles(3) folderCount:1];
    [_coordinator finishRequest:stalledAppend files:OpenFiles(2) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"replacement:replace:1:0"]));
}

- (void)testEmptyResultStillUnblocksFollowingAppend {
    OpenRequestToken *replacement = [self beginAppending:NO tagged:@"first"];
    OpenRequestToken *append = [self beginAppending:YES tagged:@"second"];
    [_coordinator finishRequest:append files:OpenFiles(1) folderCount:0];
    [_coordinator finishRequest:replacement files:@[] folderCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"first:replace:0:1", @"second:append:1:0"]));
}

// The first batch's folder walk hangs on a mount that never answers. Without
// the deadline every later batch in the burst would buffer unseen, and a
// multi-file open would produce nothing at all.
- (void)testAStragglerIsAbandonedRatherThanHoldingItsBurst {
    OpenRequestToken *wedged = [self beginAppending:NO tagged:@"wedged"];
    OpenRequestToken *second = [self beginAppending:YES tagged:@"second"];
    OpenRequestToken *third = [self beginAppending:YES tagged:@"third"];
    [_coordinator finishRequest:third files:OpenFiles(3) folderCount:0];
    [_coordinator finishRequest:second files:OpenFiles(2) folderCount:0];
    XCTAssertEqual(_deliveries.count, 0u);

    [_coordinator abandonStalledRequests];
    XCTAssertEqualObjects(_deliveries, (@[@"second:append:2:0", @"third:append:3:0"]));

    // And if it does eventually answer, it is dropped rather than reordering
    // the playlist behind the user.
    [_coordinator finishRequest:wedged files:OpenFiles(9) folderCount:1];
    XCTAssertEqualObjects(_deliveries, (@[@"second:append:2:0", @"third:append:3:0"]));
}

- (void)testAbandonIsANoOpWithNothingWaiting {
    OpenRequestToken *only = [self beginAppending:NO tagged:@"only"];
    [_coordinator abandonStalledRequests];
    XCTAssertEqual(_deliveries.count, 0u);
    // The request is untouched, so it still delivers when it finishes.
    [_coordinator finishRequest:only files:OpenFiles(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"only:replace:1:0"]));
}

// An append arriving before any replacement is a genuine append, not a
// silently rewritten replacement.
- (void)testAFirstAppendIsNotRewrittenIntoAReplacement {
    OpenRequestToken *append = [self beginAppending:YES tagged:@"first"];
    [_coordinator finishRequest:append files:OpenFiles(1) folderCount:0];
    XCTAssertEqualObjects(_deliveries, (@[@"first:append:1:0"]));
}

@end
