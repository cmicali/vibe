//
//  The bounded, single-flight open coordinator itself, not just its rules:
//  claim rebinding, cancellation, and the completion contract every caller
//  reads an error code off.
//

#import <XCTest/XCTest.h>
#import <AVFoundation/AVFoundation.h>

#import "AudioFileOpenCoordinator.h"

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

// The invariant every caller depends on: a completion carries a file, or a
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
