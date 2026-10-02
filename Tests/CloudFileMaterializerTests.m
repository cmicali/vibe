//
//  CloudFileMaterializerTests.m
//
//  The real NSFileCoordinator wrapper and token/cancellation ordering at an
//  injected provider boundary; provider-mediated coordination stays
//  integration work.
//

#import <XCTest/XCTest.h>
#include <stdatomic.h>

#import "CloudFileMaterializer.h"
#import "CloudFileMaterializer+Debug.h"
#import "NSURLUtil+Debug.h"

@interface CloudFileMaterializerTests : XCTestCase
@end

@implementation CloudFileMaterializerTests

- (void)tearDown {
    [CloudFileMaterializer setFakeTransferProvider:nil acquireSlot:nil
                                       releaseSlot:nil didFinish:nil];
    [NSURLUtil setDatalessProbe:nil];
    [super tearDown];
}

// Both seams together, as VibeFakeCloud installs them.
- (void)installFakeCloudCompleting:(NSMutableArray<NSNumber *> *)completions
                    chargingSeconds:(NSTimeInterval (^)(NSURL *url))charge {
    [NSURLUtil setDatalessProbe:^BOOL(NSURL *candidate) {
        return YES;
    }];
    [CloudFileMaterializer setFakeTransferProvider:^NSTimeInterval(NSURL *candidate, NSString *role) {
        return charge(candidate);
    } acquireSlot:nil releaseSlot:nil didFinish:^(NSURL *candidate, NSString *role, BOOL completed) {
        [completions addObject:@(completed)];
    }];
}

- (void)testCancelBeforeWorkerEntryInvalidatesOnlyThePreparedToken {
    NSURL *url = [NSURL fileURLWithPath:@"/fake/cloud-track.flac"];
    NSMutableArray<NSNumber *> *completions = [NSMutableArray array];
    [self installFakeCloudCompleting:completions
                     chargingSeconds:^NSTimeInterval(NSURL *candidate) { return 0.001; }];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    CloudFileMaterializationToken *cancelledToken = [materializer prepareMaterialization];
    [materializer cancel];

    NSError *error = nil;
    XCTAssertFalse([materializer materializeURL:url token:cancelledToken error:&error]);
    XCTAssertEqualObjects(error.domain, NSCocoaErrorDomain);
    XCTAssertEqual(error.code, NSUserCancelledError);

    CloudFileMaterializationToken *nextToken = [materializer prepareMaterialization];
    error = nil;
    XCTAssertTrue([materializer materializeURL:url token:nextToken error:&error]);
    XCTAssertNil(error);
    XCTAssertEqualObjects(completions, (@[@NO, @YES]));
}

- (void)testAPathTheProviderDisownsPaysNoTransfer {
    NSURL *url = [NSURL fileURLWithPath:@"/fake/local-track.flac"];
    NSMutableArray<NSNumber *> *completions = [NSMutableArray array];
    [self installFakeCloudCompleting:completions
                     chargingSeconds:^NSTimeInterval(NSURL *candidate) { return 0; }];
    [NSURLUtil setDatalessProbe:^BOOL(NSURL *candidate) {
        return NO;
    }];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    NSError *error = nil;
    XCTAssertTrue([materializer materializeURL:url
                                         token:[materializer prepareMaterialization]
                                         error:&error]);
    XCTAssertNil(error);
    XCTAssertEqual(completions.count, 0u);
}

// The fake's transfer provider is asked ahead of the dataless probe, so a
// path it charges for transfers even where the probe answers local.
- (void)testTheFakeTransferIsAskedAheadOfTheDatalessProbe {
    NSURL *url = [NSURL fileURLWithPath:@"/fake/track.flac"];
    NSMutableArray<NSNumber *> *completions = [NSMutableArray array];
    [self installFakeCloudCompleting:completions
                     chargingSeconds:^NSTimeInterval(NSURL *candidate) { return 0.001; }];
    [NSURLUtil setDatalessProbe:^BOOL(NSURL *candidate) {
        return NO;
    }];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    NSError *error = nil;
    XCTAssertTrue([materializer materializeURL:url
                                         token:[materializer prepareMaterialization]
                                         error:&error]);
    XCTAssertNil(error);
    XCTAssertEqualObjects(completions, (@[@YES]));
}

- (void)testRealCoordinatedReadMaterializesAForcedDatalessLocalFile {
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
            URLByAppendingPathComponent:[NSUUID UUID].UUIDString];
    XCTAssertTrue([[NSMutableData dataWithLength:4096] writeToURL:url atomically:YES]);
    [NSURLUtil setDatalessProbe:^BOOL(NSURL *candidate) {
        return [candidate isEqual:url];
    }];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    NSError *error = nil;
    XCTAssertTrue([materializer materializeURL:url
                                         token:[materializer prepareMaterialization]
                                         error:&error]);
    XCTAssertNil(error);
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
}

- (void)testCancelWhileQueuedForTheSlotAbandonsTheTransfer {
    NSURL *url = [NSURL fileURLWithPath:@"/fake/queued-track.flac"];
    NSMutableArray<NSNumber *> *completions = [NSMutableArray array];
    [NSURLUtil setDatalessProbe:^BOOL(NSURL *candidate) {
        return YES;
    }];
    [CloudFileMaterializer setFakeTransferProvider:^NSTimeInterval(NSURL *candidate, NSString *role) {
        return 5.0;
    } acquireSlot:^BOOL(NSURL *candidate, NSString *role, BOOL (^cancelled)(void)) {
        // A full slot: admission is decided by cancellation alone.
        while (!cancelled()) {
        }
        return NO;
    } releaseSlot:nil didFinish:^(NSURL *candidate, NSString *role, BOOL completed) {
        [completions addObject:@(completed)];
    }];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    CloudFileMaterializationToken *token = [materializer prepareMaterialization];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [materializer cancel];
    });
    NSError *error = nil;
    XCTAssertFalse([materializer materializeURL:url token:token error:&error]);
    XCTAssertEqualObjects(error.domain, NSCocoaErrorDomain);
    XCTAssertEqual(error.code, NSUserCancelledError);
    XCTAssertEqualObjects(completions, (@[@NO]));
}

- (void)testCancelDuringActiveFakeTransferReleasesAndFinishesExactlyOnce {
    NSURL *url = [NSURL fileURLWithPath:@"/fake/active-track.flac"];
    XCTestExpectation *acquired = [self expectationWithDescription:@"slot acquired"];
    XCTestExpectation *returned = [self expectationWithDescription:@"materialize returned"];
    __block NSUInteger releases = 0;
    __block NSMutableArray<NSNumber *> *completions = [NSMutableArray array];
    [CloudFileMaterializer setFakeTransferProvider:^NSTimeInterval(NSURL *candidate,
                                                                   NSString *role) {
        return 5.0;
    } acquireSlot:^BOOL(NSURL *candidate, NSString *role, BOOL (^cancelled)(void)) {
        [acquired fulfill];
        return YES;
    } releaseSlot:^(NSURL *candidate, NSString *role) {
        releases++;
    } didFinish:^(NSURL *candidate, NSString *role, BOOL completed) {
        [completions addObject:@(completed)];
    }];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    CloudFileMaterializationToken *token = [materializer prepareMaterialization];
    __block BOOL ready = YES;
    __block NSError *finishError = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ready = [materializer materializeURL:url token:token error:&finishError];
        [returned fulfill];
    });
    [self waitForExpectations:@[acquired] timeout:VIBE_TEST_HANG_TIMEOUT];
    [materializer cancel];
    [self waitForExpectations:@[returned] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertFalse(ready);
    XCTAssertEqualObjects(finishError.domain, NSCocoaErrorDomain);
    XCTAssertEqual(finishError.code, NSUserCancelledError);
    XCTAssertEqual(releases, 1u);
    XCTAssertEqualObjects(completions, (@[@NO]));
}

- (void)testFailureSentinelForwardsRoleReleasesSlotAndReportsProviderError {
    NSURL *url = [NSURL fileURLWithPath:@"/fake/failing-track.flac"];
    NSMutableArray<NSString *> *hookRoles = [NSMutableArray array];
    NSMutableArray<NSNumber *> *completions = [NSMutableArray array];
    __block NSUInteger releases = 0;
    [CloudFileMaterializer setFakeTransferProvider:^NSTimeInterval(NSURL *candidate,
                                                                   NSString *role) {
        [hookRoles addObject:[@"request:" stringByAppendingString:role]];
        return -0.001;
    } acquireSlot:^BOOL(NSURL *candidate, NSString *role, BOOL (^cancelled)(void)) {
        [hookRoles addObject:[@"acquire:" stringByAppendingString:role]];
        return YES;
    } releaseSlot:^(NSURL *candidate, NSString *role) {
        releases++;
        [hookRoles addObject:[@"release:" stringByAppendingString:role]];
    } didFinish:^(NSURL *candidate, NSString *role, BOOL completed) {
        [hookRoles addObject:[@"finish:" stringByAppendingString:role]];
        [completions addObject:@(completed)];
    }];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    materializer.label = @"metadata-scan";
    NSError *error = nil;
    XCTAssertFalse([materializer materializeURL:url
                                         token:[materializer prepareMaterialization]
                                         error:&error]);
    XCTAssertEqualObjects(error.domain, @"com.vibe.fake-cloud");
    XCTAssertEqual(releases, 1u);
    XCTAssertEqualObjects(completions, (@[@NO]));
    XCTAssertEqualObjects(hookRoles, (@[@"request:metadata-scan",
                                        @"acquire:metadata-scan",
                                        @"release:metadata-scan",
                                        @"finish:metadata-scan"]));
}

#pragma mark - Availability

// Runs a wait on a worker, signalling the semaphore when it returns.
- (dispatch_semaphore_t)wait:(CloudFileAvailability *)availability at:(uint64_t)offset length:(uint64_t)length
                 interrupted:(BOOL (^)(void))interrupted result:(CloudFileAvailabilityWait *)result
                       error:(NSError *__strong *)error {
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *waitError = nil;
        *result = [availability waitForBytesAt:offset length:length interrupted:interrupted error:&waitError];
        if (error) {
            *error = waitError;
        }
        dispatch_semaphore_signal(returned);
    });
    return returned;
}

- (void)assertStillWaiting:(dispatch_semaphore_t)returned {
    XCTAssertNotEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10)), 0);
}

- (void)awaitReturn:(dispatch_semaphore_t)returned {
    XCTAssertEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
}

// AIFF and some WAVs read at exactly the size: the end, never a wait.
- (void)testAvailabilityAnswersARangeAtOrPastTheSizeAtOnce {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    XCTAssertEqual([availability waitForBytesAt:100 length:4 interrupted:nil error:NULL], CloudFileAvailabilityReady);
    XCTAssertEqual([availability waitForBytesAt:500 length:1 interrupted:nil error:NULL], CloudFileAvailabilityReady);
    XCTAssertEqual([availability waitForBytesAt:10 length:0 interrupted:nil error:NULL], CloudFileAvailabilityReady);
}

// A range is clipped to the size, so one running past it waits only for the
// last byte; notes only move forward.
- (void)testAvailabilityWaitsForTheRangeClippedToTheSize {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    [availability noteWrittenBytes:60];
    [availability noteWrittenBytes:20];
    XCTAssertEqual([availability waitForBytesAt:0 length:60 interrupted:nil error:NULL], CloudFileAvailabilityReady);
    CloudFileAvailabilityWait result = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self wait:availability at:90 length:50 interrupted:nil result:&result error:NULL];
    [availability noteWrittenBytes:99];
    [self assertStillWaiting:returned];
    [availability noteWrittenBytes:100];
    [self awaitReturn:returned];
    XCTAssertEqual(result, CloudFileAvailabilityReady);
}

- (void)testAvailabilityCompleteReadiesEveryRangeAndFinishesOnce {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    CloudFileAvailabilityWait result = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self wait:availability at:0 length:100 interrupted:nil result:&result error:NULL];
    [availability finishWithError:nil];
    [availability finishWithError:[NSError errorWithDomain:@"late" code:1 userInfo:nil]];
    [self awaitReturn:returned];
    XCTAssertEqual(result, CloudFileAvailabilityReady);
    XCTAssertEqual([availability waitForBytesAt:50 length:50 interrupted:nil error:NULL], CloudFileAvailabilityReady);
}

// A failed transfer fails every wait, a blocked one with its error, and
// bytes already written too: nothing read from it can be trusted.
- (void)testAvailabilityFailureFailsEveryWaitWithItsError {
    NSError *failure = [NSError errorWithDomain:@"com.vibe.test-transfer" code:3 userInfo:nil];
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    [availability noteWrittenBytes:50];
    CloudFileAvailabilityWait result = CloudFileAvailabilityReady;
    NSError *error = nil;
    dispatch_semaphore_t returned = [self wait:availability at:60 length:10 interrupted:nil result:&result error:&error];
    [availability finishWithError:failure];
    [self awaitReturn:returned];
    XCTAssertEqual(result, CloudFileAvailabilityFailed);
    XCTAssertEqualObjects(error, failure);
    error = nil;
    XCTAssertEqual([availability waitForBytesAt:0 length:10 interrupted:nil error:&error], CloudFileAvailabilityFailed);
    XCTAssertEqualObjects(error, failure);
}

// An interrupt ends a wait that would block, from another thread, and never
// a range already readable.
- (void)testAvailabilityInterruptEndsOnlyAWaitThatBlocks {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    [availability noteWrittenBytes:10];
    __block _Atomic bool interrupted = false;
    BOOL (^isInterrupted)(void) = ^BOOL{
        return atomic_load(&interrupted);
    };
    CloudFileAvailabilityWait result = CloudFileAvailabilityReady;
    dispatch_semaphore_t returned = [self wait:availability at:20 length:10 interrupted:isInterrupted result:&result error:NULL];
    [self assertStillWaiting:returned];
    atomic_store(&interrupted, true);
    [availability wakeWaiters];
    [self awaitReturn:returned];
    XCTAssertEqual(result, CloudFileAvailabilityInterrupted);
    XCTAssertEqual([availability waitForBytesAt:0 length:10 interrupted:isInterrupted error:NULL], CloudFileAvailabilityReady);
}

// The streaming lookup is asked only while a backend installs one.
- (void)testTheStreamingLookupAnswersOnlyWhileInstalled {
    NSURL *url = [NSURL fileURLWithPath:@"/remote/track.flac"];
    XCTAssertNil([CloudFileMaterializer availabilityForURL:url]);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/remote/.part"] size:1];
    [CloudFileMaterializer setRemoteRoot:[NSURL fileURLWithPath:@"/remote"] fetch:^BOOL(NSURL *candidate, void (^onCancel)(dispatch_block_t), NSError **error) {
        return NO;
    } read:^NSData *(NSURL *candidate, uint64_t offset, uint64_t length, NSError **error) {
        return nil;
    } availability:^CloudFileAvailability *(NSURL *candidate) {
        return [candidate isEqual:url] ? availability : nil;
    }];
    XCTAssertEqual([CloudFileMaterializer availabilityForURL:url], availability);
    XCTAssertNil([CloudFileMaterializer availabilityForURL:[NSURL fileURLWithPath:@"/remote/other.flac"]]);
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    XCTAssertNil([CloudFileMaterializer availabilityForURL:url]);
}

@end
