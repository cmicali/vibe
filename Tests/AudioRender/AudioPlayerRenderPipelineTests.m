//
//  AudioPlayerRenderPipelineTests.m
//

#import "AudioPlayerRenderTestCase.h"
#import "AudioDevice.h"
#import "AudioFX.h"
#import "AudioFXMath.h"
#import "CoreAudioUtil.h"
#import <objc/runtime.h>

// FX, pitch, SRC quality, stuck renders, routing, device switches, and transport under stress.
@interface AudioPlayerRenderPipelineTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderPipelineTests

- (void)testLowKillResponseAndReturnToTransparency {
    for (NSString *tone in @[@"20.wav",@"100.wav",@"1000.wav",@"8000.wav"]) {
        [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
        [self play:[self fixture:tone] paused:NO position:0];
        NSData *dry=[self renderSeconds:0.5];
        _player.fx.lowKillEnabled=YES;
        NSData *cut=[self renderSeconds:0.5];
        double gain=VibeRMS(cut,2,0,NSMakeRange(12000,12000))/VibeRMS(dry,2,0,NSMakeRange(12000,12000));
        if ([tone isEqual:@"20.wav"]) XCTAssertLessThan(gain,0.02);
        if ([tone isEqual:@"8000.wav"]) XCTAssertEqualWithAccuracy(gain,1,0.02);
        _player.fx.lowKillBoostActive=YES; NSData *boost=[self renderSeconds:0.5];
        if ([tone isEqual:@"100.wav"]) XCTAssertLessThan(VibeRMS(boost,2,0,NSMakeRange(12000,12000)),VibeRMS(cut,2,0,NSMakeRange(12000,12000)));
        _player.fx.lowKillEnabled=NO; [self renderSeconds:0.5]; XCTAssertFalse(_player.fx.lowKillBoostActive);
        NSData *restored=[self renderSeconds:0.5];
        XCTAssertEqualWithAccuracy(VibeRMS(restored,2,0,NSMakeRange(0,24000)),VibeRMS(dry,2,0,NSMakeRange(12000,12000)),0.00001);
    }
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=VibePCM([self read:url]);
    [self play:url paused:NO position:0]; _player.fx.lowKillEnabled=YES; [self render:12000];
    _player.fx.lowKillEnabled=NO; [self render:60000];
    NSData *rest=[reference subdataWithRange:NSMakeRange(72000*8,24000*8)];
    [self assertReference:rest capture:[self renderSeconds:0.6] skip:0 tolerance:0];
}
// Every way an effect is engaged — the mac's keys, the boost, the pad's cutoff
// and sends, an off landing mid-sweep, a drag — rests once released, and at
// rest the file replays exactly with no unit rendered. A low kill parked at the
// floor instead of rested is a resonant high-pass still lifting the sub-bass.
- (void)testEveryReleasedEffectRestsAndReplaysTheFileExactly {
    NSDictionary<NSString *, void (^)(AudioFX *)> *engages = @{
        @"low kill": ^(AudioFX *fx) { fx.lowKillEnabled = YES; },
        @"low kill boosted": ^(AudioFX *fx) { fx.lowKillEnabled = YES; fx.lowKillBoostActive = YES; },
        @"reverb": ^(AudioFX *fx) { fx.reverbSendEnabled = YES; },
        @"delays": ^(AudioFX *fx) { fx.delaySendEnabled = YES; fx.shortDelaySendEnabled = YES; },
        @"pad corner": ^(AudioFX *fx) {
            fx.lowKillCutoffHz = VibeFXPadLowCutHz(1); fx.reverbSendLevel = VibeFXPadReverbLevel(1); fx.delaySendLevel = VibeFXPadDelayLevel(1);
        },
        @"pad near the floor": ^(AudioFX *fx) { fx.lowKillCutoffHz = VibeFXPadLowCutHz(0.01f); },
    };
    NSDictionary<NSString *, void (^)(AudioFX *)> *releases = @{
        @"low kill": ^(AudioFX *fx) { fx.lowKillEnabled = NO; },
        @"low kill boosted": ^(AudioFX *fx) { fx.lowKillBoostActive = NO; fx.lowKillEnabled = NO; },
        @"reverb": ^(AudioFX *fx) { fx.reverbSendEnabled = NO; },
        @"delays": ^(AudioFX *fx) { fx.delaySendEnabled = NO; fx.shortDelaySendEnabled = NO; },
        // PlaybackController's lift: the corner, off on both axes.
        @"pad corner": ^(AudioFX *fx) {
            fx.lowKillCutoffHz = VibeFXPadLowCutHz(0); fx.reverbSendLevel = VibeFXPadReverbLevel(0); fx.delaySendLevel = VibeFXPadDelayLevel(0);
        },
        @"pad near the floor": ^(AudioFX *fx) { fx.lowKillCutoffHz = VibeFXPadLowCutHz(0); },
    };
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:url]);
    uint64_t (^unitRenders)(void) = ^uint64_t { return [self->_player.debugRenderCounts[@"unitRenders"] unsignedLongLongValue]; };
    for (NSString *name in engages) for (NSNumber *interrupted in @[@NO, @YES]) {
        [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
        _player.levelsEnabled = YES;
        _player.fx.delayTapBPM = 120;
        [self play:url paused:NO position:0];
        engages[name](_player.fx);
        if (interrupted.boolValue) {
            // Off and on again inside the 80 ms sweep; on the pad, a drag's
            // steps, each close enough to be written to the engaged filter.
            [self render:_blockSize];
            releases[name](_player.fx); [self render:_blockSize];
            engages[name](_player.fx); [self render:12000];
            if ([name hasPrefix:@"pad"]) {
                for (float hz = 300; hz < 400; hz *= 1.05f) {
                    _player.fx.lowKillCutoffHz = hz; [self render:_blockSize];
                }
            }
            releases[name](_player.fx); [self render:_blockSize];
            engages[name](_player.fx);
        }
        [self render:12000];
        XCTAssertGreaterThan(unitRenders(), 0ull, @"%@: the effect never rendered", name);
        releases[name](_player.fx);
        uint64_t rested = unitRenders();
        for (int second = 0; second < 60; second++) {
            rested = unitRenders();
            [self render:48000];
            if (unitRenders() == rested) break;
        }
        XCTAssertEqual(unitRenders(), rested, @"%@ (interrupted %@): never rested", name, interrupted);
        [self play:url paused:NO position:0];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
        XCTAssertEqual(unitRenders(), rested, @"%@ (interrupted %@): a released effect rendered", name, interrupted);
    }
}
- (void)testDelayTimingStereoAndDecay {
    for (NSNumber *shortDelay in @[@NO,@YES]) for (NSNumber *bpm in @[@120,@160]) {
        [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
        _player.fx.delayTapBPM=bpm.floatValue;
        if (shortDelay.boolValue) _player.fx.shortDelaySendEnabled=YES; else _player.fx.delaySendEnabled=YES;
        [self play:[self fixture:@"impulse.wav"] paused:NO position:0];
        NSData *output=[self renderSeconds:3]; [self assertFinite:output peak:1];
        NSUInteger tap=(NSUInteger)llround(48000*60.0/bpm.doubleValue*(shortDelay.boolValue?0.25:0.5));
        NSUInteger impulse=12000;
        double left=VibeRMS(output,2,0,NSMakeRange(impulse+tap,256));
        double right=VibeRMS(output,2,1,NSMakeRange(impulse+tap,256));
        XCTAssertGreaterThan(left,right*1.9); XCTAssertGreaterThan(left,0.00001);
        XCTAssertGreaterThan(VibeRMS(output,2,1,NSMakeRange(impulse+2*tap,256)),VibeRMS(output,2,0,NSMakeRange(impulse+2*tap,256))*1.9);
        XCTAssertLessThan(VibeRMS(output,2,0,NSMakeRange(impulse+5*tap,256)),left);
        _player.fx.delaySendEnabled=NO; _player.fx.shortDelaySendEnabled=NO;
        NSData *tail=[self renderSeconds:4]; [self assertFinite:tail peak:1];
        XCTAssertLessThan(VibeRMS(tail,2,0,NSMakeRange(3*48000,48000)),0.0001);
    }
}
- (void)testReverbTailAndRapidFXChanges {
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    _player.fx.reverbSendEnabled=YES; [self play:[self fixture:@"impulse.wav"] paused:NO position:0];
    NSData *first=[self renderSeconds:0.6];
    _player.fx.reverbSendEnabled=NO; NSData *tail=[self renderSeconds:5];
    XCTAssertGreaterThan(VibeRMS(first,2,0,NSMakeRange(24000,4800)),0.000001);
    XCTAssertGreaterThan(VibeRMS(tail,2,0,NSMakeRange(0,4800)),0.000001);
    XCTAssertLessThan(VibeRMS(tail,2,0,NSMakeRange(4*48000,48000)),VibeRMS(tail,2,0,NSMakeRange(0,48000)));
    for (int i=0;i<20;i++) {
        _player.fx.lowKillEnabled=i%2; _player.fx.reverbSendEnabled=i%2;
        _player.fx.delaySendEnabled=i%2; _player.fx.shortDelaySendEnabled=!(i%2); _player.fx.delayTapBPM=80+i*7;
        [self render:127];
    }
    _player.fx.lowKillEnabled=NO; _player.fx.reverbSendEnabled=NO; _player.fx.delaySendEnabled=NO; _player.fx.shortDelaySendEnabled=NO;
    [self assertFinite:[self renderSeconds:1] peak:1];
}
- (void)testPitchFrequencyDurationAndReset {
    for (NSNumber *pitch in @[@(-8),@8]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO]; _player.pitch=pitch.floatValue;
        [self play:[self fixture:@"1000.wav"] paused:NO position:0];
        NSData *data=[self renderSeconds:1]; double ratio=1+pitch.doubleValue/100;
        XCTAssertEqualWithAccuracy(VibeToneAmplitude(data,2,0,48000,1000*ratio,NSMakeRange(12000,24000)),0.25,0.002);
        XCTAssertEqualWithAccuracy(_player.position,ratio,0.02);
        [self render:(NSUInteger)(48000*(4/ratio-1+0.1))];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u);
    }
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"1000.wav"] paused:NO position:0];
    _player.pitch=4;
    NSData *shifted=[self renderSeconds:0.5];
    XCTAssertEqualWithAccuracy(VibeToneAmplitude(shifted,2,0,48000,1040,NSMakeRange(12000,12000)),0.25,0.002);
    _player.pitch=0;
    NSData *restored=[self renderSeconds:0.5];
    XCTAssertEqualWithAccuracy(VibeToneAmplitude(restored,2,0,48000,1000,NSMakeRange(12000,12000)),0.25,0.002);
    // Back at zero the unit leaves the chain: it renders no more.
    uint64_t renders=[_player.debugRenderCounts[@"varispeedRenders"] unsignedLongLongValue];
    [self render:24000];
    XCTAssertEqual([_player.debugRenderCounts[@"varispeedRenders"] unsignedLongLongValue],renders);
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; [self play:url paused:NO position:0];
    [self assertReference:VibePCM([self read:url]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
}
// A slice that ramps the ratio down keeps the kernel stretched for where the
// ramp starts. A 22 kHz tone is in that kernel's stopband at +16%, so the
// slice ramping to −1% is silent; with the target's kernel the tone would
// pass while the ratio is still above 1, and fold back. Once the ratio has
// landed, the tone plays at −1% as it should, about 6 dB down.
- (void)testARampDownKeepsTheWiderKernel {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _blockSize = 4096;
    NSData *tone = VibeStereoTone(3 * 48000, 48000, 22000, 0.5f);
    _player.maxPitch = 16;
    _player.pitch = 16;
    [self play:[self write:tone rate:48000 channels:2 name:@"22k.wav"] paused:NO position:0];
    [self render:48000];
    _player.pitch = -1;
    NSData *ramp = [self renderSeconds:4096 / 48000.0];
    [self render:4096];
    NSData *landed = [self renderSeconds:8192 / 48000.0];
    XCTAssertLessThan(VibeRMS(ramp, 2, 0, NSMakeRange(0, 4096)), 1e-5, @"the ramp down let the tone through");
    XCTAssertGreaterThan(VibeRMS(landed, 2, 0, NSMakeRange(0, 8192)), 0.1, @"the tone plays once the ratio has landed");
}
// Under the pump the output cannot follow the file's rate, so this measures
// the bus's converter: the fallback a device that refuses a rate takes.
- (void)testSampleRateConversionQuality {
    for (NSArray<NSNumber *> *rates in @[@[@48000,@44100],@[@48000,@96000],@[@48000,@32000],@[@44100,@48000],@[@96000,@44100]]) {
        NSNumber *rate=rates[1];
        NSString *tone=[NSString stringWithFormat:@"tone-%@.wav",rates[0]];
        [self startPlayerAt:rate.doubleValue channels:2 fx:NO bitPerfect:YES automatic:NO];
        [self play:[self fixture:tone] paused:NO position:0]; NSData *data=[self renderSeconds:1];
        NSRange window=NSMakeRange((NSUInteger)(_rate*0.25),(NSUInteger)(_rate*0.5));
        double amplitude=VibeToneAmplitude(data,2,0,_rate,1000,window);
        XCTAssertLessThan(fabs(20*log10(amplitude/0.25)),0.01);
        XCTAssertEqualWithAccuracy(_player.position,1,0.02);
        double signal=amplitude/sqrt(2), rms=VibeRMS(data,2,0,window);
        XCTAssertLessThan(fabs(rms-signal),0.00001);
        [self render:(NSUInteger)(_rate*3.1)];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u);
        [self startPlayerAt:rate.doubleValue channels:2 fx:NO bitPerfect:YES automatic:NO];
        [self play:[self fixture:@"23000.wav"] paused:NO position:0]; data=[self renderSeconds:1];
        if (_rate<48000) XCTAssertLessThan(VibeRMS(data,2,0,window),0.000032); // -90 dBFS alias ceiling
    }
}
// A render stuck inside the pipeline past the wait's bound, on a thread of its
// own, must not let a withdrawal free or reset what it is inside, and no later
// render may clear the evidence that it is: the pipeline admits one render at a
// time, so the rebuilt output's callbacks render silence meanwhile. A rate
// change replaces the meter, the bus, the varispeed hosting and the FX chain,
// and each stays allocated until the first drain that sees the render outside.
- (void)testAStuckRenderDefersEveryTeardownUntilItLeaves {
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    _player.levelsEnabled = YES;
    [self play:[self fixture:@"100.wav"] paused:NO position:0];
    [self render:4096];
    __weak AudioLevelMeter *tap = nil;
    __weak AudioVoiceBus *bus = nil;
    @autoreleasepool {
        tap = _player.debugLevelMeter;
        bus = [_player valueForKey:@"voiceBus"]; // the ivar, read between renders
        XCTAssertNotNil(tap);
        XCTAssertNotNil(bus);
    }
    XCTAssertEqual([_player.debugRenderCounts[@"renderRefusals"] unsignedIntegerValue], 0u);
    [_player debugHoldRenderInside:YES];
    dispatch_group_t stuck = dispatch_group_create();
    dispatch_group_async(stuck, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        [self->_player debugRenderOnCallerThread:256]; // an output unit's callback, blocked inside the old pipeline
    });
    [self settleUntil:^BOOL { return [self->_player.debugRenderCounts[@"rendersHeld"] unsignedIntegerValue] == 1; }];
    XCTAssertTrue([_player debugSetOutputRate:96000]);
    XCTAssertGreaterThanOrEqual([_player.debugRenderCounts[@"renderLeaveWork"] unsignedIntegerValue], 4u,
                                @"the tap, the bus, the varispeed hosting and the FX chain wait for the render");
    XCTAssertNotNil(tap, @"the meter was freed under a render");
    XCTAssertNotNil(bus, @"the bus was freed under a render");
    XCTAssertTrue(_player.isPlaying);
    XCTAssertEqualWithAccuracy([_player.debugRenderCounts[@"outputRate"] doubleValue], 96000, 0);
    // The rebuilt output's renders find a render inside: silence, and the
    // parked teardowns stay parked, since the render they wait for is inside.
    [_capture setLength:0];
    @autoreleasepool { [self render:512]; }
    const float *refused = _capture.bytes;
    for (NSUInteger i = 0; i < _capture.length / sizeof(float); i++) {
        XCTAssertEqual(refused[i], 0.0f, @"a refused render wrote sound at sample %lu", (unsigned long)i);
    }
    XCTAssertGreaterThanOrEqual([_player.debugRenderCounts[@"renderRefusals"] unsignedIntegerValue], 2u);
    XCTAssertGreaterThanOrEqual([_player.debugRenderCounts[@"renderLeaveWork"] unsignedIntegerValue], 4u,
                                @"a refused render ran the teardowns of the render still inside");
    XCTAssertNotNil(tap, @"the meter was freed under a render another render followed");
    XCTAssertNotNil(bus, @"the bus was freed under a render another render followed");
    [_player debugHoldRenderInside:NO];
    XCTAssertEqual(dispatch_group_wait(stuck, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L,
                   @"the held render did not leave once the hold lifted");
    XCTAssertEqual([_player.debugRenderCounts[@"rendersHeld"] unsignedIntegerValue], 0u);
    NSUInteger refusals = [_player.debugRenderCounts[@"renderRefusals"] unsignedIntegerValue];
    @autoreleasepool { [self render:256]; } // the render left; the drain after this one runs the parked teardowns
    XCTAssertEqual([_player.debugRenderCounts[@"renderLeaveWork"] unsignedIntegerValue], 0u);
    // The beta signal probe's poll holds the old meter until its next 100 ms
    // tick of the pump's clock finds it removed; nothing else may.
    @autoreleasepool { [self render:9600]; }
    XCTAssertNil(tap, @"the meter outlived the render it waited for");
    XCTAssertNil(bus, @"the bus outlived the render it waited for");
    [self assertFinite:[self renderSeconds:0.1] peak:1.0f];
    XCTAssertEqual([_player.debugRenderCounts[@"renderRefusals"] unsignedIntegerValue], refusals,
                   @"a render was refused with none inside");
}

- (void)testFormatChangesAndModeToggles {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    for (NSString *file in @[@"noise-44100-16-1.wav",@"noise-96000-24-2.wav",@"noise-48000-32-1.wav",@"noise-48000-24-2.wav"]) {
        [self play:[self fixture:file] paused:NO position:0]; [self assertFinite:[self renderSeconds:0.1] peak:0.6];
    }
    [_player setBitPerfectOutput:YES exclusiveOutput:NO enableFX:NO allowAnyDevice:NO];
    // A new play settles on the mode's chain even without a HAL destination.
    [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
    XCTAssertFalse([_player.debugRenderCounts[@"varispeed"] boolValue]);
    [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:NO allowAnyDevice:NO]; [self render:2048];
    XCTAssertTrue([_player.debugRenderCounts[@"varispeed"] boolValue]);
    XCTAssertFalse(_player.bitPerfectReport.enabled);
}
- (void)testLiveFXAndBitPerfectRouting {
    for (NSNumber *rate in @[@44100, @48000, @96000]) for (NSNumber *initialFX in @[@NO, @YES]) {
        [self startPlayerAt:rate.doubleValue channels:2 fx:initialFX.boolValue bitPerfect:NO automatic:NO];
        if (!initialFX.boolValue) {
            XCTAssertLessThanOrEqual([_player.debugRenderCounts[@"hostedUnits"] unsignedIntegerValue], 1u);
        }
        NSURL *url = [self fixture:[NSString stringWithFormat:@"noise-%@-24-2.wav", rate]];
        AudioTrack *track = [self play:url paused:YES position:0.25];
        NSUInteger installedNodes = 0;
        for (int i = 0; i < 8; i++) {
            BOOL bitPerfect = i % 2;
            [_player setBitPerfectOutput:bitPerfect exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
            NSDictionary *counts = _player.debugRenderCounts;
            XCTAssertEqual([counts[@"fxConnected"] boolValue], !bitPerfect);
            XCTAssertEqual([counts[@"varispeed"] boolValue], !bitPerfect);
            XCTAssertTrue(_player.isPaused);
            XCTAssertEqual(_player.currentTrack, track);
            XCTAssertEqualWithAccuracy(_player.position, 0.25, 1.0 / _rate);
            if (i == 0) installedNodes = [counts[@"hostedUnits"] unsignedIntegerValue];
            XCTAssertLessThanOrEqual([counts[@"hostedUnits"] unsignedIntegerValue], installedNodes);
        }
        [_player resume];
        [self render:4096];
        for (NSNumber *enabled in @[@YES, @NO, @YES]) {
            double position = _player.position;
            [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:enabled.boolValue allowAnyDevice:NO];
            NSDictionary *counts = _player.debugRenderCounts;
            XCTAssertEqual([counts[@"fxConnected"] boolValue], enabled.boolValue);
            XCTAssertTrue(_player.isPlaying);
            XCTAssertEqual(_player.currentTrack, track);
            XCTAssertEqualWithAccuracy(_player.position, position, 1.0 / _rate);
            [self assertFinite:[self renderSeconds:0.1] peak:0.3];
        }
        XCTAssertEqual([self count:@"finish"], 0u);
        [self settleUntil:^BOOL { return [self count:@"start"] >= 1; }];
        XCTAssertEqual([self count:@"start"], 1u);
        [_player setBitPerfectOutput:YES exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
        [self play:url paused:NO position:0];
        [self assertReference:VibePCM([self read:url]) capture:[self renderSeconds:2.1]
                         skip:[self startupSkip] tolerance:0];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"], 1u);
    }
}

- (void)testBitPerfectDeviceSelectionConstrainsQueuedCrossfade {
    AudioDevice *a = [[AudioDevice alloc] initWithName:@"A" uid:@"a" deviceId:1 isSystemDefault:YES transportType:kAudioDeviceTransportTypeVirtual];
    AudioDevice *b = [[AudioDevice alloc] initWithName:@"B" uid:@"b" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[a, b]; } retryScheduler:nil];
    Method method = class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance));
    IMP replacement = imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; });
    IMP original = method_setImplementation(method, replacement);
    @try {
        _outputModesProvider = ^(NSString *uid, BOOL *bitPerfect, BOOL *exclusive) {
            *bitPerfect = [uid isEqualToString:@"b"];
            *exclusive = NO;
        };
        for (NSNumber *selectBeforePlay in @[@YES, @NO]) {
            [self startPlayerAt:44100 channels:2 fx:YES bitPerfect:NO automatic:NO];
            _player.crossfadeMilliseconds = 2000;
            [self play:[self fixture:@"noise-44100-24-2.wav"] paused:NO position:0];
            [self render:4410];
            NSUInteger starts = [self count:@"start"];
            __weak AudioPlayer *weakPlayer = _player;
            AudioTrack *next = [AudioTrack withURL:[self fixture:@"noise-44100-16-2.wav"]];
            // Queue both submissions before either can settle or main can apply
            // dependent settings. The mode can land before or during the open.
            [_player runSyncOnQueue:^{
                if (selectBeforePlay.boolValue) {
                    [weakPlayer setOutputDevice:2 completion:^{ weakPlayer.crossfadeMilliseconds = 10; }];
                    [weakPlayer play:next];
                } else {
                    [weakPlayer play:next];
                    [weakPlayer setOutputDevice:2 completion:^{ weakPlayer.crossfadeMilliseconds = 10; }];
                }
            }];
            [_player runSyncOnQueue:^{}];
            [self settleUntil:^BOOL { return [self count:@"start"] > starts || self->_playError; }];
            XCTAssertNil(_playError);
            XCTAssertTrue(_player.bitPerfectReport.enabled);
            XCTAssertEqual(_player.crossfadeMilliseconds, 10);
            [_capture setLength:0];
            [self render:4410];
            XCTAssertEqual([_player.debugRenderCounts[@"retiredFades"] unsignedIntegerValue], 0u,
                           @"Bit-perfect playback retained a two-second crossfade: %@", _player.debugRenderCounts);
            XCTAssertEqualWithAccuracy([_player.debugRenderCounts[@"gain"] doubleValue], 1, 1e-6);
            [self render:88200];
            [self assertReference:VibePCM([self read:[self fixture:@"noise-44100-16-2.wav"]])
                          capture:_capture skip:2205 tolerance:0];
        }
    } @finally {
        [_player debugShutdown]; _player = nil;
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
    }
}

- (void)testFailedDeviceSwitchReconcilesOutputGraph {
    // System Output's default comes from the manager's snapshot, so each case
    // is a snapshot: the default present (its bind refused), none published
    // yet, devices without a default, or no device at all.
    AudioDevice *systemDefault = [[AudioDevice alloc] initWithName:@"Default" uid:@"default" deviceId:1
                                                   isSystemDefault:YES transportType:kAudioDeviceTransportTypeVirtual];
    AudioDevice *undefaulted = [[AudioDevice alloc] initWithName:@"Other" uid:@"other" deviceId:1
                                                 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    __block NSArray<AudioDevice *> *snapshot = nil;
    __block AudioDeviceManager *devices = nil;
    // Replace only the device I/O boundaries; the real rebuild and PCM path run.
    // The bind retry is the one timer among them: two real seconds out, it
    // reports an unpublished default again, into the replay of a run that slow.
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getClassMethod(CoreAudioUtil.class, @selector(readSystemDefaultOutputDeviceID:)),
        class_getInstanceMethod(AudioPlayer.class, @selector(setOutputUnitDevice:)),
        class_getInstanceMethod(AudioPlayer.class, @selector(scheduleSystemOutputBindRetryOnQueue)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *device) { *device = 1; return YES; }),
        imp_implementationWithBlock(^BOOL(id player, AudioDeviceID device) { return NO; }),
        imp_implementationWithBlock(^(id player) {}),
    };
    IMP originals[sizeof(methods) / sizeof(*methods)];
    const NSUInteger swizzled = sizeof(methods) / sizeof(*methods);
    for (NSUInteger i = 0; i < swizzled; i++) originals[i] = method_setImplementation(methods[i], replacements[i]);
    @try {
        for (NSString *failure in @[@"concrete", @"system-refused", @"system-unpublished",
                                    @"system-undefaulted", @"system-missing"]) {
        BOOL publish = ![failure isEqualToString:@"concrete"] && ![failure isEqualToString:@"system-unpublished"];
        snapshot = [failure isEqualToString:@"system-refused"] ? @[systemDefault]
                 : [failure isEqualToString:@"system-undefaulted"] ? @[undefaulted] : @[];
        devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) {
            return publish ? snapshot : nil;
        } retryScheduler:nil];
        if (publish) {
            dispatch_semaphore_t published = dispatch_semaphore_create(0);
            [devices refreshOutputDevicesWithCompletion:^(BOOL ok) { dispatch_semaphore_signal(published); }];
            XCTAssertEqual(dispatch_semaphore_wait(published,
                    dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        }
        for (NSString *state in @[@"stopped", @"paused", @"playing"]) {
            BOOL systemOutput = [failure hasPrefix:@"system-"];
            BOOL defaultBindRefused = [failure isEqualToString:@"system-refused"];
            // Only a published snapshot with no device at all parks the track,
            // and a default missing among present devices is a moment's gap
            // while macOS moves it, bound by the retry without an error.
            BOOL parked = [failure isEqualToString:@"system-missing"];
            BOOL reportsError = ![failure isEqualToString:@"system-undefaulted"];
            BOOL committedSystemOutput = systemOutput && !defaultBindRefused;
            [self startPlayerAt:44100 channels:2 fx:YES bitPerfect:YES automatic:NO];
            NSURL *url = [self fixture:@"noise-44100-24-2.wav"];
            if (![state isEqualToString:@"stopped"]) {
                [self play:url paused:[state isEqualToString:@"paused"] position:0];
                [self render:4096];
            }
            XCTAssertFalse([_player.debugRenderCounts[@"fxConnected"] boolValue]);
            if (systemOutput) {
                [_player runSyncOnQueue:^{ self->_player.currentlyRequestedAudioDeviceId = 2; }];
            }
            NSInteger requestedDevice = _player.currentlyRequestedAudioDeviceId;
            NSTimeInterval position = _player.position;
            AudioTrack *track = _player.currentTrack;
            NSUInteger deviceChanges = [self count:@"device"];
            __block BOOL completed = NO;
            __weak AudioPlayerRenderTests *weakSelf = self;
            // An absent destination has no saved modes, as when a device
            // disappears after selection but before the queued bind.
            [_player setOutputDevice:(systemOutput ? -1 : 3) completion:^{
                AudioPlayerRenderTests *strongSelf = weakSelf;
                NSArray *deviceEvents = [strongSelf->_events filteredArrayUsingPredicate:
                        [NSPredicate predicateWithFormat:@"event == 'device'"]];
                XCTAssertEqual(deviceEvents.count, deviceChanges + 1);
                XCTAssertEqualObjects(deviceEvents.lastObject[@"device"],
                                      @(committedSystemOutput ? -1 : requestedDevice));
                completed = YES;
            }];
            [self settleUntil:^BOOL { return completed; }];
            XCTAssertEqual(_playError != nil, reportsError, @"%@ %@: %@", failure, state, _playError);
            XCTAssertEqual(_player.currentlyRequestedAudioDeviceId, committedSystemOutput ? -1 : requestedDevice);
            XCTAssertEqual(_player.bitPerfectReport.enabled, !committedSystemOutput);
            XCTAssertEqual([_player.debugRenderCounts[@"fxConnected"] boolValue], committedSystemOutput);
            if (committedSystemOutput && ![state isEqualToString:@"stopped"]) {
                XCTAssertEqual(_player.currentTrack, track);
                XCTAssertEqualWithAccuracy(_player.position, position, 1.0 / _rate);
                XCTAssertEqual(_player.isPaused, parked || [state isEqualToString:@"paused"]);
                XCTAssertTrue([_player.debugRenderCounts[@"varispeed"] boolValue]);
            } else {
                XCTAssertTrue(_player.isStopped);
            }
            // Unchanged modes stay a no-op; replay must still render exact PCM.
            [_player setBitPerfectOutput:!committedSystemOutput exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
            _playError = nil;
            [self play:url paused:NO position:0];
            XCTAssertEqual([_player.debugRenderCounts[@"fxConnected"] boolValue], committedSystemOutput);
            XCTAssertEqual([_player.debugRenderCounts[@"varispeed"] boolValue], committedSystemOutput);
            [self assertReference:VibePCM([self read:url]) capture:[self renderSeconds:2.1]
                             skip:[self startupSkip] tolerance:0];
        }
        }
    } @finally {
        [_player debugShutdown]; _player = nil;
        for (NSUInteger i = 0; i < swizzled; i++) {
            method_setImplementation(methods[i], originals[i]);
            imp_removeBlock(replacements[i]);
        }
    }
}

- (void)testFXBypassClearsWetTails {
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    _player.fx.reverbSendEnabled = YES;
    _player.fx.delaySendEnabled = YES;
    _player.fx.shortDelaySendEnabled = YES;
    [self play:[self fixture:@"impulse.wav"] paused:NO position:0];
    NSData *wet = [self renderSeconds:0.6];
    XCTAssertGreaterThan(VibeRMS(wet, 2, 0, NSMakeRange(24000, 4800)), 0.000001);
    [_player setBitPerfectOutput:YES exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
    [self render:2048];
    [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
    NSData *dry = [self renderSeconds:1];
    XCTAssertFalse(_player.fx.reverbSendEnabled);
    XCTAssertFalse(_player.fx.delaySendEnabled);
    XCTAssertFalse(_player.fx.shortDelaySendEnabled);
    XCTAssertEqual(VibeRMS(dry, 2, 0, NSMakeRange(0, dry.length / 8)), 0);
    XCTAssertEqual([self count:@"finish"], 0u);
}

- (void)testQueuedFXBypassPreservesLaterEffectActions {
    for (NSNumber *bitPerfect in @[@NO, @YES]) {
        [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
        _player.fx.lowKillEnabled = YES;
        _player.fx.lowKillBoostActive = YES;
        _player.fx.reverbSendEnabled = YES;
        _player.fx.delaySendEnabled = YES;
        _player.fx.shortDelaySendEnabled = YES;
        (void)_player.debugRenderCounts;
        // Hold the queue until the later UI actions have published their intent.
        [self withPlayerQueueHeld:^{
            AudioPlayer *player = self->_player;
            [player setBitPerfectOutput:bitPerfect.boolValue exclusiveOutput:NO enableFX:bitPerfect.boolValue allowAnyDevice:NO];
            XCTAssertFalse(player.fx.lowKillEnabled);
            XCTAssertFalse(player.fx.lowKillBoostActive);
            XCTAssertFalse(player.fx.reverbSendEnabled);
            XCTAssertFalse(player.fx.delaySendEnabled);
            XCTAssertFalse(player.fx.shortDelaySendEnabled);
            [player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
            player.fx.lowKillEnabled = YES;
            player.fx.lowKillBoostActive = YES;
            player.fx.reverbSendEnabled = YES;
            player.fx.delaySendEnabled = YES;
            player.fx.shortDelaySendEnabled = YES;
        }];
        XCTAssertTrue([_player.debugRenderCounts[@"fxConnected"] boolValue]);
        XCTAssertTrue(_player.fx.lowKillEnabled);
        XCTAssertTrue(_player.fx.lowKillBoostActive);
        XCTAssertTrue(_player.fx.reverbSendEnabled);
        XCTAssertTrue(_player.fx.delaySendEnabled);
        XCTAssertTrue(_player.fx.shortDelaySendEnabled);
        [self play:[self fixture:@"impulse.wav"] paused:NO position:0];
        NSData *wet = [self renderSeconds:0.6];
        XCTAssertGreaterThan(VibeRMS(wet, 2, 0, NSMakeRange(24000, 4800)), 0.000001);
    }
}

- (void)testFailedAndEmptyOpenRecover {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    NSURL *empty=[_temporary URLByAppendingPathComponent:@"empty.wav"];
    [[NSData data] writeToURL:empty atomically:YES];
    for (NSURL *url in @[empty,[_temporary URLByAppendingPathComponent:@"missing.wav"]]) {
        _playError=nil; [_player play:[AudioTrack withURL:url]];
        [self settleUntil:^BOOL { return self->_playError!=nil; }];
        XCTAssertTrue(_player.isStopped); XCTAssertEqual([self count:@"finish"],0u);
        _playError=nil; [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
        XCTAssertGreaterThan(VibeRMS([self renderSeconds:0.1],2,0,NSMakeRange(960,3840)),0.1);
        [_player stop]; [self render:2048];
    }
}
- (void)testRepeatedTransportAndResourceBound {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    for (int i=0;i<40;i++) {
        [self play:[self fixture:i%2?@"noise-48000-24-2.wav":@"noise-48000-24-1.wav"] paused:NO position:0];
        [self render:512]; [_player pause]; [_player resume]; [_player seekToPosition:0.25];
        [self render:2048]; [_player stop]; [self render:2048];
        XCTAssertEqual([self count:@"finish"],0u); XCTAssertEqual([_player.debugRenderCounts[@"hostedUnits"] unsignedIntegerValue],0u);
        XCTAssertEqual([_player.debugRenderCounts[@"retiredFades"] unsignedIntegerValue],0u);
    }
}
// Gain flat within 0.01 dB, duration exact, and a tone above the bus's Nyquist
// below -90 dBFS.
- (void)testOrdinaryPlaybackConvertsRateInTheBus {
    for (NSArray<NSNumber *> *rates in @[@[@48000,@44100],@[@44100,@48000],@[@96000,@44100]]) {
        NSNumber *rate=rates[1];
        NSString *tone=[NSString stringWithFormat:@"tone-%@.wav",rates[0]];
        [self startPlayerAt:rate.doubleValue channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:[self fixture:tone] paused:NO position:0]; NSData *data=[self renderSeconds:1];
        XCTAssertTrue([_player.debugRenderCounts[@"varispeed"] boolValue]);
        NSRange window=NSMakeRange((NSUInteger)(_rate*0.25),(NSUInteger)(_rate*0.5));
        double amplitude=VibeToneAmplitude(data,2,0,_rate,1000,window);
        XCTAssertLessThan(fabs(20*log10(amplitude/0.25)),0.01);
        XCTAssertEqualWithAccuracy(_player.position,1,0.02);
        double signal=amplitude/sqrt(2), rms=VibeRMS(data,2,0,window);
        XCTAssertLessThan(fabs(rms-signal),0.00001);
        [self render:(NSUInteger)(_rate*3.1)];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u);
        [self startPlayerAt:rate.doubleValue channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:[self fixture:@"23000.wav"] paused:NO position:0]; data=[self renderSeconds:1];
        if (_rate<48000) XCTAssertLessThan(VibeRMS(data,2,0,window),0.000032); // -90 dBFS alias ceiling
    }
}
// Thirty plays in a hundred milliseconds under a two-second crossfade: the
// pool has eight slots and keeps two free by cutting the oldest fading voice,
// every play still starts, every voice still ends, and once the last fade is
// out only the current voice is live with nothing left fading.
- (void)testSkipStormStaysInsideThePoolAndSettles {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _player.crossfadeMilliseconds=2000;
    // Five-second files: the last one must outlive every two-second fade-out.
    NSData *noise=VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    NSMutableData *longNoise=[NSMutableData data];
    while (longNoise.length<5*48000*8) [longNoise appendData:noise];
    NSArray<NSURL *> *urls=@[[self write:longNoise rate:48000 channels:2 name:@"storm-a.wav"],
                             [self write:longNoise rate:48000 channels:2 name:@"storm-b.wav"]];
    [self play:urls[0] paused:NO position:0]; [self render:4800];
    for (int i=0;i<30;i++) {
        NSUInteger starts=[self count:@"start"];
        [_player play:[AudioTrack withURL:urls[(i+1)%2]]];
        [self settleUntil:^BOOL { return [self count:@"start"]>starts || self->_playError; }];
        XCTAssertNil(_playError);
        [self render:160]; // 3.3 ms between skips
        XCTAssertLessThanOrEqual([_player.debugRenderCounts[@"retiredFades"] unsignedIntegerValue],8u);
        XCTAssertLessThanOrEqual([_player.debugRenderCounts[@"liveVoices"] unsignedIntegerValue],8u);
    }
    NSData *tail=[self renderSeconds:2.2];
    [self assertFinite:tail peak:2.0];
    XCTAssertEqual([_player.debugRenderCounts[@"retiredFades"] unsignedIntegerValue],0u);
    XCTAssertEqual([_player.debugRenderCounts[@"liveVoices"] unsignedIntegerValue],1u);
    [self settleUntil:^BOOL { return [self count:@"start"] >= 31; }];
    XCTAssertEqual([self count:@"start"],31u); XCTAssertEqual([self count:@"finish"],0u);
    XCTAssertTrue(_player.isPlaying); XCTAssertEqualObjects(_player.currentTrack.url,urls[0]); // the thirtieth skip landed on a
}
// The voice plays what its ring holds, then zero-fills and counts the frames
// it could not fill; fed again, it continues from the exact frame it stopped at.
- (void)testAStarvedDecoderHoldsThePositionAndResumesExactly {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=VibePCM([self read:url]);
    NSUInteger sourceFrames=reference.length/8;
    [self play:url paused:NO position:0];
    NSData *head=[self renderSeconds:0.5];
    [self assertReference:[reference subdataWithRange:NSMakeRange(0,head.length)] capture:head skip:[self startupSkip] tolerance:0];
    [_player debugStarveDecoder:YES];
    NSData *starved=[self renderSeconds:1.5];
    NSUInteger held=(NSUInteger)llround(_player.position*_rate);
    XCTAssertGreaterThan(held,24000u); XCTAssertLessThan(held,96000u, @"the ring is shorter than the file, so the render must have run dry");
    XCTAssertEqual([_player.debugRenderCounts[@"underrunFrames"] unsignedIntegerValue],96000u-held);
    XCTAssertTrue(_player.isPlaying); XCTAssertEqual([self count:@"finish"],0u);
    [self assertReference:[reference subdataWithRange:NSMakeRange(24000*8,(held-24000)*8)]
                  capture:[starved subdataWithRange:NSMakeRange(0,(held-24000)*8)] skip:0 tolerance:0];
    XCTAssertEqual(VibeRMS(starved,2,0,NSMakeRange(held-24000,96000-held)),0);
    [_player debugStarveDecoder:NO];
    NSData *resumed=[self renderSeconds:(double)(sourceFrames-held)/_rate+0.1];
    [self assertReference:[reference subdataWithRange:NSMakeRange(held*8,(sourceFrames-held)*8)]
                  capture:resumed skip:0 tolerance:0];
    [self settleUntil:^BOOL { return [self count:@"finish"]==1; }];
}
- (void)testRealTimerPumpAndFade {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:YES];
    NSMutableData *captured=[NSMutableData data];
    [_player debugSetCapture:^(AVAudioPCMBuffer *buffer) { [captured appendData:VibePCM(buffer)]; }];
    // Four seconds: on the real timer a stalled runner must not reach the end
    // before the pause at 0.1 s.
    NSURL *url=[self write:VibeUniqueNoise(4*48000,0x5EEDu) rate:48000 channels:2 name:@"real-timer.wav"];
    [self play:url paused:NO position:0];
    [self settleUntil:^BOOL { return self->_player.position>0.1; }];
    [_player pause]; [self settleUntil:^BOOL { return self->_player.isPaused; }];
    [_player debugSetCapture:nil];
    XCTAssertGreaterThan(captured.length,4800u*8); [self assertFinite:captured peak:0.251];
    XCTAssertEqual([self count:@"finish"],0u);
}
// Modes: 0 ordinary, 1 bit-perfect, 2 bit-perfect with Declick off, whose
// first sample is the file's and whose stop cuts at once.
- (void)testStartupAndStopEnvelopesAreBounded {
    for (NSNumber *mode in @[@0, @1, @2])
    for (NSNumber *rate in @[@44100,@48000,@88200,@96000,@176400,@192000]) {
        [self startPlayerAt:rate.doubleValue channels:2 fx:NO bitPerfect:mode.intValue>0 automatic:NO];
        _player.declick = mode.intValue != 2;
        NSMutableData *constant=[NSMutableData dataWithLength:(NSUInteger)_rate*2*4];
        float *values=constant.mutableBytes; for(NSUInteger i=0;i<constant.length/4;i++) values[i]=0.25;
        NSURL *url=[self write:constant rate:_rate channels:2 name:@"constant.wav"];
        [self play:url paused:NO position:0]; NSData *start=[self renderSeconds:0.1]; const float *s=start.bytes;
        NSUInteger end=start.length/8, settled=(NSUInteger)(_rate*0.05);
        if (mode.intValue == 2) {
            for(NSUInteger i=0;i<end;i++) XCTAssertEqual(s[i*2],0.25f,@"%@ Hz frame %lu",rate,(unsigned long)i);
            [_player stop]; NSData *stop=[self renderSeconds:0.1]; const float *e=stop.bytes;
            for(NSUInteger i=0;i<end;i++) XCTAssertEqual(e[i*2],0.0f,@"%@ Hz frame %lu after stop",rate,(unsigned long)i);
            continue;
        }
        XCTAssertLessThan(s[0],0.01f);
        for(NSUInteger i=1;i<end;i++) { XCTAssertGreaterThanOrEqual(s[i*2]+1e-7f,s[(i-1)*2]); XCTAssertLessThan(fabsf(s[i*2]-s[(i-1)*2]),0.002f); }
        for(NSUInteger i=settled;i<end;i++) XCTAssertEqual(s[i*2],0.25f);
        [_player stop]; NSData *stop=[self renderSeconds:0.1]; const float *e=stop.bytes;
        for(NSUInteger i=settled;i<end;i++) XCTAssertEqual(e[i*2],0);
        // The voice retires only after its ramp: no full-amplitude discontinuity.
        float worst=0; for(NSUInteger i=1;i<end;i++) worst=MAX(worst,fabsf(e[i*2]-e[(i-1)*2]));
        XCTAssertLessThan(worst,0.02f,@"%@ Hz",rate);
    }
}
- (void)testCrossfadePowerAndInterruption {
    for (NSNumber *milliseconds in @[@500,@2000]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        _player.crossfadeMilliseconds=milliseconds.integerValue;
        NSMutableData *left=[NSMutableData dataWithLength:4*48000*8], *right=[left mutableCopy];
        float *l=left.mutableBytes,*r=right.mutableBytes;
        for(NSUInteger f=0;f<4*48000;f++) { l[f*2]=0.25; r[f*2+1]=0.25; }
        AudioTrack *a=[AudioTrack withURL:[self write:left rate:48000 channels:2 name:@"left.wav"]];
        AudioTrack *b=[AudioTrack withURL:[self write:right rate:48000 channels:2 name:@"right.wav"]];
        [_player play:a]; [self settleUntil:^BOOL { return [self count:@"start"]==1; }]; [self render:4800];
        [_player play:b]; [self settleUntil:^BOOL { return [self count:@"start"]==2; }];
        double duration=milliseconds.doubleValue/1000;
        NSData *mix=[self renderSeconds:duration+0.1]; const float *p=mix.bytes;
        for(NSUInteger f=(NSUInteger)(0.1*_rate);f<(NSUInteger)((duration-0.05)*_rate);f+=128) {
            double power=pow(p[f*2]/0.25,2)+pow(p[f*2+1]/0.25,2);
            XCTAssertEqualWithAccuracy(power,1,0.06);
        }
        NSUInteger middle=(NSUInteger)(duration*0.5*_rate);
        XCTAssertEqualWithAccuracy(p[middle*2],0.25/sqrt(2),0.025);
        XCTAssertEqualWithAccuracy(p[middle*2+1],0.25/sqrt(2),0.025);
        XCTAssertEqual([_player.debugRenderCounts[@"retiredFades"] unsignedIntegerValue],0u);
        [_player play:a]; [self settleUntil:^BOOL { return [self count:@"start"]==3; }]; [self render:4800];
        [_player play:b]; [self settleUntil:^BOOL { return [self count:@"start"]==4; }]; [self render:4800];
        [_player pause]; NSData *paused=[self renderSeconds:0.1];
        XCTAssertEqual(VibeRMS(paused,2,0,NSMakeRange(2400,2400)),0);
        XCTAssertEqual(VibeRMS(paused,2,1,NSMakeRange(2400,2400)),0);
        XCTAssertEqual([self count:@"finish"],0u);
    }
}
- (void)testTruncatedPCMAndBoundaryLengths {
    NSURL *source=[self fixture:@"noise-48000-24-2.wav"];
    NSData *reference=VibePCM([self read:source]);
    for(NSNumber *length in @[@1,@255,@256,@257,@4095,@4096,@4097]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        NSURL *url=[self write:[reference subdataWithRange:NSMakeRange(0,length.unsignedIntegerValue*8)] rate:48000 channels:2 name:@"boundary.wav"];
        [self play:url paused:NO position:0]; [self render:length.unsignedIntegerValue+4096];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u); XCTAssertTrue(_player.isStopped);
        [self assertFinite:_capture peak:0.251];
    }
    NSMutableData *truncated=[[NSData dataWithContentsOfURL:source] mutableCopy];
    [truncated setLength:truncated.length/2]; NSURL *url=[_temporary URLByAppendingPathComponent:@"truncated.wav"];
    [truncated writeToURL:url atomically:YES];
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    [_player play:[AudioTrack withURL:url]];
    [self settleUntil:^BOOL { return [self count:@"start"] || self->_playError; }];
    if (!_playError) {
        [self renderSeconds:2.1];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertTrue(_player.isStopped); XCTAssertEqual([self count:@"finish"],1u);
    }
    _playError=nil; [self play:source paused:NO position:0];
    [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
}
- (void)testPausedLoadStaysSilentAndPendingCommandsSettle {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"];
    [self play:url paused:YES position:0.25];
    XCTAssertEqual(VibeRMS([self renderSeconds:0.1],2,0,NSMakeRange(0,4800)),0);
    XCTAssertTrue(_player.isPaused);
    [_player resume]; [_player pause]; [_player resume]; [self render:4096];
    XCTAssertTrue(_player.isPlaying); XCTAssertEqual([self count:@"finish"],0u);
    [_player stop]; [_player play:[AudioTrack withURL:url]]; [_player stop]; [self render:2048];
    [self settleUntil:^BOOL { return self->_player.isStopped; }];
    XCTAssertEqual(VibeRMS([self renderSeconds:0.1],2,0,NSMakeRange(0,4800)),0);
}

@end
