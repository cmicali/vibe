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
    // All 1,000 are decided at submission: their failures drain while the
    // worker is still parked.
    [self waitForExpectations:@[allRejected] timeout:2];
    XCTAssertEqual(rejected, 1000u);
    dispatch_semaphore_signal(releaseRunning);
    [self waitForExpectations:@[parkedRan] timeout:1];
}

// An inline refusal would re-enter a caller submitting from a serial queue
// with its own failure block.
- (void)testEveryRejectionIsDeliveredOnTheFailureQueue {
    // A grace far above the gap to the over-bound submit: expired first, the
    // parked item would free its slot and that submit would park, not fail.
    AudioWorkScheduler *scheduler = [self schedulerWithPendingCount:1 grace:0.5];
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
    XCTestExpectation *expiredOnQueue = [self expectationWithDescription:@"expiry on failureQueue"];
    [scheduler submitWork:^{
        XCTFail(@"expired work ran");
    } failureQueue:failureQueue admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTAssertEqual(failure, VibeAudioWorkAdmissionFailureWaitExpired);
        dispatch_assert_queue(failureQueue);
        [expiredOnQueue fulfill];
    }];

    // Submitting from the failure queue itself: an async delivery cannot run
    // until the submitting block has returned, an inline one runs inside it.
    __block BOOL submitting = NO;
    __block BOOL rejectedInline = NO;
    XCTestExpectation *refusedOnQueue = [self expectationWithDescription:@"refusal on failureQueue"];
    dispatch_sync(failureQueue, ^{
        submitting = YES;
        [scheduler submitWork:^{
            XCTFail(@"work beyond the pending bound ran");
        } failureQueue:failureQueue admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
            XCTAssertEqual(failure, VibeAudioWorkAdmissionFailurePendingLimit);
            dispatch_assert_queue(failureQueue);
            rejectedInline = submitting;
            [refusedOnQueue fulfill];
        }];
        submitting = NO;
    });

    [self waitForExpectations:@[refusedOnQueue, expiredOnQueue] timeout:2];
    XCTAssertFalse(rejectedInline, @"the refusal must not run before submitWork: returns");
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
    // Decided at submission, so it arrives while the slot's owner is blocked.
    [self waitForExpectations:@[rejected] timeout:1];
    dispatch_semaphore_signal(releaseRunning);
}

// The expiry source stays resumed for the scheduler's whole life, and a
// resumed source released uncancelled leaks. Dealloc with pending work is
// unreachable, and so untested: a running item's block holds the scheduler, and
// finishing it promotes the pending item.
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
