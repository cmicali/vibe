//
//  VibeFakeCloudTests.m
//

#import <XCTest/XCTest.h>

#import "AudioFileMaterializationCoordinator.h"
#import "CloudFileMaterializer.h"
#import "DownloadProgressMonitor.h"
#import "NSURLUtil.h"
#import "VibeFakeCloud.h"

@interface VibeFakeCloudTests : XCTestCase
@end

@implementation VibeFakeCloudTests

- (BOOL)waitUntil:(BOOL (^)(void))predicate timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!predicate() && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.002];
    }
    return predicate();
}

- (XCTestExpectation *)startMaterialization:(CloudFileMaterializer *)materializer
                                     forURL:(NSURL *)url
                                       name:(NSString *)name
                                 completion:(void (^)(BOOL ready, NSError *error))completion {
    CloudFileMaterializationToken *token = [materializer prepareMaterialization];
    XCTestExpectation *finished = [self expectationWithDescription:name];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSError *error = nil;
        BOOL ready = [materializer materializeURL:url token:token error:&error];
        completion(ready, error);
        [finished fulfill];
    });
    return finished;
}

- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) {
        block();
    }
    else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

- (float)firstProgressForMode:(VibeFakeCloudProgressMode)mode
                    afterDelay:(NSTimeInterval)delay {
    [VibeFakeCloud installWithTransferSeconds:4.0 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];
    [VibeFakeCloud setProgressMode:mode];

    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithFormat:
            @"/fake/progress-%ld.wav", (long)mode]];
    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    materializer.label = @"playback";
    XCTestExpectation *transferFinished = [self startMaterialization:materializer
            forURL:url name:@"progress transfer finished"
            completion:^(BOOL ready, NSError *error) {}];
    XCTAssertTrue([self waitUntil:^BOOL{
        for (NSDictionary *event in [VibeFakeCloud traceEvents]) {
            if ([event[@"event"] isEqual:@"started"]) return YES;
        }
        return NO;
    } timeout:3]);
    if (delay > 0) {
        [NSThread sleepForTimeInterval:delay];
    }

    XCTestExpectation *reported = [self expectationWithDescription:@"progress reported"];
    __block float first = NAN;
    __block DownloadProgressMonitor *monitor = nil;
    [self onMain:^{
        monitor = [DownloadProgressMonitor monitorReplacing:nil forURL:url
                currentURL:^NSURL *{ return url; }
                movement:nil
                handler:^(float fraction) {
            if (isnan(first)) {
                first = fraction;
                [reported fulfill];
            }
        }];
    }];
    [self waitForExpectations:@[reported] timeout:3];
    [self onMain:^{ [monitor cancel]; }];
    [materializer cancel];
    [self waitForExpectations:@[transferFinished] timeout:3];
    return first;
}

- (void)tearDown {
    [VibeFakeCloud uninstall];
    [super tearDown];
}

- (void)testInstallAndEveryScenarioOptionAreObservableInStatistics {
    [VibeFakeCloud installWithTransferSeconds:2.5 datalessPercent:73];
    XCTAssertTrue([VibeFakeCloud isInstalled]);
    [VibeFakeCloud setTransferCapacity:0];
    [VibeFakeCloud setUniformDurations:YES];
    [VibeFakeCloud setProgressMode:VibeFakeCloudProgressStall];
    [VibeFakeCloud setUnflaggedPlaceholders:YES];
    [VibeFakeCloud setStickyDataless:YES];
    [VibeFakeCloud setFailingBasename:@"bad.wav"];

    NSDictionary *stats = [VibeFakeCloud statistics];
    XCTAssertEqualObjects(stats[@"installed"], @YES);
    XCTAssertEqualObjects(stats[@"baseSeconds"], @2.5);
    XCTAssertEqualObjects(stats[@"percent"], @73);
    XCTAssertEqualObjects(stats[@"capacity"], @0);
    XCTAssertEqualObjects(stats[@"uniform"], @YES);
    XCTAssertEqualObjects(stats[@"progressMode"], @"stall");
    XCTAssertEqualObjects(stats[@"unflagged"], @YES);
    XCTAssertEqualObjects(stats[@"sticky"], @YES);
    XCTAssertEqualObjects(stats[@"failingBasename"], @"bad.wav");

    [VibeFakeCloud uninstall];
    XCTAssertFalse([VibeFakeCloud isInstalled]);
}

- (void)testOneMaterializationProducesOrderedRoleBearingTraceAndBalancedStats {
    NSUInteger completedBefore =
            [(NSNumber *)[VibeFakeCloud statistics][@"completed"] unsignedIntegerValue];
    [VibeFakeCloud installWithTransferSeconds:0.001 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    materializer.label = @"metadata-scan";
    NSURL *url = [NSURL fileURLWithPath:@"/fake/trace.wav"];
    NSError *error = nil;
    XCTAssertTrue([materializer materializeURL:url
                                         token:[materializer prepareMaterialization]
                                         error:&error]);
    XCTAssertNil(error);

    NSArray<NSDictionary *> *events = [VibeFakeCloud traceEvents];
    XCTAssertEqual(events.count, 3u);
    XCTAssertEqualObjects([events valueForKey:@"event"],
                          (@[@"requested", @"started", @"completed"]));
    XCTAssertEqualObjects([events valueForKey:@"role"],
                          (@[@"metadata-scan", @"metadata-scan", @"metadata-scan"]));
    XCTAssertEqualObjects([events valueForKey:@"file"],
                          (@[@"trace.wav", @"trace.wav", @"trace.wav"]));
    XCTAssertEqualObjects([events valueForKey:@"seq"], (@[@0, @1, @2]));

    NSDictionary *stats = [VibeFakeCloud statistics];
    XCTAssertEqual([(NSNumber *)stats[@"completed"] unsignedIntegerValue], completedBefore + 1);
    XCTAssertEqualObjects(stats[@"materialized"], @1);
    XCTAssertEqualObjects(stats[@"executing"], @0);
    XCTAssertEqualObjects(stats[@"queued"], @0);
    XCTAssertEqualObjects(stats[@"maxConcurrency"], @1);
}

- (void)testProductionCoordinatorMapsEveryRoleToTheExactProviderLabel {
    [VibeFakeCloud installWithTransferSeconds:0.001 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];
    AudioFileMaterializationCoordinator *coordinator =
            [[AudioFileMaterializationCoordinator alloc] init];
    NSArray<NSNumber *> *roles = @[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRolePrefetch),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ];
    NSArray<NSString *> *labels = @[
        @"playback", @"prefetch", @"metadata-priority", @"metadata-scan"
    ];
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.fake-cloud-role-map", DISPATCH_QUEUE_SERIAL);

    for (NSUInteger index = 0; index < roles.count; index++) {
        XCTestExpectation *ready = [self expectationWithDescription:labels[index]];
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithFormat:
                @"/fake/role-%lu.wav", (unsigned long)index]];
        __unused AudioFileMaterializationRequestToken *token = [coordinator
                materializeURL:url
                          role:(VibeAudioFileMaterializationRole)roles[index].unsignedIntegerValue
               completionQueue:completionQueue
                    completion:^(VibeAudioFileMaterializationResult result,
                                 NSError *error, NSTimeInterval elapsed) {
            XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
            XCTAssertNil(error);
            [ready fulfill];
        }];
        [self waitForExpectations:@[ready] timeout:1];
    }

    NSArray<NSDictionary *> *requests = [[VibeFakeCloud traceEvents]
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                    ^BOOL(NSDictionary *event, NSDictionary *bindings) {
        return [event[@"event"] isEqual:@"requested"];
    }]];
    XCTAssertEqualObjects([requests valueForKey:@"role"], labels);
}

- (void)testTraceRingRetainsTheNewestEventsAndSequenceNeverResetsInsideARun {
    [VibeFakeCloud installWithTransferSeconds:0.0001 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];
    for (NSUInteger index = 0; index < 180; index++) {
        CloudFileMaterializer *materializer = [CloudFileMaterializer new];
        materializer.label = @"metadata-scan";
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithFormat:
                @"/fake/ring-%lu.wav", (unsigned long)index]];
        NSError *error = nil;
        XCTAssertTrue([materializer materializeURL:url
                                             token:[materializer prepareMaterialization]
                                             error:&error]);
        XCTAssertNil(error);
    }

    NSArray<NSDictionary *> *events = [VibeFakeCloud traceEvents];
    XCTAssertEqual(events.count, 512u);
    XCTAssertEqualObjects(events.firstObject[@"seq"], @28);
    XCTAssertEqualObjects(events.lastObject[@"seq"], @539);
    XCTAssertEqualObjects([VibeFakeCloud statistics][@"traceCount"], @512);

    [VibeFakeCloud clearTrace];
    XCTAssertEqual([VibeFakeCloud traceEvents].count, 0u);
    XCTAssertEqualObjects([VibeFakeCloud statistics][@"traceCount"], @0);

    CloudFileMaterializer *afterClear = [CloudFileMaterializer new];
    afterClear.label = @"metadata-scan";
    NSError *error = nil;
    XCTAssertTrue([afterClear materializeURL:
            [NSURL fileURLWithPath:@"/fake/after-clear.wav"]
                                          token:[afterClear prepareMaterialization]
                                          error:&error]);
    XCTAssertNil(error);
    NSArray<NSDictionary *> *afterClearEvents = [VibeFakeCloud traceEvents];
    XCTAssertEqualObjects([afterClearEvents valueForKey:@"seq"], (@[@540, @541, @542]));
}

- (void)testCapacityOneQueuedCancellationBalancesEveryLiveCounter {
    NSDictionary *before = [VibeFakeCloud statistics];
    NSUInteger completedBefore = [before[@"completed"] unsignedIntegerValue];
    NSUInteger cancelledBefore = [before[@"cancelled"] unsignedIntegerValue];
    [VibeFakeCloud installWithTransferSeconds:30.0 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];
    [VibeFakeCloud setTransferCapacity:1];

    CloudFileMaterializer *first = [CloudFileMaterializer new];
    first.label = @"playback";
    __block BOOL firstReady = NO;
    __block NSError *firstError = nil;
    XCTestExpectation *firstFinished = [self startMaterialization:first
            forURL:[NSURL fileURLWithPath:@"/fake/capacity-first.wav"]
            name:@"first transfer finished"
            completion:^(BOOL ready, NSError *error) {
        firstReady = ready;
        firstError = error;
    }];
    XCTAssertTrue([self waitUntil:^BOOL{
        return [[VibeFakeCloud statistics][@"executing"] unsignedIntegerValue] == 1;
    } timeout:3]);

    CloudFileMaterializer *queued = [CloudFileMaterializer new];
    queued.label = @"metadata-scan";
    NSURL *queuedURL = [NSURL fileURLWithPath:@"/fake/capacity-queued.wav"];
    __block BOOL queuedReady = YES;
    __block NSError *queuedError = nil;
    XCTestExpectation *queuedFinished = [self startMaterialization:queued forURL:queuedURL
            name:@"queued transfer cancelled"
            completion:^(BOOL ready, NSError *error) {
        queuedReady = ready;
        queuedError = error;
    }];
    XCTAssertTrue([self waitUntil:^BOOL{
        return [[VibeFakeCloud statistics][@"queued"] unsignedIntegerValue] == 1;
    } timeout:3]);
    [queued cancel];
    [self waitForExpectations:@[queuedFinished] timeout:3];

    NSDictionary *whileFirstRuns = [VibeFakeCloud statistics];
    XCTAssertEqualObjects(whileFirstRuns[@"executing"], @1);
    XCTAssertEqualObjects(whileFirstRuns[@"queued"], @0);
    [first cancel];
    [self waitForExpectations:@[firstFinished] timeout:3];

    XCTAssertFalse(firstReady);
    XCTAssertEqualObjects(firstError.domain, NSCocoaErrorDomain);
    XCTAssertEqual(firstError.code, NSUserCancelledError);
    XCTAssertFalse(queuedReady);
    XCTAssertEqualObjects(queuedError.domain, NSCocoaErrorDomain);
    XCTAssertEqual(queuedError.code, NSUserCancelledError);
    NSDictionary *stats = [VibeFakeCloud statistics];
    XCTAssertEqualObjects(stats[@"executing"], @0);
    XCTAssertEqualObjects(stats[@"queued"], @0);
    XCTAssertEqualObjects(stats[@"maxConcurrency"], @1);
    XCTAssertEqual([stats[@"completed"] unsignedIntegerValue], completedBefore);
    XCTAssertEqual([stats[@"cancelled"] unsignedIntegerValue], cancelledBefore + 2);
    NSArray *queuedStarts = [[VibeFakeCloud traceEvents] filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *event, NSDictionary *bindings) {
        return [event[@"file"] isEqual:@"capacity-queued.wav"]
                && [event[@"event"] isEqual:@"started"];
    }]];
    XCTAssertEqual(queuedStarts.count, 0u, @"a cancelled queued transfer never took the slot");
}

- (void)testStickyProbeRedownloadsWhileOrdinaryMaterializationBecomesLocal {
    NSUInteger completedBefore = [[VibeFakeCloud statistics][@"completed"] unsignedIntegerValue];
    [VibeFakeCloud installWithTransferSeconds:0.001 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];
    NSURL *url = [NSURL fileURLWithPath:@"/fake/sticky.wav"];
    XCTAssertTrue([NSURLUtil isDatalessFile:url]);

    CloudFileMaterializer *first = [CloudFileMaterializer new];
    NSError *error = nil;
    XCTAssertTrue([first materializeURL:url token:[first prepareMaterialization] error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse([NSURLUtil isDatalessFile:url]);
    NSUInteger traceAfterFirst = [VibeFakeCloud traceEvents].count;

    CloudFileMaterializer *localReplay = [CloudFileMaterializer new];
    XCTAssertTrue([localReplay materializeURL:url
                                       token:[localReplay prepareMaterialization] error:&error]);
    XCTAssertEqual([VibeFakeCloud traceEvents].count, traceAfterFirst,
                   @"an ordinary completed path is not downloaded again");

    [VibeFakeCloud setStickyDataless:YES];
    XCTAssertTrue([NSURLUtil isDatalessFile:url]);
    CloudFileMaterializer *stickyReplay = [CloudFileMaterializer new];
    XCTAssertTrue([stickyReplay materializeURL:url
                                        token:[stickyReplay prepareMaterialization] error:&error]);
    XCTAssertTrue([NSURLUtil isDatalessFile:url]);
    XCTAssertEqual([VibeFakeCloud traceEvents].count, traceAfterFirst + 3);
    XCTAssertEqual([[VibeFakeCloud statistics][@"completed"] unsignedIntegerValue],
                   completedBefore + 2);
}

- (void)testUnflaggedProbeSaysLocalWhileTheProviderStillTransfers {
    [VibeFakeCloud installWithTransferSeconds:0.001 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];
    [VibeFakeCloud setUnflaggedPlaceholders:YES];
    NSURL *url = [NSURL fileURLWithPath:@"/fake/unflagged.wav"];
    XCTAssertFalse([NSURLUtil isDatalessFile:url]);

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    NSError *error = nil;
    XCTAssertTrue([materializer materializeURL:url
                                         token:[materializer prepareMaterialization] error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse([NSURLUtil isDatalessFile:url]);
    XCTAssertEqualObjects([[VibeFakeCloud traceEvents] valueForKey:@"event"],
                          (@[@"requested", @"started", @"completed"]));
    XCTAssertEqualObjects([VibeFakeCloud statistics][@"materialized"], @1);
}

- (void)testProviderFailureIsCancelledInTheTraceAndNeverMaterialized {
    NSUInteger cancelledBefore = [[VibeFakeCloud statistics][@"cancelled"] unsignedIntegerValue];
    [VibeFakeCloud installWithTransferSeconds:0.001 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];
    [VibeFakeCloud setFailingBasename:@"provider-failure.wav"];

    CloudFileMaterializer *materializer = [CloudFileMaterializer new];
    materializer.label = @"metadata-scan";
    NSError *error = nil;
    XCTAssertFalse([materializer materializeURL:
            [NSURL fileURLWithPath:@"/fake/provider-failure.wav"]
                                         token:[materializer prepareMaterialization]
                                         error:&error]);
    XCTAssertEqualObjects(error.domain, @"com.vibe.fake-cloud");
    XCTAssertEqual(error.code, 1);
    XCTAssertEqualObjects([[VibeFakeCloud traceEvents] valueForKey:@"event"],
                          (@[@"requested", @"started", @"cancelled"]));
    NSDictionary *stats = [VibeFakeCloud statistics];
    XCTAssertEqualObjects(stats[@"materialized"], @0);
    XCTAssertEqual([stats[@"cancelled"] unsignedIntegerValue], cancelledBefore + 1);
    XCTAssertEqualObjects(stats[@"executing"], @0);
    XCTAssertEqualObjects(stats[@"queued"], @0);
}

- (void)testEveryScriptedProgressModeDrivesTheInstalledProgressSource {
    float none = [self firstProgressForMode:VibeFakeCloudProgressNone afterDelay:0];
    XCTAssertEqualWithAccuracy(none, 0, 0.0001);
    float linear = [self firstProgressForMode:VibeFakeCloudProgressLinear afterDelay:0];
    XCTAssertGreaterThan(linear, 0);
    XCTAssertLessThan(linear, 1);
    float sparse = [self firstProgressForMode:VibeFakeCloudProgressSparse afterDelay:0];
    XCTAssertEqualWithAccuracy(sparse, 0, 0.0001,
            @"sparse progress has no step before its ten-second cadence");
    float stall = [self firstProgressForMode:VibeFakeCloudProgressStall afterDelay:1.75];
    XCTAssertEqualWithAccuracy(stall, 0.4, 0.03);
}

- (void)testMetadataSamePathOverlapIsNamedAndCounted {
    [VibeFakeCloud installWithTransferSeconds:30.0 datalessPercent:100];
    [VibeFakeCloud setUniformDurations:YES];
    [VibeFakeCloud setTransferCapacity:0];
    NSURL *url = [NSURL fileURLWithPath:@"/fake/overlap.wav"];

    CloudFileMaterializer *playback = [CloudFileMaterializer new];
    playback.label = @"playback";
    __block BOOL playbackReady = YES;
    __block NSError *playbackError = nil;
    XCTestExpectation *playbackFinished = [self startMaterialization:playback forURL:url
            name:@"overlap playback finished" completion:^(BOOL ready, NSError *error) {
        playbackReady = ready;
        playbackError = error;
    }];
    XCTAssertTrue([self waitUntil:^BOOL{
        for (NSDictionary *event in [VibeFakeCloud traceEvents]) {
            if ([event[@"event"] isEqual:@"started"]
                    && [event[@"role"] isEqual:@"playback"]) return YES;
        }
        return NO;
    } timeout:3]);

    CloudFileMaterializer *metadata = [CloudFileMaterializer new];
    metadata.label = @"metadata-scan";
    __block BOOL metadataReady = YES;
    __block NSError *metadataError = nil;
    XCTestExpectation *metadataFinished = [self startMaterialization:metadata forURL:url
            name:@"overlap metadata finished" completion:^(BOOL ready, NSError *error) {
        metadataReady = ready;
        metadataError = error;
    }];
    XCTAssertTrue([self waitUntil:^BOOL{
        return [[VibeFakeCloud statistics][@"metadataOverlapTransfers"]
                unsignedIntegerValue] == 1;
    } timeout:3]);

    [playback cancel];
    [metadata cancel];
    [self waitForExpectations:@[playbackFinished, metadataFinished] timeout:3];

    XCTAssertFalse(playbackReady);
    XCTAssertEqualObjects(playbackError.domain, NSCocoaErrorDomain);
    XCTAssertEqual(playbackError.code, NSUserCancelledError);
    XCTAssertFalse(metadataReady);
    XCTAssertEqualObjects(metadataError.domain, NSCocoaErrorDomain);
    XCTAssertEqual(metadataError.code, NSUserCancelledError);

    NSDictionary *stats = [VibeFakeCloud statistics];
    XCTAssertEqualObjects(stats[@"metadataOverlapTransfers"], @1);
    XCTAssertEqualObjects(stats[@"foregroundContentionStarts"], @1);
    NSArray *overlaps = [[VibeFakeCloud traceEvents] filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *event, NSDictionary *bindings) {
        return [event[@"event"] isEqual:@"overlap"];
    }]];
    XCTAssertEqual(overlaps.count, 1u);
    XCTAssertEqualObjects(overlaps.firstObject[@"roles"],
                          (@[@"playback", @"metadata-scan"]));
}

- (void)testCumulativeContentionOracleCountsPlaybackAndPrefetch {
    for (NSString *foregroundRole in @[@"playback", @"prefetch"]) {
        [VibeFakeCloud installWithTransferSeconds:30.0 datalessPercent:100];
        [VibeFakeCloud setUniformDurations:YES];
        [VibeFakeCloud setTransferCapacity:0];

        CloudFileMaterializer *foreground = [CloudFileMaterializer new];
        foreground.label = foregroundRole;
        NSURL *foregroundURL = [NSURL fileURLWithPath:[NSString stringWithFormat:
                @"/fake/%@-foreground.wav", foregroundRole]];
        __block BOOL foregroundReady = YES;
        __block NSError *foregroundError = nil;
        XCTestExpectation *foregroundFinished = [self startMaterialization:foreground
                forURL:foregroundURL
                name:[foregroundRole stringByAppendingString:@" finished"]
                completion:^(BOOL ready, NSError *error) {
            foregroundReady = ready;
            foregroundError = error;
        }];
        XCTAssertTrue([self waitUntil:^BOOL{
            for (NSDictionary *event in [VibeFakeCloud traceEvents]) {
                if ([event[@"event"] isEqual:@"started"]
                        && [event[@"role"] isEqual:foregroundRole]) {
                    return YES;
                }
            }
            return NO;
        } timeout:3], @"%@ transfer never started", foregroundRole);

        CloudFileMaterializer *metadata = [CloudFileMaterializer new];
        metadata.label = @"metadata-scan";
        NSURL *metadataURL = [NSURL fileURLWithPath:[NSString stringWithFormat:
                @"/fake/%@-metadata.wav", foregroundRole]];
        __block BOOL metadataReady = YES;
        __block NSError *metadataError = nil;
        XCTestExpectation *metadataFinished = [self startMaterialization:metadata
                forURL:metadataURL
                name:[foregroundRole stringByAppendingString:@" metadata finished"]
                completion:^(BOOL ready, NSError *error) {
            metadataReady = ready;
            metadataError = error;
        }];
        XCTAssertTrue([self waitUntil:^BOOL{
            return [[VibeFakeCloud statistics][@"foregroundContentionStarts"]
                    unsignedIntegerValue] == 1;
        } timeout:3]);

        NSDictionary *stats = [VibeFakeCloud statistics];
        XCTAssertEqualObjects(stats[@"foregroundContentionStarts"], @1,
                @"%@ did not count as foreground", foregroundRole);
        NSDictionary *contention = [stats[@"contentionEvents"] lastObject];
        XCTAssertEqualObjects(contention[@"foregroundInFlight"], @1);

        [foreground cancel];
        [metadata cancel];
        [self waitForExpectations:@[foregroundFinished, metadataFinished] timeout:3];
        XCTAssertFalse(foregroundReady);
        XCTAssertEqualObjects(foregroundError.domain, NSCocoaErrorDomain);
        XCTAssertEqual(foregroundError.code, NSUserCancelledError);
        XCTAssertFalse(metadataReady);
        XCTAssertEqualObjects(metadataError.domain, NSCocoaErrorDomain);
        XCTAssertEqual(metadataError.code, NSUserCancelledError);
    }
}

@end
