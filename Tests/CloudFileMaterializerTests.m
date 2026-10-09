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

#include <limits.h>
#include <stdlib.h>

@interface CloudFileMaterializerTests : XCTestCase
@end

@implementation CloudFileMaterializerTests {
    NSMutableArray<NSURL *> *_temporaryRoots;
}

- (void)tearDown {
    [CloudFileMaterializer setFakeTransferProvider:nil acquireSlot:nil
                                       releaseSlot:nil didFinish:nil];
    [NSURLUtil setDatalessProbe:nil];
    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    for (NSURL *root in _temporaryRoots) {
        [NSFileManager.defaultManager removeItemAtURL:root error:NULL];
    }
    _temporaryRoots = nil;
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
    XCTAssertFalse([materializer materializeURL:url token:cancelledToken onReadable:nil error:&error]);
    XCTAssertEqualObjects(error.domain, NSCocoaErrorDomain);
    XCTAssertEqual(error.code, NSUserCancelledError);

    CloudFileMaterializationToken *nextToken = [materializer prepareMaterialization];
    error = nil;
    XCTAssertTrue([materializer materializeURL:url token:nextToken onReadable:nil error:&error]);
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
                                    onReadable:nil
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
                                    onReadable:nil
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
    __block BOOL readable = NO;
    XCTAssertTrue([materializer materializeURL:url
                                         token:[materializer prepareMaterialization]
                                    onReadable:^{ readable = YES; }
                                         error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse(readable, @"a provider's file is never readable before it is whole");
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
    XCTAssertFalse([materializer materializeURL:url token:token onReadable:nil error:&error]);
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
        ready = [materializer materializeURL:url token:token onReadable:nil error:&finishError];
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
                                    onReadable:nil
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
    return [self read:availability at:offset length:length into:nil copied:NULL interrupted:interrupted result:result
                error:error];
}

// The same wait, copying what blocks hold into `buffer` when one is given.
- (dispatch_semaphore_t)read:(CloudFileAvailability *)availability at:(uint64_t)offset length:(uint64_t)length
                        into:(NSMutableData *)buffer copied:(uint64_t *)copied
                 interrupted:(BOOL (^)(void))interrupted result:(CloudFileAvailabilityWait *)result
                       error:(NSError *__strong *)error {
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint64_t got = 0;
        NSError *waitError = nil;
        *result = [availability waitForBytesAt:offset length:length windowInto:buffer.mutableBytes capacity:buffer.length
                                        copied:&got interrupted:interrupted deadline:nil error:&waitError];
        if (copied) {
            *copied = got;
        }
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
    XCTAssertEqual([availability waitForBytesAt:100 length:4 windowInto:NULL capacity:0 copied:NULL interrupted:nil deadline:nil error:NULL], CloudFileAvailabilityReady);
    XCTAssertEqual([availability waitForBytesAt:500 length:1 windowInto:NULL capacity:0 copied:NULL interrupted:nil deadline:nil error:NULL], CloudFileAvailabilityReady);
    XCTAssertEqual([availability waitForBytesAt:10 length:0 windowInto:NULL capacity:0 copied:NULL interrupted:nil deadline:nil error:NULL], CloudFileAvailabilityReady);
}

// A range is clipped to the size, so one running past it waits only for the
// last byte; notes only move forward.
- (void)testAvailabilityWaitsForTheRangeClippedToTheSize {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    [availability noteWrittenBytes:60];
    [availability noteWrittenBytes:20];
    XCTAssertEqual([availability waitForBytesAt:0 length:60 windowInto:NULL capacity:0 copied:NULL interrupted:nil deadline:nil error:NULL], CloudFileAvailabilityReady);
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
    XCTAssertEqual([availability waitForBytesAt:50 length:50 windowInto:NULL capacity:0 copied:NULL interrupted:nil deadline:nil error:NULL], CloudFileAvailabilityReady);
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
    XCTAssertEqual([availability waitForBytesAt:0 length:10 windowInto:NULL capacity:0 copied:NULL interrupted:nil deadline:nil error:&error], CloudFileAvailabilityFailed);
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
    XCTAssertEqual([availability waitForBytesAt:0 length:10 windowInto:NULL capacity:0 copied:NULL interrupted:isInterrupted deadline:nil error:NULL], CloudFileAvailabilityReady);
}

#pragma mark - The tail window

static NSData *WindowPattern(NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    for (NSUInteger i = 0; i < length; i++) {
        ((uint8_t *)data.mutableBytes)[i] = (uint8_t)(i * 13 + 5);
    }
    return data;
}

// A probe that never blocks: Interrupted means the range would have waited.
static CloudFileAvailabilityWait Probe(CloudFileAvailability *availability, uint64_t offset, uint64_t length,
                                       uint8_t *_Nullable buffer, uint64_t capacity, uint64_t *copied) {
    return [availability waitForBytesAt:offset length:length windowInto:buffer capacity:capacity copied:copied
                            interrupted:^BOOL { return YES; } deadline:nil error:NULL];
}

// A range wholly inside the window is ready past the download's edge and
// copied out of it, as much as the capacity takes, or, without a buffer,
// ready with nothing copied; straddling the window's start, it waits for the
// disk. A deadline ends a wait as an interrupt does.
- (void)testAvailabilityServesARangeInsideTheWindowFromMemory {
    NSData *file = WindowPattern(100);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    [availability noteWrittenBytes:10];
    [availability installWindow:[file subdataWithRange:NSMakeRange(60, 40)] atOffset:60];
    XCTAssertEqual(availability.windowLength, 40u);

    uint8_t buffer[64] = {0};
    uint64_t copied = 99;
    XCTAssertEqual(Probe(availability, 70, 10, buffer, 64, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 30u, @"to the window's end, within the capacity");
    XCTAssertEqual(memcmp(buffer, (const uint8_t *)file.bytes + 70, 30), 0);
    XCTAssertEqual(Probe(availability, 60, 4, buffer, 2, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 2u, @"never past the capacity");
    XCTAssertEqual(Probe(availability, 95, 50, buffer, 64, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 5u, @"clipped to the size");
    XCTAssertEqual(memcmp(buffer, (const uint8_t *)file.bytes + 95, 5), 0);

    XCTAssertEqual(Probe(availability, 70, 10, NULL, 0, &copied), CloudFileAvailabilityReady,
                   @"held, for readyBytesAt: to hand over");
    XCTAssertEqual(copied, 0u);
    XCTAssertEqual([availability waitForBytesAt:55 length:10 windowInto:NULL capacity:0 copied:NULL interrupted:nil
                                       deadline:[NSDate dateWithTimeIntervalSinceNow:0.05] error:NULL],
                   CloudFileAvailabilityInterrupted, @"the deadline ends the wait");
    XCTAssertEqual(Probe(availability, 55, 10, buffer, 64, &copied), CloudFileAvailabilityInterrupted,
                   @"a range straddling the window's start waits for the disk");
    XCTAssertEqual(Probe(availability, 0, 10, buffer, 64, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 0u, @"bytes on disk are read from the disk");
}

// The download reaching the window's start drops it: the straddling range is
// then on disk, and a range in the window past the edge waits for the disk.
- (void)testAvailabilityDropsTheWindowWhenTheDownloadReachesIt {
    NSData *file = WindowPattern(100);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    [availability installWindow:[file subdataWithRange:NSMakeRange(60, 40)] atOffset:60];
    [availability noteWrittenBytes:59];
    XCTAssertEqual(availability.windowLength, 40u);
    [availability noteWrittenBytes:65];
    XCTAssertEqual(availability.windowLength, 0u);
    uint8_t buffer[64];
    uint64_t copied = 99;
    XCTAssertEqual(Probe(availability, 55, 10, buffer, 64, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 0u);
    XCTAssertEqual(Probe(availability, 70, 10, buffer, 64, &copied), CloudFileAvailabilityInterrupted);

    [availability installWindow:[file subdataWithRange:NSMakeRange(60, 40)] atOffset:60];
    XCTAssertEqual(availability.windowLength, 0u, @"a window the download has reached is never installed");
    [availability installWindow:[file subdataWithRange:NSMakeRange(80, 20)] atOffset:80];
    XCTAssertEqual(availability.windowLength, 20u);
    [availability installWindow:[file subdataWithRange:NSMakeRange(90, 10)] atOffset:90];
    XCTAssertEqual(availability.windowLength, 20u, @"one window at a time");
    [availability finishWithError:nil];
    XCTAssertEqual(availability.windowLength, 0u, @"the finish drops it");
}

// A window arriving wakes a reader already waiting inside it; one past the
// size, or after a failure, is refused, and a failure still fails every wait.
- (void)testAvailabilityWindowWakesAWaitingReaderAndNeverOutlivesAFailure {
    NSData *file = WindowPattern(100);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    __block CloudFileAvailabilityWait result = CloudFileAvailabilityFailed;
    __block uint64_t copied = 0;
    uint8_t *buffer = calloc(64, 1);
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint64_t got = 0;
        result = [availability waitForBytesAt:96 length:4 windowInto:buffer capacity:64 copied:&got interrupted:nil deadline:nil error:NULL];
        copied = got;
        dispatch_semaphore_signal(returned);
    });
    [self assertStillWaiting:returned];
    [availability installWindow:WindowPattern(51) atOffset:50];
    XCTAssertEqual(availability.windowLength, 0u, @"past the size");
    [availability installWindow:[file subdataWithRange:NSMakeRange(50, 50)] atOffset:50];
    [self awaitReturn:returned];
    XCTAssertEqual(result, CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 4u);
    XCTAssertEqual(memcmp(buffer, (const uint8_t *)file.bytes + 96, 4), 0);
    free(buffer);

    NSError *failure = [NSError errorWithDomain:@"com.vibe.test-transfer" code:4 userInfo:nil];
    [availability finishWithError:failure];
    XCTAssertEqual(availability.windowLength, 0u);
    NSError *error = nil;
    uint8_t probe[8];
    XCTAssertEqual([availability waitForBytesAt:96 length:4 windowInto:probe capacity:8 copied:NULL
                                    interrupted:nil deadline:nil error:&error], CloudFileAvailabilityFailed);
    XCTAssertEqualObjects(error, failure);
    [availability installWindow:[file subdataWithRange:NSMakeRange(50, 50)] atOffset:50];
    XCTAssertEqual(availability.windowLength, 0u, @"nothing is installed once finished");
}

// What a stream holds now, never waiting: the window's bytes from memory, the
// part file's only below the bytes noted, so a write not yet noted (the
// writer writes, then notes) is never read; nothing once finished.
- (void)testAvailabilityHandsOverWhatItHoldsWithoutWaiting {
    NSData *file = WindowPattern(1000);
    NSURL *part = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"CloudFileMaterializerTests-%@.part", NSUUID.UUID.UUIDString]]];
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtURL:part error:NULL];
    }];
    // 600 bytes on disk, 400 of them noted: the rest is a write in progress.
    XCTAssertTrue([[file subdataWithRange:NSMakeRange(0, 600)] writeToURL:part atomically:NO]);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:part size:1000];
    XCTAssertNil([availability readyBytesAt:0 length:10], @"nothing noted yet");
    [availability noteWrittenBytes:400];
    [availability installWindow:[file subdataWithRange:NSMakeRange(900, 100)] atOffset:900];

    XCTAssertEqualObjects([availability readyBytesAt:100 length:200], [file subdataWithRange:NSMakeRange(100, 200)]);
    XCTAssertEqualObjects([availability readyBytesAt:300 length:200], [file subdataWithRange:NSMakeRange(300, 100)],
                          @"the noted prefix only, never the half-written block past it");
    XCTAssertNil([availability readyBytesAt:450 length:10], @"written but not noted");
    XCTAssertNil([availability readyBytesAt:850 length:100], @"neither noted nor inside the window");
    XCTAssertEqualObjects([availability readyBytesAt:950 length:100], [file subdataWithRange:NSMakeRange(950, 50)],
                          @"from the window, clipped to the size");
    XCTAssertNil([availability readyBytesAt:1000 length:10]);

    [availability finishWithError:nil];
    XCTAssertNil([availability readyBytesAt:0 length:10], @"finished: the part is the file by now");
}

// The last reader leaving calls back each time, and nothing else does.
- (void)testAvailabilityCallsBackWhenItsLastReaderGoes {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    __block NSUInteger gone = 0;
    availability.onLastReaderGone = ^{
        gone++;
    };
    [availability removeReader];
    [availability addReader];
    [availability addReader];
    [availability removeReader];
    XCTAssertEqual(availability.readerCount, 1u);
    XCTAssertEqual(gone, 0u);
    [availability removeReader];
    XCTAssertEqual(gone, 1u);
    [availability addReader];
    [availability removeReader];
    XCTAssertEqual(gone, 2u);
    XCTAssertEqual(availability.readerCount, 0u);
}

// The remote fetch is handed the caller's readable callback as it is, and
// nil when there is none.
- (void)testTheRemoteFetchIsHandedTheReadableCallback {
    char resolved[PATH_MAX];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *root = [NSURL fileURLWithPath:@(realpath(base.fileSystemRepresentation, resolved)) isDirectory:YES];
    NSURL *url = [root URLByAppendingPathComponent:@"track.flac"];
    XCTAssertTrue([NSFileManager.defaultManager createFileAtPath:url.path contents:[NSData dataWithBytes:"x" length:1]
                                                      attributes:@{NSFilePosixPermissions: @0}]);
    __block NSUInteger fetches = 0;
    __block dispatch_block_t handed = nil;
    [CloudFileMaterializer setRemoteRoot:root fetch:^BOOL(NSURL *candidate, dispatch_block_t onReadable,
                                                          void (^onCancel)(dispatch_block_t), NSError **error) {
        fetches++;
        handed = onReadable;
        if (onReadable) {
            onReadable();
        }
        return YES;
    } read:^NSData *(NSURL *candidate, uint64_t offset, uint64_t length, NSError **error) {
        return nil;
    } availability:nil];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    __block NSUInteger readables = 0;
    dispatch_block_t onReadable = ^{
        readables++;
    };
    XCTAssertTrue([materializer materializeURL:url token:[materializer prepareMaterialization]
                                    onReadable:onReadable error:NULL]);
    XCTAssertEqual(readables, 1u);
    XCTAssertEqual(handed, onReadable);
    XCTAssertTrue([materializer materializeURL:url token:[materializer prepareMaterialization]
                                    onReadable:nil error:NULL]);
    XCTAssertEqual(fetches, 2u);
    XCTAssertNil(handed);

    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    [NSFileManager.defaultManager removeItemAtURL:root error:NULL];
}

// The streaming lookup is asked only while a backend installs one.
- (void)testTheStreamingLookupAnswersOnlyWhileInstalled {
    NSURL *url = [NSURL fileURLWithPath:@"/remote/track.flac"];
    XCTAssertNil([CloudFileMaterializer availabilityForURL:url]);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/remote/.part"] size:1];
    [CloudFileMaterializer setRemoteRoot:[NSURL fileURLWithPath:@"/remote"] fetch:^BOOL(NSURL *candidate, dispatch_block_t onReadable, void (^onCancel)(dispatch_block_t), NSError **error) {
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

#pragma mark - Remote backends per root

// A fresh directory, spelled as realpath answers it, removed in tearDown.
- (NSURL *)makeTemporaryRoot {
    char resolved[PATH_MAX];
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:NULL];
    NSURL *root = [NSURL fileURLWithPath:@(realpath(base.fileSystemRepresentation, resolved)) isDirectory:YES];
    if (!_temporaryRoots) {
        _temporaryRoots = [NSMutableArray array];
    }
    [_temporaryRoots addObject:root];
    return root;
}

// A one-byte file its owner may not read: a remote placeholder under a root.
- (NSURL *)makePlaceholder:(NSString *)relative under:(NSURL *)root {
    NSURL *url = [root URLByAppendingPathComponent:relative];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:NULL];
    XCTAssertTrue([NSFileManager.defaultManager createFileAtPath:url.path contents:[NSData dataWithBytes:"x" length:1]
                                                      attributes:@{NSFilePosixPermissions: @0}]);
    return url;
}

// A backend that logs its name for every call, and reads back its name.
- (void)installBackendNamed:(NSString *)name at:(NSURL *)root
               availability:(CloudFileAvailability *)availability log:(NSMutableArray<NSString *> *)log {
    [CloudFileMaterializer setRemoteRoot:root fetch:^BOOL(NSURL *url, dispatch_block_t onReadable,
                                                          void (^onCancel)(dispatch_block_t), NSError **error) {
        [log addObject:[@"fetch " stringByAppendingString:name]];
        return YES;
    } read:^NSData *(NSURL *url, uint64_t offset, uint64_t length, NSError **error) {
        [log addObject:[@"read " stringByAppendingString:name]];
        return [name dataUsingEncoding:NSUTF8StringEncoding];
    } availability:^CloudFileAvailability *(NSURL *url) {
        [log addObject:[@"availability " stringByAppendingString:name]];
        return availability;
    }];
}

- (BOOL)materialize:(NSURL *)url {
    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    return [materializer materializeURL:url token:[materializer prepareMaterialization] onReadable:nil error:NULL];
}

- (NSString *)remoteReadOf:(NSURL *)url {
    NSData *bytes = CloudFileMaterializer.remoteRead(url, 0, 1, NULL);
    return bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
}

// Two roots each reach their own blocks, and a root inside another wins over it.
- (void)testEachRootReachesItsOwnBackendAndTheLongestRootWins {
    NSURL *outer = [self makeTemporaryRoot];
    NSURL *inner = [outer URLByAppendingPathComponent:@"inner" isDirectory:YES];
    NSURL *other = [self makeTemporaryRoot];
    NSURL *outerFile = [self makePlaceholder:@"a.flac" under:outer];
    NSURL *innerFile = [self makePlaceholder:@"b.flac" under:inner];
    NSURL *otherFile = [self makePlaceholder:@"c.flac" under:other];
    CloudFileAvailability *outerStream = [[CloudFileAvailability alloc] initWithoutPartFile];
    CloudFileAvailability *innerStream = [[CloudFileAvailability alloc] initWithoutPartFile];
    NSMutableArray<NSString *> *log = [NSMutableArray array];
    [self installBackendNamed:@"inner" at:inner availability:innerStream log:log];
    [self installBackendNamed:@"outer" at:outer availability:outerStream log:log];
    [self installBackendNamed:@"other" at:other availability:nil log:log];

    XCTAssertTrue([self materialize:outerFile]);
    XCTAssertTrue([self materialize:innerFile]);
    XCTAssertTrue([self materialize:otherFile]);
    XCTAssertEqualObjects(log, (@[@"fetch outer", @"fetch inner", @"fetch other"]));

    XCTAssertEqualObjects([self remoteReadOf:outerFile], @"outer");
    XCTAssertEqualObjects([self remoteReadOf:innerFile], @"inner");
    XCTAssertEqualObjects([self remoteReadOf:otherFile], @"other");

    XCTAssertEqual([CloudFileMaterializer availabilityForURL:outerFile], outerStream);
    XCTAssertEqual([CloudFileMaterializer availabilityForURL:innerFile], innerStream);
    XCTAssertNil([CloudFileMaterializer availabilityForURL:otherFile]);

    // Installing a root again replaces its backend alone.
    [log removeAllObjects];
    [self installBackendNamed:@"outer again" at:outer availability:nil log:log];
    XCTAssertEqualObjects([self remoteReadOf:outerFile], @"outer again");
    XCTAssertEqualObjects([self remoteReadOf:innerFile], @"inner");
    XCTAssertEqualObjects(log, (@[@"read outer again", @"read inner"]));
}

- (void)testRemovingOneRootKeepsTheOthersAndANilRootRemovesThemAll {
    NSURL *outer = [self makeTemporaryRoot];
    NSURL *inner = [outer URLByAppendingPathComponent:@"inner" isDirectory:YES];
    NSURL *other = [self makeTemporaryRoot];
    NSURL *innerFile = [self makePlaceholder:@"b.flac" under:inner];
    NSURL *otherFile = [self makePlaceholder:@"c.flac" under:other];
    NSMutableArray<NSString *> *log = [NSMutableArray array];
    [self installBackendNamed:@"outer" at:outer availability:nil log:log];
    [self installBackendNamed:@"inner" at:inner availability:nil log:log];
    [self installBackendNamed:@"other" at:other availability:nil log:log];

    [CloudFileMaterializer setRemoteRoot:inner fetch:nil read:nil availability:nil];
    XCTAssertEqualObjects([self remoteReadOf:innerFile], @"outer");
    XCTAssertEqualObjects([self remoteReadOf:otherFile], @"other");
    XCTAssertTrue([NSURLUtil isRemotePlaceholderFile:innerFile]);

    [CloudFileMaterializer setRemoteRoot:other fetch:nil read:nil availability:nil];
    XCTAssertFalse([NSURLUtil isRemotePlaceholderFile:otherFile]);
    XCTAssertTrue([NSURLUtil isRemotePlaceholderFile:innerFile]);

    [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    XCTAssertNil(CloudFileMaterializer.remoteRead);
    XCTAssertNil([CloudFileMaterializer availabilityForURL:innerFile]);
    XCTAssertFalse([NSURLUtil isRemotePlaceholderFile:innerFile]);
    XCTAssertFalse([NSURLUtil isDatalessFile:innerFile]);
    XCTAssertEqualObjects(log, (@[@"read outer", @"read other"]));
}

// The read is nil with no root. Otherwise it is one block that asks the
// backend holding each URL, and fails for a URL under no root.
- (void)testTheRemoteReadDispatchesPerURL {
    XCTAssertNil(CloudFileMaterializer.remoteRead);
    NSURL *first = [self makeTemporaryRoot];
    NSURL *second = [self makeTemporaryRoot];
    NSMutableArray<NSString *> *log = [NSMutableArray array];
    [self installBackendNamed:@"first" at:first availability:nil log:log];
    CloudFileRemoteRead read = CloudFileMaterializer.remoteRead;
    XCTAssertNotNil(read);
    [self installBackendNamed:@"second" at:second availability:nil log:log];

    // A block taken before the second install still reaches it.
    NSData *bytes = read([second URLByAppendingPathComponent:@"x.flac"], 0, 1, NULL);
    XCTAssertEqualObjects(bytes, [@"second" dataUsingEncoding:NSUTF8StringEncoding]);
    XCTAssertEqualObjects([self remoteReadOf:[first URLByAppendingPathComponent:@"x.flac"]], @"first");

    NSError *error = nil;
    XCTAssertNil(read([NSURL fileURLWithPath:@"/nowhere/x.flac"], 0, 1, &error));
    XCTAssertEqualObjects(error.domain, NSPOSIXErrorDomain);
    XCTAssertEqual(error.code, EACCES);
    XCTAssertEqualObjects(log, (@[@"read second", @"read first"]));
}

#pragma mark - Blocks, and a writer with no part file

// The writer's wait for work on a worker, signalling when it returns. Its
// deadline outlasts every guard the test waits on, so only news returns it.
- (dispatch_semaphore_t)waitForWork:(CloudFileAvailability *)availability open:(BOOL *)open
                             wanted:(uint64_t *)wanted length:(uint64_t *)length position:(uint64_t *)position {
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        uint64_t offset = 0, count = 0, at = 0;
        *open = [availability waitForWorkUntil:[NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_GATE_TIMEOUT]
                                        wanted:&offset length:&count readerPosition:&at];
        *wanted = offset;
        *length = count;
        *position = at;
        dispatch_semaphore_signal(returned);
    });
    return returned;
}

// Takes whatever news is pending, so the next writer's wait waits.
static void TakeNews(CloudFileAvailability *availability) {
    uint64_t offset, length, position;
    [availability waitForWorkUntil:[NSDate distantPast] wanted:&offset length:&length readerPosition:&position];
}

// Contiguous blocks answer a range across their boundary, as much as the
// capacity takes, clipped to the size; a gap waits until a block fills it.
- (void)testBlocksServeARangeAcrossTheirBoundaryAndAGapWaits {
    NSData *file = WindowPattern(300);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:300];
    [availability installBlock:[file subdataWithRange:NSMakeRange(0, 100)] atOffset:0];
    [availability installBlock:[file subdataWithRange:NSMakeRange(100, 100)] atOffset:100];
    [availability installBlock:[file subdataWithRange:NSMakeRange(250, 50)] atOffset:250];
    XCTAssertEqual(availability.windowLength, 250u);

    uint8_t buffer[256] = {0};
    uint64_t copied = 0;
    XCTAssertEqual(Probe(availability, 90, 20, buffer, 256, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 110u, @"to the end of the contiguous blocks");
    XCTAssertEqual(memcmp(buffer, (const uint8_t *)file.bytes + 90, 110), 0);
    XCTAssertEqual(Probe(availability, 90, 20, buffer, 15, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 15u, @"never past the capacity");
    XCTAssertEqual(Probe(availability, 260, 100, buffer, 256, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 40u, @"clipped to the size");
    XCTAssertEqual(memcmp(buffer, (const uint8_t *)file.bytes + 260, 40), 0);
    XCTAssertEqualObjects([availability readyBytesAt:50 length:100], [file subdataWithRange:NSMakeRange(50, 100)]);
    XCTAssertNil([availability readyBytesAt:220 length:10]);

    NSMutableData *read = [NSMutableData dataWithLength:64];
    CloudFileAvailabilityWait result = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self read:availability at:190 length:20 into:read copied:&copied
                                   interrupted:nil result:&result error:NULL];
    [self assertStillWaiting:returned];
    [availability installBlock:[file subdataWithRange:NSMakeRange(200, 50)] atOffset:200];
    [self awaitReturn:returned];
    XCTAssertEqual(result, CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 64u);
    XCTAssertEqual(memcmp(read.bytes, (const uint8_t *)file.bytes + 190, 64), 0);
}

// A block the blocks already hold is ignored; one overlapping them replaces
// every block it overlaps. Past the size, nothing is installed.
- (void)testABlockAlreadyHeldIsIgnoredAndAnOverlapReplaces {
    NSData *file = WindowPattern(400);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:400];
    [availability installBlock:[file subdataWithRange:NSMakeRange(0, 100)] atOffset:0];
    [availability installBlock:[file subdataWithRange:NSMakeRange(100, 100)] atOffset:100];
    [availability installBlock:[file subdataWithRange:NSMakeRange(50, 100)] atOffset:50];
    XCTAssertEqual(availability.windowLength, 200u);
    XCTAssertEqual(availability.progressBytes, 200u, @"wholly held: ignored");

    [availability installBlock:[file subdataWithRange:NSMakeRange(150, 100)] atOffset:150];
    XCTAssertEqual(availability.windowLength, 200u);
    XCTAssertEqual(availability.progressBytes, 300u);
    uint8_t buffer[64];
    uint64_t copied = 0;
    XCTAssertEqual(Probe(availability, 100, 10, buffer, 64, &copied), CloudFileAvailabilityInterrupted,
                   @"the block it overlapped is gone");
    XCTAssertEqual(Probe(availability, 160, 50, buffer, 64, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(memcmp(buffer, (const uint8_t *)file.bytes + 160, (size_t)copied), 0);

    [availability installBlock:WindowPattern(100) atOffset:350];
    XCTAssertEqual(availability.windowLength, 200u, @"past the size");
}

// With no part file the size is unknown, so a wait waits; once noted, a range
// at or past it is the end, with nothing copied. Only an error finishes it.
- (void)testWithNoPartFileAWaitBeforeTheSizeBlocksAndTheEndCopiesNothing {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    XCTAssertNil(availability.partURL);
    XCTAssertEqual(availability.size, UINT64_MAX);
    NSMutableData *read = [NSMutableData dataWithLength:16];
    uint64_t copied = 99;
    CloudFileAvailabilityWait result = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self read:availability at:1000 length:10 into:read copied:&copied
                                   interrupted:nil result:&result error:NULL];
    [self assertStillWaiting:returned];
    [availability noteSize:500];
    [self awaitReturn:returned];
    XCTAssertEqual(result, CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 0u);

    [availability noteSize:800];
    XCTAssertEqual(availability.size, 500u, @"noted once");
    uint8_t buffer[16];
    XCTAssertEqual(Probe(availability, 500, 1, buffer, 16, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 0u);
    XCTAssertEqual(Probe(availability, 0, 1, buffer, 16, &copied), CloudFileAvailabilityInterrupted,
                   @"below the size, only blocks answer");
    XCTAssertThrows([availability finishWithError:nil]);
}

// A shortened end makes a wait at or past it the end, wakes one blocked
// there, and clips copies; it never raises the size.
- (void)testAShortenedEndIsTheEndAndNeverRaisesTheSize {
    NSData *file = WindowPattern(100);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:1000];
    [availability installBlock:file atOffset:0];
    NSMutableData *read = [NSMutableData dataWithLength:16];
    uint64_t copied = 99;
    CloudFileAvailabilityWait result = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self read:availability at:500 length:10 into:read copied:&copied
                                   interrupted:nil result:&result error:NULL];
    [self assertStillWaiting:returned];
    [availability noteShortenedEnd:400];
    [self awaitReturn:returned];
    XCTAssertEqual(result, CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 0u);
    XCTAssertEqual(availability.size, 400u);

    [availability noteShortenedEnd:900];
    XCTAssertEqual(availability.size, 400u, @"never raised");
    uint8_t buffer[128];
    XCTAssertEqual(Probe(availability, 400, 10, buffer, 128, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 0u);
    XCTAssertEqual(Probe(availability, 390, 20, buffer, 128, &copied), CloudFileAvailabilityInterrupted);
    [availability noteShortenedEnd:80];
    XCTAssertEqual(Probe(availability, 50, 100, buffer, 128, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 30u, @"a held block is clipped to the end");
}

// Progress counts every block byte once, at install, and the bytes noted, so
// a drop never lowers it.
- (void)testProgressOnlyGrows {
    NSData *file = WindowPattern(1000);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:1000];
    [availability installBlock:[file subdataWithRange:NSMakeRange(0, 100)] atOffset:0];
    [availability installBlock:[file subdataWithRange:NSMakeRange(500, 100)] atOffset:500];
    XCTAssertEqual(availability.progressBytes, 200u);
    [availability dropBlocksOutsideRangeAt:0 length:100];
    XCTAssertEqual(availability.windowLength, 100u);
    XCTAssertEqual(availability.progressBytes, 200u);
    [availability installBlock:[file subdataWithRange:NSMakeRange(500, 100)] atOffset:500];
    XCTAssertEqual(availability.progressBytes, 300u);

    CloudFileAvailability *transfer = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    [transfer noteWrittenBytes:10];
    [transfer installWindow:[file subdataWithRange:NSMakeRange(60, 40)] atOffset:60];
    XCTAssertEqual(transfer.progressBytes, 50u);
    [transfer noteWrittenBytes:65];
    XCTAssertEqual(transfer.windowLength, 0u);
    XCTAssertEqual(transfer.progressBytes, 105u);
}

// What is held from an offset ends where the contiguous bytes do, the disk's
// below the bytes written and then the blocks'; asking records no reader
// position and raises no news for the writer.
- (void)testHeldEndIsTheContiguousBytesAndRecordsNothing {
    NSData *file = WindowPattern(1000);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:1000];
    [availability installBlock:[file subdataWithRange:NSMakeRange(0, 100)] atOffset:0];
    [availability installBlock:[file subdataWithRange:NSMakeRange(100, 100)] atOffset:100];
    [availability installBlock:[file subdataWithRange:NSMakeRange(500, 100)] atOffset:500];
    TakeNews(availability);
    uint8_t buffer[8];
    uint64_t copied = 0;
    XCTAssertEqual(Probe(availability, 550, 1, buffer, 8, &copied), CloudFileAvailabilityReady);
    TakeNews(availability);
    XCTAssertEqual([availability heldEndAt:0], 200u, @"across the boundary");
    XCTAssertEqual([availability heldEndAt:150], 200u);
    XCTAssertEqual([availability heldEndAt:200], 200u, @"a gap: the offset itself");
    XCTAssertEqual([availability heldEndAt:300], 300u);
    XCTAssertEqual([availability heldEndAt:520], 600u);
    uint64_t offset = 0, length = 0, position = 0;
    NSDate *soon = [NSDate dateWithTimeIntervalSinceNow:0.05];
    XCTAssertTrue([availability waitForWorkUntil:soon wanted:&offset length:&length readerPosition:&position]);
    XCTAssertEqual(position, 550u, @"the last wait's offset, not the queries'");

    CloudFileAvailability *transfer = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:1000];
    [transfer noteWrittenBytes:300];
    [transfer installWindow:[file subdataWithRange:NSMakeRange(600, 400)] atOffset:600];
    XCTAssertEqual([transfer heldEndAt:10], 300u, @"the disk below the bytes written");
    XCTAssertEqual([transfer heldEndAt:300], 300u);
    XCTAssertEqual([transfer heldEndAt:700], 1000u, @"the tail window");
    [transfer noteWrittenBytes:600];
    XCTAssertEqual([transfer heldEndAt:10], 600u, @"the window is dropped once the disk reaches it");
}

// Noting the reader's position wakes the writer's wait for work, which then
// reports it. A transfer ignores it.
- (void)testNotingTheReaderPositionWakesTheWriter {
    NSData *file = WindowPattern(1000);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:1000];
    [availability installBlock:[file subdataWithRange:NSMakeRange(900, 100)] atOffset:900];
    uint8_t buffer[8];
    uint64_t copied = 0;
    XCTAssertEqual(Probe(availability, 950, 1, buffer, 8, &copied), CloudFileAvailabilityReady);
    TakeNews(availability);
    BOOL open = NO;
    uint64_t wanted = 0, length = 0, position = 0;
    dispatch_semaphore_t returned = [self waitForWork:availability open:&open wanted:&wanted length:&length
                                             position:&position];
    [availability noteReaderPosition:0];
    [self awaitReturn:returned];
    XCTAssertTrue(open);
    XCTAssertEqual(position, 0u, @"the head, not the last wait's offset");

    CloudFileAvailability *transfer = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:1000];
    [transfer noteReaderPosition:500];
    uint64_t offset = 0, at = 7;
    [transfer waitForWorkUntil:[NSDate distantPast] wanted:&offset length:&length readerPosition:&at];
    XCTAssertEqual(at, 0u, @"a transfer ignores it");
}

// A drop keeps the block at byte 0, the block ending at the size, and a block
// a blocked wait wants; with no wait blocked, that one goes too.
- (void)testADropKeepsTheFirstTheLastAndTheWantedBlocks {
    NSData *file = WindowPattern(500);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:500];
    for (NSUInteger offset = 0; offset < 500; offset += 100) {
        if (offset != 200) {
            [availability installBlock:[file subdataWithRange:NSMakeRange(offset, 100)] atOffset:offset];
        }
    }
    TakeNews(availability);
    BOOL open = NO;
    uint64_t wanted = 0, length = 0, position = 0;
    dispatch_semaphore_t woken = [self waitForWork:availability open:&open wanted:&wanted length:&length position:&position];
    NSMutableData *read = [NSMutableData dataWithLength:20];
    uint64_t copied = 0;
    CloudFileAvailabilityWait result = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self read:availability at:190 length:20 into:read copied:&copied
                                   interrupted:nil result:&result error:NULL];
    [self awaitReturn:woken];
    XCTAssertEqual(wanted, 190u);
    XCTAssertEqual(length, 20u);

    [availability dropBlocksOutsideRangeAt:300 length:100];
    XCTAssertEqual(availability.windowLength, 400u, @"first, wanted, inside and last are all kept");
    [availability installBlock:[file subdataWithRange:NSMakeRange(200, 100)] atOffset:200];
    [self awaitReturn:returned];
    XCTAssertEqual(result, CloudFileAvailabilityReady);
    XCTAssertEqual(memcmp(read.bytes, (const uint8_t *)file.bytes + 190, 20), 0);

    [availability dropBlocksOutsideRangeAt:300 length:100];
    XCTAssertEqual(availability.windowLength, 300u, @"nothing wanted now");
    uint8_t buffer[16];
    XCTAssertEqual(Probe(availability, 150, 10, buffer, 16, &copied), CloudFileAvailabilityInterrupted);
    XCTAssertEqual(Probe(availability, 0, 10, buffer, 16, &copied), CloudFileAvailabilityReady);
    XCTAssertEqual(Probe(availability, 490, 10, buffer, 16, &copied), CloudFileAvailabilityReady);
}

// A reader blocking wakes the writer's wait for work with the range it
// wants; its read once a block lands clears it.
- (void)testABlockedReaderWakesTheWritersWaitForWork {
    NSData *file = WindowPattern(1000);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:1000];
    BOOL open = NO;
    uint64_t wanted = 0, length = 0, position = 0;
    dispatch_semaphore_t woken = [self waitForWork:availability open:&open wanted:&wanted length:&length position:&position];
    [self assertStillWaiting:woken];
    NSMutableData *read = [NSMutableData dataWithLength:50];
    uint64_t copied = 0;
    CloudFileAvailabilityWait result = CloudFileAvailabilityFailed;
    dispatch_semaphore_t returned = [self read:availability at:200 length:50 into:read copied:&copied
                                   interrupted:nil result:&result error:NULL];
    [self awaitReturn:woken];
    XCTAssertTrue(open);
    XCTAssertEqual(wanted, 200u);
    XCTAssertEqual(length, 50u);
    XCTAssertEqual(position, 200u);

    [availability installBlock:[file subdataWithRange:NSMakeRange(0, 256)] atOffset:0];
    [self awaitReturn:returned];
    XCTAssertEqual(result, CloudFileAvailabilityReady);
    XCTAssertEqual(copied, 50u);
    XCTAssertTrue([availability waitForWorkUntil:[NSDate distantPast] wanted:&wanted length:&length readerPosition:&position]);
    XCTAssertEqual(length, 0u, @"no wait is blocked");
}

// A reader entering another block wakes the writer's wait for work; reads
// within one block do not. A finish wakes it, and it answers NO from then on.
- (void)testACrossedBlockAndAFinishWakeTheWritersWaitForWork {
    NSData *file = WindowPattern(300);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:300];
    [availability installBlock:[file subdataWithRange:NSMakeRange(0, 100)] atOffset:0];
    [availability installBlock:[file subdataWithRange:NSMakeRange(100, 100)] atOffset:100];
    uint8_t buffer[16];
    uint64_t copied = 0;
    XCTAssertEqual(Probe(availability, 10, 10, buffer, 16, &copied), CloudFileAvailabilityReady);
    TakeNews(availability);

    BOOL open = NO;
    uint64_t wanted = 0, length = 99, position = 0;
    dispatch_semaphore_t woken = [self waitForWork:availability open:&open wanted:&wanted length:&length position:&position];
    XCTAssertEqual(Probe(availability, 50, 10, buffer, 16, &copied), CloudFileAvailabilityReady);
    [self assertStillWaiting:woken];
    XCTAssertEqual(Probe(availability, 150, 10, buffer, 16, &copied), CloudFileAvailabilityReady);
    [self awaitReturn:woken];
    XCTAssertTrue(open);
    XCTAssertEqual(position, 150u);
    XCTAssertEqual(length, 0u);

    woken = [self waitForWork:availability open:&open wanted:&wanted length:&length position:&position];
    [self assertStillWaiting:woken];
    [availability finishWithError:[NSError errorWithDomain:@"com.vibe.test-read-ahead" code:1 userInfo:nil]];
    [self awaitReturn:woken];
    XCTAssertFalse(open);
    XCTAssertFalse([availability waitForWorkUntil:[NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT]
                                           wanted:&wanted length:&length readerPosition:&position]);
    XCTAssertEqual(availability.windowLength, 0u);
}

// Setting the pause wakes nobody; clearing it wakes the writer's wait for
// work. The deadline alone returns it otherwise.
- (void)testClearingThePauseWakesTheWritersWaitForWork {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:100];
    BOOL open = NO;
    uint64_t wanted = 0, length = 0, position = 0;
    dispatch_semaphore_t woken = [self waitForWork:availability open:&open wanted:&wanted length:&length position:&position];
    availability.readAheadPaused = YES;
    XCTAssertTrue(availability.readAheadPaused);
    [self assertStillWaiting:woken];
    availability.readAheadPaused = NO;
    [self awaitReturn:woken];
    XCTAssertTrue(open);
    XCTAssertFalse(availability.readAheadPaused);

    woken = [self waitForWork:availability open:&open wanted:&wanted length:&length position:&position];
    availability.readAheadPaused = NO;
    [self assertStillWaiting:woken];
    [availability finishWithError:[NSError errorWithDomain:@"com.vibe.test-read-ahead" code:2 userInfo:nil]];
    [self awaitReturn:woken];

    CloudFileAvailability *idle = [[CloudFileAvailability alloc] initWithoutPartFile];
    XCTAssertTrue([idle waitForWorkUntil:[NSDate dateWithTimeIntervalSinceNow:0.05]
                                  wanted:&wanted length:&length readerPosition:&position]);
}

// Either writer's wait sleeps until woken: a flag set with no wake ends
// nothing.
- (void)testAWaitNeedsAWakeToSeeAnInterrupt {
    CloudFileAvailability *withoutPart = [[CloudFileAvailability alloc] initWithoutPartFile];
    [withoutPart noteSize:100];
    for (CloudFileAvailability *availability in @[
             [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100], withoutPart]) {
        __block _Atomic bool interrupted = false;
        dispatch_semaphore_t asked = dispatch_semaphore_create(0);
        BOOL (^isInterrupted)(void) = ^BOOL{
            dispatch_semaphore_signal(asked);
            return atomic_load(&interrupted);
        };
        CloudFileAvailabilityWait result = CloudFileAvailabilityReady;
        dispatch_semaphore_t returned = [self wait:availability at:10 length:10 interrupted:isInterrupted
                                            result:&result error:NULL];
        [self awaitReturn:asked];
        atomic_store(&interrupted, true);
        XCTAssertNotEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC))), 0,
                          @"%@: no wake, still waiting", availability.partURL ? @"transfer" : @"no part file");
        [availability wakeWaiters];
        [self awaitReturn:returned];
        XCTAssertEqual(result, CloudFileAvailabilityInterrupted);
    }
}

// With no part file the deadline is honored: short or long, the wait ends
// Interrupted, never before it.
- (void)testWithNoPartFileTheDeadlineIsHonored {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithoutPartFile];
    [availability noteSize:100];
    for (NSNumber *seconds in @[@0.05, @0.6]) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds.doubleValue];
        XCTAssertEqual([availability waitForBytesAt:10 length:10 windowInto:NULL capacity:0 copied:NULL
                                        interrupted:^BOOL { return NO; } deadline:deadline error:NULL],
                       CloudFileAvailabilityInterrupted);
        // A lower bound: descheduling only makes the clock later, never earlier.
        XCTAssertGreaterThanOrEqual([NSDate.date timeIntervalSinceDate:deadline], 0.0);
    }
}

@end
