//
//  AudioPlayerRenderOutputTests.m
//

#import "AudioPlayerRenderTestCase.h"
#import "AudioFX.h"
#import "AudioFX+Debug.h"
#import "AudioLevelMeter+Debug.h"
#import "AudioOutputUnitInternal.h"
#import "CoreAudioUtil.h"
#import <objc/runtime.h>

// The output's rate and path, output-unit failures, idle stop and decode failures.
@interface AudioPlayerRenderOutputTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderOutputTests

// The volume is the render's last stage, after the meter. At full volume the
// output is the file exactly; at half the fader it is the file times 1/8, the
// cube, exactly, since that is a power of two; at zero it is silence while
// the meter before it still sees the signal; and back at full volume every
// frame continues the file exactly, mid-stream. Each change ramps across one
// slice, which the captures skip.
- (void)testVolumeIsExactAtFullAndSilentAtZero {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSURL *noise = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:noise]);
    XCTAssertEqual(_player.volume, 1.0f, @"full volume by default");
    [self play:noise paused:NO position:0];
    [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];

    [self play:noise paused:NO position:0];
    [self render:_blockSize * 8];
    _player.volume = 0.5f;
    [self render:_blockSize];
    NSMutableData *scaled = [[self renderSeconds:0.25] mutableCopy];
    float *p = scaled.mutableBytes;
    for (NSUInteger i = 0; i < scaled.length / sizeof(float); i++) p[i] *= 8;
    XCTAssertEqual([self assertExactExcerptsOf:@[reference] inCapture:scaled rampFrames:0 ramped:NULL], 1u,
                   @"half the fader is the file at exactly 1/8");

    _player.levelsEnabled = YES;
    _player.volume = 0;
    [self render:_blockSize];
    [self assertFinite:[self renderSeconds:0.5] peak:0];
    [_player runSyncOnQueue:^{
        NSDictionary *signal = [[self->_player debugLevelMeter] signalDiagnosticSnapshot];
        XCTAssertTrue([signal[@"aboveThreshold"] boolValue], @"the meter is before the volume: %@", signal);
    }];
    _player.levelsEnabled = NO;

    _player.volume = 1;
    [self render:_blockSize];
    XCTAssertEqual([self assertExactExcerptsOf:@[reference] inCapture:[self renderSeconds:0.5] rampFrames:0 ramped:NULL], 1u,
                   @"back at full volume, every frame continues the file exactly");
}

// A start plays at the volume it was left at, never ramping from full: with
// Declick off, the first sample is already the file at exactly 1/8, and so is
// the first after a resume from the idle stop.
- (void)testAStartPlaysAtTheVolumeItWasLeftAt {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _player.declick = NO;
    _player.volume = 0.5f;
    NSURL *noise = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:noise]);
    [self play:noise paused:NO position:0];
    NSMutableData *scaled = [[self renderSeconds:0.25] mutableCopy];
    float *p = scaled.mutableBytes;
    for (NSUInteger i = 0; i < scaled.length / sizeof(float); i++) p[i] *= 8;
    XCTAssertEqual(memcmp(scaled.bytes, reference.bytes, 64 * 2 * sizeof(float)), 0, @"the first frames ramped");
    XCTAssertEqual([self assertExactExcerptsOf:@[reference] inCapture:scaled rampFrames:0 ramped:NULL], 1u);

    // Moved while the idle stop holds the output: the resume lands on 1/64.
    [_player pause];
    [self renderSeconds:6.1];
    XCTAssertFalse([_player.debugRenderCounts[@"running"] boolValue]);
    _player.volume = 0.25f;
    [_player resume];
    scaled = [[self renderSeconds:0.25] mutableCopy];
    p = scaled.mutableBytes;
    for (NSUInteger i = 0; i < scaled.length / sizeof(float); i++) p[i] *= 64;
    XCTAssertEqual([self assertExactExcerptsOf:@[reference] inCapture:scaled rampFrames:0 ramped:NULL], 1u,
                   @"the resume ramped");
}

// The output's rate moves under the pipeline (a device's or a route's under
// the output unit, here the pump's): playing, the tone continues at the new
// rate from the same position; paused, the position holds and the resume
// continues there.
- (void)testOutputRateChangeKeepsThePlayingAndPausedTrack {
    [self startPlayerAt:44100 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSURL *url = [self fixture:@"1000.wav"];
    AudioTrack *track = [self play:url paused:NO position:0];
    [self render:22050];
    double before = _player.position;
    XCTAssertTrue([_player debugSetOutputRate:96000]);
    _rate = 96000;
    XCTAssertTrue(_player.isPlaying);
    XCTAssertEqual(_player.currentTrack, track);
    XCTAssertEqualWithAccuracy(_player.position, before, 0.01);
    XCTAssertEqual([_player.debugRenderCounts[@"outputRate"] doubleValue], 96000.0);
    XCTAssertTrue([_player.debugRenderCounts[@"varispeed"] boolValue], @"the varispeed was hosted again at the new rate");
    NSData *data = [self renderSeconds:0.5];
    XCTAssertEqualWithAccuracy(VibeToneAmplitude(data, 2, 0, 96000, 1000, NSMakeRange(9600, 24000)), 0.25, 0.005);
    XCTAssertEqualWithAccuracy(_player.position, before + 0.5, 0.01);
    XCTAssertEqual([self count:@"finish"], 0u);
    [self settleUntil:^BOOL { return [self count:@"start"] >= 1; }];
    XCTAssertEqual([self count:@"start"], 1u, @"a restore is not a new play");

    [_player pause]; [self render:4800];
    XCTAssertTrue(_player.isPaused);
    double paused = _player.position;
    XCTAssertTrue([_player debugSetOutputRate:48000]);
    _rate = 48000;
    XCTAssertTrue(_player.isPaused);
    XCTAssertEqualWithAccuracy(_player.position, paused, 0.01);
    XCTAssertEqual(VibeRMS([self renderSeconds:0.2], 2, 0, NSMakeRange(0, 9600)), 0.0, @"paused stays silent across the change");
    XCTAssertEqualWithAccuracy(_player.position, paused, 0.01);
    [_player resume];
    data = [self renderSeconds:0.5];
    XCTAssertTrue(_player.isPlaying);
    XCTAssertEqualWithAccuracy(VibeToneAmplitude(data, 2, 0, 48000, 1000, NSMakeRange(4800, 12000)), 0.25, 0.005);
    XCTAssertEqualWithAccuracy(_player.position, paused + 0.5, 0.01);
    XCTAssertTrue([_player debugSetOutputRate:48000], @"the current rate is a no-op");
    XCTAssertTrue(_player.isPlaying);
}

// A lossy source at another rate and width is mixed on its own rate and then
// resampled to the bus's: a 48 kHz file on a 96 kHz bus plays at its own
// speed and a mono one lands in both channels. The reference is the decode
// folded and resampled off the bus, exact but for the AAC decode's rounding.
- (void)testALossyDecodeIsMixedThenResampledToTheBus {
    for (NSURL *url in @[[self optionalFixture:@"cbr.mp3"], [self writeMonoAAC]]) {
        AVAudioPCMBuffer *decoded = [self read:url];
        [self startPlayerAt:96000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        [self play:url paused:NO position:0];
        NSDictionary *conversion = _player.debugCurrentConversion;
        XCTAssertEqualObjects(conversion[@"algorithm"], @"r8brain-free-src", @"%@", url.lastPathComponent);
        XCTAssertEqual([conversion[@"mixed"] boolValue], decoded.format.channelCount == 1);
        NSData *capture = [self renderSeconds:decoded.frameLength / decoded.format.sampleRate + 0.1];
        // The finish reaches main by an async hop, which a loaded runner can
        // land after the last block's run-loop turn; nothing renders while
        // this waits, so the frame count the speed check rests on holds.
        [self settleUntil:^BOOL { return [self count:@"finish"] > 0; }];
        XCTAssertEqual([self count:@"finish"], 1u, @"%@ played at its own speed", url.lastPathComponent);
        [self assertReference:VibePCM(VibeReferenceResample([self stereo:decoded], 96000)) capture:capture
                         skip:[self startupSkip] tolerance:[url.pathExtension isEqual:@"m4a"] ? kVibeAACDecodeTolerance : 0];
    }
}

// A one-second mono 440 Hz tone, AAC at 44.1 kHz, in the temporary directory.
- (NSURL *)writeMonoAAC {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:1];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:44100];
    buffer.frameLength = 44100;
    for (NSUInteger f = 0; f < 44100; f++) buffer.floatChannelData[0][f] = 0.25f * sinf((float)(2 * M_PI * 440 * f / 44100));
    NSURL *url = [_temporary URLByAppendingPathComponent:@"mono.m4a"];
    NSError *error = nil;
    AudioStreamBasicDescription aac = {0};
    aac.mFormatID = kAudioFormatMPEG4AAC;
    aac.mSampleRate = 44100;
    aac.mChannelsPerFrame = 1;
    aac.mFramesPerPacket = 1024;
    AudioFileHandle *file = [[AudioFileHandle alloc] initForWriting:url fileType:kAudioFileM4AType
                                                         fileFormat:[[AVAudioFormat alloc] initWithStreamDescription:&aac]
                                                   processingFormat:format error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertTrue([file writeFromBuffer:buffer error:&error], @"%@", error);
    XCTAssertTrue([file closeWithError:&error], @"%@", error);
    return url;
}

// The bus's own fold: mono into both channels, wider unchanged.
- (AVAudioPCMBuffer *)stereo:(AVAudioPCMBuffer *)buffer {
    if (buffer.format.channelCount != 1) return buffer;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:buffer.format.sampleRate channels:2];
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:buffer.frameLength];
    out.frameLength = buffer.frameLength;
    memcpy(out.floatChannelData[0], buffer.floatChannelData[0], buffer.frameLength * sizeof(float));
    memcpy(out.floatChannelData[1], buffer.floatChannelData[0], buffer.frameLength * sizeof(float));
    return out;
}

// The segment leaves the render at once: its units render nothing more, and
// the output is the file, sample for sample, from where playback stood.
- (void)testDisabledFXProcessNothingWhileTailsRing {
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:url]);
    _player.fx.delayTapBPM = 120;
    _player.fx.reverbSendEnabled = YES;
    _player.fx.delaySendEnabled = YES;
    [self play:url paused:NO position:0];
    [self render:9600];
    _player.fx.reverbSendEnabled = NO;
    _player.fx.delaySendEnabled = NO;
    [self render:2400];
    XCTAssertGreaterThan([_player.debugRenderCounts[@"unitRenders"] unsignedLongLongValue], 0ull, @"the sends rendered");
    [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:NO allowAnyDevice:NO];
    [_player runSyncOnQueue:^{}];
    NSDictionary *counts = _player.debugRenderCounts;
    XCTAssertFalse([counts[@"fxConnected"] boolValue]);
    XCTAssertTrue(_player.isPlaying);
    uint64_t rested = [counts[@"unitRenders"] unsignedLongLongValue];
    NSUInteger from = (NSUInteger)llround(_player.position * 48000);
    NSData *capture = [self renderSeconds:1.0];
    XCTAssertEqual([_player.debugRenderCounts[@"unitRenders"] unsignedLongLongValue], rested, @"a disabled segment rendered a unit");
    NSData *excerpt = [reference subdataWithRange:NSMakeRange(from * 2 * sizeof(float), 48000 * 2 * sizeof(float))];
    [self assertReference:excerpt capture:capture skip:0 tolerance:0];
    // The tails' pending rests fire without touching a unit.
    [self render:48000 * 12];
    XCTAssertEqual([_player.debugRenderCounts[@"unitRenders"] unsignedLongLongValue], rested);
}

// Not the container's 0, and the flags are never read as PCM's: FLAC's and
// ALAC's 24-bit flag carries the float bit.
- (void)testAudioPathReportsALosslessCodecsDeclaredDepth {
    NSDictionary<NSString *, NSArray *> *expected = @{
        @"lossless.flac": @[@"FLAC", @24, @NO], @"lossless.m4a": @[@"ALAC", @24, @NO],
        @"noise-48000-24-2.wav": @[@"PCM", @24, @NO], @"noise-48000-32-2.wav": @[@"PCM", @32, @YES],
    };
    for (NSString *name in expected) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:[self fixture:name] paused:NO position:0];
        [self render:4800];
        NSDictionary *source = _player.audioPathSnapshot[0];
        XCTAssertEqualObjects(source[@"codec"], expected[name][0], @"%@", name);
        XCTAssertEqual([source[@"bitsPerChannel"] intValue], [expected[name][1] intValue], @"%@", name);
        XCTAssertEqual([source[@"float"] boolValue], [expected[name][2] boolValue], @"%@: %@", name, source);
        XCTAssertTrue([source[@"lossless"] boolValue], @"%@", name);
    }
}

- (void)testAudioPathNamesTheOggCodecs {
    NSDictionary<NSString *, NSString *> *expected = @{@"lossy.ogg": @"Vorbis", @"lossy.opus": @"Opus"};
    for (NSString *name in expected) {
        NSURL *url = [self optionalFixture:name];
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:url paused:NO position:0];
        [self render:4800];
        NSDictionary *source = _player.audioPathSnapshot[0];
        XCTAssertEqualObjects(source[@"codec"], expected[name], @"%@", name);
        XCTAssertFalse([source[@"lossless"] boolValue], @"%@", name);
    }
}

// The decoder's stage carries both sides of a conversion: the file's decoded
// format and the bus's, which the Settings row shows as the decoder's output.
- (void)testAudioPathDecoderReportsBothSidesOfTheConversion {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"noise-44100-24-1.wav"] paused:NO position:0];
    [self render:4800];
    NSDictionary *decode = _player.audioPathSnapshot[1];
    XCTAssertEqualObjects(decode[@"read"], @"converted");
    XCTAssertEqual([decode[@"sampleRate"] doubleValue], 44100.0);
    XCTAssertEqual([decode[@"channels"] intValue], 1);
    XCTAssertEqual([decode[@"toSampleRate"] doubleValue], 48000.0);
    XCTAssertEqual([decode[@"toChannels"] intValue], 2);
    XCTAssertTrue([decode[@"resampled"] boolValue]);
    XCTAssertTrue([decode[@"mixed"] boolValue]);
}

// The player's half of the reopen wait's bound: a rate change completes while
// a late successor's reopen waits for a render held inside the bus.
- (void)testARebuildCompletesWhileAVoiceRenderIsStuck {
    self.continueAfterFailure = YES;
    [self playOnTheDecodePool:^{
        NSData *pcm = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
        [self play:[self write:[pcm subdataWithRange:NSMakeRange(0, 2000 * 8)] rate:48000 channels:2 name:@"ended-short.wav"] paused:NO position:0];
    }];
    __block AudioVoiceBus *bus;
    __block VibeVoiceID voice;
    [_player runSyncOnQueue:^{
        bus = [self->_player valueForKey:@"voiceBus"];
        voice = [[self->_player valueForKey:@"voice"] unsignedLongLongValue];
    }];
    dispatch_sync([bus decodeQueueAtIndex:0], ^{});
    XCTAssertEqual([bus snapshotOfVoice:voice].endOfStream, 2000u);
    dispatch_group_t stuck = dispatch_group_create();
    dispatch_group_t rebuild = dispatch_group_create();
    [bus debugHoldRender:YES];
    dispatch_group_async(stuck, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        [self->_player debugRenderOnCallerThread:256];
    });
    @try {
        [self settleUntil:^BOOL { return bus.debugRendersHeld == 1; }];
        [_player prefetchTrack:[AudioTrack withURL:[self fixture:@"noise-48000-24-2.wav"]]];
        [self settleUntil:^BOOL { return [bus snapshotOfVoice:voice].endOfStream == UINT64_MAX; }]; // the reopen waits
        dispatch_group_async(rebuild, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            XCTAssertTrue([self->_player debugSetOutputRate:96000]);
        });
        XCTAssertEqual(dispatch_group_wait(rebuild, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L,
                       @"the rate change completes within its bound while a render is held inside the bus");
        XCTAssertEqual(bus.debugRendersHeld, 1u, @"the render was still stuck when the rebuild completed");
        XCTAssertEqualWithAccuracy([_player.debugRenderCounts[@"outputRate"] doubleValue], 96000, 0);
    } @finally {
        [bus debugHoldRender:NO];
        XCTAssertEqual(dispatch_group_wait(stuck, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        XCTAssertEqual(dispatch_group_wait(rebuild, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
    }
    [_player runSyncOnQueue:^{ [self->_player drainVoiceBusOnQueue]; }];
    [self assertFinite:[self renderSeconds:0.1] peak:1.0f];
}

// A rebuild leaves the old bus's decoder to finish its read on its own:
// the player queue answers at once, the rate change completes with the read
// still stalled, and the re-voiced track reads the file only after that
// decoder has left it, then plays.
- (void)testAStalledFileReadHoldsNeitherTheQueueNorTheRebuild {
    self.continueAfterFailure = YES;
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:YES];
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    dispatch_semaphore_t reading = dispatch_semaphore_create(0), releaseRead = dispatch_semaphore_create(0);
    dispatch_semaphore_t rebuilt = dispatch_semaphore_create(0), responsive = dispatch_semaphore_create(0);
    Method read = class_getInstanceMethod(AudioFileHandle.class, @selector(readIntoBuffer:frameCount:error:));
    __block IMP original;
    __block _Atomic(BOOL) held = NO;
    IMP blocked = imp_implementationWithBlock(^BOOL(AudioFileHandle *file, AVAudioPCMBuffer *buffer, AVAudioFrameCount frames, NSError **error) {
        if ([file.url isEqual:url] && !atomic_exchange(&held, YES)) {
            dispatch_semaphore_signal(reading);
            dispatch_semaphore_wait(releaseRead, DISPATCH_TIME_FOREVER);
        }
        return ((BOOL (*)(id, SEL, AVAudioPCMBuffer *, AVAudioFrameCount, NSError **))original)
                (file, @selector(readIntoBuffer:frameCount:error:), buffer, frames, error);
    });
    original = method_setImplementation(read, blocked);
    long rebuildWait = 0, queueWait = 0;
    @try {
        [self play:url paused:NO position:0];
        XCTAssertEqual(dispatch_semaphore_wait(reading, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        AudioPlayer *player = _player;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            XCTAssertTrue([player debugSetOutputRate:96000]);
            dispatch_semaphore_signal(rebuilt);
        });
        rebuildWait = dispatch_semaphore_wait(rebuilt, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC));
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [player runSyncOnQueue:^{ dispatch_semaphore_signal(responsive); }];
        });
        queueWait = dispatch_semaphore_wait(responsive, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC));
        XCTAssertEqual(rebuildWait, 0L, @"the rate change waited on the stalled read");
        XCTAssertEqual(queueWait, 0L, @"the player queue waited on the stalled read");
        XCTAssertEqualWithAccuracy([_player.debugRenderCounts[@"outputRate"] doubleValue], 96000, 0);
        XCTAssertTrue(_player.isPlaying);
        // The re-voiced track reads nothing while the retired decoder may be
        // inside its file: the pump runs, and the position holds.
        NSTimeInterval before = _player.position;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        XCTAssertEqualWithAccuracy(_player.position, before, 0.0001, @"the file was read under the stalled decoder");
    } @finally {
        dispatch_semaphore_signal(releaseRead);
        if (rebuildWait) dispatch_semaphore_wait(rebuilt, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC));
        if (queueWait) dispatch_semaphore_wait(responsive, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC));
        [_player runSyncOnQueue:^{}];
    }
    // The read released, the retired decoder leaves and the track plays on.
    // The fixture is 2 s on the real timer: a runner that starves this thread
    // that long sees the track finish, and its position reset, between polls.
    NSTimeInterval resumedFrom = _player.position;
    BOOL (^played)(void) = ^BOOL { return self->_player.position > resumedFrom + 0.1 || [self count:@"finish"] == 1; };
    [self settleUntil:played];
    XCTAssertTrue(played(), @"the track never played after the decoder left");
    XCTAssertNil(_playError);
    // TRAP: the re-voiced track's decoder reads through the swizzle until the
    // player stops, so removing the block while a read is in flight frees it
    // under that decoder. Restore the original, stop the player and drain the
    // bus's decode queue first; only then can no read be inside the block.
    __block AudioVoiceBus *bus;
    [_player runSyncOnQueue:^{ bus = [self->_player valueForKey:@"voiceBus"]; }];
    method_setImplementation(read, original);
    [_player debugShutdown]; _player = nil;
    if ([bus decodeQueueAtIndex:0]) dispatch_sync([bus decodeQueueAtIndex:0], ^{});
    imp_removeBlock(blocked);
}

// A failed effect render is silence, not audio, and the status reaches the
// output unit; a rebuild hosts the units again and the chain renders.
- (void)testAFailedEffectSilencesTheSliceAndReachesTheOutputUnit {
    for (NSNumber *unit in @[@0, @1]) {
        [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
        _player.fx.lowKillEnabled = unit.intValue == 0;
        _player.fx.reverbSendEnabled = unit.intValue == 1;
        [self play:[self fixture:@"1000.wav"] paused:NO position:0];
        [self render:4800];
        __block BOOL uninitialized = NO;
        [_player runSyncOnQueue:^{ uninitialized = [self->_player.fx debugUninitializeUnitAtIndex:unit.unsignedIntegerValue]; }];
        XCTAssertTrue(uninitialized, @"unit %@", unit);
        NSError *error = nil;
        AVAudioPCMBuffer *output = [_player debugRenderFrames:256 error:&error];
        XCTAssertNil(output, @"unit %@: the output unit received a failed slice as audio", unit);
        XCTAssertNotNil(error, @"unit %@", unit);
        XCTAssertTrue([_player debugSetOutputRate:96000], @"unit %@", unit);
        [self assertFinite:[self renderSeconds:0.1] peak:1.0f];
    }
}

// With an error, rather than publishing Playing over nothing.
- (void)testAMissingOutputUnitFailsTheStart {
    self.continueAfterFailure = YES;
    Method initializer = class_getInstanceMethod(AudioOutputUnit.class, @selector(init));
    IMP failure = imp_implementationWithBlock(^id(id receiver) { return nil; });
    IMP original = method_setImplementation(initializer, failure);
    @try {
        _player = [[AudioPlayer alloc] initWithDeviceUID:@"" name:@"" enableFX:NO delegate:self];
        [self settleUntil:^BOOL { return [self count:@"init"] == 1; }];
        XCTAssertFalse(_player.manualRenderingActive);
        [_player play:[AudioTrack withURL:[self fixture:@"noise-48000-24-2.wav"]]];
        [self settleUntil:^BOOL { return [self count:@"start"] > 0 || self->_playError; }];
        XCTAssertNotNil(_playError, @"a missing output unit must fail the start");
        XCTAssertEqual(_playError.code, VibeAudioErrorEngineStartFailed);
        XCTAssertTrue(_player.isStopped);
        XCTAssertFalse(_player.outputAudioActive);
        XCTAssertEqual([self count:@"start"], 0u);
    } @finally {
        method_setImplementation(initializer, original);
        imp_removeBlock(failure);
    }
}

// An output unit made late — it could not be made at init — brings its
// device's rate before the play's segment is built, so the voice is built at
// that rate, not the fallback's; the output unit itself stays device-free here,
// so the start then fails as one without a unit does.
- (void)testAnOutputUnitMadeLateBringsItsRateBeforeTheVoice {
    self.continueAfterFailure = YES;
    [self startPlayerAt:44100 channels:2 fx:NO bitPerfect:NO automatic:NO];
    AudioPlayer *target = _player;
    __block NSUInteger created = 0;
    Method drives = class_getInstanceMethod(AudioPlayer.class, @selector(drivesOutputDeviceOnQueue));
    Method create = class_getInstanceMethod(AudioPlayer.class, NSSelectorFromString(@"createOutputUnitOnQueue"));
    __block IMP originalDrives, originalCreate;
    IMP driveReplacement = imp_implementationWithBlock(^BOOL(AudioPlayer *receiver) {
        return receiver == target ? YES : ((BOOL (*)(id, SEL))originalDrives)(receiver, @selector(drivesOutputDeviceOnQueue));
    });
    IMP createReplacement = imp_implementationWithBlock(^BOOL(AudioPlayer *receiver) {
        if (receiver != target) return ((BOOL (*)(id, SEL))originalCreate)(receiver, NSSelectorFromString(@"createOutputUnitOnQueue"));
        created++;
        // A unit follows its device's rate through applyOutputRateOnQueue:,
        // whose pipeline effect is this setter; no device is opened.
        SEL setter = NSSelectorFromString(@"setMasterBusFormatOnQueue:");
        ((void (*)(id, SEL, id))[receiver methodForSelector:setter])(receiver, setter,
                [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2]);
        return YES;
    });
    originalDrives = method_setImplementation(drives, driveReplacement);
    originalCreate = method_setImplementation(create, createReplacement);
    @try {
        [_player play:[AudioTrack withURL:[self fixture:@"noise-44100-24-2.wav"]]];
        [self settleUntil:^BOOL { return [self count:@"start"] > 0 || self->_playError; }];
        XCTAssertEqual(created, 1u);
        XCTAssertNotNil(_playError, @"no unit came of the creation, so the start fails");
        XCTAssertEqual([self count:@"start"], 0u);
        [_player runSyncOnQueue:^{
            AudioVoiceBus *bus = [target valueForKey:@"voiceBus"];
            XCTAssertNotNil(bus);
            XCTAssertEqual([target masterBusFormatOnQueue].sampleRate, 48000.0);
            XCTAssertEqual(bus.format.sampleRate, 48000.0, @"the segment was built at the fallback rate, not the output unit's");
        }];
    } @finally {
        method_setImplementation(drives, originalDrives);
        method_setImplementation(create, originalCreate);
        imp_removeBlock(driveReplacement);
        imp_removeBlock(createReplacement);
    }
}

// A voice parked at the fallback rate — a paused start with no unit — is
// re-voiced at the output unit's rate when a resume makes the unit, before the
// start; the device-free output unit then fails the start, and the voice stays
// parked at its position.
- (void)testAnOutputUnitMadeLateReconcilesAParkedVoice {
    self.continueAfterFailure = YES;
    [self startPlayerAt:44100 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"noise-44100-24-2.wav"] paused:YES position:1.5];
    AudioPlayer *target = _player;
    __block NSUInteger created = 0;
    Method drives = class_getInstanceMethod(AudioPlayer.class, @selector(drivesOutputDeviceOnQueue));
    Method create = class_getInstanceMethod(AudioPlayer.class, NSSelectorFromString(@"createOutputUnitOnQueue"));
    __block IMP originalDrives, originalCreate;
    IMP driveReplacement = imp_implementationWithBlock(^BOOL(AudioPlayer *receiver) {
        return receiver == target ? YES : ((BOOL (*)(id, SEL))originalDrives)(receiver, @selector(drivesOutputDeviceOnQueue));
    });
    IMP createReplacement = imp_implementationWithBlock(^BOOL(AudioPlayer *receiver) {
        if (receiver != target) return ((BOOL (*)(id, SEL))originalCreate)(receiver, NSSelectorFromString(@"createOutputUnitOnQueue"));
        created++;
        SEL setter = NSSelectorFromString(@"setMasterBusFormatOnQueue:");
        ((void (*)(id, SEL, id))[receiver methodForSelector:setter])(receiver, setter,
                [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2]);
        return YES;
    });
    originalDrives = method_setImplementation(drives, driveReplacement);
    originalCreate = method_setImplementation(create, createReplacement);
    @try {
        NSUInteger events = _events.count;
        [_player resume];
        [self settleUntil:^BOOL { return self->_playError != nil || self->_events.count > events; }];
        [_player runSyncOnQueue:^{}];
        XCTAssertEqual(created, 1u);
        XCTAssertNotNil(_playError, @"no unit came of the creation, so the resume's start fails");
        XCTAssertTrue(_player.isPaused, @"the failed start keeps the voice parked");
        XCTAssertEqualWithAccuracy(_player.position, 1.5, 0.01);
        [_player runSyncOnQueue:^{
            AudioVoiceBus *bus = [target valueForKey:@"voiceBus"];
            XCTAssertEqual([target masterBusFormatOnQueue].sampleRate, 48000.0);
            XCTAssertEqual(bus.format.sampleRate, 48000.0, @"the parked voice stayed at the fallback rate");
            XCTAssertEqual(bus.occupiedSlotCount, 1u, @"the voice was not re-voiced at the new rate");
        }];
    } @finally {
        method_setImplementation(drives, originalDrives);
        method_setImplementation(create, originalCreate);
        imp_removeBlock(driveReplacement);
        imp_removeBlock(createReplacement);
    }
}

// Runs `body` on a pump player whose output is a real AudioOutputUnit that
// never reaches the HAL: its configure does nothing and its start is `start`.
// The unit is attached through the production wiring, so its refusals reach
// the player the way a device's would.
- (void)withOutputUnitStartingAs:(OSStatus (^)(void))start body:(void (^)(AudioPlayer *target))body {
    [self startPlayerAt:44100 channels:2 fx:NO bitPerfect:NO automatic:NO];
    AudioPlayer *target = _player;
    Method drives = class_getInstanceMethod(AudioPlayer.class, @selector(drivesOutputDeviceOnQueue));
    Method create = class_getInstanceMethod(AudioPlayer.class, NSSelectorFromString(@"createOutputUnitOnQueue"));
    Method configure = class_getInstanceMethod(AudioOutputUnit.class, @selector(halConfigureFormat:renderProc:refCon:));
    Method halStart = class_getInstanceMethod(AudioOutputUnit.class, @selector(halStartUnit));
    __block IMP originalDrives, originalCreate;
    IMP driveReplacement = imp_implementationWithBlock(^BOOL(AudioPlayer *receiver) {
        return receiver == target ? YES : ((BOOL (*)(id, SEL))originalDrives)(receiver, @selector(drivesOutputDeviceOnQueue));
    });
    IMP createReplacement = imp_implementationWithBlock(^BOOL(AudioPlayer *receiver) {
        if (receiver != target) return ((BOOL (*)(id, SEL))originalCreate)(receiver, NSSelectorFromString(@"createOutputUnitOnQueue"));
        SEL attach = NSSelectorFromString(@"attachOutputUnitOnQueue:");
        ((void (*)(id, SEL, id))[receiver methodForSelector:attach])(receiver, attach, [[AudioOutputUnit alloc] init]);
        return YES;
    });
    IMP configureReplacement = imp_implementationWithBlock(^(id receiver, AVAudioFormat *format, void *proc, void *refCon) {});
    IMP startReplacement = imp_implementationWithBlock(^OSStatus(id receiver) { return start(); });
    originalDrives = method_setImplementation(drives, driveReplacement);
    originalCreate = method_setImplementation(create, createReplacement);
    IMP originalConfigure = method_setImplementation(configure, configureReplacement);
    IMP originalStart = method_setImplementation(halStart, startReplacement);
    @try {
        body(target);
    } @finally {
        __block AudioOutputUnit *unit = nil;
        [_player runSyncOnQueue:^{ unit = [target valueForKey:@"outputUnit"]; }];
        [unit waitUntilIdle];
        method_setImplementation(drives, originalDrives);
        method_setImplementation(create, originalCreate);
        method_setImplementation(configure, originalConfigure);
        method_setImplementation(halStart, originalStart);
        imp_removeBlock(driveReplacement);
        imp_removeBlock(createReplacement);
        imp_removeBlock(configureReplacement);
        imp_removeBlock(startReplacement);
    }
}

// An RME takes ~215 ms to start, a waking DAC seconds.
- (void)testASlowDeviceStartHoldsNeitherThePlayNorThePlayerQueue {
    self.continueAfterFailure = YES;
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    [self withOutputUnitStartingAs:^OSStatus {
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        return noErr;
    } body:^(AudioPlayer *target) {
        [self->_player play:[AudioTrack withURL:[self fixture:@"noise-44100-24-2.wav"]]];
        [self settleUntil:^BOOL { return [self count:@"start"] > 0 || self->_playError; }];
        XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0,
                       @"the device start never began");
        XCTAssertNil(self->_playError);
        [self settleUntil:^BOOL { return [self count:@"start"] >= 1; }];
        XCTAssertEqual([self count:@"start"], 1u, @"the play settled only once the device had started");
        XCTAssertTrue(self->_player.isPlaying);
        uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        [self->_player runSyncOnQueue:^{}];
        XCTAssertLessThan((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e6, 50.0,
                          @"the player queue waited on the device's start");
        [self->_player play:[AudioTrack withURL:[self fixture:@"noise-48000-24-2.wav"]]];
        [self settleUntil:^BOOL { return [self count:@"start"] > 1 || self->_playError; }];
        XCTAssertEqual([self count:@"start"], 2u, @"a play submitted during the device start waited for it");
        dispatch_semaphore_signal(release);
    }];
    XCTAssertNil(_playError);
}

// The refusal arrives after the player published Playing.
- (void)testARefusedDeviceStartParksThePlayAndSaysSo {
    self.continueAfterFailure = YES;
    [self withOutputUnitStartingAs:^OSStatus { return kAudioHardwareNotRunningError; } body:^(AudioPlayer *target) {
        [self->_player play:[AudioTrack withURL:[self fixture:@"noise-44100-24-2.wav"]]];
        [self settleUntil:^BOOL { return self->_playError != nil; }];
        [self->_player runSyncOnQueue:^{}];
        XCTAssertNotNil(self->_playError, @"the refusal was never reported");
        XCTAssertEqual(self->_playError.code, VibeAudioErrorEngineStartFailed);
        XCTAssertTrue(self->_player.isPaused, @"the refused start left the play Playing over nothing");
        XCTAssertFalse(self->_player.outputAudioActive);
        __block BOOL running = YES;
        [self->_player runSyncOnQueue:^{ running = [[target valueForKey:@"outputUnit"] running]; }];
        XCTAssertFalse(running, @"the refused unit is still asked to run");
        // The attempt left idle; the idle stop the park armed answers it again.
        XCTAssertFalse(self->_player.outputIdle);
        [self renderPastIdleStopExpectingIdleEdges:1];
    }];
}

// The path, stage by stage, as the Settings window and dump_audio_path read it.
- (void)testAudioPathReportsEveryStage {
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"noise-44100-16-2.wav"] paused:NO position:0];
    [self render:4800];
    NSArray<NSDictionary *> *path = _player.audioPathSnapshot;
    XCTAssertEqualObjects([path valueForKey:@"stage"],
                          (@[@"source", @"decode", @"bus", @"varispeed", @"fx", @"meter", @"output", @"device"]));
    NSDictionary *source = path[0], *decode = path[1], *bus = path[2], *varispeed = path[3], *fx = path[4], *meter = path[5], *output = path[6], *device = path[7];
    XCTAssertEqualObjects(source[@"file"], @"noise-44100-16-2.wav");
    XCTAssertEqualObjects(source[@"codec"], @"PCM");
    XCTAssertEqual([source[@"sampleRate"] doubleValue], 44100.0);
    XCTAssertEqual([source[@"bitsPerChannel"] intValue], 16);
    XCTAssertEqual([source[@"channels"] intValue], 2);
    XCTAssertTrue([source[@"lossless"] boolValue]);
    XCTAssertEqualObjects(decode[@"read"], @"converted");
    XCTAssertEqual([decode[@"fromSampleRate"] doubleValue], 44100.0);
    XCTAssertEqual([decode[@"toSampleRate"] doubleValue], 48000.0);
    XCTAssertEqualObjects(decode[@"algorithm"], @"r8brain-free-src");
    XCTAssertFalse([decode[@"mixed"] boolValue]);
    XCTAssertEqual([bus[@"sampleRate"] doubleValue], 48000.0);
    XCTAssertEqual([bus[@"liveVoices"] intValue], 1);
    XCTAssertTrue([varispeed[@"present"] boolValue]);
    XCTAssertFalse([varispeed[@"engaged"] boolValue]);
    XCTAssertEqual([varispeed[@"latencyFrames"] doubleValue], 0, @"no delay at zero pitch");
    _player.pitch = -1;
    [self render:4800];
    NSDictionary *pitched = _player.audioPathSnapshot[3];
    XCTAssertTrue([pitched[@"engaged"] boolValue]);
    XCTAssertEqualWithAccuracy([pitched[@"latencyFrames"] doubleValue], 64 / 0.99, 1e-9, @"the kernel's half-width at the ratio");
    XCTAssertTrue([fx[@"connected"] boolValue]);
    XCTAssertTrue([fx[@"inRender"] boolValue]);
    XCTAssertEqual([fx[@"hostedUnits"] intValue], 10);
    XCTAssertNotNil(fx[@"latencySeconds"], @"the dry path's latency");
    XCTAssertGreaterThanOrEqual([fx[@"latencySeconds"] doubleValue], 0);
    XCTAssertFalse([meter[@"present"] boolValue]);
    XCTAssertEqualObjects(output[@"renderedBy"], @"pump");
    XCTAssertEqual([output[@"sampleRate"] doubleValue], 48000.0);
    XCTAssertTrue([output[@"running"] boolValue]);
    XCTAssertFalse([output[@"idleStopPending"] boolValue]);
    XCTAssertFalse([device[@"present"] boolValue], @"no device under the pump");
    // Stopped, the output keeps running until the deferred idle stop, and
    // says so; after it, the output is idle.
    [_player stop];
    [self render:4800];
    output = _player.audioPathSnapshot[6];
    XCTAssertTrue([output[@"running"] boolValue]);
    XCTAssertTrue([output[@"idleStopPending"] boolValue]);
    [self render:48000 * 7];
    output = _player.audioPathSnapshot[6];
    XCTAssertFalse([output[@"running"] boolValue]);
    XCTAssertFalse([output[@"idleStopPending"] boolValue]);
}

// The idle stop waits for a send's tail: a reverb released before a pause
// keeps the output past the delay until the unit's declared tail rests, and
// a send still held through the pause keeps it no longer than that tail.
- (void)testAReleasedTailKeepsTheOutputPastTheIdleStop {
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
    _player.fx.reverbSendEnabled = YES;
    [self render:24000];
    _player.fx.reverbSendEnabled = NO; // the gate closes; the tail rings for the unit's declared time
    [_player pause];
    [self render:2048];
    __block BOOL active = NO;
    __block NSTimeInterval tail = 0;
    [_player runSyncOnQueue:^{ active = self->_player.fx.sendsActive; tail = self->_player.fx.longestTailSeconds; }];
    XCTAssertTrue(active, @"the released reverb's tail is not ringing");
    XCTAssertGreaterThan(tail, 6.0, @"a tail the idle stop's delay already covers proves nothing");
    [self renderSeconds:6.5];
    XCTAssertTrue([_player.debugRenderCounts[@"running"] boolValue], @"the idle stop cut a ringing tail");
    XCTAssertTrue([_player.audioPathSnapshot[6][@"idleStopPending"] boolValue]);
    [self renderSeconds:tail + 1.5];
    [_player runSyncOnQueue:^{ active = self->_player.fx.sendsActive; }];
    XCTAssertFalse(active, @"the tail never rested");
    XCTAssertFalse([_player.debugRenderCounts[@"running"] boolValue], @"the output kept running after the tail rested");
    XCTAssertTrue(_player.isPaused);
    // A send held through the pause: the stop waits its tail and no longer.
    [_player resume];
    [self render:4800];
    _player.fx.reverbSendEnabled = YES;
    [self render:4800];
    [_player pause];
    [self render:2048];
    [self renderSeconds:6.5];
    XCTAssertTrue([_player.debugRenderCounts[@"running"] boolValue]);
    [self renderSeconds:tail + 1.5];
    XCTAssertFalse([_player.debugRenderCounts[@"running"] boolValue], @"a held send held the output past its tail");
    _player.fx.reverbSendEnabled = NO;
}

// Silence to the far side of the idle stop's 6 s, in blocks large enough that
// the stretch costs nothing, then the edge `edges` counts.
- (void)renderPastIdleStopExpectingIdleEdges:(NSUInteger)edges {
    NSUInteger blockSize = _blockSize;
    _blockSize = 4096;
    [self renderSeconds:6.1];
    _blockSize = blockSize;
    [self settleUntil:^BOOL { return [self count:@"idle"] == edges; }];
    XCTAssertTrue(_player.outputIdle);
}

// outputIdle is what the iOS session's release waits for. A pause, a stop and
// a track's end: idle is the idle stop's edge, not the verb's.
- (void)testTheOutputIsIdleOnlyOnceItsIdleStopHasStoppedIt {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    XCTAssertTrue(_player.outputIdle, @"an output never started has nothing to stop");
    AudioTrack *track = [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
    [self render:4800];
    XCTAssertFalse(_player.outputIdle);
    [_player pause]; [self render:2048];
    XCTAssertTrue(_player.isPaused);
    XCTAssertFalse(_player.outputIdle, @"idle under a running output");
    [self renderPastIdleStopExpectingIdleEdges:1];
    XCTAssertFalse([_player.debugRenderCounts[@"running"] boolValue]);
    [_player resume]; [self render:4800];
    XCTAssertFalse(_player.outputIdle);
    [_player stop]; [self render:4800];
    XCTAssertTrue(_player.isStopped);
    XCTAssertFalse(_player.outputIdle, @"a stop leaves the output warm for the next play");
    [self renderPastIdleStopExpectingIdleEdges:2];
    [self play:track.url paused:NO position:1.9];
    [self renderSeconds:0.5];
    [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
    XCTAssertFalse(_player.outputIdle);
    [self renderPastIdleStopExpectingIdleEdges:3];
}

// The delay at 60 BPM declares a 25 s tail: ten seconds after the pause the
// output is still rendering it, which is when a fixed timer released the
// session under it.
- (void)testATailLongerThanTenSecondsHoldsTheOutputFromIdle {
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
    _player.fx.delayTapBPM = 60;
    _player.fx.delaySendEnabled = YES;
    [self render:24000];
    _player.fx.delaySendEnabled = NO;
    [_player pause]; [self render:2048];
    __block NSTimeInterval tail = 0;
    [_player runSyncOnQueue:^{ tail = self->_player.fx.longestTailSeconds; }];
    XCTAssertGreaterThan(tail, 10.0, @"a tail the old delay already covered proves nothing");
    _blockSize = 4096;
    [self renderSeconds:10.1];
    XCTAssertTrue([_player.debugRenderCounts[@"running"] boolValue], @"the idle stop cut a ringing tail");
    XCTAssertFalse(_player.outputIdle, @"idle under a ringing tail");
    XCTAssertEqual([self count:@"idle"], 0u);
    [self renderSeconds:tail + 1.5];
    XCTAssertFalse([_player.debugRenderCounts[@"running"] boolValue]);
    [self settleUntil:^BOOL { return [self count:@"idle"] == 1; }];
    XCTAssertTrue(_player.outputIdle);
}

// A resume inside the idle stop's delay cancels it: no edge, then or later.
- (void)testAResumeBeforeTheIdleStopLeavesNothingToRelease {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
    [self render:4800];
    [_player pause]; [self render:2048];
    [self renderSeconds:5];
    [_player resume];
    [self renderSeconds:1.5]; // past the cancelled stop's deadline, short of the file's end
    XCTAssertTrue(_player.isPlaying);
    XCTAssertFalse(_player.outputIdle);
    XCTAssertEqual([self count:@"idle"], 0u, @"the cancelled idle stop still reported");
}

// The idle edge is in flight to main when a new play starts the output: the
// edge still arrives, and the answer it finds is the newer start's.
- (void)testAnIdleEdgeOvertakenByANewPlayFindsTheOutputStarted {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    AudioTrack *track = [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
    [self render:4800];
    [_player pause]; [self render:2048];
    // Rendered without a turn of main's run loop, so the edge stays queued.
    for (NSUInteger rendered = 0; rendered < 48000 * 7 && !_player.outputIdle; rendered += 256) {
        XCTAssertNotNil([_player debugRenderFrames:256 error:NULL]);
    }
    XCTAssertTrue(_player.outputIdle);
    XCTAssertEqual([self count:@"idle"], 0u);
    [_player play:track];
    // Polled without a turn of main's run loop, which would deliver the queued edge.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (_player.outputIdle && deadline.timeIntervalSinceNow > 0) usleep(100);
    XCTAssertFalse(_player.outputIdle, @"the play never started the output");
    [self settleUntil:^BOOL { return [self count:@"idle"] == 1 && [self count:@"start"] == 2; }];
    for (NSDictionary *event in _events) {
        if ([event[@"event"] isEqual:@"idle"]) XCTAssertFalse([event[@"outputIdle"] boolValue], @"a stale edge read as idle");
    }
}

// An open that fails, and one that lands parked, never started the output:
// nothing will stop it later, so it must already answer idle.
- (void)testAFailedOrParkedOpenLeavesTheOutputIdle {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [_player play:[AudioTrack withURL:[_temporary URLByAppendingPathComponent:@"missing.wav"]]];
    [self settleUntil:^BOOL { return self->_playError != nil; }];
    XCTAssertTrue(_player.isStopped);
    XCTAssertTrue(_player.outputIdle, @"a failed open waits for a stop that cannot come");
    _playError = nil;
    [self play:[self fixture:@"noise-48000-24-2.wav"] paused:YES position:0.5];
    XCTAssertTrue(_player.isPaused);
    XCTAssertTrue(_player.outputIdle, @"a parked open waits for a stop that cannot come");
    [self renderSeconds:6.1];
    XCTAssertEqual([self count:@"idle"], 0u, @"an output that never left idle has no edge");
}

// iOS stops the unit seconds before it delivers a media-services reset, with
// no interruption: the player pauses once the verdicts have had their time,
// instead of publishing Playing over a dead output. Inside that time it has
// not, since an interruption's Began reads was-playing from it.
- (void)testASystemStopNoVerdictFollowsPauses {
    self.continueAfterFailure = YES;
    [self withOutputUnitStartingAs:^OSStatus { return noErr; } body:^(AudioPlayer *target) {
        [self->_player play:[AudioTrack withURL:[self fixture:@"noise-44100-24-2.wav"]]];
        [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
        __block AudioOutputUnit *unit = nil;
        [self->_player runSyncOnQueue:^{ unit = [target valueForKey:@"outputUnit"]; }];
        [unit waitUntilIdle];
        unit.failureHandler(nil, unit.runGeneration, NO);
        [self->_player runSyncOnQueue:^{}];
        [self renderSeconds:0.5];
        XCTAssertTrue(self->_player.isPlaying, @"paused before a verdict could read was-playing");
        XCTAssertEqual([self count:@"pause"], 0u);
        [self renderSeconds:0.6];
        [self settleUntil:^BOOL { return [self count:@"pause"] == 1; }];
        XCTAssertTrue(self->_player.isPaused);
        XCTAssertNil(self->_playError);
        [self renderPastIdleStopExpectingIdleEdges:1];
    }];
}

// A restart inside the verdict's time, as a route's recovery makes, is left
// playing.
- (void)testASystemStopARestartFollowsKeepsPlaying {
    self.continueAfterFailure = YES;
    [self withOutputUnitStartingAs:^OSStatus { return noErr; } body:^(AudioPlayer *target) {
        [self->_player play:[AudioTrack withURL:[self fixture:@"noise-44100-24-2.wav"]]];
        [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
        __block AudioOutputUnit *unit = nil;
        [self->_player runSyncOnQueue:^{ unit = [target valueForKey:@"outputUnit"]; }];
        [unit waitUntilIdle];
        unit.failureHandler(nil, unit.runGeneration, NO);
        [self->_player runSyncOnQueue:^{
            XCTAssertFalse([target renderingOnQueue]);
            XCTAssertTrue([target startOutputOnQueue:NULL]);
        }];
        [self renderSeconds:1.5];
        XCTAssertTrue(self->_player.isPlaying);
        XCTAssertEqual([self count:@"pause"], 0u);
    }];
}

// An interruption: the system stops the unit under the app and the verdict
// pauses. The output still answers idle only at its idle stop.
- (void)testASystemStopAnswersIdleAtItsIdleStop {
    self.continueAfterFailure = YES;
    [self withOutputUnitStartingAs:^OSStatus { return noErr; } body:^(AudioPlayer *target) {
        [self->_player play:[AudioTrack withURL:[self fixture:@"noise-44100-24-2.wav"]]];
        [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
        __block AudioOutputUnit *unit = nil;
        [self->_player runSyncOnQueue:^{ unit = [target valueForKey:@"outputUnit"]; }];
        [unit waitUntilIdle];
        unit.failureHandler(nil, unit.runGeneration, NO); // what RemoteIO's IsRunning listener reports
        [self->_player pause];
        [self settleUntil:^BOOL { return [self count:@"pause"] == 1; }];
        XCTAssertFalse([self->_player.debugRenderCounts[@"running"] boolValue]);
        XCTAssertFalse(self->_player.outputIdle, @"a system stop is not the idle stop");
        [self renderPastIdleStopExpectingIdleEdges:1];
    }];
}

- (void)checkDecodeFailureForSuccessor:(BOOL)successor afterFrames:(NSUInteger)after superseded:(BOOL)superseded repeatedURL:(BOOL)repeatedURL {
    NSData *pcm = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    NSURL *firstURL = [self write:[pcm subdataWithRange:NSMakeRange(0, (successor ? 2048 : 16000) * 8)]
            rate:48000 channels:2 name:@"failure-current.wav"];
    NSURL *failedURL = successor && !repeatedURL ? [self write:[pcm subdataWithRange:NSMakeRange(0, 16000 * 8)]
            rate:48000 channels:2 name:@"failure-successor.wav"] : firstURL;
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _player.declick = NO;
    __block BOOL refuse = YES;
    __block AudioFileHandle *firstHandle = nil;
    Method method = class_getInstanceMethod(AudioFileHandle.class, @selector(readIntoBuffer:frameCount:error:));
    __block IMP original;
    IMP replacement = imp_implementationWithBlock(^BOOL(AudioFileHandle *file, AVAudioPCMBuffer *buffer,
                                                        AVAudioFrameCount frames, NSError **error) {
        if (!firstHandle) firstHandle = file;
        if (refuse && (!repeatedURL || file != firstHandle) && [file.url isEqual:failedURL]
                && file.framePosition >= (AVAudioFramePosition)after) {
            buffer.frameLength = 0;
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
            return NO;
        }
        return ((BOOL (*)(id, SEL, id, AVAudioFrameCount, NSError **))original)(file,
                @selector(readIntoBuffer:frameCount:error:), buffer, frames, error);
    });
    original = method_setImplementation(method, replacement);
    @try {
        AudioTrack *track = [self play:firstURL paused:NO position:0];
        if (successor) {
            [_player prefetchTrack:[AudioTrack withURL:failedURL]];
            [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        }
        if (superseded) {
            // Hold main delivery until a new submission of the exact same row exists.
            XCTAssertNotNil([_player debugRenderFrames:256 error:NULL]);
            refuse = NO;
            [_player play:track];
            [self settleUntil:^BOOL { return [self count:@"start"] == 2; }];
            XCTAssertNil(_playError);
            [self render:1024];
            XCTAssertTrue(_player.isPlaying);
        }
        else {
            [self render:20000];
            if (successor && after == 0) {
                XCTAssertNil(_playError, @"an unheard successor failed against the current row");
                XCTAssertEqual([self count:@"advance"], 0u);
                [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
                XCTAssertEqual([self count:@"finish"], 1u);
            }
            else {
                XCTAssertNotNil(_playError);
                XCTAssertEqualObjects(_playError.userInfo[kVibeAudioErrorTrackURLKey], failedURL);
                XCTAssertEqual([self count:@"finish"], 0u, @"a failed decode auto-advanced as clean EOF");
                XCTAssertTrue(_player.isStopped);
                if (successor) {
                    [self settleUntil:^BOOL { return [self count:@"advance"] >= 1; }];
                    XCTAssertEqual([self count:@"advance"], 1u);
                }
            }
        }
    }
    @finally { method_setImplementation(method, original); imp_removeBlock(replacement); }
}

- (void)testCurrentDecodeFailureReportsErrorInsteadOfTrackEnd {
    [self checkDecodeFailureForSuccessor:NO afterFrames:4096 superseded:NO repeatedURL:NO];
}
- (void)testUnheardSuccessorFailureDoesNotResetTheCurrentRow {
    [self checkDecodeFailureForSuccessor:YES afterFrames:0 superseded:NO repeatedURL:NO];
}
- (void)testUnheardSuccessorFailureWithTheSameURLDoesNotResetTheCurrentRow {
    [self checkDecodeFailureForSuccessor:YES afterFrames:0 superseded:NO repeatedURL:YES];
}
- (void)testPromotedSuccessorFailureNamesTheSuccessor {
    [self checkDecodeFailureForSuccessor:YES afterFrames:4096 superseded:NO repeatedURL:NO];
}
- (void)testDecodeFailureDeliveryIsDroppedAfterReplayOfTheSameRow {
    [self checkDecodeFailureForSuccessor:NO afterFrames:0 superseded:YES repeatedURL:NO];
}

// A hung device holds its HAL reads 30 s: the rate a bind follows is the one
// the player queue waits for, and it waits at most its bound.
- (void)testAHungDeviceRateReadHoldsThePlayerQueueOnlyForItsBound {
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    __block _Atomic bool returned = false;
    Method method = class_getClassMethod(CoreAudioUtil.class, @selector(readNominalSampleRate:forDeviceID:));
    IMP replacement = imp_implementationWithBlock(^BOOL(id cls, Float64 *rate, AudioDeviceID deviceID) {
        dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        atomic_store(&returned, true);
        return NO;
    });
    [self withOutputUnitStartingAs:^OSStatus { return noErr; } body:^(AudioPlayer *target) {
        [target runSyncOnQueue:^{ [target ensureOutputUnitOnQueue]; }];
        IMP original = method_setImplementation(method, replacement);
        @try {
            uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            [target runSyncOnQueue:^{ [target followOutputDeviceRateOnQueue]; }];
            double waited = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e9;
            XCTAssertLessThan(waited, 2.0, @"the player queue waited out the hung device");
        } @finally {
            dispatch_semaphore_signal(release);
            [self settleUntil:^BOOL { return atomic_load(&returned); }];
            [self settleUntil:^BOOL { return [CoreAudioUtil performBoundedRead:^{} within:0.1 late:nil]; }];
            method_setImplementation(method, original);
            imp_removeBlock(replacement);
        }
    }];
}

- (void)testNewLocalPlayEscapesAStalledOldDecoder {
    self.continueAfterFailure = YES;
    [self playOnTheDecodePool:^{
        self->_player.declick = NO;
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
    }];
    __block AudioVoiceBus *bus;
    __block VibeVoiceID old;
    [_player runSyncOnQueue:^{
        bus = [self->_player valueForKey:@"voiceBus"];
        old = [[self->_player valueForKey:@"voice"] unsignedLongLongValue];
    }];
    dispatch_queue_t decoder = [bus decodeQueueAtIndex:0];
    [self settleUntil:^BOOL { return [bus snapshotOfVoice:old].written >= 65536; }];
    dispatch_semaphore_t reading = dispatch_semaphore_create(0), letRead = dispatch_semaphore_create(0);
    Method produce = class_getInstanceMethod(AudioVoiceBus.class, @selector(produceChunkForSlot:final:));
    __block IMP originalProduce;
    __block _Atomic(BOOL) heldRead = NO;
    IMP heldProduce = imp_implementationWithBlock(^uint32_t(id receiver, NSUInteger slot, BOOL *final) {
        if (receiver == bus && !heldRead) {
            heldRead = YES;
            dispatch_semaphore_signal(reading);
            dispatch_semaphore_wait(letRead, DISPATCH_TIME_FOREVER);
        }
        return ((uint32_t (*)(id, SEL, NSUInteger, BOOL *))originalProduce)(receiver, @selector(produceChunkForSlot:final:), slot, final);
    });
    originalProduce = method_setImplementation(produce, heldProduce);
    @try {
        for (int i = 0; i < 64 && !heldRead; i++) [self render:1024];
        XCTAssertEqual(dispatch_semaphore_wait(reading, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        NSURL *next = [self fixture:@"noise-48000-16-2.wav"];
        NSData *reference = [self sourcePCM:next];
        [self play:next paused:NO position:0];
        __block VibeVoiceID current;
        [_player runSyncOnQueue:^{ current = [[self->_player valueForKey:@"voice"] unsignedLongLongValue]; }];
        [self settleUntil:^BOOL { return [bus snapshotOfVoice:current].written >= 65536; }];
        NSData *blocked = [self renderSeconds:1];
        [self assertReference:[reference subdataWithRange:NSMakeRange(0, blocked.length)] capture:blocked skip:0 tolerance:0];
        dispatch_semaphore_signal(letRead);
        dispatch_sync(decoder, ^{});
        NSData *released = [self renderSeconds:0.25];
        [self assertReference:[reference subdataWithRange:NSMakeRange(blocked.length, released.length)] capture:released skip:0 tolerance:0];
        XCTAssertNil(_playError);
        XCTAssertEqual([self count:@"finish"], 0u, @"releasing the old read must not finish the new song");
    } @finally {
        dispatch_semaphore_signal(letRead);
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        [_player runSyncOnQueue:^{ [bus stopReadingThen:^{ dispatch_semaphore_signal(stopped); }]; }];
        XCTAssertEqual(dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        method_setImplementation(produce, originalProduce);
        imp_removeBlock(heldProduce);
    }
}

@end
