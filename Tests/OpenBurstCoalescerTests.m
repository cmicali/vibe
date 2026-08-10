//
// The open-burst coalescer: first batch replaces immediately, later batches
// inside the quiet period append, a deliberate open ends the burst, and a
// burst straddling launch still lands as one playlist. The scheduler is
// injected so the quiet period elapses only when a test fires it.
//

#import <XCTest/XCTest.h>

#import "OpenBurstCoalescer.h"

@interface OpenBurstCoalescerTests : XCTestCase
@end

@implementation OpenBurstCoalescerTests {
    OpenBurstCoalescer *_coalescer;
    NSMutableArray<NSString *> *_drains;          // "replace 2" / "append 1"
    NSMutableArray<dispatch_block_t> *_timers;    // scheduled quiet-period blocks
}

- (void)setUp {
    [super setUp];
    _drains = [NSMutableArray array];
    _timers = [NSMutableArray array];
    NSMutableArray<NSString *> *drains = _drains;
    NSMutableArray<dispatch_block_t> *timers = _timers;
    _coalescer = [[OpenBurstCoalescer alloc]
            initWithQuietPeriod:0.3
                      scheduler:^(NSTimeInterval delay, dispatch_block_t block) {
                          [timers addObject:block];
                      }
                           sink:^(NSArray<NSURL *> *urls, BOOL append) {
                               [drains addObject:[NSString stringWithFormat:@"%@ %lu",
                                                  append ? @"append" : @"replace",
                                                  (unsigned long)urls.count]];
                           }];
}

static NSArray<NSURL *> *URLBatch(NSUInteger count) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        [urls addObject:[NSURL fileURLWithPath:[NSString stringWithFormat:@"/private/tmp/vibe-tests/%lu.mp3",
                                                (unsigned long)i]]];
    }
    return urls;
}

// The most recently scheduled quiet period elapses.
- (void)fireQuietPeriod {
    XCTAssertTrue(_timers.count > 0);
    _timers.lastObject();
}

#pragma mark - Burst shape

- (void)testFirstBatchReplacesAndLaterBatchesAppend {
    [_coalescer startAndDrainQueue];
    [_coalescer openBurstURLs:URLBatch(2)];
    [_coalescer openBurstURLs:URLBatch(1)];
    [_coalescer openBurstURLs:URLBatch(3)];
    NSArray *expected = @[@"replace 2", @"append 1", @"append 3"];
    XCTAssertEqualObjects(_drains, expected);
}

- (void)testBatchAfterTheQuietPeriodStartsANewBurst {
    [_coalescer startAndDrainQueue];
    [_coalescer openBurstURLs:URLBatch(2)];
    [self fireQuietPeriod];
    [_coalescer openBurstURLs:URLBatch(1)];
    NSArray *expected = @[@"replace 2", @"replace 1"];
    XCTAssertEqualObjects(_drains, expected);
}

- (void)testSupersededQuietPeriodDoesNotEndTheBurst {
    [_coalescer startAndDrainQueue];
    [_coalescer openBurstURLs:URLBatch(1)];   // schedules timer A
    [_coalescer openBurstURLs:URLBatch(1)];   // supersedes with timer B
    _timers.firstObject();                    // stale timer A fires — a no-op
    [_coalescer openBurstURLs:URLBatch(1)];   // still the same burst
    NSArray *expected = @[@"replace 1", @"append 1", @"append 1"];
    XCTAssertEqualObjects(_drains, expected);
}

#pragma mark - Deliberate opens

- (void)testReplacingOpenAlwaysReplacesAndEndsTheBurst {
    [_coalescer startAndDrainQueue];
    [_coalescer openBurstURLs:URLBatch(2)];
    [_coalescer openReplacingURLs:URLBatch(1)];   // mid-burst deliberate open
    [_coalescer openBurstURLs:URLBatch(3)];       // next burst batch starts fresh
    NSArray *expected = @[@"replace 2", @"replace 1", @"replace 3"];
    XCTAssertEqualObjects(_drains, expected);
}

#pragma mark - Launch straddling

- (void)testQueuedURLsDrainAtStartAndTheRemainderAppends {
    [_coalescer enqueueURLs:URLBatch(2)];               // pre-launch batch
    XCTAssertEqual(_drains.count, 0u);
    XCTAssertTrue([_coalescer startAndDrainQueue]);
    [_coalescer openBurstURLs:URLBatch(1)];             // post-launch remainder
    NSArray *expected = @[@"replace 2", @"append 1"];
    XCTAssertEqualObjects(_drains, expected);
}

- (void)testStartWithNothingQueuedDrainsNothing {
    XCTAssertFalse([_coalescer startAndDrainQueue]);
    XCTAssertEqual(_drains.count, 0u);
    XCTAssertEqual(_timers.count, 0u);
}

- (void)testPreStartBurstEventsOnlyQueue {
    [_coalescer openBurstURLs:URLBatch(2)];   // straddles launch: no drain yet
    XCTAssertEqual(_drains.count, 0u);
    XCTAssertTrue([_coalescer startAndDrainQueue]);
    NSArray *expected = @[@"replace 2"];
    XCTAssertEqualObjects(_drains, expected);
}

- (void)testPreStartReplacingOpenQueuesForTheLaunchDrain {
    [_coalescer openReplacingURLs:URLBatch(1)];
    XCTAssertEqual(_drains.count, 0u);
    XCTAssertTrue([_coalescer startAndDrainQueue]);
    NSArray *expected = @[@"replace 1"];
    XCTAssertEqualObjects(_drains, expected);
}

@end
