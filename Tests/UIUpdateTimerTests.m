//
// UIUpdateTimer: the two gates, and the settable rate that re-arms the
// dispatch source in place — including on a suspended source, which is the
// case a rate change lands in while playback is paused or the window is
// occluded.
//
// These count real ticks over real time, so every assertion leans on the one
// direction a loaded machine cannot break: it can starve the main queue and
// dispatch will coalesce the missed fires, but nothing can invent ticks the
// timer never asked for. So an upper bound is counted over a fixed window,
// while a lower bound waits for a tick count with a deadline slack enough to
// survive a CI runner an order of magnitude slow — and still tight enough
// that the slower rate could not have reached it.
//

#import <XCTest/XCTest.h>

#import "UIUpdateTimer.h"

@interface UIUpdateTimerTests : XCTestCase
@end

// The tick counter is a file static rather than an ivar: the handler must not
// capture the test case, or it would resurrect one the runner has finished
// with, and a weak capture cannot be dereferenced under ARC. The target and
// its expectation are touched only from the main queue, which is where both
// the handler and the test method run.
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
    // Three per second cannot produce ten ticks in a second and a half,
    // whatever the leeway, so reaching ten inside that deadline is proof the
    // faster rate took — and it asks for a twentieth of 50Hz.
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
