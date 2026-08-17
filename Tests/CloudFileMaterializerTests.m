//
//  CloudFileMaterializerTests.m
//
//  The fake transfer exercises this app's token and cancellation ordering;
//  NSFileCoordinator's provider behavior remains an integration concern.
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

@end
