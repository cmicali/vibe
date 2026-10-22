//
//  AudioTrackMetadataLoaderTestCase.m
//

#import "AudioTrackMetadataLoaderTestCase.h"

#import "AudioTrackMetadataLoaderInternal.h"

static BOOL VibeMetadataLoaderCoordinatorIsSettled(
        VibeAudioFileMaterializationCoordinatorSnapshot snapshot) {
    return snapshot.claimCount == 0
            && snapshot.waiterCount == 0
            && snapshot.interactiveRunningCount == 0
            && snapshot.backgroundRunningCount == 0
            && snapshot.interactivePendingCount == 0
            && snapshot.backgroundPendingCount == 0
            && snapshot.handleRunCount == 0
            && !snapshot.foregroundTransferActive;
}

@implementation AudioTrackMetadataLoaderTestCase

- (void)setUp {
    [super setUp];
    _owner = [[VibeMetadataLoaderOwner alloc] init];
    _owner.parseCoordinator = [[MetadataParseCoordinator alloc] init];
    _loaders = [NSMutableArray array];
    _controllers = [NSMutableArray array];
    _coordinators = [NSMutableArray array];
    _delegates = [NSMutableArray array];
    _localNames = [NSMutableSet set];
    _testRootURL = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:
                    @"vibe-metadata-loader-tests-%@", NSUUID.UUID.UUIDString]]
                               isDirectory:YES];
    NSMutableSet<NSString *> *localNames = _localNames;
    [PlaceholderFiles setDatalessProbe:^BOOL(NSURL *url) {
        @synchronized (localNames) {
            return ![localNames containsObject:url.lastPathComponent];
        }
    }];
}

- (void)tearDown {
    for (AudioTrackMetadataLoader *loader in _loaders) {
        [loader cancel];
    }
    for (VibeMetadataLoaderOperationController *controller in _controllers) {
        [controller cancelAll];
    }
    for (AudioFileMaterializationCoordinator *coordinator in _coordinators) {
        [self waitForCondition:^BOOL{
            return VibeMetadataLoaderCoordinatorIsSettled(
                    [coordinator stateSnapshotForTesting]);
        } description:@"materialization coordinator did not settle during teardown"];
        VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
                [coordinator stateSnapshotForTesting];
        XCTAssertTrue(VibeMetadataLoaderCoordinatorIsSettled(snapshot),
                @"coordinator retained claims=%lu waiters=%lu running=%lu/%lu pending=%lu/%lu handles=%lu",
                (unsigned long)snapshot.claimCount,
                (unsigned long)snapshot.waiterCount,
                (unsigned long)snapshot.interactiveRunningCount,
                (unsigned long)snapshot.backgroundRunningCount,
                (unsigned long)snapshot.interactivePendingCount,
                (unsigned long)snapshot.backgroundPendingCount,
                (unsigned long)snapshot.handleRunCount);
    }
    [self waitForCondition:^BOOL{
        NSDictionary<NSString *, NSNumber *> *counts =
                self->_owner.parseCoordinator.pendingCounts;
        return counts[@"holders"].unsignedIntegerValue == 0
                && counts[@"waiters"].unsignedIntegerValue == 0;
    } description:@"metadata parse coordinator did not settle during teardown"];
    XCTAssertEqualObjects(_owner.parseCoordinator.pendingCounts,
            (@{@"holders": @0, @"waiters": @0}));
    [PlaceholderFiles setDatalessProbe:nil];
    [NSFileManager.defaultManager removeItemAtURL:_testRootURL error:nil];
    [super tearDown];
}

- (NSURL *)URLNamed:(NSString *)name {
    return [_testRootURL URLByAppendingPathComponent:name];
}

- (VibeLoaderTestTrack *)trackNamed:(NSString *)name {
    return [VibeLoaderTestTrack withURL:[self URLNamed:name]];
}

- (AudioLoadingConfiguration *)testConfigurationWithValues:(VibeAudioLoadingConfigurationValues)values {
    NSError *error = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&error];
    XCTAssertNotNil(configuration);
    XCTAssertNil(error);
    return configuration;
}

- (AudioLoadingConfiguration *)testConfigurationWithRetryCount:(NSUInteger)retryCount {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.metadataRetryCount = retryCount;
    return [self testConfigurationWithValues:values];
}

- (AudioLoadingConfiguration *)testConfiguration {
    return [self testConfigurationWithRetryCount:0];
}

- (AudioTrackMetadataLoader *)loaderWithController:
        (VibeMetadataLoaderOperationController *)controller
        cacheReader:(VibeAudioTrackMetadataCacheReader)cacheReader
        fileParser:(VibeAudioTrackMetadataFileParser)fileParser {
    return [self loaderWithController:controller
                        configuration:[self testConfiguration]
                              delegate:nil
                           cacheReader:cacheReader
                            fileParser:fileParser];
}

- (AudioTrackMetadataLoader *)loaderWithController:
        (VibeMetadataLoaderOperationController *)controller
        configuration:(AudioLoadingConfiguration *)configuration
        cacheReader:(VibeAudioTrackMetadataCacheReader)cacheReader
        fileParser:(VibeAudioTrackMetadataFileParser)fileParser {
    return [self loaderWithController:controller
                        configuration:configuration
                              delegate:nil
                           cacheReader:cacheReader
                            fileParser:fileParser];
}

- (AudioTrackMetadataLoader *)loaderWithController:
        (VibeMetadataLoaderOperationController *)controller
        configuration:(AudioLoadingConfiguration *)configuration
        delegate:(VibeMetadataLoaderDelegate *)delegate
        cacheReader:(VibeAudioTrackMetadataCacheReader)cacheReader
        fileParser:(VibeAudioTrackMetadataFileParser)fileParser {
    NSMutableSet<NSString *> *localNames = _localNames;
    AudioFileMaterializationCoordinator *coordinator =
            [[AudioFileMaterializationCoordinator alloc]
                    initWithConfiguration:configuration
                    operationFactory:^id<AudioFileMaterializationOperation>(
                            NSURL *url, VibeAudioFileMaterializationRole role) {
        return [controller operationForURL:url role:role];
    } datalessProbe:^BOOL(NSURL *url) {
        @synchronized (localNames) {
            return ![localNames containsObject:url.lastPathComponent];
        }
    } clock:^NSTimeInterval{
        return 0;
    }];
    AudioTrackMetadataLoader *loader = [[AudioTrackMetadataLoader alloc]
            initWithOwner:(AudioTrackMetadataCache *)_owner
                 delegate:delegate
     loadingConfiguration:configuration
materializationCoordinator:coordinator
               cacheReader:cacheReader
                fileParser:fileParser];
    [_loaders addObject:loader];
    [_controllers addObject:controller];
    [_coordinators addObject:coordinator];
    if (delegate) {
        [_delegates addObject:delegate];
    }
    return loader;
}

- (void)markLocal:(NSURL *)url {
    @synchronized (_localNames) {
        [_localNames addObject:url.lastPathComponent];
    }
}

- (void)waitForCondition:(BOOL (^)(void))condition description:(NSString *)description {
    if (condition()) {
        return;
    }
    XCTestExpectation *settled = [self expectationWithDescription:description];
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + VIBE_TEST_HANG_TIMEOUT;
    __block dispatch_block_t poll = nil;
    poll = ^{
        if (condition() || CFAbsoluteTimeGetCurrent() >= deadline) {
            [settled fulfill];
            poll = nil;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), poll);
    };
    dispatch_async(dispatch_get_main_queue(), poll);
    [self waitForExpectations:@[settled] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertTrue(condition(), @"%@", description);
}

- (void)waitForDelay:(NSTimeInterval)delay {
    XCTestExpectation *elapsed = [self expectationWithDescription:@"delay elapsed"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [elapsed fulfill];
    });
    [self waitForExpectations:@[elapsed] timeout:delay + VIBE_TEST_HANG_TIMEOUT];
}

- (NSMutableArray<dispatch_block_t> *)captureRetriesOf:(AudioTrackMetadataLoader *)loader {
    NSMutableArray<dispatch_block_t> *retries = [NSMutableArray array];
    loader.retryScheduler = ^(NSTimeInterval delay, dispatch_block_t block) {
        dispatch_async(dispatch_get_main_queue(), ^{ [retries addObject:block]; });
    };
    return retries;
}

@end
