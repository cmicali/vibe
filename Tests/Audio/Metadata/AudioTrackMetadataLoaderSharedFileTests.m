//
//  AudioTrackMetadataLoaderSharedFileTests.m
//

#import "AudioTrackMetadataLoaderTestCase.h"

// Rows that share one file: cue rows of an image and duplicate rows.
@interface AudioTrackMetadataLoaderSharedFileTests : AudioTrackMetadataLoaderTestCase
@end

@implementation AudioTrackMetadataLoaderSharedFileTests

#pragma mark - Shared files

- (void)testRowsOfOneFileShareOneStageOneCacheRead {
    NSURL *image = [self URLNamed:@"cue-image.flac"];
    NSMutableArray<VibeLoaderTestTrack *> *rows = VibeLoaderTestCueRows(image, 40);
    // The same file spelled another way, and one unrelated file between.
    VibeLoaderTestTrack *respelled = [self trackNamed:@"./cue-image.flac"];
    XCTAssertNotEqualObjects(respelled.url.path, image.path);
    VibeLoaderTestTrack *neighbor = [self trackNamed:@"cue-neighbor.wav"];
    [rows insertObject:neighbor atIndex:20];
    [rows addObject:respelled];
    NSMutableArray<VibeLoaderTestTrack *> *readTracks = [NSMutableArray array];
    AudioTrackMetadata *cached = VibeLoaderTestMetadataResult(YES, @"cue-image");

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"every row published once"];
    delegate.deliveryExpectation.expectedFulfillmentCount = rows.count;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) {
        @synchronized (readTracks) {
            [readTracks addObject:track];
        }
        return track == neighbor ? VibeLoaderTestMetadataResult(YES, @"neighbor") : cached;
    } fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"a stage-one cache hit must not parse the file");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader load:rows];
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects([NSSet setWithArray:readTracks],
            [NSSet setWithArray:(@[rows.firstObject, neighbor])],
            @"one read for every row of the image, one for the neighbor");
    XCTAssertEqual(readTracks.count, 2u);
    XCTAssertEqualObjects([NSSet setWithArray:delegate.deliveredTracks],
            [NSSet setWithArray:rows]);
    for (VibeLoaderTestTrack *row in rows) {
        XCTAssertEqualObjects(((VibeLoaderTestMetadata *)row.metadata).marker,
                row == neighbor ? @"neighbor" : @"cue-image");
    }
    // The fake compares by identity.
    XCTAssertEqual([NSSet setWithArray:[rows valueForKey:@"metadata"]].count, rows.count,
            @"each row needs its own copy for its own artwork state");
    XCTAssertTrue(delegate.allDeliveriesOnMain);
    XCTAssertEqual(controller.startedURLs.count, 0u);
}

- (void)testRowsOfOneUncachedFileCostOneMaterializationAndOneParse {
    NSURL *image = [self URLNamed:@"uncached-cue-image.flac"];
    NSMutableArray<VibeLoaderTestTrack *> *rows = VibeLoaderTestCueRows(image, 40);
    NSObject *countLock = [[NSObject alloc] init];
    __block NSUInteger cacheReads = 0;
    __block NSUInteger fileParses = 0;

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"every row published once"];
    delegate.deliveryExpectation.expectedFulfillmentCount = rows.count;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) {
        @synchronized (countLock) {
            cacheReads++;
        }
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *url) {
        @synchronized (countLock) {
            fileParses++;
        }
        return VibeLoaderTestMetadataResult(YES, @"uncached-image");
    }];

    [loader load:rows];
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        return [loader debugPendingBackgroundMaterializationCount] == 0;
    } description:@"settled rows left records pending, delayed or in flight"];

    XCTAssertEqualObjects(controller.startedURLs, (@[image]));
    XCTAssertEqual(fileParses, 1u);
    XCTAssertEqual(cacheReads, 2u,
            @"one stage-1 read for the file plus the owner's post-claim read");
    for (VibeLoaderTestTrack *row in rows) {
        XCTAssertEqualObjects(((VibeLoaderTestMetadata *)row.metadata).marker,
                @"uncached-image");
    }
    XCTAssertEqual([NSSet setWithArray:[rows valueForKey:@"metadata"]].count, rows.count);
}

- (void)testAFailedParseLeavesTheFilesOtherRowsTheirOwnTry {
    NSArray<VibeLoaderTestTrack *> *rows =
            VibeLoaderTestCueRows([self URLNamed:@"unreadable-cue-image.flac"], 3);
    NSObject *countLock = [[NSObject alloc] init];
    __block NSUInteger fileParses = 0;
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"every row given its own fallback"];
    delegate.deliveryExpectation.expectedFulfillmentCount = rows.count;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        @synchronized (countLock) {
            fileParses++;
        }
        return VibeLoaderTestMetadataResult(NO, @"fallback");
    }];

    [loader load:rows];
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        return [loader debugPendingBackgroundMaterializationCount] == 0;
    } description:@"the file's other rows were never requeued"];

    XCTAssertEqual(controller.startedURLs.count, rows.count);
    XCTAssertEqual(fileParses, rows.count, @"each row tries the file itself");
}

- (void)testPriorityTakesItsFilesRecordAndItsRowTakesAFailureFirst {
    NSURL *image = [self URLNamed:@"priority-cue-image.flac"];
    NSArray<VibeLoaderTestTrack *> *rows = VibeLoaderTestCueRows(image, 3);
    VibeLoaderTestTrack *blocker = [self trackNamed:@"priority-cue-blocker.wav"];
    // A lane beside the parked blocker, for the priority start.
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 2;
    AudioLoadingConfiguration *configuration = [self testConfigurationWithValues:values];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"blocker held the scan slot"];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"blocker and every row published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 1 + rows.count;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:configuration
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        return VibeLoaderTestMetadataResult([url isEqual:blocker.url], url.lastPathComponent);
    }];

    [loader load:[@[blocker] arrayByAddingObjectsFromArray:rows]];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"the file started beside the blocker"];
    controller.blocksUntilCancelled = NO;
    [loader prioritizeTrack:rows[2]];
    [self waitForExpectations:@[controller.allStartsExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    controller.allStartsExpectation = nil;
    [controller completeFirstReady];
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedURLs[1], image);
    XCTAssertEqualObjects(controller.startedRoles[1],
            @(VibeAudioFileMaterializationRoleMetadataPriority),
            @"the priority slot takes the file's record, not a record of the row");
    NSUInteger marked = [delegate.deliveredTracks indexOfObjectIdenticalTo:rows[2]];
    XCTAssertLessThan(marked, [delegate.deliveredTracks indexOfObjectIdenticalTo:rows[0]],
            @"the marked row reads first, so it takes the failure first");
    XCTAssertLessThan(marked, [delegate.deliveredTracks indexOfObjectIdenticalTo:rows[1]]);
    XCTAssertEqual(controller.startedURLs.count, 1 + rows.count,
            @"the file's other rows still try it for themselves");
}

- (void)testAbandoningARowLeavesTheRestOfItsFilesRecord {
    NSURL *image = [self URLNamed:@"abandon-cue-image.flac"];
    NSArray<VibeLoaderTestTrack *> *rows = VibeLoaderTestCueRows(image, 3);
    VibeLoaderTestTrack *blocker = [self trackNamed:@"abandon-cue-blocker.wav"];
    VibeLoaderTestTrack *departed = [self trackNamed:@"abandon-departed.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"blocker held the scan slot"];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"blocker and the remaining rows published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 3;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];

    [loader load:@[blocker, rows[0], rows[1], rows[2], departed]];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    // The record's first row, and the only row of another.
    [loader abandonQueuedTrack:rows[0]];
    [loader abandonQueuedTrack:departed];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        return [loader debugPendingBackgroundMaterializationCount] == 0;
    } description:@"the remaining rows' record did not settle"];

    XCTAssertEqualObjects(controller.startedURLs, (@[blocker.url, image]));
    XCTAssertNil(rows[0].metadata);
    XCTAssertNil(departed.metadata);
    XCTAssertTrue(rows[1].metadata.parsedOK);
    XCTAssertTrue(rows[2].metadata.parsedOK);
}

// The current row of a cue image removed while the priority slot is busy: its
// mark must go with it, or the image's other rows are never scanned.
- (void)testAbandoningAMarkedRowReleasesItsFilesOtherRowsToTheScan {
    NSURL *image = [self URLNamed:@"abandon-marked-cue-image.flac"];
    NSArray<VibeLoaderTestTrack *> *rows = VibeLoaderTestCueRows(image, 3);
    VibeLoaderTestTrack *blocker = [self trackNamed:@"abandon-marked-blocker.wav"];
    VibeLoaderTestTrack *busy = [self trackNamed:@"abandon-marked-busy-priority.wav"];
    // A lane beside the parked blocker, for the priority slot's parked start.
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 2;
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"blocker held the scan slot"];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"blocker and the remaining rows published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 3;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithValues:values]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];

    [loader load:[@[blocker] arrayByAddingObjectsFromArray:rows]];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"the priority slot parked on another file"];
    [loader prioritizeTrack:busy];
    [self waitForExpectations:@[controller.allStartsExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    controller.allStartsExpectation = nil;
    controller.blocksUntilCancelled = NO;
    // The slot is busy, so the image's record stays pending under the mark.
    [loader prioritizeTrack:rows[1]];
    [loader abandonQueuedTrack:rows[1]];
    [controller completeFirstReady];
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedURLs, (@[blocker.url, busy.url, image]));
    XCTAssertEqualObjects(controller.startedRoles.lastObject,
            @(VibeAudioFileMaterializationRoleMetadataScan));
    XCTAssertNil(rows[1].metadata);
    XCTAssertTrue(rows[0].metadata.parsedOK);
    XCTAssertTrue(rows[2].metadata.parsedOK);
}

- (void)testSuccessfulParseJoinsDuplicateRowsAndPublishesIndependentCopies {
    NSURL *url = [self URLNamed:@"duplicate-success.wav"];
    VibeLoaderTestTrack *first = [VibeLoaderTestTrack withURL:url];
    VibeLoaderTestTrack *second = [VibeLoaderTestTrack withURL:url];
    NSObject *countLock = [[NSObject alloc] init];
    __block NSUInteger cacheReads = 0;
    __block NSUInteger fileParses = 0;
    dispatch_semaphore_t parserGate = dispatch_semaphore_create(0);
    XCTestExpectation *parserEntered =
            [self expectationWithDescription:@"owner entered file parser"];
    MetadataParseCoordinator<VibeLoaderTestTrack *> *parseCoordinator = _owner.parseCoordinator;

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"both duplicate records materialized"];
    controller.allStartsExpectation.expectedFulfillmentCount = 2;
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"both duplicate rows published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) {
        @synchronized (countLock) {
            cacheReads++;
        }
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        @synchronized (countLock) {
            fileParses++;
        }
        [parserEntered fulfill];
        dispatch_semaphore_wait(parserGate, DISPATCH_TIME_FOREVER);
        return VibeLoaderTestMetadataResult(YES, @"parsed-success");
    }];

    // A second row loaded beside it would share its record; one the sweep
    // never listed gets its own, which joins the parse.
    [loader load:@[first]];
    [self waitForExpectations:@[parserEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    [loader prioritizeTrack:second];
    [self waitForCondition:^BOOL{
        return parseCoordinator.pendingCounts[@"waiters"].unsignedIntegerValue == 1;
    } description:@"duplicate row did not join the parse owner"];
    dispatch_semaphore_signal(parserGate);
    [self waitForExpectations:@[
        controller.allStartsExpectation, delegate.deliveryExpectation
    ] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqual(cacheReads, 3u,
            @"the owner's stage-1 and post-claim reads, and the priority row's check");
    XCTAssertEqual(fileParses, 1u);
    XCTAssertTrue(first.metadata.parsedOK);
    XCTAssertTrue(second.metadata.parsedOK);
    XCTAssertNotEqual(first.metadata, second.metadata,
            @"duplicate rows need independent mutable artwork state");
    XCTAssertEqualObjects(((VibeLoaderTestMetadata *)first.metadata).marker,
            @"parsed-success");
    XCTAssertEqualObjects(((VibeLoaderTestMetadata *)second.metadata).marker,
            @"parsed-success");
    XCTAssertEqualObjects([NSSet setWithArray:delegate.deliveredTracks],
            [NSSet setWithArray:(@[first, second])]);
    XCTAssertTrue(delegate.allDeliveriesOnMain);
    XCTAssertEqualObjects(parseCoordinator.pendingCounts,
            (@{@"holders": @0, @"waiters": @0}));
}

- (void)testPostClaimCacheHitCopiesIntoAJoinedRowWithoutReadingAgain {
    NSURL *url = [self URLNamed:@"duplicate-cache.wav"];
    VibeLoaderTestTrack *first = [VibeLoaderTestTrack withURL:url];
    VibeLoaderTestTrack *second = [VibeLoaderTestTrack withURL:url];
    NSObject *countLock = [[NSObject alloc] init];
    __block NSUInteger cacheReads = 0;
    dispatch_semaphore_t secondCacheGate = dispatch_semaphore_create(0);
    XCTestExpectation *secondCacheEntered =
            [self expectationWithDescription:@"owner entered post-claim cache read"];
    AudioTrackMetadata *cached =
            VibeLoaderTestMetadataResult(YES, @"post-claim-cache");
    MetadataParseCoordinator<VibeLoaderTestTrack *> *parseCoordinator = _owner.parseCoordinator;

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"cache owner and waiter published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) {
        NSUInteger read;
        @synchronized (countLock) {
            cacheReads++;
            read = cacheReads;
        }
        if (read == 2) {
            [secondCacheEntered fulfill];
            dispatch_semaphore_wait(secondCacheGate, DISPATCH_TIME_FOREVER);
            return cached;
        }
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        XCTFail(@"a post-claim cache hit must bypass file parsing");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader load:@[first]];
    [self waitForExpectations:@[secondCacheEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    [loader prioritizeTrack:second];
    [self waitForCondition:^BOOL{
        return parseCoordinator.pendingCounts[@"waiters"].unsignedIntegerValue == 1;
    } description:@"duplicate row did not join while the second cache read was held"];
    dispatch_semaphore_signal(secondCacheGate);
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqual(cacheReads, 3u,
            @"the owner's stage-1 and post-claim reads, and the priority row's check");
    XCTAssertTrue(first.metadata.parsedOK);
    XCTAssertTrue(second.metadata.parsedOK);
    XCTAssertNotEqual(first.metadata, second.metadata);
    XCTAssertEqualObjects(((VibeLoaderTestMetadata *)first.metadata).marker,
            @"post-claim-cache");
    XCTAssertEqualObjects(((VibeLoaderTestMetadata *)second.metadata).marker,
            @"post-claim-cache");
    XCTAssertEqualObjects([NSSet setWithArray:delegate.deliveredTracks],
            [NSSet setWithArray:(@[first, second])]);
    XCTAssertTrue(delegate.allDeliveriesOnMain);
    XCTAssertEqualObjects(parseCoordinator.pendingCounts,
            (@{@"holders": @0, @"waiters": @0}));
}

- (void)testFailedParsePublishesIndependentFallbacksToOwnerAndWaiter {
    NSURL *url = [self URLNamed:@"duplicate-fallback.wav"];
    VibeLoaderTestTrack *first = [VibeLoaderTestTrack withURL:url];
    VibeLoaderTestTrack *second = [VibeLoaderTestTrack withURL:url];
    NSObject *countLock = [[NSObject alloc] init];
    __block NSUInteger fileParses = 0;
    dispatch_semaphore_t parserGate = dispatch_semaphore_create(0);
    XCTestExpectation *parserEntered =
            [self expectationWithDescription:@"fallback parser entered"];
    MetadataParseCoordinator<VibeLoaderTestTrack *> *parseCoordinator = _owner.parseCoordinator;

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"both fallbacks published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(VibeLoaderTestTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        @synchronized (countLock) {
            fileParses++;
        }
        [parserEntered fulfill];
        dispatch_semaphore_wait(parserGate, DISPATCH_TIME_FOREVER);
        return VibeLoaderTestMetadataResult(NO, @"filename-fallback");
    }];

    [loader load:@[first]];
    [self waitForExpectations:@[parserEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    [loader prioritizeTrack:second];
    [self waitForCondition:^BOOL{
        return parseCoordinator.pendingCounts[@"waiters"].unsignedIntegerValue == 1;
    } description:@"fallback waiter did not join the parse owner"];
    dispatch_semaphore_signal(parserGate);
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqual(fileParses, 1u);
    XCTAssertNotNil(first.metadata);
    XCTAssertNotNil(second.metadata);
    XCTAssertFalse(first.metadata.parsedOK);
    XCTAssertFalse(second.metadata.parsedOK);
    XCTAssertNotEqual(first.metadata, second.metadata);
    XCTAssertEqualObjects(((VibeLoaderTestMetadata *)first.metadata).marker,
            @"filename-fallback");
    XCTAssertEqualObjects(((VibeLoaderTestMetadata *)second.metadata).marker,
            @"filename-fallback");
    XCTAssertEqualObjects([NSSet setWithArray:delegate.deliveredTracks],
            [NSSet setWithArray:(@[first, second])]);
    XCTAssertTrue(delegate.allDeliveriesOnMain);
    XCTAssertEqualObjects(parseCoordinator.pendingCounts,
            (@{@"holders": @0, @"waiters": @0}));
}

@end
