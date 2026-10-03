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
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *waitError = nil;
        *result = [availability waitForBytesAt:offset length:length windowInto:NULL capacity:0 copied:NULL interrupted:interrupted error:&waitError];
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
    XCTAssertEqual([availability waitForBytesAt:100 length:4 windowInto:NULL capacity:0 copied:NULL interrupted:nil error:NULL], CloudFileAvailabilityReady);
    XCTAssertEqual([availability waitForBytesAt:500 length:1 windowInto:NULL capacity:0 copied:NULL interrupted:nil error:NULL], CloudFileAvailabilityReady);
    XCTAssertEqual([availability waitForBytesAt:10 length:0 windowInto:NULL capacity:0 copied:NULL interrupted:nil error:NULL], CloudFileAvailabilityReady);
}

// A range is clipped to the size, so one running past it waits only for the
// last byte; notes only move forward.
- (void)testAvailabilityWaitsForTheRangeClippedToTheSize {
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:[NSURL fileURLWithPath:@"/p"] size:100];
    [availability noteWrittenBytes:60];
    [availability noteWrittenBytes:20];
    XCTAssertEqual([availability waitForBytesAt:0 length:60 windowInto:NULL capacity:0 copied:NULL interrupted:nil error:NULL], CloudFileAvailabilityReady);
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
    XCTAssertEqual([availability waitForBytesAt:50 length:50 windowInto:NULL capacity:0 copied:NULL interrupted:nil error:NULL], CloudFileAvailabilityReady);
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
    XCTAssertEqual([availability waitForBytesAt:0 length:10 windowInto:NULL capacity:0 copied:NULL interrupted:nil error:&error], CloudFileAvailabilityFailed);
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
    XCTAssertEqual([availability waitForBytesAt:0 length:10 windowInto:NULL capacity:0 copied:NULL interrupted:isInterrupted error:NULL], CloudFileAvailabilityReady);
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
                            interrupted:^BOOL { return YES; } error:NULL];
}

// A range wholly inside the window is ready past the download's edge and
// copied out of it, as much as the capacity takes; without a buffer, or
// straddling the window's start, it waits for the disk.
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

    XCTAssertEqual(Probe(availability, 70, 10, NULL, 0, &copied), CloudFileAvailabilityInterrupted,
                   @"a reader of the disk alone waits");
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
        result = [availability waitForBytesAt:96 length:4 windowInto:buffer capacity:64 copied:&got interrupted:nil error:NULL];
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
                                    interrupted:nil error:&error], CloudFileAvailabilityFailed);
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

@end
