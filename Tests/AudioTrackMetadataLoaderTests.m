//
//  AudioTrackMetadataLoaderTests.m
//

#import <XCTest/XCTest.h>

#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataLoader+Debug.h"
#import "AudioTrackMetadataLoaderInternal.h"
#import "MetadataParseCoordinator.h"
#import "NSURLUtil+Debug.h"

// AudioTrackMetadata's real implementation is ObjC++/TagLib and deliberately
// stays out of the host-less target. These tests replace the loader's parse
// boundary; this definition only satisfies the dormant production path's
// class reference, and fails loudly if that boundary is ever crossed.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation AudioTrackMetadata
+ (BOOL)supportsSecureCoding {
    return YES;
}

+ (instancetype)metadataWithURL:(NSURL *)url {
    [NSException raise:NSInternalInconsistencyException
                format:@"Metadata parser escaped its test seam for %@", url];
    return nil;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    return [super init];
}

- (void)encodeWithCoder:(NSCoder *)coder {
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}
@end
#pragma clang diagnostic pop

@interface VibeLoaderTestMetadata : NSObject <NSCopying>
@property(nonatomic) BOOL parsedOK;
@property(nonatomic, copy) NSString *marker;
@end

@implementation VibeLoaderTestMetadata
- (id)copyWithZone:(NSZone *)zone {
    VibeLoaderTestMetadata *copy = [[[self class] allocWithZone:zone] init];
    copy.parsedOK = self.parsedOK;
    copy.marker = self.marker;
    return copy;
}
@end

static AudioTrackMetadata *VibeLoaderTestMetadataResult(BOOL parsedOK,
                                                        NSString *marker) {
    VibeLoaderTestMetadata *metadata = [[VibeLoaderTestMetadata alloc] init];
    metadata.parsedOK = parsedOK;
    metadata.marker = marker;
    return (AudioTrackMetadata *)metadata;
}

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

@interface VibeMetadataLoaderOwner : NSObject
@property(nonatomic, strong) MetadataParseCoordinator<AudioTrack *> *parseCoordinator;
@property(atomic) uint64_t cacheGeneration;
@property(atomic, strong) id metadataCache;
@end

@implementation VibeMetadataLoaderOwner
@end

@interface VibeMetadataLoaderDelegate : NSObject <AudioTrackMetadataCacheDelegate>
@property(nonatomic, strong) XCTestExpectation *deliveryExpectation;
@property(nonatomic, strong) NSMutableArray<AudioTrack *> *deliveredTracks;
@property(nonatomic, strong) NSMutableArray<AudioTrackMetadata *> *deliveredMetadata;
@property(nonatomic) BOOL allDeliveriesOnMain;
@end

@implementation VibeMetadataLoaderDelegate
- (instancetype)init {
    self = [super init];
    if (self) {
        _deliveredTracks = [NSMutableArray array];
        _deliveredMetadata = [NSMutableArray array];
        _allDeliveriesOnMain = YES;
    }
    return self;
}

- (void)didLoadMetadata:(AudioTrack *)track {
    self.allDeliveriesOnMain &= NSThread.isMainThread;
    [self.deliveredTracks addObject:track];
    [self.deliveredMetadata addObject:track.metadata];
    [self.deliveryExpectation fulfill];
}
@end

@class VibeMetadataLoaderOperationController;

@interface VibeMetadataLoaderOperation : NSObject <AudioFileMaterializationOperation>
- (instancetype)initWithURL:(NSURL *)url
                       role:(VibeAudioFileMaterializationRole)role
                 controller:(VibeMetadataLoaderOperationController *)controller;
- (void)completeReady;
- (void)completeFailed;
- (void)forceCancel;
@end

@interface VibeMetadataLoaderOperationController : NSObject
@property(atomic) BOOL blocksUntilCancelled;
@property(atomic, strong) XCTestExpectation *firstStartExpectation;
@property(atomic, strong) XCTestExpectation *allStartsExpectation;
@property(atomic, strong) XCTestExpectation *cancellationExpectation;
@property(atomic, copy) void (^startObserver)(NSURL *url,
        VibeAudioFileMaterializationRole role);
- (id<AudioFileMaterializationOperation>)operationForURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role;
- (void)recordStartForURL:(NSURL *)url role:(VibeAudioFileMaterializationRole)role;
- (void)recordCancellation;
- (BOOL)consumeFailureForURL:(NSURL *)url;
- (NSArray<NSURL *> *)startedURLs;
- (NSArray<NSNumber *> *)startedRoles;
- (void)failNextStarts:(NSUInteger)count forURL:(NSURL *)url;
- (void)completeFirstReady;
- (void)completeFirstFailed;
- (void)completeLastReady;
- (void)cancelAll;
@end

@implementation VibeMetadataLoaderOperation {
    NSURL *_url;
    VibeAudioFileMaterializationRole _role;
    __weak VibeMetadataLoaderOperationController *_controller;
    NSCondition *_condition;
    BOOL _finished;
    BOOL _ready;
    BOOL _cancelled;
}

- (instancetype)initWithURL:(NSURL *)url
                       role:(VibeAudioFileMaterializationRole)role
                 controller:(VibeMetadataLoaderOperationController *)controller {
    self = [super init];
    if (self) {
        _url = [url copy];
        _role = role;
        _controller = controller;
        _condition = [[NSCondition alloc] init];
    }
    return self;
}

- (BOOL)runWithError:(NSError *__autoreleasing *)error {
    VibeMetadataLoaderOperationController *controller = _controller;
    [controller recordStartForURL:_url role:_role];
    if ([controller consumeFailureForURL:_url]) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadUnknownError userInfo:nil];
        }
        return NO;
    }
    if (!controller.blocksUntilCancelled) {
        return YES;
    }
    [_condition lock];
    while (!_finished) {
        [_condition wait];
    }
    BOOL ready = _ready;
    BOOL cancelled = _cancelled;
    [_condition unlock];
    if (!ready && error) {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                     code:cancelled ? NSUserCancelledError
                                                    : NSFileReadUnknownError
                                 userInfo:nil];
    }
    return ready;
}

- (void)cancel {
    [_condition lock];
    BOOL first = !_finished;
    _finished = YES;
    _ready = NO;
    _cancelled = YES;
    [_condition broadcast];
    [_condition unlock];
    if (first) {
        [_controller recordCancellation];
    }
}

- (void)completeFailed {
    [_condition lock];
    if (!_finished) {
        _finished = YES;
        _ready = NO;
        _cancelled = NO;
        [_condition broadcast];
    }
    [_condition unlock];
}

- (void)completeReady {
    [_condition lock];
    if (!_finished) {
        _finished = YES;
        _ready = YES;
        [_condition broadcast];
    }
    [_condition unlock];
}

- (void)forceCancel {
    [self cancel];
}

@end

@implementation VibeMetadataLoaderOperationController {
    NSLock *_lock;
    NSMutableArray<VibeMetadataLoaderOperation *> *_operations;
    NSMutableArray<NSURL *> *_startedURLs;
    NSMutableArray<NSNumber *> *_startedRoles;
    NSMutableDictionary<NSString *, NSNumber *> *_failuresRemainingByPath;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _operations = [NSMutableArray array];
        _startedURLs = [NSMutableArray array];
        _startedRoles = [NSMutableArray array];
        _failuresRemainingByPath = [NSMutableDictionary dictionary];
    }
    return self;
}

- (id<AudioFileMaterializationOperation>)operationForURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role {
    VibeMetadataLoaderOperation *operation = [[VibeMetadataLoaderOperation alloc]
            initWithURL:url role:role controller:self];
    [_lock lock];
    [_operations addObject:operation];
    [_lock unlock];
    return operation;
}

- (void)recordStartForURL:(NSURL *)url role:(VibeAudioFileMaterializationRole)role {
    [_lock lock];
    [_startedURLs addObject:url];
    [_startedRoles addObject:@(role)];
    NSUInteger count = _startedURLs.count;
    void (^observer)(NSURL *, VibeAudioFileMaterializationRole) = self.startObserver;
    XCTestExpectation *first = self.firstStartExpectation;
    XCTestExpectation *all = self.allStartsExpectation;
    [_lock unlock];
    if (observer) {
        observer(url, role);
    }
    if (count == 1) {
        [first fulfill];
    }
    [all fulfill];
}

- (void)recordCancellation {
    [self.cancellationExpectation fulfill];
}

- (BOOL)consumeFailureForURL:(NSURL *)url {
    [_lock lock];
    NSUInteger remaining = _failuresRemainingByPath[url.path].unsignedIntegerValue;
    if (remaining > 0) {
        _failuresRemainingByPath[url.path] = @(remaining - 1);
    }
    [_lock unlock];
    return remaining > 0;
}

- (NSArray<NSURL *> *)startedURLs {
    [_lock lock];
    NSArray *result = [_startedURLs copy];
    [_lock unlock];
    return result;
}

- (NSArray<NSNumber *> *)startedRoles {
    [_lock lock];
    NSArray *result = [_startedRoles copy];
    [_lock unlock];
    return result;
}

- (void)failNextStarts:(NSUInteger)count forURL:(NSURL *)url {
    [_lock lock];
    _failuresRemainingByPath[url.path] = @(count);
    [_lock unlock];
}

- (void)completeFirstReady {
    [_lock lock];
    VibeMetadataLoaderOperation *operation = _operations.firstObject;
    [_lock unlock];
    [operation completeReady];
}

- (void)completeFirstFailed {
    [_lock lock];
    VibeMetadataLoaderOperation *operation = _operations.firstObject;
    [_lock unlock];
    [operation completeFailed];
}

- (void)completeLastReady {
    [_lock lock];
    VibeMetadataLoaderOperation *operation = _operations.lastObject;
    [_lock unlock];
    [operation completeReady];
}

- (void)cancelAll {
    [_lock lock];
    NSArray *operations = [_operations copy];
    [_lock unlock];
    for (VibeMetadataLoaderOperation *operation in operations) {
        [operation forceCancel];
    }
}

@end

@interface AudioTrackMetadataLoaderTests : XCTestCase
- (AudioTrackMetadataLoader *)loaderWithController:
        (VibeMetadataLoaderOperationController *)controller
        configuration:(AudioLoadingConfiguration *)configuration
        delegate:(nullable VibeMetadataLoaderDelegate *)delegate
        cacheReader:(nullable VibeAudioTrackMetadataCacheReader)cacheReader
        fileParser:(nullable VibeAudioTrackMetadataFileParser)fileParser;
- (void)waitForCondition:(BOOL (^)(void))condition
             description:(NSString *)description;
@end

@implementation AudioTrackMetadataLoaderTests {
    VibeMetadataLoaderOwner *_owner;
    NSMutableArray<AudioTrackMetadataLoader *> *_loaders;
    NSMutableArray<VibeMetadataLoaderOperationController *> *_controllers;
    NSMutableArray<AudioFileMaterializationCoordinator *> *_coordinators;
    NSMutableArray<VibeMetadataLoaderDelegate *> *_delegates;
    NSMutableSet<NSString *> *_localNames;
    NSURL *_testRootURL;
}

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
    [NSURLUtil setDatalessProbe:^BOOL(NSURL *url) {
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
    [NSURLUtil setDatalessProbe:nil];
    [NSFileManager.defaultManager removeItemAtURL:_testRootURL error:nil];
    [super tearDown];
}

- (NSURL *)URLNamed:(NSString *)name {
    return [_testRootURL URLByAppendingPathComponent:name];
}

- (AudioTrack *)trackNamed:(NSString *)name {
    return [AudioTrack withURL:[self URLNamed:name]];
}

- (AudioLoadingConfiguration *)testConfigurationWithRetryCount:(NSUInteger)retryCount {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.metadataRetryCount = retryCount;
    NSError *error = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&error];
    XCTAssertNotNil(configuration);
    XCTAssertNil(error);
    return configuration;
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
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 2;
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
    [self waitForExpectations:@[settled] timeout:3];
    XCTAssertTrue(condition(), @"%@", description);
}

- (void)waitForDelay:(NSTimeInterval)delay {
    XCTestExpectation *elapsed = [self expectationWithDescription:@"delay elapsed"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [elapsed fulfill];
    });
    [self waitForExpectations:@[elapsed] timeout:delay + 1];
}

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

    [self waitForExpectations:@[checksEntered] timeout:2];
    XCTAssertEqual(controller.startedURLs.count, 0u,
            @"stage 2 began while stage-1 cache checks were still blocked");
    for (NSUInteger index = 0; index < tracks.count; index++) {
        dispatch_semaphore_signal(cacheGate);
    }
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:2];

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
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];
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
    [self waitForExpectations:@[controller.cancellationExpectation] timeout:2];
}

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
    [self waitForExpectations:@[controller.firstStartExpectation, ordinaryChecks] timeout:2];
    XCTAssertEqualObjects(controller.startedURLs, (@[priority.url]));
    XCTAssertEqualObjects(controller.startedRoles,
            (@[@(VibeAudioFileMaterializationRoleMetadataPriority)]));

    dispatch_semaphore_signal(cacheGate);
    dispatch_semaphore_signal(cacheGate);
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:2];
    XCTAssertEqualObjects(controller.startedURLs,
            (@[priority.url, first.url, second.url]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataPriority),
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
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
    [self waitForExpectations:@[pickEntered] timeout:2];
    [loader prioritizeTrack:track];
    [loader debugSetBeforeScanPickValidation:nil];
    dispatch_semaphore_signal(pickGate);
    [self waitForExpectations:@[controller.firstStartExpectation, parsed] timeout:2];

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
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];
    [self waitForCondition:^BOOL{
        return [[loader debugScanLaneState][@"liveTokens"] unsignedIntegerValue] == 1;
    } description:@"scan token was not installed"];
    [loader prioritizeTrack:track];
    [controller completeFirstReady];
    [self waitForExpectations:@[parsed] timeout:2];

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
    [self waitForExpectations:@[blockerEntered] timeout:2];
    [self waitForCondition:^BOOL{
        return [loader debugParseQualityOfServiceForTrack:target]
                == NSQualityOfServiceUtility;
    } description:@"target utility parse was not queued behind the blocker"];

    [loader prioritizeTrack:target];
    XCTAssertEqual([loader debugParseQualityOfServiceForTrack:target],
                   NSQualityOfServiceUserInitiated);

    dispatch_semaphore_signal(blockerGate);
    [self waitForExpectations:@[bothParsed] timeout:2];
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
    [self waitForExpectations:@[parserEntered] timeout:2];
    XCTAssertEqual([loader debugParseQualityOfServiceForTrack:target],
                   NSQualityOfServiceUtility);

    [loader prioritizeTrack:target];
    // The executing thread already inherited its QoS; this only proves that
    // the operation stays reachable for priority bookkeeping until settlement.
    XCTAssertEqual([loader debugParseQualityOfServiceForTrack:target],
                   NSQualityOfServiceUserInitiated);

    dispatch_semaphore_signal(parserGate);
    [self waitForExpectations:@[parserReturned] timeout:2];
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

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.firstStartExpectation =
            [self expectationWithDescription:@"duplicate scan reopened"];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"cache target and duplicate published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
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
    [self waitForExpectations:@[scanCacheEntered] timeout:2];
    [loader prioritizeTrack:cachedTarget];
    dispatch_semaphore_signal(scanCacheGate);
    [self waitForExpectations:@[targetCacheEntered] timeout:2];
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
    ] timeout:2];

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
        @synchronized (cacheLock) {
            parseCount++;
        }
        return VibeLoaderTestMetadataResult(YES,
                [NSString stringWithFormat:@"parse-%lu", (unsigned long)parseCount]);
    }];

    [loader prioritizeTrack:first];
    [loader load:@[first, second]];
    [self waitForExpectations:@[
        controller.firstStartExpectation, secondCacheEntered
    ] timeout:2];
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
    [self waitForExpectations:@[
        controller.allStartsExpectation, delegate.deliveryExpectation
    ] timeout:2];

    XCTAssertEqualObjects(controller.startedURLs, (@[first.url, second.url]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataPriority),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
    ]));
    XCTAssertEqualObjects([NSSet setWithArray:delegate.deliveredTracks],
            [NSSet setWithArray:(@[first, second])]);
}

- (void)testPriorityAddedDuringParseRetiresAtSettlementAndReopensDuplicate {
    NSURL *url = [self URLNamed:@"parse-target-duplicate.wav"];
    AudioTrack *parseTarget = [AudioTrack withURL:url];
    AudioTrack *scanDuplicate = [AudioTrack withURL:url];
    AudioTrack *scanBlocker = [self trackNamed:@"parse-target-blocker.wav"];
    dispatch_semaphore_t parserGate = dispatch_semaphore_create(0);
    XCTestExpectation *parserEntered =
            [self expectationWithDescription:@"target parser held"];
    XCTestExpectation *allParsed = [self expectationWithDescription:@"all rows parsed"];
    allParsed.expectedFulfillmentCount = 3;
    NSObject *stateLock = [[NSObject alloc] init];
    __block NSUInteger parseCount = 0;
    __block BOOL firstTargetParse = YES;

    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundMaterializations = 2;
    NSError *configurationError = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&configurationError];
    XCTAssertNotNil(configuration);
    XCTAssertNil(configurationError);

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
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"target priority started"];
    [loader prioritizeTrack:parseTarget];
    [self waitForExpectations:@[controller.allStartsExpectation] timeout:2];
    [self waitForCondition:^BOOL{
        return [[loader debugPriorityLaneState][@"liveTokens"] unsignedIntegerValue] == 1;
    } description:@"target priority token was not installed"];
    [controller completeLastReady];
    [self waitForExpectations:@[parserEntered] timeout:2];

    [loader prioritizeTrack:parseTarget];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForCondition:^BOOL{
        NSDictionary *state = [loader debugScanLaneState];
        return [state[@"stageOneFinished"] boolValue]
                && [state[@"pending"] containsObject:url.lastPathComponent];
    } description:@"duplicate did not wait in the scan lane during target parse"];
    XCTAssertEqual(controller.startedURLs.count, 2u);

    controller.allStartsExpectation =
            [self expectationWithDescription:@"duplicate scan reopened after parse"];
    dispatch_semaphore_signal(parserGate);
    [self waitForExpectations:@[
        controller.allStartsExpectation, allParsed, delegate.deliveryExpectation
    ] timeout:2];

    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
    [self waitForCondition:^BOOL{
        NSDictionary *priority = [loader debugPriorityLaneState];
        NSDictionary *scan = [loader debugScanLaneState];
        return [priority[@"pending"] count] == 0
                && ![priority[@"inFlight"] boolValue]
                && [scan[@"pending"] count] == 0
                && ![scan[@"inFlight"] boolValue];
    } description:@"parse-time priority mark or duplicate scan did not drain"];
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
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:2];

    XCTAssertEqual(track.metadata, cached);
    XCTAssertEqualObjects(delegate.deliveredTracks, (@[track]));
    XCTAssertEqualObjects(delegate.deliveredMetadata, (@[cached]));
    XCTAssertTrue(delegate.allDeliveriesOnMain);
    XCTAssertEqual(controller.startedURLs.count, 0u);
}

- (void)testSuccessfulParseJoinsDuplicateRowsAndPublishesIndependentCopies {
    NSURL *url = [self URLNamed:@"duplicate-success.wav"];
    AudioTrack *first = [AudioTrack withURL:url];
    AudioTrack *second = [AudioTrack withURL:url];
    NSObject *countLock = [[NSObject alloc] init];
    __block NSUInteger cacheReads = 0;
    __block NSUInteger fileParses = 0;
    dispatch_semaphore_t parserGate = dispatch_semaphore_create(0);
    XCTestExpectation *parserEntered =
            [self expectationWithDescription:@"owner entered file parser"];
    MetadataParseCoordinator<AudioTrack *> *parseCoordinator = _owner.parseCoordinator;

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
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) {
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

    [loader load:@[first, second]];
    [self waitForExpectations:@[parserEntered] timeout:2];
    [self waitForCondition:^BOOL{
        return parseCoordinator.pendingCounts[@"waiters"].unsignedIntegerValue == 1;
    } description:@"duplicate row did not join the parse owner"];
    dispatch_semaphore_signal(parserGate);
    [self waitForExpectations:@[
        controller.allStartsExpectation, delegate.deliveryExpectation
    ] timeout:2];

    XCTAssertEqual(cacheReads, 3u,
            @"two stage-1 reads plus the owner's post-claim read are required");
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

- (void)testPostClaimCacheHitServesAJoinedRowWhenItsCacheEntryDisappears {
    NSURL *url = [self URLNamed:@"duplicate-cache.wav"];
    AudioTrack *first = [AudioTrack withURL:url];
    AudioTrack *second = [AudioTrack withURL:url];
    NSObject *countLock = [[NSObject alloc] init];
    __block NSUInteger cacheReads = 0;
    dispatch_semaphore_t secondCacheGate = dispatch_semaphore_create(0);
    XCTestExpectation *secondCacheEntered =
            [self expectationWithDescription:@"owner entered post-claim cache read"];
    AudioTrackMetadata *cached =
            VibeLoaderTestMetadataResult(YES, @"post-claim-cache");
    MetadataParseCoordinator<AudioTrack *> *parseCoordinator = _owner.parseCoordinator;

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"cache owner and waiter published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) {
        NSUInteger read;
        @synchronized (countLock) {
            cacheReads++;
            read = cacheReads;
        }
        if (read == 3) {
            [secondCacheEntered fulfill];
            dispatch_semaphore_wait(secondCacheGate, DISPATCH_TIME_FOREVER);
            return cached;
        }
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        XCTFail(@"a post-claim cache hit must bypass file parsing");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader load:@[first, second]];
    [self waitForExpectations:@[secondCacheEntered] timeout:2];
    [self waitForCondition:^BOOL{
        return parseCoordinator.pendingCounts[@"waiters"].unsignedIntegerValue == 1;
    } description:@"duplicate row did not join while the second cache read was held"];
    dispatch_semaphore_signal(secondCacheGate);
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:2];

    XCTAssertEqual(cacheReads, 4u,
            @"the waiter must retry cache before copying the owner's result");
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
    AudioTrack *first = [AudioTrack withURL:url];
    AudioTrack *second = [AudioTrack withURL:url];
    NSObject *countLock = [[NSObject alloc] init];
    __block NSUInteger fileParses = 0;
    dispatch_semaphore_t parserGate = dispatch_semaphore_create(0);
    XCTestExpectation *parserEntered =
            [self expectationWithDescription:@"fallback parser entered"];
    MetadataParseCoordinator<AudioTrack *> *parseCoordinator = _owner.parseCoordinator;

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"both fallbacks published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfiguration]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        @synchronized (countLock) {
            fileParses++;
        }
        [parserEntered fulfill];
        dispatch_semaphore_wait(parserGate, DISPATCH_TIME_FOREVER);
        return VibeLoaderTestMetadataResult(NO, @"filename-fallback");
    }];

    [loader load:@[first, second]];
    [self waitForExpectations:@[parserEntered] timeout:2];
    [self waitForCondition:^BOOL{
        return parseCoordinator.pendingCounts[@"waiters"].unsignedIntegerValue == 1;
    } description:@"fallback waiter did not join the parse owner"];
    dispatch_semaphore_signal(parserGate);
    [self waitForExpectations:@[delegate.deliveryExpectation] timeout:2];

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

- (void)testFailedScanRetriesBehindUntriedRowsThenParsesOnce {
    AudioTrack *first = [self trackNamed:@"retry-first.wav"];
    AudioTrack *second = [self trackNamed:@"retry-second.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    [controller failNextStarts:1 forURL:first.url];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"failed scan retried"];
    controller.allStartsExpectation.expectedFulfillmentCount = 3;
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"both retry rows published"];
    delegate.deliveryExpectation.expectedFulfillmentCount = 2;
    NSObject *parseLock = [[NSObject alloc] init];
    NSMutableArray<NSURL *> *parsedURLs = [NSMutableArray array];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:1]
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        @synchronized (parseLock) {
            [parsedURLs addObject:url];
        }
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];

    [loader load:@[first, second]];
    [self waitForExpectations:@[
        controller.allStartsExpectation, delegate.deliveryExpectation
    ] timeout:2];

    XCTAssertEqualObjects(controller.startedURLs,
            (@[first.url, second.url, first.url]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
    @synchronized (parseLock) {
        XCTAssertEqualObjects(parsedURLs, (@[second.url, first.url]));
    }
    XCTAssertTrue(first.metadata.parsedOK);
    XCTAssertTrue(second.metadata.parsedOK);
}

- (void)testFailedScanStopsAtItsAttemptBudgetWithoutParsing {
    AudioTrack *track = [self trackNamed:@"retry-exhausted.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    [controller failNextStarts:2 forURL:track.url];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"attempt budget spent"];
    controller.allStartsExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:1]
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"an exhausted materialization must not parse");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader load:@[track]];
    [self waitForExpectations:@[controller.allStartsExpectation] timeout:2];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsFailed == 2;
    } description:@"second failed attempt did not settle"];
    [self waitForDelay:0.02];

    XCTAssertEqual(controller.startedURLs.count, 2u);
    XCTAssertNil(track.metadata);
    XCTAssertEqualObjects(_owner.parseCoordinator.pendingCounts,
            (@{@"holders": @0, @"waiters": @0}));
}

- (void)testDuplicateRowsShareOnePathAttemptBudget {
    NSURL *url = [self URLNamed:@"duplicate-exhausted-path.wav"];
    NSArray<AudioTrack *> *duplicates = @[
        [AudioTrack withURL:url],
        [AudioTrack withURL:url],
        [AudioTrack withURL:url],
    ];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    [controller failNextStarts:10 forURL:url];
    controller.allStartsExpectation =
            [self expectationWithDescription:@"shared path budget spent"];
    controller.allStartsExpectation.expectedFulfillmentCount = 2;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:1]
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        XCTFail(@"duplicates on an exhausted path must not parse");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader load:duplicates];
    [self waitForExpectations:@[controller.allStartsExpectation] timeout:2];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsFailed == 2;
    } description:@"duplicate path did not settle its shared attempt budget"];
    [self waitForDelay:0.05];

    XCTAssertEqual(controller.startedURLs.count, 2u,
            @"duplicate rows must not multiply a per-path attempt budget");
    XCTAssertEqualObjects([loader debugScanLaneState][@"pending"], (@[]));
    for (AudioTrack *track in duplicates) {
        XCTAssertNil(track.metadata);
    }
}

- (void)testSamePathScanAndPrioritySlotsSpendOneSharedPathBudget {
    NSURL *url = [self URLNamed:@"joined-duplicate-attempts.wav"];
    AudioTrack *scan = [AudioTrack withURL:url];
    AudioTrack *priority = [AudioTrack withURL:url];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"first duplicate scan held"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:2]
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *parsedURL) {
        XCTFail(@"duplicates on an exhausted path must not parse");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader load:@[scan, priority]];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];
    [loader prioritizeTrack:priority];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    [self waitForCondition:^BOOL{
        NSDictionary *lane = [loader debugPriorityLaneState];
        return [lane[@"pending"] count] == 1
                && [lane[@"liveTokens"] unsignedIntegerValue] == 0
                && [coordinator stateSnapshotForTesting].waiterCount == 1;
    } description:@"priority did not stay behind the active same-path scan claim"];

    [controller failNextStarts:10 forURL:url];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstFailed];
    [self waitForCondition:^BOOL{
        return controller.startedURLs.count >= 3;
    } description:@"remaining physical retries did not start"];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsFailed == 3;
    } description:@"three physical provider failures did not spend three attempts"];
    [self waitForDelay:0.05];

    XCTAssertEqual(controller.startedURLs.count, 3u,
            @"separate slot submissions must not multiply the shared path budget");
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
    ]));
    XCTAssertEqualObjects([loader debugPriorityLaneState][@"pending"], (@[]));
    XCTAssertEqualObjects([loader debugScanLaneState][@"pending"], (@[]));
    XCTAssertNil(scan.metadata);
    XCTAssertNil(priority.metadata);
}

- (void)testNewPriorityEdgeCannotResetAnExhaustedPathBudget {
    AudioTrack *track = [self trackNamed:@"priority-exhausted-path.wav"];
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"priority attempt started"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:[self testConfigurationWithRetryCount:0]
            cacheReader:^AudioTrackMetadata *(AudioTrack *candidate) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"an exhausted priority path must not parse");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];

    [loader prioritizeTrack:track];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];
    [loader prioritizeTrack:track];
    [controller completeFirstFailed];

    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsFailed == 1;
    } description:@"failed priority attempt did not spend its path budget"];
    [self waitForDelay:0.05];

    NSDictionary *priority = [loader debugPriorityLaneState];
    XCTAssertEqual(controller.startedURLs.count, 1u);
    XCTAssertEqualObjects(priority[@"pending"], (@[]));
    XCTAssertFalse([priority[@"inFlight"] boolValue]);
    XCTAssertEqual([priority[@"liveTokens"] unsignedIntegerValue], 0u);
    XCTAssertNil(track.metadata);
}

- (void)testProductionGatedTimerReopensADatalessScanAfterForegroundRelease {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"foreground started"];
    XCTestExpectation *cacheChecked =
            [self expectationWithDescription:@"scan stage one checked cache"];
    XCTestExpectation *parsed = [self expectationWithDescription:@"gated scan parsed"];
    NSObject *cacheLock = [[NSObject alloc] init];
    __block BOOL reportedCacheCheck = NO;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) {
        @synchronized (cacheLock) {
            if (!reportedCacheCheck) {
                reportedCacheCheck = YES;
                [cacheChecked fulfill];
            }
        }
        return nil;
    } fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-real-gate", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __block CFAbsoluteTime foregroundSettledAt = 0;
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-real-timer.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        foregroundSettledAt = CFAbsoluteTimeGetCurrent();
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"timer admitted gated scan"];
    AudioTrack *track = [self trackNamed:@"real-timer-scan.wav"];
    [loader load:@[track]];
    [self waitForExpectations:@[cacheChecked] timeout:2];
    [self waitForDelay:0.1];
    XCTAssertEqual(controller.startedURLs.count, 1u,
            @"dataless scan entered while foreground was active");

    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted] timeout:2];
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:2];

    XCTAssertGreaterThanOrEqual(CFAbsoluteTimeGetCurrent() - foregroundSettledAt, 0.65,
            @"scan reopened before the production gated timer fired");
    XCTAssertEqualObjects(controller.startedURLs, (@[
        [self URLNamed:@"foreground-real-timer.wav"], track.url
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
}

- (void)testYieldedPriorityWaitsWithoutSpinThenRetriesOnceWhenLocal {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation = [self expectationWithDescription:@"foreground started"];
    XCTestExpectation *parsed = [self expectationWithDescription:@"priority parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-yield-local", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-local.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];

    AudioTrack *priority = [self trackNamed:@"yielded-local.wav"];
    [loader prioritizeTrack:priority];
    [loader load:@[priority]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsYielded == 1;
    } description:@"priority request did not yield"];
    [self waitForDelay:0.02];
    for (NSUInteger kick = 0; kick < 8; kick++) {
        [loader setNeighborhoodURLs:@[priority.url]];
    }
    [self waitForDelay:0.05];
    XCTAssertEqual([coordinator stateSnapshotForTesting].requestsYielded, 1u,
            @"yielded priority record spun while the foreground was active");
    XCTAssertEqual(controller.startedURLs.count, 1u);

    controller.allStartsExpectation =
            [self expectationWithDescription:@"local priority retried"];
    [self markLocal:priority.url];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted] timeout:2];
    [loader recheckForegroundGate];
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:2];

    for (NSUInteger tick = 0; tick < 8; tick++) {
        [loader recheckForegroundGate];
    }
    [self waitForDelay:0.02];

    XCTAssertEqualObjects(controller.startedURLs, (@[
        [self URLNamed:@"foreground-local.wav"], priority.url
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
    ]));
    XCTAssertEqual([coordinator stateSnapshotForTesting].requestsYielded, 1u);
}

- (void)testYieldedPriorityDemotesToOrdinaryScanWhenStillDatalessAtRelease {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation = [self expectationWithDescription:@"foreground started"];
    XCTestExpectation *parsed = [self expectationWithDescription:@"demoted record parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-yield-demote", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-demote.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];

    AudioTrack *priority = [self trackNamed:@"yielded-dataless.wav"];
    [loader prioritizeTrack:priority];
    [loader load:@[priority]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsYielded == 1;
    } description:@"priority request did not yield"];
    [self waitForDelay:0.02];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"demoted scan started"];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted] timeout:2];
    [loader recheckForegroundGate];
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:2];

    for (NSUInteger tick = 0; tick < 8; tick++) {
        [loader recheckForegroundGate];
    }
    [self waitForDelay:0.02];

    XCTAssertEqualObjects(controller.startedURLs, (@[
        [self URLNamed:@"foreground-demote.wav"], priority.url
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
    XCTAssertEqual([coordinator stateSnapshotForTesting].requestsYielded, 1u);
}

- (void)testUnrelatedIdleKickJudgesYieldBeforePickingPriorityAgain {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"foreground started"];
    XCTestExpectation *parsed =
            [self expectationWithDescription:@"idle-demoted record parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-idle-kick", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-idle-kick.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];

    AudioTrack *priority = [self trackNamed:@"idle-kick-dataless.wav"];
    [loader prioritizeTrack:priority];
    [loader load:@[priority]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsYielded == 1
                && [[loader debugPriorityLaneState][@"yieldedUnderHold"]
                        unsignedIntegerValue] == 1;
    } description:@"priority record did not park after yielding"];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"idle kick started ordinary scan"];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted] timeout:2];
    [loader setNeighborhoodURLs:@[priority.url]];
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:2];

    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
    XCTAssertEqual([coordinator stateSnapshotForTesting].requestsYielded, 1u);
}

- (void)testRepeatPriorityEdgeJoinsNewSamePathForegroundClaim {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"first foreground started"];
    XCTestExpectation *parsed =
            [self expectationWithDescription:@"same-path waiter parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-same-path-repeat", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *firstCompleted =
            [self expectationWithDescription:@"first foreground completed"];
    __unused AudioFileMaterializationRequestToken *firstToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-before-same-path.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        [firstCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];

    AudioTrack *priority = [self trackNamed:@"same-path-repeat.wav"];
    [loader prioritizeTrack:priority];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsYielded == 1
                && [[loader debugPriorityLaneState][@"yieldedUnderHold"]
                        unsignedIntegerValue] == 1;
    } description:@"first priority edge did not yield and park"];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"same-path playback started"];
    [controller completeFirstReady];
    [self waitForExpectations:@[firstCompleted] timeout:2];
    XCTestExpectation *samePathCompleted =
            [self expectationWithDescription:@"same-path playback completed"];
    __unused AudioFileMaterializationRequestToken *samePathToken = [coordinator
            materializeURL:priority.url
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        [samePathCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.allStartsExpectation] timeout:2];

    [loader prioritizeTrack:priority];
    [self waitForCondition:^BOOL{
        VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
                [coordinator stateSnapshotForTesting];
        NSDictionary *state = [loader debugPriorityLaneState];
        return snapshot.waiterCount == 2
                && [state[@"inFlight"] boolValue]
                && [state[@"liveTokens"] unsignedIntegerValue] == 1;
    } description:@"repeat edge did not join the active same-path claim"];

    [controller completeLastReady];
    [self waitForExpectations:@[samePathCompleted, parsed] timeout:2];

    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRolePlayback),
    ]), @"the metadata waiter must not start another provider operation");
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
            [coordinator stateSnapshotForTesting];
    XCTAssertEqual(snapshot.requestsYielded, 1u);
    XCTAssertEqual(snapshot.requestsReady, 3u,
            @"both foreground owners and the metadata waiter must settle Ready");
}

- (void)testFreshPriorityMarkSurvivesOlderYieldJudgementProbe {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"foreground started"];
    XCTestExpectation *parsed =
            [self expectationWithDescription:@"fresh priority parsed"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [parsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-priority-revision", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-priority-revision.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];

    AudioTrack *priority = [self trackNamed:@"priority-revision.wav"];
    [loader prioritizeTrack:priority];
    [loader load:@[priority]];
    [self waitForCondition:^BOOL{
        NSDictionary *state = [loader debugPriorityLaneState];
        return [coordinator stateSnapshotForTesting].requestsYielded == 1
                && [state[@"yieldedUnderHold"] unsignedIntegerValue] == 1;
    } description:@"priority request did not park after yielding"];

    dispatch_semaphore_t probeGate = dispatch_semaphore_create(0);
    XCTestExpectation *probeEntered =
            [self expectationWithDescription:@"old mark locality probe entered"];
    NSObject *probeLock = [[NSObject alloc] init];
    __block BOOL shouldGateProbe = YES;
    [NSURLUtil setDatalessProbe:^BOOL(NSURL *url) {
        BOOL gate = NO;
        if ([url isEqual:priority.url]) {
            @synchronized (probeLock) {
                gate = shouldGateProbe;
                shouldGateProbe = NO;
            }
        }
        if (gate) {
            [probeEntered fulfill];
            dispatch_semaphore_wait(probeGate, DISPATCH_TIME_FOREVER);
        }
        return YES;
    }];

    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted, probeEntered] timeout:2];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"fresh priority mark retried"];
    [loader prioritizeTrack:priority];
    dispatch_semaphore_signal(probeGate);
    [self waitForExpectations:@[controller.allStartsExpectation, parsed] timeout:2];

    XCTAssertEqualObjects(controller.startedURLs, (@[
        [self URLNamed:@"foreground-priority-revision.wav"], priority.url
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRolePlayback),
        @(VibeAudioFileMaterializationRoleMetadataPriority),
    ]));
}

- (void)testCancellingYieldedPriorityDropsItBeforeForegroundRelease {
    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation = [self expectationWithDescription:@"foreground started"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"cancelled yielded record parsed");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-yield-cancel", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *foregroundCompleted =
            [self expectationWithDescription:@"foreground completed"];
    __unused AudioFileMaterializationRequestToken *foregroundToken = [coordinator
            materializeURL:[self URLNamed:@"foreground-cancel.wav"]
                      role:VibeAudioFileMaterializationRolePlayback
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        [foregroundCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];

    AudioTrack *priority = [self trackNamed:@"yielded-cancel.wav"];
    [loader prioritizeTrack:priority];
    [loader load:@[priority]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsYielded == 1;
    } description:@"priority request did not yield"];
    [self waitForDelay:0.02];
    [loader cancel];

    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[foregroundCompleted] timeout:2];
    for (NSUInteger tick = 0; tick < 8; tick++) {
        [loader recheckForegroundGate];
    }
    [self waitForDelay:1.05];
    XCTAssertEqual(controller.startedURLs.count, 1u,
            @"cancelled yielded record was readmitted by the gated timer");
}

- (void)testCancellingAdmissionDelayedRecordPreventsItsRetry {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundPendingMaterializations = 1;
    values.metadataRetryCount = 1;
    NSError *configurationError = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&configurationError];
    XCTAssertNotNil(configuration);
    XCTAssertNil(configurationError);

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation = [self expectationWithDescription:@"lane occupied"];
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:configuration
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"cancelled delayed record parsed");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-delay-cancel", DISPATCH_QUEUE_SERIAL);
    __unused AudioFileMaterializationRequestToken *running = [coordinator
            materializeURL:[self URLNamed:@"running-background.wav"]
                      role:VibeAudioFileMaterializationRoleMetadataScan
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {}];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];
    AudioFileMaterializationRequestToken *pending = [coordinator
            materializeURL:[self URLNamed:@"pending-background.wav"]
                      role:VibeAudioFileMaterializationRoleMetadataScan
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {}];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    } description:@"background pending slot was not occupied"];

    [loader load:@[[self trackNamed:@"delayed.wav"]]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsAdmissionExhausted == 1;
    } description:@"loader request was not admission exhausted"];
    [self waitForDelay:0.02];
    NSDictionary *delayedState = [loader debugScanLaneState];
    XCTAssertEqualObjects(delayedState[@"pending"], (@[]));
    XCTAssertEqualObjects(delayedState[@"delayed"], (@[@"delayed.wav"]));
    XCTAssertEqualObjects(delayedState[@"inFlight"], @NO);
    XCTAssertEqualObjects(delayedState[@"stageOneFinished"], @YES);
    [loader cancel];
    [pending cancel];
    [running cancel];

    [self waitForDelay:0.35];
    XCTAssertEqual(controller.startedURLs.count, 1u,
            @"cancelled delayed record retried after its eligibility edge");
    XCTAssertEqual([coordinator stateSnapshotForTesting].requestsAdmissionExhausted, 1u);
}

- (void)testAdmissionDelayedRecordRetriesOnceAfterCapacityFreesAndPublishes {
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumBackgroundPendingMaterializations = 1;
    values.metadataRetryCount = 1;
    NSError *configurationError = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&configurationError];
    XCTAssertNotNil(configuration);
    XCTAssertNil(configurationError);

    VibeMetadataLoaderOperationController *controller =
            [[VibeMetadataLoaderOperationController alloc] init];
    controller.blocksUntilCancelled = YES;
    controller.firstStartExpectation =
            [self expectationWithDescription:@"background lane occupied"];
    VibeMetadataLoaderDelegate *delegate = [[VibeMetadataLoaderDelegate alloc] init];
    delegate.deliveryExpectation =
            [self expectationWithDescription:@"retried metadata published"];
    __block NSUInteger parseCount = 0;
    AudioTrackMetadataLoader *loader = [self loaderWithController:controller
            configuration:configuration
            delegate:delegate
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        parseCount++;
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    AudioFileMaterializationCoordinator *coordinator = _coordinators.lastObject;
    dispatch_queue_t completionQueue = dispatch_queue_create(
            "com.vibe.tests.metadata-delay-retry", DISPATCH_QUEUE_SERIAL);
    XCTestExpectation *runningCompleted =
            [self expectationWithDescription:@"running claim completed"];
    __unused AudioFileMaterializationRequestToken *running = [coordinator
            materializeURL:[self URLNamed:@"retry-running-background.wav"]
                      role:VibeAudioFileMaterializationRoleMetadataScan
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {
        XCTAssertEqual(result, VibeAudioFileMaterializationResultReady);
        [runningCompleted fulfill];
    }];
    [self waitForExpectations:@[controller.firstStartExpectation] timeout:2];
    AudioFileMaterializationRequestToken *pending = [coordinator
            materializeURL:[self URLNamed:@"retry-pending-background.wav"]
                      role:VibeAudioFileMaterializationRoleMetadataScan
           completionQueue:completionQueue
                completion:^(VibeAudioFileMaterializationResult result,
                             NSError *error, NSTimeInterval elapsed) {}];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].backgroundPendingCount == 1;
    } description:@"background pending slot was not occupied"];

    AudioTrack *target = [self trackNamed:@"retry-after-admission.wav"];
    [loader load:@[target]];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].requestsAdmissionExhausted == 1;
    } description:@"loader request was not admission exhausted"];
    [self waitForCondition:^BOOL{
        return [[loader debugScanLaneState][@"delayed"]
                containsObject:target.url.lastPathComponent];
    } description:@"admission-exhausted record did not enter the delayed set"];

    controller.allStartsExpectation =
            [self expectationWithDescription:@"delayed retry started"];
    [pending cancel];
    [self waitForCondition:^BOOL{
        return [coordinator stateSnapshotForTesting].backgroundPendingCount == 0;
    } description:@"cancelled pending claim retained its capacity"];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstReady];
    [self waitForExpectations:@[runningCompleted] timeout:2];
    [self waitForExpectations:@[
        controller.allStartsExpectation, delegate.deliveryExpectation
    ] timeout:2];

    XCTAssertEqual(parseCount, 1u);
    XCTAssertTrue(target.metadata.parsedOK);
    XCTAssertTrue(delegate.allDeliveriesOnMain);
    XCTAssertEqualObjects(controller.startedURLs, (@[
        [self URLNamed:@"retry-running-background.wav"], target.url
    ]));
    XCTAssertEqualObjects(controller.startedRoles, (@[
        @(VibeAudioFileMaterializationRoleMetadataScan),
        @(VibeAudioFileMaterializationRoleMetadataScan),
    ]));
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
            [coordinator stateSnapshotForTesting];
    XCTAssertEqual(snapshot.requestsAdmissionExhausted, 1u);
    XCTAssertEqual(snapshot.requestsReady, 2u);
}

- (void)testCancellingReplacedLoaderDropsItsPendingRecordsAndToken {
    VibeMetadataLoaderOperationController *oldController =
            [[VibeMetadataLoaderOperationController alloc] init];
    oldController.blocksUntilCancelled = YES;
    oldController.firstStartExpectation = [self expectationWithDescription:@"old started"];
    oldController.cancellationExpectation = [self expectationWithDescription:@"old cancelled"];
    AudioTrackMetadataLoader *oldLoader = [self loaderWithController:oldController
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        XCTFail(@"cancelled loader parsed a track");
        return VibeLoaderTestMetadataResult(NO, @"unexpected");
    }];
    [oldLoader load:@[
        [self trackNamed:@"old-zero.wav"],
        [self trackNamed:@"old-one.wav"],
        [self trackNamed:@"old-two.wav"],
    ]];
    [self waitForExpectations:@[oldController.firstStartExpectation] timeout:2];
    [oldLoader cancel];
    [self waitForExpectations:@[oldController.cancellationExpectation] timeout:2];

    VibeMetadataLoaderOperationController *newController =
            [[VibeMetadataLoaderOperationController alloc] init];
    newController.firstStartExpectation = [self expectationWithDescription:@"replacement started"];
    XCTestExpectation *replacementParsed = [self expectationWithDescription:@"replacement parsed"];
    AudioTrackMetadataLoader *replacement = [self loaderWithController:newController
            cacheReader:^AudioTrackMetadata *(AudioTrack *track) { return nil; }
            fileParser:^AudioTrackMetadata *(NSURL *url) {
        [replacementParsed fulfill];
        return VibeLoaderTestMetadataResult(YES, url.lastPathComponent);
    }];
    [replacement load:@[[self trackNamed:@"new.wav"]]];
    [self waitForExpectations:@[newController.firstStartExpectation, replacementParsed] timeout:2];

    XCTestExpectation *oldCallbackDrained = [self expectationWithDescription:@"old callback drained"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [oldCallbackDrained fulfill];
    });
    [self waitForExpectations:@[oldCallbackDrained] timeout:1];
    XCTAssertEqual(oldController.startedURLs.count, 1u,
            @"cancelled loader admitted another pending record");
}

@end
