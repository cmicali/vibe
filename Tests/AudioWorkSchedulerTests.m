//
// Fixed-slot audio work admission and pending cancellation.
//

#import <XCTest/XCTest.h>

#import "AudioWorkScheduler.h"

@interface AudioWorkSchedulerTests : XCTestCase
@end

@implementation AudioWorkSchedulerTests

- (AudioWorkScheduler *)schedulerWithPendingCount:(NSUInteger)pendingCount
                                             grace:(NSTimeInterval)grace {
    return [[AudioWorkScheduler alloc]
            initWithLabel:@"com.vibe.tests.audio-work"
            qualityOfService:QOS_CLASS_UTILITY
            maximumRunningCount:1
            maximumPendingCount:pendingCount
            pendingGrace:grace];
}

- (void)testPendingCancellationRemovesWorkBeforeDispatch {
    AudioWorkScheduler *scheduler = [self schedulerWithPendingCount:1 grace:5];
    dispatch_semaphore_t releaseRunning = dispatch_semaphore_create(0);
    XCTestExpectation *runningStarted = [self expectationWithDescription:@"running started"];
    [scheduler submitWork:^{
        [runningStarted fulfill];
        dispatch_semaphore_wait(releaseRunning, DISPATCH_TIME_FOREVER);
    } failureQueue:dispatch_get_main_queue() admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTFail(@"running work was rejected");
    }];
    [self waitForExpectations:@[runningStarted] timeout:1];

    XCTestExpectation *pendingDidNotRun = [self expectationWithDescription:@"pending did not run"];
    pendingDidNotRun.inverted = YES;
    __weak NSObject *weakCapture = nil;
    AudioWorkToken *pending = nil;
    @autoreleasepool {
        NSObject *capture = [[NSObject alloc] init];
        weakCapture = capture;
        pending = [scheduler submitWork:^{
            XCTAssertNotNil(capture);
            [pendingDidNotRun fulfill];
        } failureQueue:dispatch_get_main_queue() admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
            XCTFail(@"cancelled pending work was rejected");
        }];
    }
    XCTAssertNotNil(weakCapture);
    XCTAssertTrue([pending cancelIfPending]);
    XCTAssertNil(weakCapture);
    dispatch_semaphore_signal(releaseRunning);

    [self waitForExpectations:@[pendingDidNotRun] timeout:0.05];
}

- (void)testARejectedStormNeverWaitsBehindTheBlockedWorker {
    AudioWorkScheduler *scheduler = [self schedulerWithPendingCount:1 grace:5];
    dispatch_semaphore_t releaseRunning = dispatch_semaphore_create(0);
    XCTestExpectation *runningStarted = [self expectationWithDescription:@"running started"];
    [scheduler submitWork:^{
        [runningStarted fulfill];
        dispatch_semaphore_wait(releaseRunning, DISPATCH_TIME_FOREVER);
    } failureQueue:dispatch_get_main_queue() admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTFail(@"running work was rejected");
    }];
    [self waitForExpectations:@[runningStarted] timeout:1];

    XCTestExpectation *parkedRan = [self expectationWithDescription:@"parked ran"];
    [scheduler submitWork:^{
        [parkedRan fulfill];
    } failureQueue:dispatch_get_main_queue() admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTFail(@"the one pending slot was rejected");
    }];

    // Delivery is on failureQueue, so count them there rather than inline.
    XCTestExpectation *allRejected = [self expectationWithDescription:@"all rejected"];
    __block NSUInteger rejected = 0;
    for (NSUInteger index = 0; index < 1000; index++) {
        [scheduler submitWork:^{
            XCTFail(@"work beyond the pending bound ran");
        } failureQueue:dispatch_get_main_queue()
          admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
            XCTAssertEqual(failure, VibeAudioWorkAdmissionFailurePendingLimit);
            if (++rejected == 1000) {
                [allRejected fulfill];
            }
        }];
    }
    // The point is that none of the 1,000 is waiting on the blocked worker:
    // they are all decided at submission and their failures drain on the main
    // queue while that worker is still parked on its semaphore.
    [self waitForExpectations:@[allRejected] timeout:2];
    XCTAssertEqual(rejected, 1000u);
    dispatch_semaphore_signal(releaseRunning);
    [self waitForExpectations:@[parkedRan] timeout:1];
}

// Every rejection arrives on failureQueue, whichever branch decided it. The
// pending-limit refusal used to run inline on the submitting thread, so a
// caller submitting from a serial queue could be re-entered by its own failure
// block — and the two branches disagreed about which queue that block owned.
- (void)testEveryRejectionIsDeliveredOnTheFailureQueue {
    AudioWorkScheduler *scheduler = [self schedulerWithPendingCount:1 grace:0.05];
    dispatch_queue_t failureQueue = dispatch_queue_create("com.vibe.tests.failure",
                                                          DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t releaseRunning = dispatch_semaphore_create(0);
    XCTestExpectation *runningStarted = [self expectationWithDescription:@"running started"];
    [scheduler submitWork:^{
        [runningStarted fulfill];
        dispatch_semaphore_wait(releaseRunning, DISPATCH_TIME_FOREVER);
    } failureQueue:failureQueue admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTFail(@"running work was rejected");
    }];
    [self waitForExpectations:@[runningStarted] timeout:1];

    // The parked one expires; the one past the bound is refused immediately.
    // Both must land on failureQueue and neither inline.
    XCTestExpectation *expiredOnQueue = [self expectationWithDescription:@"expiry on failureQueue"];
    [scheduler submitWork:^{
        XCTFail(@"expired work ran");
    } failureQueue:failureQueue admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTAssertEqual(failure, VibeAudioWorkAdmissionFailureWaitExpired);
        dispatch_assert_queue(failureQueue);
        [expiredOnQueue fulfill];
    }];

    __block BOOL rejectedInline = NO;
    XCTestExpectation *refusedOnQueue = [self expectationWithDescription:@"refusal on failureQueue"];
    [scheduler submitWork:^{
        XCTFail(@"work beyond the pending bound ran");
    } failureQueue:failureQueue admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTAssertEqual(failure, VibeAudioWorkAdmissionFailurePendingLimit);
        dispatch_assert_queue(failureQueue);
        [refusedOnQueue fulfill];
    }];
    XCTAssertFalse(rejectedInline, @"the refusal must not run before submitWork: returns");

    [self waitForExpectations:@[refusedOnQueue, expiredOnQueue] timeout:2];
    dispatch_semaphore_signal(releaseRunning);
}

- (void)testPendingGraceExpiresAsAdmissionFailureWithoutRunningTheFileWork {
    AudioWorkScheduler *scheduler = [self schedulerWithPendingCount:1 grace:0.05];
    dispatch_semaphore_t releaseRunning = dispatch_semaphore_create(0);
    XCTestExpectation *runningStarted = [self expectationWithDescription:@"running started"];
    [scheduler submitWork:^{
        [runningStarted fulfill];
        dispatch_semaphore_wait(releaseRunning, DISPATCH_TIME_FOREVER);
    } failureQueue:dispatch_get_main_queue() admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTFail(@"running work was rejected");
    }];
    [self waitForExpectations:@[runningStarted] timeout:1];

    XCTestExpectation *pendingDidNotRun = [self expectationWithDescription:@"expired work did not run"];
    pendingDidNotRun.inverted = YES;
    XCTestExpectation *admissionFailed = [self expectationWithDescription:@"admission failed"];
    [scheduler submitWork:^{
        [pendingDidNotRun fulfill];
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTAssertEqual(failure, VibeAudioWorkAdmissionFailureWaitExpired);
        [admissionFailed fulfill];
    }];
    [self waitForExpectations:@[admissionFailed] timeout:1];
    dispatch_semaphore_signal(releaseRunning);
    [self waitForExpectations:@[pendingDidNotRun] timeout:0.05];
}

- (void)testRunningCancellationCannotPretendAnOSCallReleasedItsSlot {
    AudioWorkScheduler *scheduler = [self schedulerWithPendingCount:0 grace:1];
    dispatch_semaphore_t releaseRunning = dispatch_semaphore_create(0);
    XCTestExpectation *runningStarted = [self expectationWithDescription:@"running started"];
    AudioWorkToken *running = [scheduler submitWork:^{
        [runningStarted fulfill];
        dispatch_semaphore_wait(releaseRunning, DISPATCH_TIME_FOREVER);
    } failureQueue:dispatch_get_main_queue() admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTFail(@"running work was rejected");
    }];
    [self waitForExpectations:@[runningStarted] timeout:1];
    XCTAssertFalse([running cancelIfPending]);

    XCTestExpectation *rejected = [self expectationWithDescription:@"rejected"];
    [scheduler submitWork:^{
        XCTFail(@"a second task entered the occupied slot");
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        [rejected fulfill];
    }];
    // The refusal is decided at submission, so it arrives while the slot's
    // owner is still blocked rather than after it releases.
    [self waitForExpectations:@[rejected] timeout:1];
    dispatch_semaphore_signal(releaseRunning);
}

// A scheduler that goes away must take its armed expiry timer with it. The
// source is resumed for the object's whole life, and releasing a resumed
// source without cancelling it leaks the source and its handler.
//
// Note what this does NOT test, because it cannot happen: dealloc with pending
// work. Pending work only exists while every slot is running, a running item's
// dispatch block holds the scheduler strongly, and finishing it promotes the
// pending item — so the last reference can never drop while anything is parked.
// dealloc's drain is insurance for that unreachable state; this is the part
// with a live path to it.
- (void)testDeallocatingWithAnArmedTimerIsClean {
    __weak AudioWorkScheduler *weakScheduler = nil;
    @autoreleasepool {
        AudioWorkScheduler *scheduler = [self schedulerWithPendingCount:2 grace:0.05];
        weakScheduler = scheduler;
        XCTestExpectation *ran = [self expectationWithDescription:@"work ran"];
        [scheduler submitWork:^{
            [ran fulfill];
        } failureQueue:dispatch_get_main_queue() admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
            XCTFail(@"work was rejected");
        }];
        [self waitForExpectations:@[ran] timeout:1];
    }
    // Past the grace, so a surviving timer would have fired into a freed object.
    XCTestExpectation *outlivedItsGrace = [self expectationWithDescription:@"quiet"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        XCTAssertNil(weakScheduler, @"the scheduler must not outlive its last reference");
        [outlivedItsGrace fulfill];
    });
    [self waitForExpectations:@[outlivedItsGrace] timeout:2];
}

@end
