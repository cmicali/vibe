//
//  CloudFileMaterializerTests.m
//
//  These tests exercise the real local NSFileCoordinator wrapper and this
//  app's token/cancellation ordering at an injected provider boundary. Actual
//  provider-mediated coordination and cancellation remain integration work.
//


#import <XCTest/XCTest.h>

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

// The two seams go in together, as VibeFakeCloud installs them. The transfer
// provider is asked ahead of the probe and owns the "is this mine" decision:
// it must answer 0 for a path whose transfer is not wanted, which is what
// keeps a replayed file from re-downloading.
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

    // Cancellation is per token, not a latch: the reusable metadata lane can
    // prepare its next call after a hold lifts and complete normally.
    CloudFileMaterializationToken *nextToken = [materializer prepareMaterialization];
    error = nil;
    XCTAssertTrue([materializer materializeURL:url token:nextToken error:&error]);
    XCTAssertNil(error);
    XCTAssertEqualObjects(completions, (@[@NO, @YES]));
}

// The transfer provider owns "is this mine": a path it answers 0 for pays no
// transfer, however the probe answers. VibeFakeCloud answers 0 for local and
// already-materialized paths, which is what lets a replayed corpus settle.
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

// The unflagged-placeholder shape: the probe disowns the file — a provider
// that never sets SF_DATALESS — while its transfer still costs. The fake is
// asked ahead of the probe for exactly this, so the transfer runs anyway.
- (void)testAnUnflaggedPlaceholderStillCostsItsTransfer {
    NSURL *url = [NSURL fileURLWithPath:@"/fake/unflagged-track.flac"];
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

// A transfer cancelled while still queued for the shared provider slot ends
// exactly as one cancelled mid-wait: NO, NSUserCancelledError, and a didFinish
// saying it did not complete.
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
    [self waitForExpectations:@[acquired] timeout:2];
    [materializer cancel];
    [self waitForExpectations:@[returned] timeout:2];

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

@end
