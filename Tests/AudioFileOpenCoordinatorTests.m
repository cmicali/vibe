//
//  The bounded, single-flight open coordinator itself, not just its rules:
//  claim rebinding, cancellation, and the completion contract every caller
//  reads an error code off.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "AudioFileOpenCoordinator.h"
#import "AudioFileOpenCoordinatorInternal.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioWorkScheduler.h"

@class VibeOpenTestMaterializationHarness;

@interface VibeOpenTestMaterializationOperation : NSObject <AudioFileMaterializationOperation>
- (instancetype)initWithRole:(VibeAudioFileMaterializationRole)role
                       harness:(VibeOpenTestMaterializationHarness *)harness;
@property (nonatomic, readonly) VibeAudioFileMaterializationRole role;
@property (nonatomic, readonly) NSUInteger cancellationCount;
- (void)deferCancellationCompletion;
- (void)completeReady;
- (void)completeFailed;
@end

@interface VibeOpenTestMaterializationHarness : NSObject
- (id<AudioFileMaterializationOperation>)operationForURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role;
- (void)didStartOperation:(VibeOpenTestMaterializationOperation *)operation;
- (BOOL)waitForStartedCount:(NSUInteger)count;
- (BOOL)waitForCancellationCount:(NSUInteger)count;
- (NSArray<VibeOpenTestMaterializationOperation *> *)startedOperations;
- (void)completeAllReady;
@end

@implementation VibeOpenTestMaterializationOperation {
    NSCondition *_condition;
    __weak VibeOpenTestMaterializationHarness *_harness;
    BOOL _finished;
    BOOL _ready;
    BOOL _defersCancellationCompletion;
    NSUInteger _cancellationCount;
}

- (instancetype)initWithRole:(VibeAudioFileMaterializationRole)role
                       harness:(VibeOpenTestMaterializationHarness *)harness {
    self = [super init];
    if (self) {
        _role = role;
        _harness = harness;
        _condition = [[NSCondition alloc] init];
    }
    return self;
}

- (BOOL)runWithError:(NSError *__autoreleasing *)error {
    [_harness didStartOperation:self];
    [_condition lock];
    while (!_finished) {
        [_condition wait];
    }
    BOOL ready = _ready;
    [_condition unlock];
    if (!ready && error) {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                     code:NSUserCancelledError userInfo:nil];
    }
    return ready;
}

- (void)cancel {
    [_condition lock];
    _cancellationCount++;
    if (!_defersCancellationCompletion) {
        _finished = YES;
        _ready = NO;
        [_condition broadcast];
    }
    [_condition unlock];
}

- (void)deferCancellationCompletion {
    [_condition lock];
    _defersCancellationCompletion = YES;
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

- (void)completeFailed {
    [_condition lock];
    if (!_finished) {
        _finished = YES;
        _ready = NO;
        [_condition broadcast];
    }
    [_condition unlock];
}

- (NSUInteger)cancellationCount {
    [_condition lock];
    NSUInteger count = _cancellationCount;
    [_condition unlock];
    return count;
}

@end

@implementation VibeOpenTestMaterializationHarness {
    NSCondition *_condition;
    NSMutableArray<VibeOpenTestMaterializationOperation *> *_operations;
    NSMutableArray<VibeOpenTestMaterializationOperation *> *_startedOperations;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _condition = [[NSCondition alloc] init];
        _operations = [NSMutableArray array];
        _startedOperations = [NSMutableArray array];
    }
    return self;
}

- (id<AudioFileMaterializationOperation>)operationForURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role {
    VibeOpenTestMaterializationOperation *operation =
            [[VibeOpenTestMaterializationOperation alloc] initWithRole:role harness:self];
    [_condition lock];
    [_operations addObject:operation];
    [_condition broadcast];
    [_condition unlock];
    return operation;
}

- (void)didStartOperation:(VibeOpenTestMaterializationOperation *)operation {
    [_condition lock];
    [_startedOperations addObject:operation];
    [_condition broadcast];
    [_condition unlock];
}

- (BOOL)waitForStartedCount:(NSUInteger)count {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    [_condition lock];
    while (_startedOperations.count < count) {
        if (![_condition waitUntilDate:deadline]) {
            [_condition unlock];
            return NO;
        }
    }
    [_condition unlock];
    return YES;
}

- (BOOL)waitForCancellationCount:(NSUInteger)count {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    [_condition lock];
    while (YES) {
        NSArray *operations = [_operations copy];
        [_condition unlock];
        NSUInteger total = 0;
        for (VibeOpenTestMaterializationOperation *operation in operations) {
            total += operation.cancellationCount;
        }
        if (total >= count) {
            return YES;
        }
        if (deadline.timeIntervalSinceNow <= 0) {
            return NO;
        }
        [_condition lock];
        [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}

- (NSArray<VibeOpenTestMaterializationOperation *> *)startedOperations {
    [_condition lock];
    NSArray *operations = [_startedOperations copy];
    [_condition unlock];
    return operations;
}

- (void)completeAllReady {
    [_condition lock];
    NSArray *operations = [_operations copy];
    [_condition unlock];
    for (VibeOpenTestMaterializationOperation *operation in operations) {
        [operation completeReady];
    }
}

@end

@interface AudioFileOpenCoordinatorTests : XCTestCase
@end

@implementation AudioFileOpenCoordinatorTests {
    NSURL *_directory;
    AudioFileOpenCoordinator *_coordinator;
    dispatch_queue_t _completionQueue;
}

- (void)setUp {
    [super setUp];
    // Its own instance, never +sharedCoordinator: the claim table is process
    // state, and tests that shared it would see each other's paths.
    _coordinator = [[AudioFileOpenCoordinator alloc] init];
    _completionQueue = dispatch_queue_create("com.vibe.tests.open", DISPATCH_QUEUE_SERIAL);
    _directory = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"vibe-open-%@",
                    NSUUID.UUID.UUIDString]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_directory
                           withIntermediateDirectories:YES attributes:nil error:nil];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_directory error:nil];
    [super tearDown];
}

// A minimal but genuinely openable 16-bit PCM WAV. Written by hand rather than
// taken from Assets/test_audio_files, which is gitignored and so cannot be a
// test dependency.
- (NSURL *)writeToneNamed:(NSString *)name {
    const uint32_t sampleRate = 44100;
    const uint16_t channels = 1;
    const uint32_t frames = 1024;
    const uint32_t dataBytes = frames * channels * sizeof(int16_t);
    NSMutableData *wav = [NSMutableData data];
    void (^append32)(uint32_t) = ^(uint32_t v) { [wav appendBytes:&v length:4]; };
    void (^append16)(uint16_t) = ^(uint16_t v) { [wav appendBytes:&v length:2]; };
    [wav appendBytes:"RIFF" length:4];
    append32(36 + dataBytes);
    [wav appendBytes:"WAVEfmt " length:8];
    append32(16);                                   // PCM fmt chunk size
    append16(1);                                    // PCM
    append16(channels);
    append32(sampleRate);
    append32(sampleRate * channels * sizeof(int16_t));
    append16(channels * sizeof(int16_t));           // block align
    append16(16);                                   // bits per sample
    [wav appendBytes:"data" length:4];
    append32(dataBytes);
    for (uint32_t frame = 0; frame < frames; frame++) {
        int16_t sample = (int16_t)(8000 * sin(2.0 * M_PI * 440.0 * frame / sampleRate));
        [wav appendBytes:&sample length:sizeof(sample)];
    }
    NSURL *url = [_directory URLByAppendingPathComponent:name];
    XCTAssertTrue([wav writeToURL:url atomically:YES]);
    return url;
}

- (AudioFileOpenCoordinator *)coordinatorWithStateQueue:(dispatch_queue_t)stateQueue
                                    backgroundScheduler:(AudioWorkScheduler *)backgroundScheduler {
    return [self coordinatorWithStateQueue:stateQueue
                        backgroundScheduler:backgroundScheduler
                 materializationCoordinator:
                         [AudioFileMaterializationCoordinator sharedCoordinator]];
}

- (AudioFileOpenCoordinator *)coordinatorWithStateQueue:(dispatch_queue_t)stateQueue
                                    backgroundScheduler:(AudioWorkScheduler *)backgroundScheduler
                             materializationCoordinator:
                                     (AudioFileMaterializationCoordinator *)materializationCoordinator {
    AudioWorkScheduler *playbackScheduler = [[AudioWorkScheduler alloc]
            initWithLabel:@"com.vibe.tests.open.playback"
            qualityOfService:QOS_CLASS_USER_INITIATED
            maximumRunningCount:1 maximumPendingCount:1 pendingGrace:5];
    AudioWorkScheduler *background = backgroundScheduler ?: [[AudioWorkScheduler alloc]
            initWithLabel:@"com.vibe.tests.open.background"
            qualityOfService:QOS_CLASS_UTILITY
            maximumRunningCount:1 maximumPendingCount:2 pendingGrace:5];
    return [[AudioFileOpenCoordinator alloc] initWithStateQueue:stateQueue
            playbackScheduler:playbackScheduler backgroundScheduler:background
            materializationCoordinator:materializationCoordinator];
}

- (AudioFileMaterializationCoordinator *)materializationCoordinatorWithHarness:
        (VibeOpenTestMaterializationHarness *)harness {
    return [self materializationCoordinatorWithHarness:harness
            configuration:[AudioLoadingConfiguration productionConfiguration]];
}

- (AudioFileMaterializationCoordinator *)materializationCoordinatorWithHarness:
        (VibeOpenTestMaterializationHarness *)harness
        configuration:(AudioLoadingConfiguration *)configuration {
    return [[AudioFileMaterializationCoordinator alloc]
            initWithConfiguration:configuration
            operationFactory:^id<AudioFileMaterializationOperation>(
                    NSURL *url, VibeAudioFileMaterializationRole role) {
        return [harness operationForURL:url role:role];
    } datalessProbe:^BOOL(NSURL *url) {
        return YES;   // fabricated paths would stat as local and skip the lanes
    } clock:^NSTimeInterval{
        return [NSDate date].timeIntervalSinceReferenceDate;
    }];
}

#pragma mark - Claim observation

- (void)testWhenClaimedWaitsUntilStateQueueRegistersTheClaim {
    dispatch_queue_t stateQueue = dispatch_queue_create(
            "com.vibe.tests.open.blocked-state", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async(stateQueue, ^{
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    });
    AudioFileOpenCoordinator *coordinator = [self coordinatorWithStateQueue:stateQueue
                                                        backgroundScheduler:nil];
    NSURL *url = [self writeToneNamed:@"claim-waits.wav"];
    AudioFileOpenToken *token = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback
            completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {}];
    XCTestExpectation *early = [self expectationWithDescription:@"claim not registered early"];
    early.inverted = YES;
    [token whenClaimedOnQueue:_completionQueue completion:^(VibeAudioFileOpenClaimResult result) {
        [early fulfill];
    }];
    [self waitForExpectations:@[early] timeout:0.05];
    XCTestExpectation *claimed = [self expectationWithDescription:@"claim registered"];
    [token whenClaimedOnQueue:_completionQueue completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultClaimed);
        [claimed fulfill];
    }];
    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[claimed] timeout:5];
}

- (void)testMultipleObserversFireOnceForOneRegistration {
    NSURL *url = [self writeToneNamed:@"claim-observers.wav"];
    AudioFileOpenToken *token = [_coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback
            completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {}];
    XCTestExpectation *first = [self expectationWithDescription:@"first observer"];
    XCTestExpectation *second = [self expectationWithDescription:@"second observer"];
    [token whenClaimedOnQueue:_completionQueue completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultClaimed);
        [first fulfill];
    }];
    [token whenClaimedOnQueue:_completionQueue completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultClaimed);
        [second fulfill];
    }];
    [self waitForExpectations:@[first, second] timeout:5];
}

- (void)testObserverAddedAfterRegistrationFiresExactlyOnce {
    NSURL *url = [self writeToneNamed:@"claim-late-observer.wav"];
    AudioFileOpenToken *token = [_coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback
            completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {}];
    XCTestExpectation *registered = [self expectationWithDescription:@"registered"];
    [token whenClaimedOnQueue:_completionQueue completion:^(VibeAudioFileOpenClaimResult result) {
        [registered fulfill];
    }];
    [self waitForExpectations:@[registered] timeout:5];
    XCTestExpectation *late = [self expectationWithDescription:@"late observer"];
    late.expectedFulfillmentCount = 1;
    [token whenClaimedOnQueue:_completionQueue completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultClaimed);
        [late fulfill];
    }];
    [self waitForExpectations:@[late] timeout:5];
}

- (void)testCancellationBeforeRegistrationSettlesCancelled {
    dispatch_queue_t stateQueue = dispatch_queue_create(
            "com.vibe.tests.open.cancelled-state", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async(stateQueue, ^{
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    });
    AudioFileOpenCoordinator *coordinator = [self coordinatorWithStateQueue:stateQueue
                                                        backgroundScheduler:nil];
    NSURL *url = [self writeToneNamed:@"claim-cancelled.wav"];
    AudioFileOpenToken *token = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback
            completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTFail(@"cancelled token must not deliver");
    }];
    XCTestExpectation *cancelled = [self expectationWithDescription:@"cancelled before claim"];
    [token whenClaimedOnQueue:_completionQueue completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultCancelled);
        [cancelled fulfill];
    }];
    [token cancel];
    [self waitForExpectations:@[cancelled] timeout:5];
    dispatch_semaphore_signal(gate);
}

- (void)testClaimAcknowledgementDoesNotWaitForBackgroundAdmission {
    AudioWorkScheduler *background = [[AudioWorkScheduler alloc]
            initWithLabel:@"com.vibe.tests.open.occupied-background"
            qualityOfService:QOS_CLASS_UTILITY
            maximumRunningCount:1 maximumPendingCount:1 pendingGrace:5];
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [background submitWork:^{
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    } failureQueue:_completionQueue admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {}];
    VibeOpenTestMaterializationHarness *harness =
            [[VibeOpenTestMaterializationHarness alloc] init];
    AudioFileMaterializationCoordinator *materialization =
            [self materializationCoordinatorWithHarness:harness];
    AudioFileOpenCoordinator *coordinator = [self coordinatorWithStateQueue:
            dispatch_queue_create("com.vibe.tests.open.claim-before-admit", DISPATCH_QUEUE_SERIAL)
            backgroundScheduler:background materializationCoordinator:materialization];
    NSURL *url = [self writeToneNamed:@"claim-before-admission.wav"];
    XCTestExpectation *opened = [self expectationWithDescription:@"opened after admission"];
    AudioFileOpenToken *token = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePrefetch
            completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        XCTAssertNil(error);
        [opened fulfill];
    }];
    XCTestExpectation *claimed = [self expectationWithDescription:@"claim before admission"];
    [token whenClaimedOnQueue:_completionQueue completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultClaimed);
        [claimed fulfill];
    }];
    XCTAssertTrue([harness waitForStartedCount:1]);
    [self waitForExpectations:@[claimed] timeout:5];
    [harness completeAllReady];
    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[opened] timeout:5];
}

#pragma mark - The completion contract

- (void)testAnOpenDeliversTheFile {
    NSURL *url = [self writeToneNamed:@"tone.wav"];
    XCTestExpectation *opened = [self expectationWithDescription:@"opened"];
    [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
          completionQueue:_completionQueue
               completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        XCTAssertNil(error);
        XCTAssertGreaterThan(file.length, 0);
        [opened fulfill];
    }];
    [self waitForExpectations:@[opened] timeout:5];
}

// The guarantee every caller depends on: a completion carries a file, or a
// reason there is none. Nothing may hand out nil/nil, because callers read
// error.code and log error.localizedDescription off it.
- (void)testAMissingFileFailsWithAnErrorRatherThanSilently {
    NSURL *url = [_directory URLByAppendingPathComponent:@"absent.wav"];
    XCTestExpectation *failed = [self expectationWithDescription:@"failed"];
    [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
          completionQueue:_completionQueue
               completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNil(file);
        XCTAssertNotNil(error, @"a nil file must always be explained");
        [failed fulfill];
    }];
    [self waitForExpectations:@[failed] timeout:5];
}

- (void)testAnEmptyFileFailsWithAnErrorRatherThanSilently {
    NSURL *url = [_directory URLByAppendingPathComponent:@"empty.wav"];
    XCTAssertTrue([[NSData data] writeToURL:url atomically:YES]);
    XCTestExpectation *failed = [self expectationWithDescription:@"failed"];
    [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
          completionQueue:_completionQueue
               completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNil(file);
        XCTAssertNotNil(error);
        [failed fulfill];
    }];
    [self waitForExpectations:@[failed] timeout:5];
}

#pragma mark - Cancellation and rebinding

- (void)testACancelledTokenNeverDelivers {
    NSURL *url = [self writeToneNamed:@"cancelled.wav"];
    XCTestExpectation *neverDelivered = [self expectationWithDescription:@"no delivery"];
    neverDelivered.inverted = YES;
    AudioFileOpenToken *token =
            [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
                  completionQueue:_completionQueue
                       completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        [neverDelivered fulfill];
    }];
    [token cancel];
    [self waitForExpectations:@[neverDelivered] timeout:1.5];
}

// The bug this replaced: a waiter that left and a new one that bound to the
// same still-registered claim used to receive the abandoned run's empty result
// — a nil file with a nil error, which the player reports as "could not open".
// The rebound waiter must get a real run instead.
- (void)testARebindAfterCancellationGetsAFreshRunNotTheAbandonedResult {
    NSURL *url = [self writeToneNamed:@"rebound.wav"];
    AudioFileOpenToken *first =
            [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
                  completionQueue:_completionQueue
                       completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTFail(@"the cancelled request must not deliver");
    }];
    [first cancel];

    XCTestExpectation *delivered = [self expectationWithDescription:@"second delivered"];
    [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
          completionQueue:_completionQueue
               completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file, @"a rebound waiter gets its own run, not the abandoned one's");
        XCTAssertNil(error);
        [delivered fulfill];
    }];
    [self waitForExpectations:@[delivered] timeout:5];
}

- (void)testARebindWhileAnAbandonedHandleOpenReturnsGetsAFreshRun {
    NSURL *url = [self writeToneNamed:@"controlled-rebound.wav"];
    dispatch_semaphore_t firstOpenBegan = dispatch_semaphore_create(0);
    dispatch_semaphore_t releaseFirstOpen = dispatch_semaphore_create(0);
    NSLock *countLock = [[NSLock alloc] init];
    __block NSUInteger openCount = 0;
    VibeAudioFileOpener opener = ^AVAudioFile *(NSURL *openURL, NSError **error) {
        [countLock lock];
        NSUInteger invocation = ++openCount;
        [countLock unlock];
        if (invocation == 1) {
            dispatch_semaphore_signal(firstOpenBegan);
            dispatch_semaphore_wait(releaseFirstOpen, DISPATCH_TIME_FOREVER);
            return nil;
        }
        return [[AVAudioFile alloc] initForReading:openURL error:error];
    };
    AudioWorkScheduler *playbackScheduler = [[AudioWorkScheduler alloc]
            initWithLabel:@"com.vibe.tests.open.controlled-playback"
            qualityOfService:QOS_CLASS_USER_INITIATED
            maximumRunningCount:1 maximumPendingCount:1 pendingGrace:5];
    AudioWorkScheduler *backgroundScheduler = [[AudioWorkScheduler alloc]
            initWithLabel:@"com.vibe.tests.open.controlled-background"
            qualityOfService:QOS_CLASS_UTILITY
            maximumRunningCount:1 maximumPendingCount:1 pendingGrace:5];
    AudioFileOpenCoordinator *coordinator = [[AudioFileOpenCoordinator alloc]
            initWithStateQueue:dispatch_queue_create(
                    "com.vibe.tests.open.controlled-rebind", DISPATCH_QUEUE_SERIAL)
            playbackScheduler:playbackScheduler
            backgroundScheduler:backgroundScheduler
            materializationCoordinator:[AudioFileMaterializationCoordinator sharedCoordinator]
            fileOpener:opener];

    XCTestExpectation *oldSilent = [self expectationWithDescription:@"old handle waiter silent"];
    oldSilent.inverted = YES;
    AudioFileOpenToken *first = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposeGapless completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        [oldSilent fulfill];
    }];
    XCTAssertEqual(dispatch_semaphore_wait(firstOpenBegan,
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0);
    [first cancel];

    XCTestExpectation *secondClaimed = [self expectationWithDescription:@"new handle waiter claimed"];
    XCTestExpectation *secondOpened = [self expectationWithDescription:@"fresh handle run opened"];
    AudioFileOpenToken *second = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposeGapless completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        XCTAssertNil(error);
        [secondOpened fulfill];
    }];
    [second whenClaimedOnQueue:_completionQueue completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultClaimed);
        [secondClaimed fulfill];
    }];
    [self waitForExpectations:@[secondClaimed] timeout:2];
    dispatch_semaphore_signal(releaseFirstOpen);
    [self waitForExpectations:@[secondOpened] timeout:2];
    [self waitForExpectations:@[oldSilent] timeout:0.1];
    [countLock lock];
    NSUInteger deliveredOpenCount = openCount;
    [countLock unlock];
    XCTAssertEqual(deliveredOpenCount, 2u);
}

// Same purpose, same path, no cancel: the second request replaces the first as
// the claim's waiter rather than starting a second open of the same file.
- (void)testASamePathRequestRebindsDeliveryToTheLatestWaiter {
    NSURL *url = [self writeToneNamed:@"single-flight.wav"];
    XCTestExpectation *supersededSilent = [self expectationWithDescription:@"superseded silent"];
    supersededSilent.inverted = YES;
    XCTestExpectation *latestDelivered = [self expectationWithDescription:@"latest delivered"];
    [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
          completionQueue:_completionQueue
               completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        [supersededSilent fulfill];
    }];
    [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
          completionQueue:_completionQueue
               completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        [latestDelivered fulfill];
    }];
    [self waitForExpectations:@[latestDelivered] timeout:5];
    [self waitForExpectations:@[supersededSilent] timeout:0.5];
}

// Purpose is part of the claim key, so the foreground open and a background
// readahead of the same file are separate work with separate lanes — a
// prefetch's claim must never swallow the play the user is waiting on.
- (void)testDifferentPurposesForOnePathAreIndependentClaims {
    NSURL *url = [self writeToneNamed:@"two-purposes.wav"];
    XCTestExpectation *playback = [self expectationWithDescription:@"playback delivered"];
    XCTestExpectation *prefetch = [self expectationWithDescription:@"prefetch delivered"];
    [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
          completionQueue:_completionQueue
               completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        [playback fulfill];
    }];
    [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePrefetch
          completionQueue:_completionQueue
               completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        [prefetch fulfill];
    }];
    [self waitForExpectations:@[playback, prefetch] timeout:5];
}

// Cancelling one purpose's claim leaves the other's alone, which is what stops
// a play's supersession from retiring the prefetch racing it (and vice versa).
- (void)testCancellingOnePurposeLeavesTheOtherDelivering {
    NSURL *url = [self writeToneNamed:@"one-cancelled.wav"];
    XCTestExpectation *prefetchSilent = [self expectationWithDescription:@"prefetch silent"];
    prefetchSilent.inverted = YES;
    XCTestExpectation *playback = [self expectationWithDescription:@"playback delivered"];
    AudioFileOpenToken *prefetchToken =
            [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePrefetch
                  completionQueue:_completionQueue
                       completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        [prefetchSilent fulfill];
    }];
    [prefetchToken cancel];
    [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePlayback
          completionQueue:_completionQueue
               completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        [playback fulfill];
    }];
    [self waitForExpectations:@[playback] timeout:5];
    [self waitForExpectations:@[prefetchSilent] timeout:0.5];
}

#pragma mark - Path-wide materialization integration

- (void)testPurposesMapToCentralRolesAndGaplessBypassesMaterialization {
    VibeOpenTestMaterializationHarness *harness =
            [[VibeOpenTestMaterializationHarness alloc] init];
    AudioFileMaterializationCoordinator *materialization =
            [self materializationCoordinatorWithHarness:harness];
    AudioFileOpenCoordinator *coordinator = [self coordinatorWithStateQueue:
            dispatch_queue_create("com.vibe.tests.open.roles", DISPATCH_QUEUE_SERIAL)
            backgroundScheduler:nil materializationCoordinator:materialization];
    NSURL *playURL = [self writeToneNamed:@"role-playback.wav"];
    NSURL *prefetchURL = [self writeToneNamed:@"role-prefetch.wav"];
    NSURL *gaplessURL = [self writeToneNamed:@"role-gapless.wav"];
    XCTestExpectation *play = [self expectationWithDescription:@"play opened"];
    XCTestExpectation *prefetch = [self expectationWithDescription:@"prefetch opened"];
    XCTestExpectation *gapless = [self expectationWithDescription:@"gapless opened"];
    __unused AudioFileOpenToken *playToken = [coordinator openURL:playURL
            purpose:VibeAudioFileOpenPurposePlayback completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        [play fulfill];
    }];
    __unused AudioFileOpenToken *prefetchToken = [coordinator openURL:prefetchURL
            purpose:VibeAudioFileOpenPurposePrefetch completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        [prefetch fulfill];
    }];
    XCTAssertTrue([harness waitForStartedCount:2]);
    NSSet<NSNumber *> *roles = [NSSet setWithArray:
            [[harness.startedOperations valueForKey:@"role"] copy]];
    XCTAssertTrue([roles containsObject:@(VibeAudioFileMaterializationRolePlayback)]);
    XCTAssertTrue([roles containsObject:@(VibeAudioFileMaterializationRolePrefetch)]);

    __unused AudioFileOpenToken *gaplessToken = [coordinator openURL:gaplessURL
            purpose:VibeAudioFileOpenPurposeGapless completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        [gapless fulfill];
    }];
    [self waitForExpectations:@[gapless] timeout:2];
    XCTAssertEqual(harness.startedOperations.count, 2u);
    [harness completeAllReady];
    [self waitForExpectations:@[play, prefetch] timeout:2];
}

- (void)testPlaybackAndPrefetchShareOneMaterializationThenOpenSeparateHandles {
    VibeOpenTestMaterializationHarness *harness =
            [[VibeOpenTestMaterializationHarness alloc] init];
    AudioFileMaterializationCoordinator *materialization =
            [self materializationCoordinatorWithHarness:harness];
    AudioFileOpenCoordinator *coordinator = [self coordinatorWithStateQueue:
            dispatch_queue_create("com.vibe.tests.open.shared-materialization", DISPATCH_QUEUE_SERIAL)
            backgroundScheduler:nil materializationCoordinator:materialization];
    NSURL *url = [self writeToneNamed:@"shared-materialization.wav"];
    XCTestExpectation *playClaimed = [self expectationWithDescription:@"play registered"];
    XCTestExpectation *prefetchClaimed = [self expectationWithDescription:@"prefetch registered"];
    XCTestExpectation *playOpened = [self expectationWithDescription:@"play handle"];
    XCTestExpectation *prefetchOpened = [self expectationWithDescription:@"prefetch handle"];
    __block AVAudioFile *playFile = nil;
    __block AVAudioFile *prefetchFile = nil;
    AudioFileOpenToken *playToken = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        playFile = file;
        [playOpened fulfill];
    }];
    [playToken whenClaimedOnQueue:_completionQueue
                       completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultClaimed);
        [playClaimed fulfill];
    }];
    XCTAssertTrue([harness waitForStartedCount:1]);
    AudioFileOpenToken *prefetchToken = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePrefetch completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        prefetchFile = file;
        [prefetchOpened fulfill];
    }];
    [prefetchToken whenClaimedOnQueue:_completionQueue
                           completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultClaimed);
        [prefetchClaimed fulfill];
    }];
    [self waitForExpectations:@[playClaimed, prefetchClaimed] timeout:2];
    VibeAudioFileMaterializationCoordinatorSnapshot snapshot =
            [materialization stateSnapshotForTesting];
    XCTAssertEqual(snapshot.claimCount, 1u);
    XCTAssertEqual(snapshot.waiterCount, 2u);
    XCTAssertEqual(harness.startedOperations.count, 1u);
    [harness completeAllReady];
    [self waitForExpectations:@[playOpened, prefetchOpened] timeout:2];
    XCTAssertNotNil(playFile);
    XCTAssertNotNil(prefetchFile);
    XCTAssertNotEqual(playFile, prefetchFile);
}

- (void)testSamePurposeRebindAndOldCancellationKeepOneCentralOperation {
    VibeOpenTestMaterializationHarness *harness =
            [[VibeOpenTestMaterializationHarness alloc] init];
    AudioFileMaterializationCoordinator *materialization =
            [self materializationCoordinatorWithHarness:harness];
    AudioFileOpenCoordinator *coordinator = [self coordinatorWithStateQueue:
            dispatch_queue_create("com.vibe.tests.open.rebind-materialization", DISPATCH_QUEUE_SERIAL)
            backgroundScheduler:nil materializationCoordinator:materialization];
    NSURL *url = [self writeToneNamed:@"rebind-materialization.wav"];
    XCTestExpectation *firstSilent = [self expectationWithDescription:@"old waiter silent"];
    firstSilent.inverted = YES;
    AudioFileOpenToken *first = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        [firstSilent fulfill];
    }];
    XCTAssertTrue([harness waitForStartedCount:1]);
    XCTestExpectation *secondClaimed = [self expectationWithDescription:@"new waiter registered"];
    XCTestExpectation *secondOpened = [self expectationWithDescription:@"new waiter opened"];
    AudioFileOpenToken *second = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        [secondOpened fulfill];
    }];
    [second whenClaimedOnQueue:_completionQueue completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultClaimed);
        [secondClaimed fulfill];
    }];
    [self waitForExpectations:@[secondClaimed] timeout:2];
    [first cancel];
    XCTAssertEqual(harness.startedOperations.count, 1u);
    XCTAssertEqual(harness.startedOperations.firstObject.cancellationCount, 0u);
    [harness completeAllReady];
    [self waitForExpectations:@[secondOpened] timeout:2];
    [self waitForExpectations:@[firstSilent] timeout:0.1];
}

- (void)testCancellingCurrentWaiterDetachesTheCentralRequest {
    VibeOpenTestMaterializationHarness *harness =
            [[VibeOpenTestMaterializationHarness alloc] init];
    AudioFileMaterializationCoordinator *materialization =
            [self materializationCoordinatorWithHarness:harness];
    AudioFileOpenCoordinator *coordinator = [self coordinatorWithStateQueue:
            dispatch_queue_create("com.vibe.tests.open.cancel-materialization", DISPATCH_QUEUE_SERIAL)
            backgroundScheduler:nil materializationCoordinator:materialization];
    NSURL *url = [self writeToneNamed:@"cancel-materialization.wav"];
    XCTestExpectation *silent = [self expectationWithDescription:@"cancelled delivery"];
    silent.inverted = YES;
    AudioFileOpenToken *token = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        [silent fulfill];
    }];
    XCTAssertTrue([harness waitForStartedCount:1]);
    [token cancel];
    XCTAssertTrue([harness waitForCancellationCount:1]);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while ([materialization stateSnapshotForTesting].claimCount != 0
            && deadline.timeIntervalSinceNow > 0) {
        [NSThread sleepForTimeInterval:0.005];
    }
    XCTAssertEqual([materialization stateSnapshotForTesting].claimCount, 0u);
    [self waitForExpectations:@[silent] timeout:0.1];
}

- (void)testOuterRebindJoinsAndRestartsADelayedCancelledMaterialization {
    VibeOpenTestMaterializationHarness *harness =
            [[VibeOpenTestMaterializationHarness alloc] init];
    AudioFileMaterializationCoordinator *materialization =
            [self materializationCoordinatorWithHarness:harness];
    AudioFileOpenCoordinator *coordinator = [self coordinatorWithStateQueue:
            dispatch_queue_create("com.vibe.tests.open.delayed-central-rebind",
                                  DISPATCH_QUEUE_SERIAL)
            backgroundScheduler:nil materializationCoordinator:materialization];
    NSURL *url = [self writeToneNamed:@"delayed-central-rebind.wav"];
    XCTestExpectation *oldSilent = [self expectationWithDescription:@"cancelled outer waiter silent"];
    oldSilent.inverted = YES;
    AudioFileOpenToken *old = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        [oldSilent fulfill];
    }];
    XCTAssertTrue([harness waitForStartedCount:1]);
    VibeOpenTestMaterializationOperation *first = harness.startedOperations.firstObject;
    [first deferCancellationCompletion];
    [old cancel];

    XCTestExpectation *newClaimed = [self expectationWithDescription:@"replacement outer waiter claimed"];
    XCTestExpectation *newOpened = [self expectationWithDescription:@"replacement outer waiter opened"];
    AudioFileOpenToken *replacement = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNotNil(file);
        XCTAssertNil(error);
        [newOpened fulfill];
    }];
    [replacement whenClaimedOnQueue:_completionQueue
                         completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultClaimed);
        [newClaimed fulfill];
    }];
    [self waitForExpectations:@[newClaimed] timeout:2];
    VibeAudioFileMaterializationCoordinatorSnapshot rebound =
            [materialization stateSnapshotForTesting];
    XCTAssertEqual(rebound.claimCount, 1u);
    XCTAssertEqual(rebound.waiterCount, 1u);
    XCTAssertEqual(harness.startedOperations.count, 1u);
    XCTAssertEqual(first.cancellationCount, 1u);

    [first completeFailed];
    XCTAssertTrue([harness waitForStartedCount:2]);
    VibeOpenTestMaterializationOperation *second = harness.startedOperations.lastObject;
    XCTAssertEqual(second.role, VibeAudioFileMaterializationRolePlayback);
    [second completeReady];
    [self waitForExpectations:@[newOpened] timeout:2];
    [self waitForExpectations:@[oldSilent] timeout:0.1];
    VibeAudioFileMaterializationCoordinatorSnapshot settled =
            [materialization stateSnapshotForTesting];
    XCTAssertEqual(settled.claimCount, 0u);
    XCTAssertEqual(settled.waiterCount, 0u);
}

- (void)testCentralFailureIsTerminalWithoutAnAudioFileOpen {
    VibeOpenTestMaterializationHarness *harness =
            [[VibeOpenTestMaterializationHarness alloc] init];
    AudioFileMaterializationCoordinator *materialization =
            [self materializationCoordinatorWithHarness:harness];
    AudioFileOpenCoordinator *coordinator = [self coordinatorWithStateQueue:
            dispatch_queue_create("com.vibe.tests.open.materialization-failure", DISPATCH_QUEUE_SERIAL)
            backgroundScheduler:nil materializationCoordinator:materialization];
    NSURL *url = [self writeToneNamed:@"materialization-failure.wav"];
    XCTestExpectation *failed = [self expectationWithDescription:@"terminal failure"];
    __unused AudioFileOpenToken *token = [coordinator openURL:url
            purpose:VibeAudioFileOpenPurposePlayback completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNil(file);
        XCTAssertEqualObjects(error.domain, VibeAudioFileOpenErrorDomain);
        XCTAssertEqual(error.code, VibeAudioFileOpenErrorMaterializationFailed);
        [failed fulfill];
    }];
    XCTAssertTrue([harness waitForStartedCount:1]);
    [harness.startedOperations.firstObject completeFailed];
    [self waitForExpectations:@[failed] timeout:2];
}

- (void)testCentralAdmissionFailureRejectsClaimAndSkipsAudioFileOpen {
    VibeOpenTestMaterializationHarness *harness =
            [[VibeOpenTestMaterializationHarness alloc] init];
    VibeAudioLoadingConfigurationValues values =
            VibeAudioLoadingProductionConfigurationValues();
    values.maximumInteractiveMaterializations = 1;
    values.maximumInteractivePendingMaterializations = 0;
    NSError *configurationError = nil;
    AudioLoadingConfiguration *configuration = [[AudioLoadingConfiguration alloc]
            initWithValues:values error:&configurationError];
    XCTAssertNotNil(configuration);
    XCTAssertNil(configurationError);
    AudioFileMaterializationCoordinator *materialization =
            [self materializationCoordinatorWithHarness:harness configuration:configuration];
    AudioFileOpenCoordinator *coordinator = [self coordinatorWithStateQueue:
            dispatch_queue_create("com.vibe.tests.open.materialization-admission", DISPATCH_QUEUE_SERIAL)
            backgroundScheduler:nil materializationCoordinator:materialization];
    NSURL *blockerURL = [self writeToneNamed:@"admission-blocker.wav"];
    NSURL *rejectedURL = [self writeToneNamed:@"admission-rejected.wav"];
    AudioFileOpenToken *blocker = [coordinator openURL:blockerURL
            purpose:VibeAudioFileOpenPurposePlayback completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {}];
    XCTAssertTrue([harness waitForStartedCount:1]);

    XCTestExpectation *claimRejected = [self expectationWithDescription:@"claim rejected"];
    XCTestExpectation *openRejected = [self expectationWithDescription:@"open rejected"];
    AudioFileOpenToken *rejected = [coordinator openURL:rejectedURL
            purpose:VibeAudioFileOpenPurposePlayback completionQueue:_completionQueue
            completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
        XCTAssertNil(file);
        XCTAssertEqualObjects(error.domain, VibeAudioFileOpenErrorDomain);
        XCTAssertEqual(error.code, VibeAudioFileOpenErrorAdmissionExhausted);
        [openRejected fulfill];
    }];
    [rejected whenClaimedOnQueue:_completionQueue
                      completion:^(VibeAudioFileOpenClaimResult result) {
        XCTAssertEqual(result, VibeAudioFileOpenClaimResultCancelled);
        [claimRejected fulfill];
    }];
    [self waitForExpectations:@[claimRejected, openRejected] timeout:2];
    XCTAssertEqual(harness.startedOperations.count, 1u);
    [blocker cancel];
    XCTAssertTrue([harness waitForCancellationCount:1]);
}

#pragma mark - Bounding

// The reason the whole thing exists: many requests for many paths must not
// multiply workers without bound. Every one of them still settles.
- (void)testABurstOfDistinctPathsAllSettle {
    const NSUInteger count = 40;
    NSMutableArray<XCTestExpectation *> *settled = [NSMutableArray array];
    for (NSUInteger index = 0; index < count; index++) {
        NSURL *url = [self writeToneNamed:[NSString stringWithFormat:@"burst-%lu.wav",
                                                                     (unsigned long)index]];
        XCTestExpectation *done = [self expectationWithDescription:
                [NSString stringWithFormat:@"settled %lu", (unsigned long)index]];
        [settled addObject:done];
        [_coordinator openURL:url purpose:VibeAudioFileOpenPurposePrefetch
              completionQueue:_completionQueue
                   completion:^(AVAudioFile *file, NSError *error, NSTimeInterval elapsed) {
            // Either outcome is fine — the background lane's pending bound may
            // legitimately refuse some of a burst this size. What must not
            // happen is a request that never answers at all.
            XCTAssertTrue(file != nil || error != nil);
            [done fulfill];
        }];
    }
    [self waitForExpectations:settled timeout:30];
}

@end
