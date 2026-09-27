// Real ticks over real time. A loaded machine can starve the main queue, and
// dispatch coalesces missed fires, but nothing invents ticks: an upper bound
// counts over a fixed window, and a lower bound waits with a deadline slack
// enough for a CI runner ten times slow yet too tight for the slower rate.

#import <XCTest/XCTest.h>

#import "UIUpdateTimer.h"

@interface UIUpdateTimerTests : XCTestCase
@end

// File statics, not ivars: capturing the test case would resurrect one the
// runner has finished with. Touched only on the main queue, where both the
// handler and the test method run.
static NSUInteger sTicks;
static NSUInteger sTarget;
static XCTestExpectation *sReachedTarget;

@implementation UIUpdateTimerTests {
    UIUpdateTimer *_timer;
}

- (void)tearDown {
    _timer.wanted = NO;
    _timer = nil;
    sTarget = 0;
    sReachedTarget = nil;
    [super tearDown];
}

// The handler runs on the main queue, and waiting spins the main runloop,
// which drains it.
- (UIUpdateTimer *)timerAtHz:(NSUInteger)hz {
    _timer = [[UIUpdateTimer alloc] initWithHz:hz handler:^{
        sTicks++;
        if (sTarget > 0 && sTicks >= sTarget) {
            sTarget = 0;
            [sReachedTarget fulfill];
            sReachedTarget = nil;
        }
    }];
    return _timer;
}

- (NSUInteger)ticksOver:(NSTimeInterval)seconds {
    sTicks = 0;
    XCTestExpectation *waited = [self expectationWithDescription:@"waited"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [waited fulfill]; });
    [self waitForExpectations:@[waited] timeout:seconds + 5.0];
    return sTicks;
}

// XCTWaiter rather than -waitForExpectations:, because a miss is an answer
// here — the slow-rate cases assert the target is *not* reached.
- (BOOL)reachedTicks:(NSUInteger)count within:(NSTimeInterval)seconds {
    sTicks = 0;
    sTarget = count;
    sReachedTarget = [self expectationWithDescription:@"ticked"];
    XCTWaiterResult result = [XCTWaiter waitForExpectations:@[sReachedTarget] timeout:seconds];
    sTarget = 0;
    sReachedTarget = nil;
    return result == XCTWaiterResultCompleted;
}

- (void)testBothGatesMustBeOpen {
    UIUpdateTimer *timer = [self timerAtHz:50];
    XCTAssertEqual([self ticksOver:0.3], (NSUInteger)0);
    timer.wanted = YES;
    XCTAssertEqual([self ticksOver:0.3], (NSUInteger)0, @"window still hidden");
    timer.wanted = NO;
    timer.windowVisible = YES;
    XCTAssertEqual([self ticksOver:0.3], (NSUInteger)0, @"not wanted");
    timer.wanted = YES;
    XCTAssertTrue([self reachedTicks:3 within:5.0], @"both gates open, so it runs");
    timer.windowVisible = NO;
    XCTAssertEqual([self ticksOver:0.3], (NSUInteger)0, @"occluded stops it entirely");
}

- (void)testRateChangeTakesEffectOnARunningTimer {
    UIUpdateTimer *timer = [self timerAtHz:3];
    timer.wanted = YES;
    timer.windowVisible = YES;
    // 3 Hz cannot produce ten ticks in 1.5 s, so reaching ten proves the faster
    // rate took.
    XCTAssertFalse([self reachedTicks:10 within:1.5]);
    timer.hz = 50;
    XCTAssertEqual(timer.hz, (NSUInteger)50);
    XCTAssertTrue([self reachedTicks:10 within:1.5]);
    timer.hz = 3;
    XCTAssertFalse([self reachedTicks:10 within:1.5], @"back to the slow rate");
}

// The rate moves while paused or occluded too — a fader tick, a resize — and
// dispatch_source_set_timer on a suspended source must neither trap nor be
// forgotten by the resume.
- (void)testRateChangeSurvivesASuspendedSource {
    UIUpdateTimer *timer = [self timerAtHz:3];
    timer.hz = 50;
    timer.wanted = YES;
    timer.windowVisible = YES;
    XCTAssertTrue([self reachedTicks:10 within:1.5]);
}

- (void)testDegenerateRatesAreIgnored {
    UIUpdateTimer *timer = [self timerAtHz:30];
    timer.hz = 0;
    XCTAssertEqual(timer.hz, (NSUInteger)30);
    timer.hz = 30; // the no-op path
    XCTAssertEqual(timer.hz, (NSUInteger)30);
}

@end
