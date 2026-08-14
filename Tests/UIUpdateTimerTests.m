//
// UIUpdateTimer: the two gates, and the settable rate that re-arms the
// dispatch source in place — including on a suspended source, which is the
// case a rate change lands in while playback is paused or the window is
// occluded.
//
// These count real ticks over real time, so the assertions are one-sided and
// slack: a loaded machine can starve the main queue, but it cannot invent
// ticks the timer never asked for.
//

#import <XCTest/XCTest.h>

#import "UIUpdateTimer.h"

@interface UIUpdateTimerTests : XCTestCase
@end

// The tick counter is a file static rather than an ivar: the handler must not
// capture the test case, or it would resurrect one the runner has finished
// with, and a weak capture cannot be dereferenced under ARC.
static NSUInteger sTicks;

@implementation UIUpdateTimerTests {
    UIUpdateTimer *_timer;
}

- (void)tearDown {
    _timer.wanted = NO;
    _timer = nil;
    [super tearDown];
}

// The handler runs on the main queue, and waiting spins the main runloop,
// which drains it.
- (UIUpdateTimer *)timerAtHz:(NSUInteger)hz {
    _timer = [[UIUpdateTimer alloc] initWithHz:hz handler:^{
        sTicks++;
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

- (void)testBothGatesMustBeOpen {
    UIUpdateTimer *timer = [self timerAtHz:50];
    XCTAssertEqual([self ticksOver:0.3], (NSUInteger)0);
    timer.wanted = YES;
    XCTAssertEqual([self ticksOver:0.3], (NSUInteger)0, @"window still hidden");
    timer.wanted = NO;
    timer.windowVisible = YES;
    XCTAssertEqual([self ticksOver:0.3], (NSUInteger)0, @"not wanted");
    timer.wanted = YES;
    XCTAssertGreaterThan([self ticksOver:0.3], (NSUInteger)2);
    timer.windowVisible = NO;
    XCTAssertEqual([self ticksOver:0.3], (NSUInteger)0, @"occluded stops it entirely");
}

- (void)testRateChangeTakesEffectOnARunningTimer {
    UIUpdateTimer *timer = [self timerAtHz:3];
    timer.wanted = YES;
    timer.windowVisible = YES;
    // Three per second cannot produce ten ticks in half a second, whatever
    // the leeway.
    XCTAssertLessThan([self ticksOver:0.5], (NSUInteger)10);
    timer.hz = 50;
    XCTAssertEqual(timer.hz, (NSUInteger)50);
    XCTAssertGreaterThan([self ticksOver:0.5], (NSUInteger)10);
    timer.hz = 3;
    XCTAssertLessThan([self ticksOver:0.5], (NSUInteger)10);
}

// The rate moves while paused or occluded too — a fader tick, a resize — and
// dispatch_source_set_timer on a suspended source must neither trap nor be
// forgotten by the resume.
- (void)testRateChangeSurvivesASuspendedSource {
    UIUpdateTimer *timer = [self timerAtHz:3];
    timer.hz = 50;
    timer.wanted = YES;
    timer.windowVisible = YES;
    XCTAssertGreaterThan([self ticksOver:0.5], (NSUInteger)10);
}

- (void)testDegenerateRatesAreIgnored {
    UIUpdateTimer *timer = [self timerAtHz:30];
    timer.hz = 0;
    XCTAssertEqual(timer.hz, (NSUInteger)30);
    timer.hz = 30; // the no-op path
    XCTAssertEqual(timer.hz, (NSUInteger)30);
}

@end
