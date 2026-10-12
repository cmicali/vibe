//
//  AudioTrackMetadataLoaderTests.m
//

#import "AudioTrackMetadataLoaderTestCase.h"

// Stage one, the cache, and the priority record.
@interface AudioTrackMetadataLoaderTests : AudioTrackMetadataLoaderTestCase
@end

@implementation AudioTrackMetadataLoaderTests

#pragma mark - Stage one and cache hits

- (void)testStageOneFullyDrainsBeforeExactNeighborhoodOrderedScanStarts {
    NSArray<AudioTrack *> *tracks = @[
        [self trackNamed:@"zero.wav"],
        [self trackNamed:@"one.wav"],
        [self trackNamed:@"two.wav"],
        [self trackNamed:@"three.wav"],
    ];
    dispatch_semaphore_t cacheGate = dispatch_semaphore_create(0);
    XCTestExpectation *checksEntered = [self expectationWithDescription:@"all cache checks entered"];
    checksEntered.expectedFulfillmentCount = tracks.count;
    NSObject *counterLock = [[NSObject alloc] init];
    NSMutableSet<AudioTrack *> *initiallyChecked = [NSMutableSet set];
    __block NSUInteger checksReturned = 0;

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.allStartsExpectation = [self expectationWithDescription:@"scan drained"];
    controller.allStartsExpectation.expectedFulfillmentCount = tracks.count;
    NSMutableArray<NSNumber *> *returnedAtStart = [NSMutableArray array];
    controller.startObserver = ^(NSURL *url, VibeAudioFileMaterializationRole role) {
        @synchronized (counterLock) {
            [returnedAtStart addObject:@(checksReturned)];
        }
    };
    XCTestExpectation *parsed = [self expectationWithDescription:@"all parsed"];
    parsed.expectedFulfillmentCount = tracks.count;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) {
        BOOL initialCheck;
        @synchronized (counterLock) {
            initialCheck = ![initiallyChecked containsObject:track];
            [initiallyChecked addObject:track];
        }
        if (!initialCheck) {
            return nil;
        }
        [checksEntered fulfill];
        dispatch_semaphore_wait(cacheGate, DISPATCH_TIME_FOREVER);
        @synchronized (counterLock) {
            checksReturned++;
        }
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    [loader setNeighborhoodURLs:@[tracks[2].url, tracks[1].url]];
    [loader load:tracks];

    [self waitForExpectations:@[checksEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual(controller.startedURLs.count, 0u,
            @"stage 2 began while stage-1 cache checks were still blocked");
    for (NSUInteger index = 0; index < tracks.count; index++) {
        dispatch_semaphore_signal(cacheGate);
    }
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedURLs, (@[
        tracks[2].url, tracks[1].url, tracks[0].url, tracks[3].url
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
    XCTAssertEqualObjects(returnedAtStart, (@[@4, @4, @4, @4]));
}

- (void)testDebugScanLaneStateReflectsBarrierPendingAndInFlightWork {
    AudioTrack *first = [self trackNamed:@"debug-first.wav"];
    AudioTrack *second = [self trackNamed:@"debug-second.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"first scan held"];
    controller.cancellationExpectation =
            [self expectationWithDescription:@"held scan cancelled"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"held debug-state scan parsed");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];
    [loader setNeighborhoodURLs:@[first.url]];
    [loader load:@[first, second]];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        return [[loader debugScanLaneState][@"liveTokens"] unsignedIntegerValue] == 1;
    } description:@"scan token was not installed"];

    NSDictionary *state = [loader debugScanLaneState];
    NSDictionary *priorityState = [loader debugPriorityLaneState];
    XCTAssertEqualObjects(state[@"pending"], (@[second.url.lastPathComponent]));
    XCTAssertEqualObjects(state[@"delayed"], (@[]));
    XCTAssertEqualObjects(state[@"inFlight"], @YES);
    XCTAssertEqualObjects(state[@"liveTokens"], @1);
    XCTAssertEqualObjects(state[@"stageOneFinished"], @YES);
    XCTAssertEqualObjects(priorityState[@"inFlight"], @NO);
    XCTAssertEqualObjects(priorityState[@"liveTokens"], @0,
            @"a scan token must not be reported as a priority token");

    [loader cancel];
    [self waitForExpectations:@[controller.cancellationExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testStageOneCacheHitInstallsAndPublishesWithoutMaterialization {
    AudioTrack *track = [self trackNamed:@"stage-one-hit.wav"];
    AudioTrackMetadata *cached = VibeLoaderTestMetadataResult(YES, @"stage-one-cache");
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"stage-one cache hit published"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return cached; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"a stage-one cache hit must not parse the file");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader load:@[track]];
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqual(track.metadata, cached);
    XCTAssertEqualObjects(delegate.deliveredTracks, (@[track]));
    XCTAssertEqualObjects(delegate.deliveredMetadata, (@[cached]));
    XCTAssertTrue(delegate.allDeliveriesOnMain);
    XCTAssertEqual(controller.startedURLs.count, 0u);
}

// The browser's road for a song not on the device: a miss must not read the
// file, which for a dataless one is a download.
- (void)testCacheOnlyHitPublishesAndMissReadsNothing {
    AudioTrack *hit = [self trackNamed:@"cache-only-hit.wav"];
    AudioTrack *miss = [self trackNamed:@"cache-only-miss.wav"];
    AudioTrackMetadata *cached = VibeLoaderTestMetadataResult(YES, @"cache-only");
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"cache-only hit published"];
    NSMutableArray<AudioTrack *> *lookups = [NSMutableArray array];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) {
        @synchronized (lookups) {
            [lookups addObject:candidate];
        }
        return candidate == hit ? cached : nil;
    }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"a cache-only lookup must not parse the file");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader loadFromCacheOnly:@[miss, hit]];
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        @synchronized (lookups) {
            return lookups.count == 2;
        }
    } description:@"both cache-only lookups ran"];

    XCTAssertEqual(hit.metadata, cached);
    XCTAssertNil(miss.metadata, @"a miss installs nothing, not even a fallback");
    XCTAssertEqualObjects(delegate.deliveredTracks, (@[hit]));
    XCTAssertTrue(delegate.allDeliveriesOnMain);
    XCTAssertEqual(controller.startedURLs.count, 0u);
}

#pragma mark - Priority

- (void)testPriorityRecordBypassesStageOneAndIsNotResubmittedByTheScan {
    AudioTrack *priority = [self trackNamed:@"priority.wav"];
    AudioTrack *first = [self trackNamed:@"first.wav"];
    AudioTrack *second = [self trackNamed:@"second.wav"];
    dispatch_semaphore_t cacheGate = dispatch_semaphore_create(0);
    XCTestExpectation *ordinaryChecks = [self expectationWithDescription:@"ordinary checks blocked"];
    ordinaryChecks.expectedFulfillmentCount = 2;
    NSObject *cacheLock = [[NSObject alloc] init];
    NSMutableSet<AudioTrack *> *initiallyChecked = [NSMutableSet set];

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.firstStartExpectation = [self expectationWithDescription:@"priority started"];
    controller.allStartsExpectation = [self expectationWithDescription:@"all starts"];
    controller.allStartsExpectation.expectedFulfillmentCount = 3;
    XCTestExpectation *parsed = [self expectationWithDescription:@"all parsed"];
    parsed.expectedFulfillmentCount = 3;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) {
        if (track == priority) {
            return nil;
        }
        BOOL initialCheck;
        @synchronized (cacheLock) {
            initialCheck = ![initiallyChecked containsObject:track];
            [initiallyChecked addObject:track];
        }
        if (!initialCheck) {
            return nil;
        }
        [ordinaryChecks fulfill];
        dispatch_semaphore_wait(cacheGate, DISPATCH_TIME_FOREVER);
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];

    [loader prioritizeTrack:priority];
    [loader load:@[priority, first, second]];
    [self waitForExpectations:@[controller.firstStartExpectation, ordinaryChecks] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(controller.startedURLs, (@[priority.url]));
    XCTAssertEqualObjects(controller.startedRoles,
            (@[@(VibeAudioFileMaterializationRoleMetadataPriority)]));

    dispatch_semaphore_signal(cacheGate);
    dispatch_semaphore_signal(cacheGate);
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(controller.startedURLs,
            (@[priority.url, first.url, second.url]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataPriority),
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
}

// The playing track's tags on a remote placeholder are read by range, so they
// arrive while the playback open's transfer of that file runs, never at its
// end: the priority record takes no claim to wait behind.
- (void)testPriorityTagsOfARemotePlaceholderArriveWhileItsPlaybackTransferRuns {
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:_testRootURL withIntermediateDirectories:YES
                                                          attributes:nil error:NULL]);
    AudioTrack *track = [self trackNamed:@"mix.mp3"];
    XCTAssertTrue([NSFileManager.defaultManager createFileAtPath:track.url.path contents:nil
                                                      attributes:@{NSFilePosixPermissions: @0}]);
    [NSURLUtil setRemotePlaceholderRoots:@[_testRootURL]];
    [self addTeardownBlock:^{
        [NSURLUtil setRemotePlaceholderRoots:@[]];
    }];
    VibeMetadataLoaderOperationController *controller = [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation = [self expectationWithDescription:@"playback transfer started"];
    controller.cancellationExpectation = [self expectationWithDescription:@"playback transfer cancelled"];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation = [self expectationWithDescription:@"tags delivered"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller configuration:[self testConfiguration]
                                                         delegate:delegate
                                                      cacheReader:^AudioTrackMetadata *(AudioTrack *t) { return nil; }
                                                       fileParser:^AudioTrackMetadata *(NSURL *url) {
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    __block BOOL playbackSettled = NO;
    AudioFileMaterializationRequestToken *playback = [coordinator materializeURL:track.url
            role:VibeAudioFileMaterializationRolePlayback completionQueue:dispatch_get_main_queue()
            completion:^(VibeAudioFileMaterializationResult result, NSError *error, NSTimeInterval elapsed) {
        playbackSettled = YES;
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    [loader prioritizeTrack:track];
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(track.metadata.parsedOK);
    XCTAssertFalse(playbackSettled, @"delivered before the transfer ended");
    XCTAssertEqual([coordinator stateSnapshotForTesting].claimCount, 1u);
    XCTAssertEqualObjects(controller.startedRoles, (@[@(VibeAudioFileMaterializationRolePlayback)]),
            @"the tags joined no claim");

    [playback cancel];
    [self waitForExpectations:@[controller.cancellationExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
}

// The shell's row removal abandons the queued entry; its undo is the later
// priority edge.
- (void)testAbandonedQueuedTrackNeverMaterializesAndPriorityRebuildsIt {
    AudioTrack *first = [self trackNamed:@"first.wav"];
    AudioTrack *removed = [self trackNamed:@"removed.wav"];
    AudioTrack *last = [self trackNamed:@"last.wav"];

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    // Park the first materialization. The stage-one barrier has drained by
    // then, so the other two entries sit in the pending list, where an abandon
    // must catch them.
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation = [self expectationWithDescription:@"first started"];
    NSObject *parsedLock = [[NSObject alloc] init];
    NSMutableSet<NSString *> *parsedNames = [NSMutableSet set];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:nil
             fileParser:^AudioTrackMetadata *(NSURL *url) {
        @synchronized (parsedLock) {
            [parsedNames addObject:url.lastPathComponent];
        }
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];

    [loader load:@[first, removed, last]];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    [loader abandonQueuedTrack:removed];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];

    [self waitForCondition:^BOOL{
        @synchronized (parsedLock) {
            return [parsedNames containsObject:@"first.wav"]
                    && [parsedNames containsObject:@"last.wav"];
        }
    } description:@"surviving rows did not parse"];
    XCTAssertEqualObjects(controller.startedURLs, (@[first.url, last.url]),
            @"the abandoned row must never start a materialization");

    [loader prioritizeTrack:removed];
    [self waitForCondition:^BOOL{
        @synchronized (parsedLock) {
            return [parsedNames containsObject:@"removed.wav"];
        }
    } description:@"the restored row did not parse"];
    XCTAssertEqualObjects(controller.startedURLs.lastObject, removed.url);
    XCTAssertEqualObjects(controller.startedRoles.lastObject,
            @(VibeAudioFileMaterializationRoleMetadataPriority));
}

- (void)testPriorityInvalidatesAnOffLockScanPickBeforeItCanClaimTheRecord {
    AudioTrack *track = [self trackNamed:@"priority-during-scan-pick.wav"];
    dispatch_semaphore_t pickGate = dispatch_semaphore_create(0);
    XCTestExpectation *pickEntered =
            [self expectationWithDescription:@"scan pick reached validation seam"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.firstStartExpectation =
            [self expectationWithDescription:@"reclassified priority started"];
    XCTestExpectation *parsed =
            [self expectationWithDescription:@"reclassified priority parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    [loader debugSetBeforeScanPickValidation:^{
        [pickEntered fulfill];
        dispatch_semaphore_wait(pickGate, DISPATCH_TIME_FOREVER);
    }];

    [loader load:@[track]];
    [self waitForExpectations:@[pickEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    [loader prioritizeTrack:track];
    [loader debugSetBeforeScanPickValidation:nil];
    dispatch_semaphore_signal(pickGate);
    [self waitForExpectations:@[controller.firstStartExpectation, parsed] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedURLs, (@[track.url]));
    XCTAssertEqualObjects(controller.startedRoles,
            (@[@(VibeAudioFileMaterializationRoleMetadataPriority)]));
}

- (void)testPriorityArrivingDuringScanMaterializationPromotesItsParse {
    AudioTrack *track = [self trackNamed:@"priority-during-scan.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"scan materialization started"];
    XCTestExpectation *parsed =
            [self expectationWithDescription:@"promoted scan result parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];

    [loader load:@[track]];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        return [[loader debugScanLaneState][@"liveTokens"] unsignedIntegerValue] == 1;
    } description:@"scan token was not installed"];
    [loader prioritizeTrack:track];
    [controller completeFirstReady];
    [self waitForExpectations:@[parsed] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedRoles,
            (@[@(VibeAudioFileMaterializationRoleMetadataScan)]));
    XCTAssertEqual([loader debugLastScheduledParseQualityOfService],
            NSQualityOfServiceUserInitiated);
    XCTAssertEqualObjects([loader debugPriorityLaneState][@"pending"], (@[]));
}

- (void)testPriorityPromotesAUtilityParseAlreadyQueuedBehindAnotherParse {
    AudioTrack *blocker = [self trackNamed:@"queued-parse-blocker.wav"];
    AudioTrack *target = [self trackNamed:@"queued-parse-target.wav"];
    dispatch_semaphore_t blockerGate = dispatch_semaphore_create(0);
    XCTestExpectation *blockerEntered =
            [self expectationWithDescription:@"blocking parser entered"];
    XCTestExpectation *bothParsed =
            [self expectationWithDescription:@"both rows parsed"];
    bothParsed.expectedFulfillmentCount = 2;

    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.localMetadataParseConcurrency = 1;
    NSError *configurationError = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&configurationError];
    XCTAssertNotNil(configuration);
    XCTAssertNil(configurationError);

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:configuration
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [bothParsed fulfill];
        if ([url isEqual:blocker.url]) {
            [blockerEntered fulfill];
            dispatch_semaphore_wait(blockerGate, DISPATCH_TIME_FOREVER);
        }
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];

    [loader load:@[blocker, target]];
    [self waitForExpectations:@[blockerEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        return [loader debugParseQualityOfServiceForTrack:target]
                == NSQualityOfServiceUtility;
    } description:@"target utility parse was not queued behind the blocker"];

    [loader prioritizeTrack:target];
    XCTAssertEqual([loader debugParseQualityOfServiceForTrack:target],
                   NSQualityOfServiceUserInitiated);

    dispatch_semaphore_signal(blockerGate);
    [self waitForExpectations:@[bothParsed] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        return [loader debugParseQualityOfServiceForTrack:target]
                == NSQualityOfServiceDefault;
    } description:@"settled queued parse remained in the operation registry"];
}

- (void)testPriorityBookkeepingTracksAUtilityParseThatIsAlreadyRunning {
    AudioTrack *target = [self trackNamed:@"running-parse-target.wav"];
    dispatch_semaphore_t parserGate = dispatch_semaphore_create(0);
    XCTestExpectation *parserEntered =
            [self expectationWithDescription:@"utility parser entered"];
    XCTestExpectation *parserReturned =
            [self expectationWithDescription:@"running parser returned"];

    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.localMetadataParseConcurrency = 1;
    NSError *configurationError = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&configurationError];
    XCTAssertNotNil(configuration);
    XCTAssertNil(configurationError);

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:configuration
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parserEntered fulfill];
        dispatch_semaphore_wait(parserGate, DISPATCH_TIME_FOREVER);
        [parserReturned fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];

    [loader load:@[target]];
    [self waitForExpectations:@[parserEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqual([loader debugParseQualityOfServiceForTrack:target],
                   NSQualityOfServiceUtility);

    [loader prioritizeTrack:target];
    // The executing thread already inherited its QoS; this only proves that
    // the operation stays reachable for priority bookkeeping until settlement.
    XCTAssertEqual([loader debugParseQualityOfServiceForTrack:target],
                   NSQualityOfServiceUserInitiated);

    dispatch_semaphore_signal(parserGate);
    [self waitForExpectations:@[parserReturned] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        return [loader debugParseQualityOfServiceForTrack:target]
                == NSQualityOfServiceDefault;
    } description:@"settled running parse remained in the operation registry"];
}

- (void)testCacheHitRetiresTargetMarkAndReopensDuplicateURLScan {
    NSURL *url = [self URLNamed:@"cache-target-duplicate.wav"];
    AudioTrack *cachedTarget = [AudioTrack withURL:url];
    AudioTrack *scanDuplicate = [AudioTrack withURL:url];
    dispatch_semaphore_t scanCacheGate = dispatch_semaphore_create(0);
    dispatch_semaphore_t targetCacheGate = dispatch_semaphore_create(0);
    XCTestExpectation *scanCacheEntered =
            [self expectationWithDescription:@"duplicate stage-one read entered"];
    XCTestExpectation *targetCacheEntered =
            [self expectationWithDescription:@"priority cache read entered"];
    NSObject *cacheLock = [[NSObject alloc] init];
    __block BOOL firstScanRead = YES;
    AudioTrackMetadata *cached = VibeLoaderTestMetadataResult(YES, @"cached-target");

    // One worker, so the stage-one read cannot enter until the setup operation
    // has installed the barrier. With more, a starved setup installs it after
    // the priority cache check, the barrier waits on the read the test holds,
    // and stage one never finishes.
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.localMetadataParseConcurrency = 1;
    NSError *configurationError = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&configurationError];
    XCTAssertNotNil(configuration);
    XCTAssertNil(configurationError);

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.firstStartExpectation =
            [self expectationWithDescription:@"duplicate scan reopened"];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"cache target and duplicate published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:configuration
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) {
        if (track == cachedTarget) {
            [targetCacheEntered fulfill];
            dispatch_semaphore_wait(targetCacheGate, DISPATCH_TIME_FOREVER);
            return cached;
        }
        BOOL shouldBlock = NO;
        @synchronized (cacheLock) {
            shouldBlock = firstScanRead;
            firstScanRead = NO;
        }
        if (shouldBlock) {
            [scanCacheEntered fulfill];
            dispatch_semaphore_wait(scanCacheGate, DISPATCH_TIME_FOREVER);
        }
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        return VibeLoaderTestMetadataResult(YES, @"parsed-duplicate");
    }];

    [loader load:@[scanDuplicate]];
    [self waitForExpectations:@[scanCacheEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    [loader prioritizeTrack:cachedTarget];
    dispatch_semaphore_signal(scanCacheGate);
    [self waitForExpectations:@[targetCacheEntered] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        NSDictionary *state = [loader debugScanLaneState];
        return [state[@"stageOneFinished"] boolValue]
                && [state[@"pending"] containsObject:url.lastPathComponent];
    } description:@"non-target duplicate was not reported in the scan lane"];
    XCTAssertEqualObjects([loader debugPriorityLaneState][@"pending"], (@[]));
    XCTAssertEqual(controller.startedURLs.count, 0u);

    dispatch_semaphore_signal(targetCacheGate);
    [self waitForExpectations:@[
        controller.firstStartExpectation, delegate.deliveryExpectation
    ] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedURLs, (@[scanDuplicate.url]));
    XCTAssertEqualObjects(controller.startedRoles,
            (@[@(VibeAudioFileMaterializationRoleMetadataScan)]));
    XCTAssertEqualObjects(((VibeLoaderTestMetadata *)cachedTarget.metadata).marker,
            @"cached-target");
    XCTAssertEqualObjects(((VibeLoaderTestMetadata *)scanDuplicate.metadata).marker,
            @"parsed-duplicate");
}

- (void)testOlderDuplicateReadyCannotRetireNewerTargetPriorityMark {
    NSURL *url = [self URLNamed:@"ready-target-duplicate.wav"];
    AudioTrack *first = [AudioTrack withURL:url];
    AudioTrack *second = [AudioTrack withURL:url];
    dispatch_semaphore_t secondCacheGate = dispatch_semaphore_create(0);
    XCTestExpectation *secondCacheEntered =
            [self expectationWithDescription:@"new target stage-one read entered"];
    NSObject *cacheLock = [[NSObject alloc] init];
    __block BOOL firstSecondRead = YES;
    __block NSUInteger parseCount = 0;
    // Held until the new target has started: a parse settling first would
    // serve its still-pending record and leave no second start to observe.
    dispatch_semaphore_t firstParseGate = dispatch_semaphore_create(0);

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"older priority started"];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"both duplicate targets published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) {
        if (track == second) {
            BOOL shouldBlock = NO;
            @synchronized (cacheLock) {
                shouldBlock = firstSecondRead;
                firstSecondRead = NO;
            }
            if (shouldBlock) {
                [secondCacheEntered fulfill];
                dispatch_semaphore_wait(secondCacheGate, DISPATCH_TIME_FOREVER);
            }
        }
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        NSUInteger parse;
        @synchronized (cacheLock) {
            parse = ++parseCount;
        }
        if (parse == 1) {
            dispatch_semaphore_wait(firstParseGate,
                    dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        }
        return VibeLoaderTestMetadataResult(YES,
                [NSString stringWithFormat:@"parse-%lu", (unsigned long)parse]);
    }];

    [loader prioritizeTrack:first];
    [loader load:@[first, second]];
    [self waitForExpectations:@[
        controller.firstStartExpectation, secondCacheEntered
    ] timeout:VIBE_TEST_HANG_TIMEOUT];
    [loader prioritizeTrack:second];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"new target priority started"];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForCondition:^BOOL{
        NSDictionary *state = [loader debugPriorityLaneState];
        return ![state[@"inFlight"] boolValue]
                && [state[@"liveTokens"] unsignedIntegerValue] == 0;
    } description:@"older priority Ready completion did not settle"];
    dispatch_semaphore_signal(secondCacheGate);
    [self waitForExpectations:@[controller.allStartsExpectation]
                      timeout:VIBE_TEST_HANG_TIMEOUT];
    dispatch_semaphore_signal(firstParseGate);
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedURLs, (@[first.url, second.url]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataPriority),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
    ]));
    XCTAssertEqualObjects([NSSet setWithArray:delegate.deliveredTracks],
            [NSSet setWithArray:(@[first, second])]);
}

- (void)testPriorityAddedDuringParseRetiresAtSettlementAndSettlesTheDuplicate {
    NSURL *url = [self URLNamed:@"parse-target-duplicate.wav"];
    AudioTrack *parseTarget = [AudioTrack withURL:url];
    AudioTrack *scanDuplicate = [AudioTrack withURL:url];
    AudioTrack *scanBlocker = [self trackNamed:@"parse-target-blocker.wav"];
    dispatch_semaphore_t parserGate = dispatch_semaphore_create(0);
    XCTestExpectation *parserEntered =
            [self expectationWithDescription:@"target parser held"];
    XCTestExpectation *allParsed =
            [self expectationWithDescription:@"target and blocker parsed"];
    allParsed.expectedFulfillmentCount = 2;
    NSObject *stateLock = [[NSObject alloc] init];
    __block NSUInteger parseCount = 0;
    __block BOOL firstTargetParse = YES;

    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 2;
    AudioLoadingConfiguration *configuration = [self testConfigurationWithValues:values];

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"scan blocker started"];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"all rows published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 3;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:configuration
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        NSUInteger currentParse;
        BOOL shouldBlock;
        @synchronized (stateLock) {
            currentParse = ++parseCount;
            shouldBlock = [parsedURL isEqual:parseTarget.url] && firstTargetParse;
            if (shouldBlock) {
                firstTargetParse = NO;
            }
        }
        [allParsed fulfill];
        if (shouldBlock) {
            [parserEntered fulfill];
            dispatch_semaphore_wait(parserGate, DISPATCH_TIME_FOREVER);
        }
        return VibeLoaderTestMetadataResult(YES,
                [NSString stringWithFormat:@"parse-%lu", (unsigned long)currentParse]);
    }];

    [loader load:@[scanBlocker, scanDuplicate]];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"target priority started"];
    [loader prioritizeTrack:parseTarget];
    [self waitForExpectations:@[controller.allStartsExpectation] timeout:VIBE_TEST_HANG_TIMEOUT];
    [self waitForCondition:^BOOL{
        return [[loader debugPriorityLaneState][@"liveTokens"] unsignedIntegerValue] == 1;
    } description:@"target priority token was not installed"];
    [controller completeLastReady];
    [self waitForExpectations:@[parserEntered] timeout:VIBE_TEST_HANG_TIMEOUT];

    [loader prioritizeTrack:parseTarget];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForCondition:^BOOL{
        NSDictionary *state = [loader debugScanLaneState];
        return [state[@"stageOneFinished"] boolValue] && ![state[@"inFlight"] boolValue];
    } description:@"blocker did not settle out of the scan lane"];
    XCTAssertEqualObjects([loader debugScanLaneState][@"pending"], (@[]),
            @"the duplicate rides the target's record");
    XCTAssertEqual(controller.startedURLs.count, 2u);

    dispatch_semaphore_signal(parserGate);
    [self waitForExpectations:@[allParsed, delegate.deliveryExpectation]
                      timeout:VIBE_TEST_HANG_TIMEOUT];

    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
    ]), @"the target's parse settles the waiting duplicate");
    XCTAssertEqualObjects(((VibeLoaderTestMetadata *)scanDuplicate.metadata).marker,
            ((VibeLoaderTestMetadata *)parseTarget.metadata).marker);
    XCTAssertNotEqual(scanDuplicate.metadata, parseTarget.metadata);
    [self waitForCondition:^BOOL{
        NSDictionary *priority = [loader debugPriorityLaneState];
        NSDictionary *scan = [loader debugScanLaneState];
        return [priority[@"pending"] count] == 0
                && ![priority[@"inFlight"] boolValue]
                && [scan[@"pending"] count] == 0
                && ![scan[@"inFlight"] boolValue];
    } description:@"parse-time priority mark or duplicate scan did not drain"];
}

@end
