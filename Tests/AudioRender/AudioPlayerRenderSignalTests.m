//
//  AudioPlayerRenderSignalTests.m
//

#import "AudioPlayerRenderTestCase.h"
#import "AudioLevelMeter+Debug.h"

static float PeakLevel(const float levels[kLevelBandCount]) {
    float peak = 0; for (NSUInteger i = 0; i < kLevelBandCount; i++) peak = MAX(peak, levels[i]); return peak;
}

// The level meter and the signal diagnostics.
@interface AudioPlayerRenderSignalTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderSignalTests

// The meter is kept across demand toggles, so an install must forget the
// accumulator, and the analyzer's partial window and references with it.
- (void)testMeterReinstallPublishesNoEarlierAudio {
    AVAudioPCMBuffer *tone = [self read:[self fixture:@"1000.wav"]];
    AudioLevelPublisher *publisher = [[AudioLevelPublisher alloc] init];
    AudioLevelMeter *tap = [[AudioLevelMeter alloc] initWithFormat:tone.format publisher:publisher
                                         normalizationMode:kLevelDefaultNormalizationMode];
    UInt32 count = VibeLevelPublicationFrameCount(tone.format.sampleRate);
    XCTAssertGreaterThanOrEqual(tone.frameLength, count);
    AVAudioPCMBuffer *silence = [self read:[self fixture:@"silence.wav"]];
    XCTAssertGreaterThanOrEqual(silence.frameLength, count);
    AudioTimeStamp stamp = { .mFlags = kAudioTimeStampSampleTimeValid };
    float levels[kLevelBandCount];
    for (int toggle = 0; toggle < 3; toggle++) {
        [tap install];
        VibeLevelMeterRender(tap.meter, tone.floatChannelData, tone.format.channelCount, count, &stamp);
        XCTAssertTrue([publisher copyLevels:levels count:kLevelBandCount sequence:NULL]);
        XCTAssertGreaterThan(PeakLevel(levels), 0.0f, @"toggle %d: the tone was not published", toggle);
        [tap remove];
        [tap install];
        VibeLevelMeterRender(tap.meter, silence.floatChannelData, tone.format.channelCount, count, &stamp);
        XCTAssertTrue([publisher copyLevels:levels count:kLevelBandCount sequence:NULL]);
        XCTAssertEqual(PeakLevel(levels), 0.0f, @"toggle %d: the new session published the tone before it", toggle);
        [tap remove];
    }
}

// A callback that began before the remove publishes into the session it
// began, which has ended.
- (void)testAMeterCallbackStalledAcrossAReinstallPublishesNothingIntoTheNewSession {
    AVAudioPCMBuffer *tone = [self read:[self fixture:@"1000.wav"]];
    AudioLevelPublisher *publisher = [[AudioLevelPublisher alloc] init];
    AudioLevelMeter *tap = [[AudioLevelMeter alloc] initWithFormat:tone.format publisher:publisher
                                         normalizationMode:kLevelDefaultNormalizationMode];
    UInt32 count = VibeLevelPublicationFrameCount(tone.format.sampleRate);
    XCTAssertGreaterThanOrEqual(tone.frameLength, count);
    AVAudioPCMBuffer *silence = [self read:[self fixture:@"silence.wav"]];
    XCTAssertGreaterThanOrEqual(silence.frameLength, count);
    AudioTimeStamp stamp = { .mFlags = kAudioTimeStampSampleTimeValid };
    [tap install];
    VibeLevelMeterRender(tap.meter, tone.floatChannelData, tone.format.channelCount, count - 1024, &stamp); // one block short of publishing
    [tap debugHoldRender:YES];
    dispatch_group_t stalled = dispatch_group_create();
    dispatch_group_async(stalled, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        VibeLevelMeterRender(tap.meter, tone.floatChannelData, tone.format.channelCount, 1024, &stamp);
    });
    [self settleUntil:^BOOL { return tap.debugRendersHeld == 1; }];
    [tap remove];
    [tap install];
    [tap debugHoldRender:NO];
    XCTAssertEqual(dispatch_group_wait(stalled, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L,
                   @"the stalled callback did not finish once the hold lifted");
    float levels[kLevelBandCount] = {0};
    XCTAssertFalse([publisher copyLevels:levels count:kLevelBandCount sequence:NULL],
                   @"the stalled callback published the tone into the new session, peak %g", PeakLevel(levels));
    VibeLevelMeterRender(tap.meter, silence.floatChannelData, tone.format.channelCount, count, &stamp);
    XCTAssertTrue([publisher copyLevels:levels count:kLevelBandCount sequence:NULL]);
    XCTAssertEqual(PeakLevel(levels), 0.0f, @"the new session opened on the previous session's audio");
    [tap remove];
}

- (void)testMeterTapDoesNotChangeSamples {
    for (NSNumber *fx in @[@NO,@YES]) {
        [self startPlayerAt:48000 channels:2 fx:fx.boolValue bitPerfect:!fx.boolValue automatic:NO];
        NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=VibePCM([self read:url]);
        [self play:url paused:NO position:0]; [self render:16000];
        _player.levelsEnabled=YES;
        __block AudioLevelMeter *tap;
        [_player runSyncOnQueue:^{
            tap = [self->_player debugLevelMeter];
            XCTAssertNotEqual([[tap signalDiagnosticSnapshot][@"request"] unsignedLongLongValue], 0u);
        }];
        [self render:16000];
        [_player runSyncOnQueue:^{
            NSDictionary *signal = [tap signalDiagnosticSnapshot];
            XCTAssertEqualObjects(signal[@"status"], @"captured");
            XCTAssertTrue([signal[@"aboveThreshold"] boolValue]);
            XCTAssertGreaterThan([signal[@"finiteRMS"] doubleValue], 0.1);
            XCTAssertLessThanOrEqual([signal[@"peak"] doubleValue], 0.5);
            XCTAssertEqual([signal[@"nonfiniteSamples"] unsignedLongLongValue], 0u);
        }];
        _player.levelsEnabled=NO; [self render:68800];
        [_player runSyncOnQueue:^{
            XCTAssertEqualObjects([tap signalDiagnosticSnapshot][@"completion"], @"first signal");
        }];
        [self assertReference:reference capture:_capture skip:[self startupSkip] tolerance:0];
    }
}
- (void)testSignalDiagnosticsBoundSilentCaptureAndRearm {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"silence.wav"] paused:NO position:0];
    _player.levelsEnabled=YES;
    __block AudioLevelMeter *tap;
    __block uint64_t request;
    __block NSDictionary *signal;
    NSMutableArray<NSDictionary *> *completed = [NSMutableArray array];
    [_player runSyncOnQueue:^{
        tap = [self->_player debugLevelMeter];
        request = [tap beginSignalDiagnosticsAtTime:[self->_player outputRenderTimeOnQueue] waitingForRetiredAudio:NO completion:^(NSDictionary *snapshot) { [completed addObject:snapshot]; }];
        XCTAssertNotEqual(request, 0u);
    }];
    [self render:192000];
    [_player runSyncOnQueue:^{
        XCTAssertFalse([tap pollSignalDiagnostics:request elapsedSeconds:0]);
        XCTAssertEqual(completed.count, 1u);
        signal = completed.firstObject;
        XCTAssertEqualObjects(signal[@"completion"], @"window elapsed");
    }];
    XCTAssertEqualObjects(signal[@"status"], @"captured");
    XCTAssertEqual([signal[@"request"] unsignedLongLongValue], request);
    XCTAssertGreaterThan([signal[@"frames"] unsignedLongLongValue], 0u);
    XCTAssertLessThanOrEqual([signal[@"frames"] unsignedLongLongValue], 144000u);
    XCTAssertEqual([signal[@"finiteRMS"] doubleValue], 0);
    XCTAssertEqual([signal[@"peak"] doubleValue], 0);
    XCTAssertFalse([signal[@"aboveThreshold"] boolValue]);
    XCTAssertEqualWithAccuracy([signal[@"observedLeadingSilenceMS"] doubleValue],
                              [signal[@"frames"] doubleValue] / 48, 1e-6);
    XCTAssertEqual([signal[@"firstSignalSampleTime"] longLongValue], -1);
    [self render:24000];
    [_player runSyncOnQueue:^{
        XCTAssertEqualObjects([tap signalDiagnosticSnapshot], signal);
        XCTAssertFalse([tap pollSignalDiagnostics:request elapsedSeconds:0]);
        XCTAssertEqual(completed.count, 1u);
        request = [tap beginSignalDiagnosticsAtTime:[self->_player outputRenderTimeOnQueue] waitingForRetiredAudio:NO completion:^(NSDictionary *snapshot) { [completed addObject:snapshot]; }];
        XCTAssertNotEqual(request, [signal[@"request"] unsignedLongLongValue]);
    }];
    [self render:16000];
    [_player runSyncOnQueue:^{ signal = [tap signalDiagnosticSnapshot]; }];
    XCTAssertEqualObjects(signal[@"status"], @"captured");
    XCTAssertEqual([signal[@"request"] unsignedLongLongValue], request);
    XCTAssertGreaterThan([signal[@"frames"] unsignedLongLongValue], 0u);
    XCTAssertLessThan([signal[@"frames"] unsignedLongLongValue], 24000u);
}
- (void)testSignalDiagnosticsKeepInterruptedCaptures {
    for (NSString *action in @[@"meter removed", @"superseded"]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        _player.levelsEnabled=YES;
        [self play:[self fixture:@"silence.wav"] paused:NO position:0];
        NSMutableArray<NSDictionary *> *completed = [NSMutableArray array];
        __block AudioLevelMeter *tap;
        __block uint64_t request;
        [_player runSyncOnQueue:^{
            tap = [self->_player debugLevelMeter];
            request = [tap beginSignalDiagnosticsAtTime:[self->_player outputRenderTimeOnQueue] waitingForRetiredAudio:NO completion:^(NSDictionary *snapshot) { [completed addObject:snapshot]; }];
        }];
        [self render:16000];
        [_player runSyncOnQueue:^{
            NSDictionary *partial = [tap signalDiagnosticSnapshot];
            XCTAssertGreaterThan([partial[@"frames"] unsignedLongLongValue], 0u);
            XCTAssertFalse([partial[@"aboveThreshold"] boolValue]);
            if ([action isEqual:@"meter removed"]) [tap remove];
            else [tap beginSignalDiagnosticsAtTime:[self->_player outputRenderTimeOnQueue] waitingForRetiredAudio:NO completion:^(NSDictionary *snapshot) { [completed addObject:snapshot]; }];
            XCTAssertEqual(completed.count, 1u);
            NSDictionary *result = completed.firstObject;
            XCTAssertEqualObjects(result[@"completion"], action);
            XCTAssertEqualObjects(result[@"frames"], partial[@"frames"]);
            XCTAssertEqualObjects(result[@"observedLeadingSilenceMS"], partial[@"observedLeadingSilenceMS"]);
            XCTAssertEqual([result[@"request"] unsignedLongLongValue], request);
            XCTAssertFalse([tap pollSignalDiagnostics:request elapsedSeconds:0]);
            if ([action isEqual:@"superseded"]) {
                XCTAssertEqualObjects([tap signalDiagnosticSnapshot][@"status"], @"no buffers observed");
                [tap remove];
                XCTAssertEqual(completed.count, 2u);
                XCTAssertEqualObjects(completed.lastObject[@"completion"], @"meter removed");
                XCTAssertEqualObjects(completed.lastObject[@"status"], @"no buffers observed");
            } else {
                XCTAssertEqualObjects([tap signalDiagnosticSnapshot], result);
                [tap remove]; [tap remove];
                XCTAssertEqual(completed.count, 1u);
            }
        }];
        [self render:16000];
        [_player runSyncOnQueue:^{ XCTAssertEqual(completed.count, [action isEqual:@"superseded"] ? 2u : 1u); }];
    }
}
- (void)testDefaultSignalDiagnosticsMeasureLeadingSilence {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    _player.levelsEnabled=YES;
    [self play:[self fixture:@"impulse.wav"] paused:NO position:0];
    [self render:24000];
    NSDictionary *signal = [self settledSignalSnapshot];
    XCTAssertEqualObjects(signal[@"status"], @"captured");
    XCTAssertTrue([signal[@"aboveThreshold"] boolValue]);
    XCTAssertEqualObjects(signal[@"completion"], @"first signal");
    XCTAssertLessThan([signal[@"frames"] unsignedLongLongValue], 24000u);
    XCTAssertEqualWithAccuracy([signal[@"observedLeadingSilenceMS"] doubleValue], 250, 1000.0 / 48000);
    [self render:24000];
    [_player runSyncOnQueue:^{
        AudioLevelMeter *tap = [self->_player debugLevelMeter];
        XCTAssertEqualObjects([tap signalDiagnosticSnapshot], signal);
    }];
}
- (void)testSignalDiagnosticsExcludePreviousTrack {
    for (NSNumber *rate in @[@44100, @48000]) for (NSNumber *fx in @[@NO, @YES])
    for (NSNumber *fade in @[@10, @500]) for (NSNumber *silence in @[@300, @700, @1500]) {
        // Isolate the direct-rate cut. SRC retains filter history across it.
        if (!fx.boolValue && rate.doubleValue != 48000) continue;
        [self startPlayerAt:rate.doubleValue channels:2 fx:fx.boolValue bitPerfect:!fx.boolValue automatic:NO];
        _player.crossfadeMilliseconds = fade.integerValue;
        _player.declick = fx.boolValue; // the bit-perfect case is the cut, which nothing overlaps
        _player.levelsEnabled=YES;
        [self play:[self fixture:@"1000.wav"] paused:NO position:0];
        [self render:12123];
        VibeTestTrack *next = [VibeTestTrack withURL:[self fixture:[NSString stringWithFormat:@"quiet-intro-%@.wav", silence]]];
        NSUInteger starts = [self count:@"start"];
        [_player play:next];
        [self settleUntil:^BOOL { return [self count:@"start"] > starts; }];
        [self render:(NSUInteger)((silence.doubleValue + 300) * _rate / 1000)];
        NSDictionary *signal = [self settledSignalSnapshot];
        XCTAssertTrue([signal[@"aboveThreshold"] boolValue]);
        if (fx.boolValue) {
            XCTAssertGreaterThan([signal[@"observationStartMS"] doubleValue], 0); // the old track's fade, excluded
        } else {
            XCTAssertLessThan([signal[@"observationStartMS"] doubleValue], 1); // cut: nothing overlaps the start
        }
        if (fx.boolValue && fade.integerValue > silence.integerValue) {
            XCTAssertGreaterThanOrEqual([signal[@"firstSignalAfterStartMS"] doubleValue], fade.doubleValue);
            XCTAssertLessThan([signal[@"observedLeadingSilenceMS"] doubleValue], 2);
        } else {
            XCTAssertEqualWithAccuracy([signal[@"firstSignalAfterStartMS"] doubleValue], silence.doubleValue, 2, @"%@", signal);
            XCTAssertEqualWithAccuracy([signal[@"observationStartMS"] doubleValue] + [signal[@"observedLeadingSilenceMS"] doubleValue],
                                      silence.doubleValue, 2, @"%@", signal);
        }
    }
}
- (void)testSignalDiagnosticsAtGaplessBoundary {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    _player.levelsEnabled=YES;
    [self play:[self fixture:@"1000.wav"] paused:NO position:0];
    VibeTestTrack *next = [VibeTestTrack withURL:[self fixture:@"quiet-intro-700.wav"]];
    [_player prefetchTrack:next];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    [self render:48000 * 5];
    NSDictionary *signal = [self settledSignalSnapshot];
    XCTAssertEqualObjects(_player.currentTrack, next);
    [self settleUntil:^BOOL { return [self count:@"advance"] >= 1; }];
    XCTAssertEqual([self count:@"advance"], 1u);
    XCTAssertTrue([signal[@"aboveThreshold"] boolValue]);
    XCTAssertEqualWithAccuracy([signal[@"firstSignalAfterStartMS"] doubleValue], 700, 2, @"%@", signal);
    XCTAssertEqualWithAccuracy([signal[@"observationStartMS"] doubleValue] + [signal[@"observedLeadingSilenceMS"] doubleValue], 700, 2);
}
- (void)testSignalDiagnosticsAfterIdleRestart {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    _player.levelsEnabled=YES;
    [self play:[self fixture:@"1000.wav"] paused:NO position:0]; [self render:144123];
    [self play:[self fixture:@"quiet-intro-300.wav"] paused:NO position:0]; [self render:24000];
    [_player stop]; [self render:48000 * 7];
    XCTAssertFalse([_player.debugRenderCounts[@"running"] boolValue]);
    [self play:[self fixture:@"quiet-intro-700.wav"] paused:NO position:0]; [self render:48000];
    NSDictionary *signal = [self settledSignalSnapshot];
    XCTAssertTrue([signal[@"aboveThreshold"] boolValue], @"%@", signal);
    XCTAssertEqualWithAccuracy([signal[@"firstSignalAfterStartMS"] doubleValue], 700, 2, @"%@", signal);
    XCTAssertEqualWithAccuracy([signal[@"observedLeadingSilenceMS"] doubleValue], 700, 2);
}

@end
