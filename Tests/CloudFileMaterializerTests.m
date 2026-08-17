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
    [CloudFileMaterializer setFakeTransferProvider:nil didFinish:nil];
    [NSURLUtil setDatalessProbe:nil];
    [super tearDown];
}

// The two seams go in together, as VibeFakeCloud installs them: the probe is
// what routes a path to the transfer at all, so a fake transfer with no fake
// placeholder behind it is never reached.
- (void)installFakeCloudCompleting:(NSMutableArray<NSNumber *> *)completions {
    [NSURLUtil setDatalessProbe:^BOOL(NSURL *candidate) {
        return YES;
    }];
    [CloudFileMaterializer setFakeTransferProvider:^NSTimeInterval(NSURL *candidate) {
        return 0.001;
    } didFinish:^(NSURL *candidate, BOOL completed) {
        [completions addObject:@(completed)];
    }];
}

- (void)testCancelBeforeWorkerEntryInvalidatesOnlyThePreparedToken {
    NSURL *url = [NSURL fileURLWithPath:@"/fake/cloud-track.flac"];
    NSMutableArray<NSNumber *> *completions = [NSMutableArray array];
    [self installFakeCloudCompleting:completions];

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

// The placeholder probe decides, not the transfer provider: a file already on
// disk is materialized by definition, whatever a fake would have charged for
// it. Replaying one must cost nothing, or a corpus never settles.
- (void)testAFileAlreadyOnDiskPaysNoTransfer {
    NSURL *url = [NSURL fileURLWithPath:@"/fake/local-track.flac"];
    NSMutableArray<NSNumber *> *completions = [NSMutableArray array];
    [self installFakeCloudCompleting:completions];
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

@end
