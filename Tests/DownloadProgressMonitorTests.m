//
//  DownloadProgressMonitorTests.m
//

#import <XCTest/XCTest.h>

#import "DownloadProgressMonitor+Debug.h"
#import "DownloadProgressMonitorInternal.h"

@interface DownloadProgressMonitorTests : XCTestCase
@property(nonatomic, strong) DownloadProgressMonitor *monitor;
@end

@implementation DownloadProgressMonitorTests

- (void)setUp {
    [super setUp];
    [DownloadProgressMonitor setFakeProgressProvider:^float(NSURL *url) {
        return url ? 0 : -1;
    }];
}

- (void)tearDown {
    [self onMain:^{
        [self.monitor cancel];
        self.monitor = nil;
    }];
    [DownloadProgressMonitor setFakeProgressProvider:nil];
    [super tearDown];
}

- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) {
        block();
    }
    else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

- (NSURL *)URLWithName:(NSString *)name {
    return [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:name]];
}

- (void)testSubPercentRawIncreaseIsMovementButNotUIProgress {
    [self onMain:^{
        __block NSUInteger movements = 0;
        NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
        NSURL *url = [self URLWithName:@"movement.mp3"];
        self.monitor = [DownloadProgressMonitor monitorReplacing:nil
                forURL:url currentURL:^NSURL *{ return url; }
                movement:^{ movements++; }
                handler:^(float fraction) { [fractions addObject:@(fraction)]; }];

        [self.monitor reportFraction:0.25f];
        [self.monitor reportFraction:0.2501f];

        XCTAssertEqual(movements, 2u);
        XCTAssertEqualObjects(fractions, (@[@0.25f]));
    }];
}

- (void)testInvalidRepeatedAndBackwardSamplesDoNotMoveOrPublish {
    [self onMain:^{
        __block NSUInteger movements = 0;
        NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
        NSURL *url = [self URLWithName:@"invalid.mp3"];
        self.monitor = [DownloadProgressMonitor monitorReplacing:nil
                forURL:url currentURL:^NSURL *{ return url; }
                movement:^{ movements++; }
                handler:^(float fraction) { [fractions addObject:@(fraction)]; }];

        [self.monitor reportFraction:0.4f];
        [self.monitor reportFraction:0.4f];
        [self.monitor reportFraction:0.2f];
        [self.monitor reportFraction:-0.1f];
        [self.monitor reportFraction:NAN];
        [self.monitor reportFraction:INFINITY];
        [self.monitor reportFraction:0.4001f];

        XCTAssertEqual(movements, 2u);
        XCTAssertEqualObjects(fractions, (@[@0.4f]));
    }];
}

- (void)testReplacementCancelsOldMonitorAndCurrentURLDropsStaleDeliveries {
    [self onMain:^{
        NSURL *firstURL = [self URLWithName:@"first.mp3"];
        NSURL *secondURL = [self URLWithName:@"second.mp3"];
        __block NSURL *currentURL = firstURL;
        __block NSUInteger firstMovements = 0;
        __block NSUInteger firstDeliveries = 0;
        DownloadProgressMonitor *first = [DownloadProgressMonitor monitorReplacing:nil
                forURL:firstURL currentURL:^NSURL *{ return currentURL; }
                movement:^{ firstMovements++; }
                handler:^(float fraction) { firstDeliveries++; }];
        [first reportFraction:0.2f];

        currentURL = secondURL;
        __block NSUInteger secondMovements = 0;
        __block NSUInteger secondDeliveries = 0;
        self.monitor = [DownloadProgressMonitor monitorReplacing:first
                forURL:secondURL currentURL:^NSURL *{ return currentURL; }
                movement:^{ secondMovements++; }
                handler:^(float fraction) { secondDeliveries++; }];
        [first reportFraction:0.5f];
        [self.monitor reportFraction:0.2f];

        currentURL = firstURL;
        [self.monitor reportFraction:0.4f];

        XCTAssertEqual(firstMovements, 1u);
        XCTAssertEqual(firstDeliveries, 1u);
        XCTAssertEqual(secondMovements, 1u);
        XCTAssertEqual(secondDeliveries, 1u);
    }];
}

- (void)testFinalFractionBypassesWholePercentGateAndOvershootIsClamped {
    [self onMain:^{
        NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
        NSURL *url = [self URLWithName:@"complete.mp3"];
        self.monitor = [DownloadProgressMonitor monitorReplacing:nil
                forURL:url currentURL:^NSURL *{ return url; }
                movement:nil
                handler:^(float fraction) { [fractions addObject:@(fraction)]; }];

        [self.monitor reportFraction:0.995f];
        [self.monitor reportFraction:1.0f];
        XCTAssertEqualObjects(fractions, (@[@0.995f, @1.0f]));

        [self.monitor cancel];
        [self.monitor reportFraction:1.5f];
        XCTAssertEqualObjects(fractions, (@[@0.995f, @1.0f]));

        self.monitor = [DownloadProgressMonitor monitorReplacing:nil
                forURL:url currentURL:^NSURL *{ return url; }
                movement:nil
                handler:^(float fraction) { [fractions addObject:@(fraction)]; }];
        [self.monitor reportFraction:1.5f];
        XCTAssertEqualObjects(fractions, (@[@0.995f, @1.0f, @1.0f]));
    }];
}

@end
