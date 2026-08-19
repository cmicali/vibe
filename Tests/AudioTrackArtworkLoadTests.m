//
//  AudioTrackArtworkLoadTests.m
//
//  Bounded art admission, materialization ordering, and generation fencing.
//

#import <XCTest/XCTest.h>

#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioTrackArtworkInternal.h"
#import "AudioWorkScheduler.h"

@interface ArtworkLoadTestMaterializationOperation : NSObject <AudioFileMaterializationOperation>
- (instancetype)initWithRun:(BOOL (^)(NSError **error))run;
@end

@implementation ArtworkLoadTestMaterializationOperation {
    BOOL (^_run)(NSError **error);
}

- (instancetype)initWithRun:(BOOL (^)(NSError **))run {
    self = [super init];
    if (self) {
        _run = [run copy];
    }
    return self;
}

- (BOOL)runWithError:(NSError **)error {
    return _run(error);
}

- (void)cancel {
}

@end

@interface ArtworkLoadSequenceMaterializationCoordinator :
        AudioFileMaterializationCoordinator
- (instancetype)initWithResults:(NSArray<NSNumber *> *)results;
@property (nonatomic, readonly) NSUInteger attemptCount;
@end

@implementation ArtworkLoadSequenceMaterializationCoordinator {
    NSArray<NSNumber *> *_results;
    NSUInteger _attemptCount;
}

- (instancetype)initWithResults:(NSArray<NSNumber *> *)results {
    self = [super initWithConfiguration:[AudioLoadingConfiguration productionConfiguration]
            operationFactory:^id<AudioFileMaterializationOperation>(
                    NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[ArtworkLoadTestMaterializationOperation alloc]
                initWithRun:^BOOL(NSError **error) { return YES; }];
    } clock:^NSTimeInterval{ return NSProcessInfo.processInfo.systemUptime; }];
    if (self) {
        _results = [results copy];
    }
    return self;
}

- (NSUInteger)attemptCount {
    return _attemptCount;
}

- (AudioFileMaterializationRequestToken *)materializeURL:(NSURL *)url
        role:(VibeAudioFileMaterializationRole)role
        completionQueue:(dispatch_queue_t)completionQueue
        registered:(dispatch_block_t)registered
        completion:(VibeAudioFileMaterializationCompletion)completion {
    NSUInteger index = MIN(_attemptCount, _results.count - 1);
    VibeAudioFileMaterializationResult result =
            (VibeAudioFileMaterializationResult)_results[index].unsignedIntegerValue;
    _attemptCount++;
    dispatch_async(completionQueue, ^{
        if (registered && result == VibeAudioFileMaterializationResultReady) {
            registered();
        }
        completion(result, nil, 0);
    });
    // This fake delivers asynchronously but has nothing to cancel.
    return nil;
}

@end

@interface ArtworkLoadObservingWorkScheduler : AudioWorkScheduler
@property (nonatomic, copy, nullable) void (^rejectionObserved)(
        VibeAudioWorkAdmissionFailure failure);
@end

@implementation ArtworkLoadObservingWorkScheduler

- (AudioWorkToken *)submitWork:(dispatch_block_t)work
                   failureQueue:(dispatch_queue_t)failureQueue
              admissionFailure:(void (^)(VibeAudioWorkAdmissionFailure failure))admissionFailure {
    void (^rejectionObserved)(VibeAudioWorkAdmissionFailure) = self.rejectionObserved;
    return [super submitWork:work failureQueue:failureQueue
            admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        if (rejectionObserved) {
            rejectionObserved(failure);
        }
        admissionFailure(failure);
    }];
}

@end

@interface AudioTrackArtworkLoadTests : XCTestCase
@end

@implementation AudioTrackArtworkLoadTests

- (AudioWorkScheduler *)scheduler {
    return [[AudioWorkScheduler alloc]
            initWithLabel:@"com.vibe.tests.artwork"
            qualityOfService:QOS_CLASS_USER_INITIATED
            maximumRunningCount:2
            maximumPendingCount:5
            pendingGrace:5];
}

- (AudioFileMaterializationCoordinator *)materializationWithFactory:
        (VibeAudioFileMaterializationOperationFactory)factory {
    return [[AudioFileMaterializationCoordinator alloc]
            initWithConfiguration:[AudioLoadingConfiguration productionConfiguration]
            operationFactory:factory
            clock:^NSTimeInterval{ return NSProcessInfo.processInfo.systemUptime; }];
}

- (void)installServicesWithFactory:(VibeAudioFileMaterializationOperationFactory)factory {
    [AudioTrackArtwork installArtLoadServicesForTesting:
            [self materializationWithFactory:factory]
                                          workScheduler:[self scheduler]];
}

- (NSData *)embeddedArtData {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(8, 8)];
    [image lockFocus];
    [NSColor.blueColor setFill];
    NSRectFill(NSMakeRect(0, 0, 8, 8));
    [image unlockFocus];
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithData:image.TIFFRepresentation];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

- (AudioTrackArtwork *)unloadedArtworkAtPath:(NSString *)path
                                   extractor:(AudioTrackArtworkExtractor)extractor {
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc]
            initWithSourceFilePath:path extractor:extractor];
    artwork.folderArt = nil;
    [artwork adoptArchivedThumbnailData:nil hasEmbeddedArt:YES];
    return artwork;
}

- (void)testSourceReadMaterializesAtMetadataPriorityBeforeExtraction {
    XCTestExpectation *materializationStarted =
            [self expectationWithDescription:@"materialization started"];
    XCTestExpectation *completed = [self expectationWithDescription:@"completed"];
    dispatch_semaphore_t releaseMaterialization = dispatch_semaphore_create(0);
    NSLock *stateLock = [NSLock new];
    __block VibeAudioFileMaterializationRole observedRole =
            VibeAudioFileMaterializationRoleMetadataScan;
    __block NSUInteger extractionCount = 0;
    [self installServicesWithFactory:^id<AudioFileMaterializationOperation>(
            NSURL *url, VibeAudioFileMaterializationRole role) {
        [stateLock lock];
        observedRole = role;
        [stateLock unlock];
        return [[ArtworkLoadTestMaterializationOperation alloc]
                initWithRun:^BOOL(NSError **error) {
            [materializationStarted fulfill];
            dispatch_semaphore_wait(releaseMaterialization, DISPATCH_TIME_FOREVER);
            return YES;
        }];
    }];
    AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:@"/tmp/priority-art.flac"
            extractor:^VibeEmbeddedArtExtractionResult(
                    NSString *path, NSData *__autoreleasing *artData) {
        [stateLock lock];
        extractionCount++;
        [stateLock unlock];
        return VibeEmbeddedArtExtractionNoArt;
    }];

    [artwork loadArtIfNeededWithLabel:@"priority" stillWanted:^{ return YES; }
            completion:^(NSImage *image) {
        XCTAssertNil(image);
        [completed fulfill];
    }];

    [self waitForExpectations:@[materializationStarted] timeout:1];
    [stateLock lock];
    VibeAudioFileMaterializationRole finalRole = observedRole;
    NSUInteger countBeforeRelease = extractionCount;
    [stateLock unlock];
    XCTAssertEqual(finalRole, VibeAudioFileMaterializationRoleMetadataPriority);
    XCTAssertEqual(countBeforeRelease, 0u);
    dispatch_semaphore_signal(releaseMaterialization);
    [self waitForExpectations:@[completed] timeout:1];
    XCTAssertFalse(artwork.artLoadPending);
}

- (void)testExpectedGenerationIsCheckedBeforeClaimingSourceRead {
    __block NSUInteger extractionCount = 0;
    AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:@"/tmp/fenced-art.flac"
            extractor:^VibeEmbeddedArtExtractionResult(
                    NSString *path, NSData *__autoreleasing *artData) {
        extractionCount++;
        return VibeEmbeddedArtExtractionNoArt;
    }];

    [artwork discardDecodedArt];
    XCTAssertNil([artwork loadArtBlockingForExpectedGeneration:0
                                          sourceFileReadAllowed:YES]);
    XCTAssertEqual(extractionCount, 0u);
    XCTAssertTrue(artwork.artNeedsLoad,
                  @"the current generation remains armed for its own request");
}

- (void)testConclusiveNilCompletesExactlyOnce {
    NSLock *stateLock = [NSLock new];
    __block NSUInteger materializationCount = 0;
    __block NSUInteger extractionCount = 0;
    [self installServicesWithFactory:^id<AudioFileMaterializationOperation>(
            NSURL *url, VibeAudioFileMaterializationRole role) {
        [stateLock lock];
        materializationCount++;
        [stateLock unlock];
        return [[ArtworkLoadTestMaterializationOperation alloc]
                initWithRun:^BOOL(NSError **error) { return YES; }];
    }];
    AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:@"/tmp/artless.flac"
            extractor:^VibeEmbeddedArtExtractionResult(
                    NSString *path, NSData *__autoreleasing *artData) {
        [stateLock lock];
        extractionCount++;
        [stateLock unlock];
        return VibeEmbeddedArtExtractionNoArt;
    }];
    XCTestExpectation *completed = [self expectationWithDescription:@"completed"];
    __block NSUInteger completionCount = 0;

    [artwork loadArtIfNeededWithLabel:@"artless" stillWanted:^{ return YES; }
            completion:^(NSImage *image) {
        completionCount++;
        XCTAssertNil(image);
        [completed fulfill];
    }];
    [self waitForExpectations:@[completed] timeout:2];

    [stateLock lock];
    NSUInteger finalMaterializationCount = materializationCount;
    NSUInteger finalExtractionCount = extractionCount;
    [stateLock unlock];
    XCTAssertEqual(finalMaterializationCount, 1u);
    XCTAssertEqual(finalExtractionCount, 1u);
    XCTAssertEqual(completionCount, 1u);
    XCTAssertFalse(artwork.artNeedsLoad);
    XCTAssertFalse(artwork.artLoadPending);
}

- (void)testYieldedMaterializationDoesNotSpendTheFailureBudget {
    NSData *embedded = [self embeddedArtData];
    ArtworkLoadSequenceMaterializationCoordinator *materialization =
            [[ArtworkLoadSequenceMaterializationCoordinator alloc] initWithResults:@[
        @(VibeAudioFileMaterializationResultYielded),
        @(VibeAudioFileMaterializationResultYielded),
        @(VibeAudioFileMaterializationResultYielded),
        @(VibeAudioFileMaterializationResultReady),
    ]];
    [AudioTrackArtwork installArtLoadServicesForTesting:materialization
                                          workScheduler:[self scheduler]];
    AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:@"/tmp/yielded.flac"
            extractor:^VibeEmbeddedArtExtractionResult(
                    NSString *path, NSData *__autoreleasing *artData) {
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    XCTestExpectation *completed = [self expectationWithDescription:@"completed after hold"];

    [artwork loadArtIfNeededWithLabel:@"yielded" stillWanted:^{ return YES; }
            completion:^(NSImage *image) {
        XCTAssertNotNil(image);
        [completed fulfill];
    }];
    [self waitForExpectations:@[completed] timeout:2];

    XCTAssertEqual(materialization.attemptCount, 4u,
                   @"three yields do not exhaust the three-failure budget");
    XCTAssertFalse(artwork.artLoadPending);
}

- (void)testAdmissionExhaustionRemainsPendingUntilCapacityRecovers {
    NSData *embedded = [self embeddedArtData];
    ArtworkLoadSequenceMaterializationCoordinator *materialization =
            [[ArtworkLoadSequenceMaterializationCoordinator alloc] initWithResults:@[
        @(VibeAudioFileMaterializationResultAdmissionExhausted),
        @(VibeAudioFileMaterializationResultAdmissionExhausted),
        @(VibeAudioFileMaterializationResultAdmissionExhausted),
        @(VibeAudioFileMaterializationResultReady),
    ]];
    [AudioTrackArtwork installArtLoadServicesForTesting:materialization
                                          workScheduler:[self scheduler]];
    AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:@"/tmp/admission.flac"
            extractor:^VibeEmbeddedArtExtractionResult(
                    NSString *path, NSData *__autoreleasing *artData) {
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    XCTestExpectation *completed =
            [self expectationWithDescription:@"completed after capacity returned"];
    __block NSUInteger completionCount = 0;

    [artwork loadArtIfNeededWithLabel:@"admission" stillWanted:^{ return YES; }
            completion:^(NSImage *image) {
        completionCount++;
        XCTAssertNotNil(image);
        [completed fulfill];
    }];
    XCTAssertTrue(artwork.artLoadPending);
    [self waitForExpectations:@[completed] timeout:2];

    XCTAssertEqual(materialization.attemptCount, 4u);
    XCTAssertEqual(completionCount, 1u);
    XCTAssertFalse(artwork.artLoadPending);
}

- (void)testWorkerAdmissionExhaustionRetriesAfterSlotReturns {
    NSData *embedded = [self embeddedArtData];
    AudioWorkScheduler *scheduler = [[AudioWorkScheduler alloc]
            initWithLabel:@"com.vibe.tests.artwork-admission"
            qualityOfService:QOS_CLASS_USER_INITIATED
            maximumRunningCount:1
            maximumPendingCount:0
            pendingGrace:5];
    XCTestExpectation *blockerStarted =
            [self expectationWithDescription:@"worker slot occupied"];
    dispatch_semaphore_t releaseBlocker = dispatch_semaphore_create(0);
    [scheduler submitWork:^{
        [blockerStarted fulfill];
        dispatch_semaphore_wait(releaseBlocker, DISPATCH_TIME_FOREVER);
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTFail(@"blocker was rejected: %ld", (long)failure);
    }];
    [self waitForExpectations:@[blockerStarted] timeout:1];

    [AudioTrackArtwork installArtLoadServicesForTesting:
            [self materializationWithFactory:^id<AudioFileMaterializationOperation>(
                    NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[ArtworkLoadTestMaterializationOperation alloc]
                initWithRun:^BOOL(NSError **error) { return YES; }];
    }] workScheduler:scheduler];
    AudioTrackArtwork *artwork = [[AudioTrackArtwork alloc]
            initWithSourceFilePath:@"/tmp/in-memory-art.flac"
                         extractor:^VibeEmbeddedArtExtractionResult(
                                 NSString *path, NSData *__autoreleasing *artData) {
        return VibeEmbeddedArtExtractionReadFailed;
    }];
    artwork.folderArt = nil;
    [artwork adoptParsedArtData:embedded];
    XCTestExpectation *completed =
            [self expectationWithDescription:@"completed after worker slot returned"];
    __block NSUInteger completionCount = 0;

    [artwork loadArtIfNeededWithLabel:@"worker admission" stillWanted:^{ return YES; }
            completion:^(NSImage *image) {
        completionCount++;
        XCTAssertNotNil(image);
        [completed fulfill];
    }];
    XCTAssertTrue(artwork.artLoadPending);
    dispatch_semaphore_signal(releaseBlocker);
    [self waitForExpectations:@[completed] timeout:2];

    XCTAssertEqual(completionCount, 1u);
    XCTAssertFalse(artwork.artLoadPending);
}

- (void)testSourceReadRematerializesAfterWorkerAdmissionReturns {
    NSData *embedded = [self embeddedArtData];
    ArtworkLoadObservingWorkScheduler *scheduler =
            [[ArtworkLoadObservingWorkScheduler alloc]
            initWithLabel:@"com.vibe.tests.source-artwork-admission"
            qualityOfService:QOS_CLASS_USER_INITIATED
            maximumRunningCount:1
            maximumPendingCount:1
            pendingGrace:5];
    XCTestExpectation *blockerStarted =
            [self expectationWithDescription:@"worker slot occupied"];
    dispatch_semaphore_t releaseBlocker = dispatch_semaphore_create(0);
    [scheduler submitWork:^{
        [blockerStarted fulfill];
        dispatch_semaphore_wait(releaseBlocker, DISPATCH_TIME_FOREVER);
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTFail(@"blocker was rejected: %ld", (long)failure);
    }];
    [self waitForExpectations:@[blockerStarted] timeout:1];

    NSLock *stateLock = [NSLock new];
    __block NSUInteger parkedWorkCount = 0;
    AudioWorkToken *parked = [scheduler submitWork:^{
        [stateLock lock];
        parkedWorkCount++;
        [stateLock unlock];
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        XCTFail(@"the pending blocker was rejected: %ld", (long)failure);
    }];

    XCTestExpectation *workerRejected =
            [self expectationWithDescription:@"source extraction rejected"];
    scheduler.rejectionObserved = ^(VibeAudioWorkAdmissionFailure failure) {
        XCTAssertEqual(failure, VibeAudioWorkAdmissionFailurePendingLimit);
        [workerRejected fulfill];
    };
    __block NSUInteger materializationCount = 0;
    __block NSUInteger extractionCount = 0;
    [AudioTrackArtwork installArtLoadServicesForTesting:
            [self materializationWithFactory:^id<AudioFileMaterializationOperation>(
                    NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[ArtworkLoadTestMaterializationOperation alloc]
                initWithRun:^BOOL(NSError **error) {
            [stateLock lock];
            materializationCount++;
            [stateLock unlock];
            return YES;
        }];
    }] workScheduler:scheduler];
    AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:
            @"/tmp/source-worker-admission.flac"
            extractor:^VibeEmbeddedArtExtractionResult(
                    NSString *path, NSData *__autoreleasing *artData) {
        [stateLock lock];
        extractionCount++;
        [stateLock unlock];
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    XCTestExpectation *completed =
            [self expectationWithDescription:@"source art completed after retry"];
    __block NSUInteger completionCount = 0;

    [artwork loadArtIfNeededWithLabel:@"source worker admission"
            stillWanted:^{ return YES; }
            completion:^(NSImage *image) {
        completionCount++;
        XCTAssertNotNil(image);
        [completed fulfill];
    }];
    [self waitForExpectations:@[workerRejected] timeout:1];

    scheduler.rejectionObserved = nil;
    XCTAssertTrue([parked cancelIfPending]);
    dispatch_semaphore_signal(releaseBlocker);
    [self waitForExpectations:@[completed] timeout:2];

    [stateLock lock];
    NSUInteger finalMaterializationCount = materializationCount;
    NSUInteger finalExtractionCount = extractionCount;
    NSUInteger finalParkedWorkCount = parkedWorkCount;
    [stateLock unlock];
    XCTAssertEqual(finalMaterializationCount, 2u);
    XCTAssertEqual(finalExtractionCount, 1u);
    XCTAssertEqual(finalParkedWorkCount, 0u);
    XCTAssertEqual(completionCount, 1u);
    XCTAssertFalse(artwork.artLoadPending);
}

- (void)testTransientMaterializationFailuresRecoverWithinTheBound {
    NSData *embedded = [self embeddedArtData];
    NSLock *stateLock = [NSLock new];
    __block NSUInteger operationRunCount = 0;
    [self installServicesWithFactory:^id<AudioFileMaterializationOperation>(
            NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[ArtworkLoadTestMaterializationOperation alloc]
                initWithRun:^BOOL(NSError **error) {
            [stateLock lock];
            operationRunCount++;
            BOOL ready = operationRunCount == 3;
            [stateLock unlock];
            if (!ready && error) {
                *error = [NSError errorWithDomain:@"ArtworkLoadTests" code:1 userInfo:nil];
            }
            return ready;
        }];
    }];
    AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:@"/tmp/recovered.flac"
            extractor:^VibeEmbeddedArtExtractionResult(
                    NSString *path, NSData *__autoreleasing *artData) {
        *artData = embedded;
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    XCTestExpectation *completed = [self expectationWithDescription:@"recovered"];

    [artwork loadArtIfNeededWithLabel:@"recovered" stillWanted:^{ return YES; }
            completion:^(NSImage *image) {
        XCTAssertNotNil(image);
        [completed fulfill];
    }];
    [self waitForExpectations:@[completed] timeout:2];

    [stateLock lock];
    NSUInteger finalOperationRunCount = operationRunCount;
    [stateLock unlock];
    XCTAssertEqual(finalOperationRunCount, 3u);
    XCTAssertFalse(artwork.artLoadPending);
}

- (void)testPersistentMaterializationFailureStopsAfterThreeAttempts {
    NSLock *stateLock = [NSLock new];
    __block NSUInteger operationRunCount = 0;
    __block NSUInteger extractionCount = 0;
    [self installServicesWithFactory:^id<AudioFileMaterializationOperation>(
            NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[ArtworkLoadTestMaterializationOperation alloc]
                initWithRun:^BOOL(NSError **error) {
            [stateLock lock];
            operationRunCount++;
            [stateLock unlock];
            if (error) {
                *error = [NSError errorWithDomain:@"ArtworkLoadTests" code:2 userInfo:nil];
            }
            return NO;
        }];
    }];
    AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:@"/tmp/failed.flac"
            extractor:^VibeEmbeddedArtExtractionResult(
                    NSString *path, NSData *__autoreleasing *artData) {
        [stateLock lock];
        extractionCount++;
        [stateLock unlock];
        return VibeEmbeddedArtExtractionNoArt;
    }];
    XCTestExpectation *completed = [self expectationWithDescription:@"bounded failure"];
    __block NSUInteger completionCount = 0;

    [artwork loadArtIfNeededWithLabel:@"failed" stillWanted:^{ return YES; }
            completion:^(NSImage *image) {
        completionCount++;
        XCTAssertNil(image);
        [completed fulfill];
    }];
    [self waitForExpectations:@[completed] timeout:2];

    [stateLock lock];
    NSUInteger finalOperationRunCount = operationRunCount;
    NSUInteger finalExtractionCount = extractionCount;
    [stateLock unlock];
    XCTAssertEqual(finalOperationRunCount, 3u);
    XCTAssertEqual(finalExtractionCount, 0u);
    XCTAssertEqual(completionCount, 1u);
    XCTAssertTrue(artwork.artNeedsLoad);
    XCTAssertFalse(artwork.artLoadPending);
}

- (void)testEighthWantedRequestWaitsForCapacityAndThenCompletes {
    [self installServicesWithFactory:^id<AudioFileMaterializationOperation>(
            NSURL *url, VibeAudioFileMaterializationRole role) {
        return [[ArtworkLoadTestMaterializationOperation alloc]
                initWithRun:^BOOL(NSError **error) { return YES; }];
    }];
    NSMutableArray<XCTestExpectation *> *completed = [NSMutableArray array];
    NSMutableArray<AudioTrackArtwork *> *artworks = [NSMutableArray array];
    __block NSUInteger waitingCompletionCount = 0;

    for (NSUInteger index = 0; index < 7; index++) {
        AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:
                [NSString stringWithFormat:@"/tmp/bounded-%lu.flac", (unsigned long)index]
                extractor:^VibeEmbeddedArtExtractionResult(
                        NSString *path, NSData *__autoreleasing *artData) {
            return VibeEmbeddedArtExtractionNoArt;
        }];
        XCTestExpectation *expectation = [self expectationWithDescription:
                [NSString stringWithFormat:@"request %lu", (unsigned long)index]];
        [completed addObject:expectation];
        [artworks addObject:artwork];
        [artwork loadArtIfNeededWithLabel:@"bounded" stillWanted:^{ return YES; }
                completion:^(NSImage *image) { [expectation fulfill]; }];
        XCTAssertTrue(artwork.artLoadPending);
    }

    AudioTrackArtwork *waiting = [self unloadedArtworkAtPath:@"/tmp/waiting.flac"
            extractor:^VibeEmbeddedArtExtractionResult(
                    NSString *path, NSData *__autoreleasing *artData) {
        return VibeEmbeddedArtExtractionNoArt;
    }];
    XCTestExpectation *waitingCompleted =
            [self expectationWithDescription:@"waiting request completed"];
    [completed addObject:waitingCompleted];
    [waiting loadArtIfNeededWithLabel:@"waiting" stillWanted:^{ return YES; }
            completion:^(NSImage *image) {
        waitingCompletionCount++;
        [waitingCompleted fulfill];
    }];
    XCTAssertTrue(waiting.artLoadPending);

    [self waitForExpectations:completed timeout:2];
    XCTAssertEqual(waitingCompletionCount, 1u);
    XCTAssertFalse(waiting.artLoadPending);
}

- (void)testTwoNewWantedEdgesWakeAfterTwoStaleReadsReleaseSlots {
    dispatch_semaphore_t releaseBaseMaterializations = dispatch_semaphore_create(0);
    [self installServicesWithFactory:^id<AudioFileMaterializationOperation>(
            NSURL *url, VibeAudioFileMaterializationRole role) {
        BOOL waits = [url.lastPathComponent hasPrefix:@"window-base-"] &&
                ![url.lastPathComponent hasPrefix:@"window-base-0."] &&
                ![url.lastPathComponent hasPrefix:@"window-base-1."];
        return [[ArtworkLoadTestMaterializationOperation alloc]
                initWithRun:^BOOL(NSError **error) {
            if (waits) {
                dispatch_semaphore_wait(releaseBaseMaterializations,
                                        DISPATCH_TIME_FOREVER);
            }
            return YES;
        }];
    }];
    dispatch_semaphore_t releaseFirstRead = dispatch_semaphore_create(0);
    dispatch_semaphore_t releaseSecondRead = dispatch_semaphore_create(0);
    XCTestExpectation *firstStarted = [self expectationWithDescription:@"first stale read"];
    XCTestExpectation *secondStarted = [self expectationWithDescription:@"second stale read"];
    NSMutableArray<XCTestExpectation *> *wantedCompletions = [NSMutableArray array];
    NSMutableArray<AudioTrackArtwork *> *baseArtworks = [NSMutableArray array];
    __block BOOL firstWanted = YES;
    __block BOOL secondWanted = YES;
    __block NSUInteger staleCompletionCount = 0;

    for (NSUInteger index = 0; index < 7; index++) {
        AudioTrackArtworkExtractor extractor =
                ^VibeEmbeddedArtExtractionResult(
                        NSString *path, NSData *__autoreleasing *artData) {
            if (index == 0) {
                [firstStarted fulfill];
                dispatch_semaphore_wait(releaseFirstRead, DISPATCH_TIME_FOREVER);
            }
            else if (index == 1) {
                [secondStarted fulfill];
                dispatch_semaphore_wait(releaseSecondRead, DISPATCH_TIME_FOREVER);
            }
            return VibeEmbeddedArtExtractionNoArt;
        };
        AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:
                [NSString stringWithFormat:@"/tmp/window-base-%lu.flac",
                                           (unsigned long)index]
                extractor:extractor];
        [baseArtworks addObject:artwork];
        if (index < 2) {
            BOOL (^wanted)(void) = index == 0
                    ? ^BOOL{ return firstWanted; }
                    : ^BOOL{ return secondWanted; };
            [artwork loadArtIfNeededWithLabel:@"stale" stillWanted:wanted
                    completion:^(NSImage *image) { staleCompletionCount++; }];
        }
        else {
            XCTestExpectation *completed = [self expectationWithDescription:
                    [NSString stringWithFormat:@"base %lu", (unsigned long)index]];
            [wantedCompletions addObject:completed];
            [artwork loadArtIfNeededWithLabel:@"base" stillWanted:^{ return YES; }
                    completion:^(NSImage *image) { [completed fulfill]; }];
        }
    }
    [self waitForExpectations:@[firstStarted, secondStarted] timeout:1];

    firstWanted = NO;
    secondWanted = NO;
    [baseArtworks[0] discardDecodedArt];
    [baseArtworks[1] discardDecodedArt];

    NSMutableArray<AudioTrackArtwork *> *newEdges = [NSMutableArray array];
    for (NSUInteger index = 0; index < 2; index++) {
        AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:
                [NSString stringWithFormat:@"/tmp/window-new-%lu.flac",
                                           (unsigned long)index]
                extractor:^VibeEmbeddedArtExtractionResult(
                        NSString *path, NSData *__autoreleasing *artData) {
            return VibeEmbeddedArtExtractionNoArt;
        }];
        [newEdges addObject:artwork];
        XCTestExpectation *completed = [self expectationWithDescription:
                [NSString stringWithFormat:@"new edge %lu", (unsigned long)index]];
        [wantedCompletions addObject:completed];
        [artwork loadArtIfNeededWithLabel:@"new edge" stillWanted:^{ return YES; }
                completion:^(NSImage *image) { [completed fulfill]; }];
        XCTAssertTrue(artwork.artLoadPending);
    }

    dispatch_semaphore_signal(releaseFirstRead);
    dispatch_semaphore_signal(releaseSecondRead);
    for (NSUInteger index = 0; index < 5; index++) {
        dispatch_semaphore_signal(releaseBaseMaterializations);
    }
    [self waitForExpectations:wantedCompletions timeout:2];

    XCTAssertEqual(staleCompletionCount, 0u);
    XCTAssertFalse(newEdges[0].artLoadPending);
    XCTAssertFalse(newEdges[1].artLoadPending);
}

- (void)testRedisplayWaitsForStaleReadThenStartsOneFreshLoad {
    NSData *embedded = [self embeddedArtData];
    XCTestExpectation *firstReadStarted =
            [self expectationWithDescription:@"first read started"];
    XCTestExpectation *completed = [self expectationWithDescription:@"fresh read completed"];
    dispatch_semaphore_t releaseFirstRead = dispatch_semaphore_create(0);
    NSLock *stateLock = [NSLock new];
    __block NSUInteger materializationCount = 0;
    __block NSUInteger extractionCount = 0;
    __block NSUInteger activeExtractions = 0;
    __block NSUInteger peakExtractions = 0;
    [self installServicesWithFactory:^id<AudioFileMaterializationOperation>(
            NSURL *url, VibeAudioFileMaterializationRole role) {
        [stateLock lock];
        materializationCount++;
        [stateLock unlock];
        return [[ArtworkLoadTestMaterializationOperation alloc]
                initWithRun:^BOOL(NSError **error) { return YES; }];
    }];
    AudioTrackArtwork *artwork = [self unloadedArtworkAtPath:@"/tmp/redisplayed.flac"
            extractor:^VibeEmbeddedArtExtractionResult(
                    NSString *path, NSData *__autoreleasing *artData) {
        [stateLock lock];
        extractionCount++;
        activeExtractions++;
        peakExtractions = MAX(peakExtractions, activeExtractions);
        BOOL first = extractionCount == 1;
        [stateLock unlock];
        if (first) {
            [firstReadStarted fulfill];
            dispatch_semaphore_wait(releaseFirstRead, DISPATCH_TIME_FOREVER);
        }
        *artData = embedded;
        [stateLock lock];
        activeExtractions--;
        [stateLock unlock];
        return VibeEmbeddedArtExtractionFoundArt;
    }];
    __block BOOL wanted = YES;
    __block NSUInteger completionCount = 0;
    BOOL (^stillWanted)(void) = ^BOOL{ return wanted; };
    void (^completion)(NSImage *) = ^(NSImage *image) {
        completionCount++;
        XCTAssertNotNil(image);
        [completed fulfill];
    };

    [artwork loadArtIfNeededWithLabel:@"redisplayed"
                          stillWanted:stillWanted completion:completion];
    [self waitForExpectations:@[firstReadStarted] timeout:1];
    wanted = NO;
    [artwork discardDecodedArt];
    wanted = YES;
    [artwork loadArtIfNeededWithLabel:@"redisplayed"
                          stillWanted:stillWanted completion:completion];
    XCTAssertFalse(artwork.artLoadPending,
                   @"the old read keeps the single-flight extraction claim");

    dispatch_semaphore_signal(releaseFirstRead);
    [self waitForExpectations:@[completed] timeout:2];

    [stateLock lock];
    NSUInteger finalMaterializationCount = materializationCount;
    NSUInteger finalExtractionCount = extractionCount;
    NSUInteger finalPeakExtractions = peakExtractions;
    [stateLock unlock];
    XCTAssertEqual(finalMaterializationCount, 2u);
    XCTAssertEqual(finalExtractionCount, 2u);
    XCTAssertEqual(finalPeakExtractions, 1u);
    XCTAssertEqual(completionCount, 1u);
    XCTAssertFalse(artwork.artLoadPending);
}

@end
