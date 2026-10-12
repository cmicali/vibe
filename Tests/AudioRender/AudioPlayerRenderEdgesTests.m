//
//  AudioPlayerRenderEdgesTests.m
//

#import "AudioPlayerRenderTestCase.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import <objc/runtime.h>

// Transport edges, declick, gapless handoffs, crossfades, cue rows and successor cancellation.
@interface AudioPlayerRenderEdgesTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderEdgesTests

- (void)testBitPerfectTransportCutsWithoutChangingSamples {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    _player.crossfadeMilliseconds = 2000; // bit-perfect output ignores it
    _player.declick = NO; // the cut rule; the default, which ramps, is the next test
    NSURL *first = [self fixture:@"noise-48000-24-2.wav"], *second = [self fixture:@"noise-48000-16-2.wav"];
    NSArray *references = @[VibePCM([self read:first]), VibePCM([self read:second])];
    [_capture setLength:0];
    [self play:first paused:NO position:0]; [self render:14400];
    [_player seekToPosition:1.0]; [self render:9600];
    [_player pause]; [self render:4800]; XCTAssertTrue(_player.isPaused);
    [_player resume]; [self render:9600];
    [self play:second paused:NO position:0]; [self render:14400];
    [_player stop]; [self render:4800]; XCTAssertTrue(_player.isStopped);
    // start, seek, resume and the track change each begin an excerpt; a cut
    // between two that happens to abut adds none.
    XCTAssertGreaterThanOrEqual([self assertExactExcerptsOf:references inCapture:_capture rampFrames:0 ramped:NULL], 3u);
    const float *tail = (const float *)_capture.bytes + (_capture.length / sizeof(float) - 4800 * 2);
    for (NSUInteger i = 0; i < 4800 * 2; i++) XCTAssertEqual(tail[i], 0.0f, @"sound after stop");
}

- (void)testBitPerfectDeclickRampsOnlyTheEdges {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    XCTAssertTrue(_player.declick);
    _player.crossfadeMilliseconds = 2000; // still clamped to the declick under the mode
    NSURL *first = [self fixture:@"noise-48000-24-2.wav"], *second = [self fixture:@"noise-48000-16-2.wav"];
    NSArray *references = @[VibePCM([self read:first]), VibePCM([self read:second])];
    [_capture setLength:0];
    [self play:first paused:NO position:0]; [self render:14400];
    [_player seekToPosition:1.0]; [self render:9600];
    [_player pause]; [self render:4800]; XCTAssertTrue(_player.isPaused);
    [_player resume]; [self render:9600];
    [self play:second paused:NO position:0]; [self render:14400];
    [_player stop]; [self render:4800]; XCTAssertTrue(_player.isStopped);
    // The same edges begin the same excerpts, and every gap between excerpts
    // is one declick: at most 10 ms of scaled frames in a row.
    NSUInteger ramp = (NSUInteger)(_rate * 0.010) + 8, ramped = 0;
    XCTAssertGreaterThanOrEqual([self assertExactExcerptsOf:references inCapture:_capture rampFrames:ramp ramped:&ramped], 3u);
    // The start, the seek, the pause, the resume, the track change and the
    // stop each ramp once (a seek or a track change overlaps its two ramps).
    XCTAssertGreaterThan(ramped, ramp / 2, @"declick applied no ramp");
    XCTAssertLessThanOrEqual(ramped, ramp * 6);
    const float *tail = (const float *)_capture.bytes + (_capture.length / sizeof(float) - 4000 * 2);
    for (NSUInteger i = 0; i < 4000 * 2; i++) XCTAssertEqual(tail[i], 0.0f, @"sound after stop");
}

// Declick off cuts ordinary playback's declick-length edges too; a crossfade
// longer than the declick is the user's choice and still fades.
- (void)testDeclickOffCutsOrdinaryEdgesAndKeepsTheCrossfade {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _player.declick = NO;
    NSURL *first = [self fixture:@"noise-48000-24-2.wav"], *second = [self fixture:@"noise-48000-16-2.wav"];
    NSArray *references = @[VibePCM([self read:first]), VibePCM([self read:second])];
    [_capture setLength:0];
    [self play:first paused:NO position:0]; [self render:14400];
    [_player seekToPosition:1.0]; [self render:9600];
    [_player pause]; [self render:4800]; XCTAssertTrue(_player.isPaused);
    [_player resume]; [self render:9600];
    [self play:second paused:NO position:0]; [self render:14400];
    XCTAssertEqual([_player.debugRenderCounts[@"retiredFades"] unsignedIntegerValue], 0u, @"a cut voice is killed, not faded");
    [_player stop];
    NSUInteger stopped = _capture.length / sizeof(float) / 2;
    [self render:14400]; XCTAssertTrue(_player.isStopped);
    XCTAssertGreaterThanOrEqual([self assertExactExcerptsOf:references inCapture:_capture rampFrames:0 ramped:NULL], 3u);
    // A block, plus the varispeed's latency (zero while it is out of the chain).
    NSUInteger latency = (NSUInteger)llround([_player.debugRenderCounts[@"varispeedLatency"] doubleValue] * _rate) + _blockSize;
    const float *out = _capture.bytes;
    for (NSUInteger i = (stopped + latency) * 2; i < _capture.length / sizeof(float); i++) {
        XCTAssertEqual(out[i], 0.0f, @"sound %lu frames after stop", (unsigned long)(i / 2 - stopped));
    }
    // The crossfade is longer than the declick, so a plain play — the one
    // verb that crossfades — leaves the outgoing voice fading.
    _player.crossfadeMilliseconds = 2000;
    [self play:first paused:NO position:0]; [self render:14400];
    NSUInteger starts = [self count:@"start"];
    [_player play:[AudioTrack withURL:second]];
    [self settleUntil:^BOOL { return [self count:@"start"] > starts; }];
    XCTAssertEqual([_player.debugRenderCounts[@"retiredFades"] unsignedIntegerValue], 1u, @"the crossfade fades with Declick off");
}

// A skip past the end reaches finishPlaybackOnQueue with the voice at full
// amplitude. The transport publishes Stopped before it retires the voice, so
// the retire must read the voice's own state, not the player's. Every adjacent
// sample of the tail is inspected, the command boundary included.
- (void)testFinishCurrentTrackFadesTheOutgoingVoice {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"100.wav"] paused:NO position:0];
    [self render:48120]; // mid-waveform, well past the startup declick
    const float *before = _capture.bytes;
    float last = before[(_capture.length / 8 - 1) * 2];
    [_player finishCurrentTrack];
    NSData *tail = [self renderSeconds:0.03];
    const float *after = tail.bytes;
    float step = fabsf(after[0] - last);
    for (NSUInteger i = 1; i < tail.length / 8; i++) step = MAX(step, fabsf(after[i * 2] - after[(i - 1) * 2]));
    XCTAssertLessThan(step, 0.02f, @"finishCurrentTrack cut the voice: a %g step", step);
    [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
    XCTAssertTrue(_player.isStopped);
}

- (void)testPauseResumeAndIdleRestart {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=VibePCM([self read:url]);
    [self play:url paused:NO position:0]; [self render:24000];
    [_player pause]; [self render:2048]; XCTAssertTrue(_player.isPaused);
    double position=_player.position; NSUInteger sourceFrame=(NSUInteger)llround(position*_rate);
    NSData *silence=[self renderSeconds:6.1];
    XCTAssertEqual(VibeRMS(silence,2,0,NSMakeRange(0,silence.length/8)),0);
    XCTAssertFalse([_player.debugRenderCounts[@"running"] boolValue]);
    XCTAssertEqualWithAccuracy(_player.position,position,0);
    XCTAssertEqual([self count:@"finish"],0u);
    [_player resume];
    NSData *tail=[reference subdataWithRange:NSMakeRange(sourceFrame*8,reference.length-sourceFrame*8)];
    [self assertReference:tail capture:[self renderSeconds:2.1-position] skip:[self startupSkip] tolerance:0];
    [self settleUntil:^BOOL { return [self count:@"resume"] >= 1; }];
    XCTAssertEqual([self count:@"resume"],1u);
}
- (void)testStopRestartAndSameTrackReplay {
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=VibePCM([self read:url]);
    for (NSNumber *block in @[@63,@256,@1024,@4096]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO]; _blockSize=block.unsignedIntegerValue;
        AudioTrack *track=[self play:url paused:NO position:0]; [self render:12000];
        NSUInteger eventsBeforeStop=_events.count;
        [_player stop]; [self render:2048]; XCTAssertTrue(_player.isStopped);
        // Whatever the stop posted to main is queued before this marker.
        [_player runSyncOnQueue:^{}];
        __block BOOL drained=NO; dispatch_async(dispatch_get_main_queue(), ^{ drained=YES; });
        [self settleUntil:^BOOL { return drained; }];
        XCTAssertNil(_player.currentTrack);
        XCTAssertEqual(_events.count,eventsBeforeStop,@"stop fires no transport or track-end callback: %@",_events);
        NSData *silence=[self renderSeconds:0.1]; XCTAssertEqual(VibeRMS(silence,2,0,NSMakeRange(0,4800)),0);
        NSUInteger starts=[self count:@"start"]; [_player play:track];
        [self settleUntil:^BOOL { return [self count:@"start"]>starts; }];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
        [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
    }
}
- (void)testSeekPlayingPausedAndNearEnd {
    for (NSNumber *paused in @[@NO,@YES]) for (NSNumber *target in @[@0.125,@1.5,@1.95]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=VibePCM([self read:url]);
        [self play:url paused:paused.boolValue position:0.5];
        if (!paused.boolValue) [self render:4096];
        [_capture setLength:0]; [_player seekToPosition:target.doubleValue]; [self render:2048];
        [self settleUntil:^BOOL { return [self count:@"seek"] >= 1; }];
        XCTAssertEqual([self count:@"seek"],1u);
        if (paused.boolValue) {
            XCTAssertTrue(_player.isPaused); XCTAssertEqualWithAccuracy(_player.position,target.doubleValue,1/_rate);
            [_player resume];
            NSUInteger start=(NSUInteger)llround(target.doubleValue*_rate);
            NSData *tail=[reference subdataWithRange:NSMakeRange(start*8,reference.length-start*8)];
            [self assertReference:tail capture:[self renderSeconds:2.1-target.doubleValue] skip:MIN(2400,tail.length/8-480) tolerance:0];
        } else {
            // The first 2048 frames include the fade and seek landing; retain
            // them so the source marker cannot drift around missing audio.
            [self render:(NSUInteger)((2.1-target.doubleValue)*_rate)];
            NSUInteger start=(NSUInteger)llround(target.doubleValue*_rate);
            NSData *tail=[reference subdataWithRange:NSMakeRange(start*8,reference.length-start*8)];
            [self assertReference:tail capture:_capture skip:MIN(2400,tail.length/8-480) tolerance:0];
        }
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u);
    }
}
// A 44.1 kHz signal split across two tracks, played at 48 kHz, matches the
// unsplit file whether the successor is named while the first track decodes or
// after it decoded whole.
- (void)testGaplessContinuesTheResamplerAcrossTheBoundary {
    NSData *whole = [VibePCM([self read:[self fixture:@"noise-44100-24-2.wav"]]) subdataWithRange:NSMakeRange(0, 44100 * 8)];
    NSURL *full = [self write:whole rate:44100 channels:2 name:@"whole441.wav"];
    NSURL *first = [self write:[whole subdataWithRange:NSMakeRange(0, 22050 * 8)] rate:44100 channels:2 name:@"first441.wav"];
    NSURL *second = [self write:[whole subdataWithRange:NSMakeRange(22050 * 8, 22050 * 8)] rate:44100 channels:2 name:@"second441.wav"];
    for (NSNumber *late in @[@NO, @YES]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:full paused:NO position:0];
        NSData *reference = [self renderSeconds:1.1];
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:first paused:NO position:0];
        NSUInteger before = late.boolValue ? 256 : 0; // the first track decodes whole before its successor is named
        [self render:before];
        [_player prefetchTrack:[AudioTrack withURL:second]];
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        [self render:52800 - before];
        XCTAssertEqual([self count:@"advance"], 1u, @"late %@", late);
        [self assertReference:reference capture:_capture skip:[self startupSkip] tolerance:0.0001f];
    }
}

// The decoder changes after the next file's open has chosen its decoder but
// before it settles: the re-prefetch of that path joins the running open, so
// its handle carries the old decoder, and the park reopens it once it lands.
// The track the gapless boundary promotes decodes under the new choice.
- (void)testADecoderChangeDuringThePrefetchOpenReopensThePark {
    NSURL *first = [self optionalFixture:@"cbr.mp3"], *second = [self optionalFixture:@"vbr.mp3"];
    AudioFileHandle.appleMPEGDecoder = NO;
    dispatch_semaphore_t opened = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    __block BOOL held = NO;
    SEL selector = @selector(initForReading:interleaved:interrupted:error:);
    Method initializer = class_getInstanceMethod(AudioFileHandle.class, selector);
    __block IMP original;
    IMP holding = imp_implementationWithBlock(^id(id receiver, NSURL *url, BOOL interleaved, BOOL (^interrupted)(void), NSError **error) {
        id handle = ((id (*)(id, SEL, NSURL *, BOOL, BOOL (^)(void), NSError **))original)(receiver, selector, url, interleaved, interrupted, error);
        if ([url.path isEqualToString:second.path] && !held) {
            held = YES;
            dispatch_semaphore_signal(opened);
            dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        }
        return handle;
    });
    original = method_setImplementation(initializer, holding);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:first paused:NO position:0];
        [_player prefetchTrack:[AudioTrack withURL:second]];
        XCTAssertEqual(dispatch_semaphore_wait(opened, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        AudioFileMaterializationCoordinator *coordinator = AudioFileMaterializationCoordinator.sharedCoordinator;
        uint64_t started = coordinator.stateSnapshotForTesting.handleOpensStarted;
        AudioFileHandle.appleMPEGDecoder = YES;
        [_player prefetchTrack:nil]; // what VibeSettingsLiveEffectMP3Decoder sends
        [_player prefetchTrack:[AudioTrack withURL:second]];
        (void)_player.audioPathSnapshot; // a player-queue round trip: both requests have run
        // Rebound to the held open: no new claim, and no second open begun.
        VibeAudioFileMaterializationCoordinatorSnapshot joined = coordinator.stateSnapshotForTesting;
        XCTAssertEqual(joined.claimCount, 0u);
        XCTAssertEqual(joined.handleRunCount, 1u);
        XCTAssertEqual(joined.handleOpensStarted, started, @"the replacement must join the held open, or this test proves nothing");
        dispatch_semaphore_signal(release);
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        [self renderSeconds:2.2];
        [self settleUntil:^BOOL { return [self count:@"advance"] > 0; }];
        XCTAssertEqual([self count:@"advance"], 1u);
        NSDictionary *source = nil;
        for (NSDictionary *stage in _player.audioPathSnapshot) {
            if ([stage[@"stage"] isEqual:@"source"]) source = stage;
        }
        XCTAssertEqualObjects(source[@"file"], second.lastPathComponent);
        XCTAssertEqualObjects(source[@"decoder"], @"apple", @"the promoted track kept the decoder it opened with before the change");
    } @finally {
        dispatch_semaphore_signal(release);
        method_setImplementation(initializer, original);
        imp_removeBlock(holding);
    }
}

// The decoder changes and the same file is played while its prefetch still
// opens under the old choice, and that stale open lands first: it must not
// start the play, whose own open, begun after the change, does.
- (void)testAStalePrefetchNeverStartsThePlayItRaces {
    NSURL *first = [self optionalFixture:@"cbr.mp3"], *second = [self optionalFixture:@"vbr.mp3"];
    AudioFileHandle.appleMPEGDecoder = NO;
    // The first open of the second file is the prefetch, the next the play's.
    NSArray<dispatch_semaphore_t> *opened = @[dispatch_semaphore_create(0), dispatch_semaphore_create(0)];
    NSArray<dispatch_semaphore_t> *release = @[dispatch_semaphore_create(0), dispatch_semaphore_create(0)];
    __block NSInteger opens = 0;
    SEL selector = @selector(initForReading:interleaved:interrupted:error:);
    Method initializer = class_getInstanceMethod(AudioFileHandle.class, selector);
    __block IMP original;
    IMP holding = imp_implementationWithBlock(^id(id receiver, NSURL *url, BOOL interleaved, BOOL (^interrupted)(void), NSError **error) {
        id handle = ((id (*)(id, SEL, NSURL *, BOOL, BOOL (^)(void), NSError **))original)(receiver, selector, url, interleaved, interrupted, error);
        NSInteger index = -1;
        if ([url.path isEqualToString:second.path]) {
            @synchronized (self) { index = opens < 2 ? opens++ : -1; }
        }
        if (index >= 0) {
            dispatch_semaphore_signal(opened[index]);
            dispatch_semaphore_wait(release[index], dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        }
        return handle;
    });
    original = method_setImplementation(initializer, holding);
    dispatch_time_t (^guard)(void) = ^{ return dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC); };
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:first paused:NO position:0];
        [_player prefetchTrack:[AudioTrack withURL:second]];
        XCTAssertEqual(dispatch_semaphore_wait(opened[0], guard()), 0L);
        AudioFileHandle.appleMPEGDecoder = YES;
        AudioFileMaterializationCoordinator *coordinator = AudioFileMaterializationCoordinator.sharedCoordinator;
        uint64_t completed = coordinator.stateSnapshotForTesting.handleOpensCompleted;
        [_player play:[AudioTrack withURL:second] atPosition:0 startPaused:NO]; // Next, with the prefetch still opening
        XCTAssertEqual(dispatch_semaphore_wait(opened[1], guard()), 0L, @"the play must run an open of its own");
        dispatch_semaphore_signal(release[0]);
        [self settleUntil:^BOOL { return coordinator.stateSnapshotForTesting.handleOpensCompleted > completed; }];
        (void)_player.audioPathSnapshot; // a player-queue round trip: the stale result has been handled
        dispatch_semaphore_signal(release[1]);
        [self settleUntil:^BOOL { return [self count:@"start"] >= 2; }];
        NSDictionary *source = nil;
        for (NSDictionary *stage in _player.audioPathSnapshot) {
            if ([stage[@"stage"] isEqual:@"source"]) source = stage;
        }
        XCTAssertEqualObjects(source[@"file"], second.lastPathComponent);
        XCTAssertEqualObjects(source[@"decoder"], @"apple", @"the stale prefetch started the play");
    } @finally {
        dispatch_semaphore_signal(release[0]);
        dispatch_semaphore_signal(release[1]);
        method_setImplementation(initializer, original);
        imp_removeBlock(holding);
    }
}

// Two 5.1 files in different channel orders under bit-perfect output: the bus
// folds each by its own layout, so its center still reaches both sides.
- (void)testBitPerfectFoldsEachChannelLayoutInsideTheStereoBus {
    NSMutableArray<NSURL *> *files = [NSMutableArray array];
    NSArray<NSNumber *> *tags = @[@(kAudioChannelLayoutTag_MPEG_5_1_A), @(kAudioChannelLayoutTag_MPEG_5_1_B)];
    NSUInteger center[2] = { 2, 4 };
    for (NSUInteger i = 0; i < 2; i++) {
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:48000 interleaved:NO
                channelLayout:[AVAudioChannelLayout layoutWithLayoutTag:tags[i].unsignedIntValue]];
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:48000];
        buffer.frameLength = 48000;
        for (NSUInteger f = 0; f < 48000; f++) buffer.floatChannelData[center[i]][f] = 0.25f;
        NSURL *url = [self writeBuffer:buffer name:[NSString stringWithFormat:@"layout-%lu.aif", (unsigned long)i]];
        XCTAssertEqual([[AudioFileHandle alloc] initForReading:url error:NULL].processingFormat.channelLayout.layoutTag, tags[i].unsignedIntValue);
        [files addObject:url];
    }
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    for (NSURL *url in files) {
        [self play:url paused:NO position:0];
        NSData *capture = [self renderSeconds:0.5];
        XCTAssertGreaterThan(VibeRMS(capture, 2, 0, NSMakeRange(4800, 12000)), 0.05, @"%@", url.lastPathComponent);
        XCTAssertGreaterThan(VibeRMS(capture, 2, 1, NSMakeRange(4800, 12000)), 0.05, @"%@", url.lastPathComponent);
    }
}

// A 5.1 file with sound in the center only, which a first-channels map
// silences: both modes fold it by layout inside the stereo bus.
- (void)testASurroundFileIsAudibleInStereo {
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:48000 interleaved:NO
            channelLayout:[AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_MPEG_5_1_A]];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:48000];
    buffer.frameLength = 48000;
    for (NSUInteger f = 0; f < 48000; f++) buffer.floatChannelData[2][f] = 0.25f;
    NSURL *url = [self writeBuffer:buffer name:@"center51.wav"];
    for (NSNumber *bitPerfect in @[@NO, @YES]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:bitPerfect.boolValue automatic:NO];
        [self play:url paused:NO position:0];
        NSData *capture = [self renderSeconds:0.5];
        XCTAssertGreaterThan(VibeRMS(capture, 2, 0, NSMakeRange(4800, 12000)), 0.05, @"bit-perfect %@", bitPerfect);
        XCTAssertGreaterThan(VibeRMS(capture, 2, 1, NSMakeRange(4800, 12000)), 0.05, @"bit-perfect %@", bitPerfect);
    }
}

- (void)testGaplessSplitSignalAcrossRenderBlocks {
    NSData *reference=VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    // 9000 frames is more than a slice: the render slices it as it would a
    // device's larger IO cycle.
    for (NSNumber *block in @[@63,@256,@1024,@4096,@9000]) for (NSNumber *mode in @[@NO,@YES]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:mode.boolValue automatic:NO]; _blockSize=block.unsignedIntegerValue;
        NSMutableArray *tracks=[NSMutableArray array]; NSUInteger start=0;
        for (NSNumber *end in @[@20003,@48001,@72007,@96000]) {
            NSData *part=[reference subdataWithRange:NSMakeRange(start*8,(end.unsignedIntegerValue-start)*8)];
            NSURL *url=[self write:part rate:48000 channels:2 name:[NSString stringWithFormat:@"split-%lu.wav",(unsigned long)start]];
            [tracks addObject:[AudioTrack withURL:url]]; start=end.unsignedIntegerValue;
        }
        _chain=tracks; _nextPrefetch=1;
        [_player play:tracks[0]];
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
        XCTAssertEqual([self count:@"advance"],3u); XCTAssertEqual([self count:@"finish"],1u);
        XCTAssertEqualObjects(_player.currentTrack,tracks.lastObject);
        XCTAssertEqualWithAccuracy(_player.duration,(96000-72007)/48000.0,0);
    }
}
// Repeat One parks the playing track's own object as its successor: a second
// handle on the same file, spliced into its start with no gap.
- (void)testATrackSplicesIntoItselfGaplessly {
    NSData *reference=VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    for (NSNumber *mode in @[@NO,@YES]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:mode.boolValue automatic:NO]; _blockSize=1024;
        AudioTrack *track=[AudioTrack withURL:[self fixture:@"noise-48000-24-2.wav"]];
        _chain=@[track,track]; _nextPrefetch=1;
        [_player play:track];
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        NSMutableData *twice=[reference mutableCopy]; [twice appendData:reference];
        [self assertReference:twice capture:[self renderSeconds:4.1] skip:[self startupSkip] tolerance:0];
        XCTAssertEqual([self count:@"advance"],1u,@"bit-perfect %@",mode); XCTAssertEqual([self count:@"finish"],1u);
        XCTAssertEqual(_player.currentTrack,track);
    }
}

#pragma mark - Track-end crossfade

// Two tones, so each track's level reads apart from the other's in any window.
- (NSArray<AudioTrack *> *)toneTracksOfSeconds:(double)firstSeconds and:(double)secondSeconds {
    NSURL *a = [self write:VibeStereoTone((NSUInteger)(firstSeconds * 48000), 48000, 440, 0.5f) rate:48000 channels:2 name:@"tone440.wav"];
    NSURL *b = [self write:VibeStereoTone((NSUInteger)(secondSeconds * 48000), 48000, 1000, 0.5f) rate:48000 channels:2 name:@"tone1000.wav"];
    return @[[AudioTrack withURL:a], [AudioTrack withURL:b]];
}

- (void)playParked:(NSArray<AudioTrack *> *)tracks {
    [_player play:tracks[0]];
    [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
    [_player prefetchTrack:tracks[1]];
    [self settleUntil:^BOOL { return [self->_player.debugRenderCounts[@"prefetched"] boolValue] || self->_player.gaplessArmed; }];
}

// Each track's tone level per 50 ms window of the capture: 22 and 50 whole cycles.
- (void)levelsOf:(NSData *)capture first:(NSMutableArray<NSNumber *> *)first second:(NSMutableArray<NSNumber *> *)second {
    for (NSUInteger at = 0; at + 2400 <= capture.length / 8; at += 2400) {
        [first addObject:@(VibeToneAmplitude(capture, 2, 0, 48000, 440, NSMakeRange(at, 2400)))];
        [second addObject:@(VibeToneAmplitude(capture, 2, 0, 48000, 1000, NSMakeRange(at, 2400)))];
    }
}

// The successor must start before the outgoing track ends for the fades to overlap.
- (void)testATrackEndCrossfadesIntoTheParkedTrack {
    NSArray<NSURL *> *urls = [[self toneTracksOfSeconds:4 and:4] valueForKey:@"url"];
    for (NSNumber *crossfade in @[@500, @2000]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO]; _blockSize = 512;
        _player.crossfadeMilliseconds = crossfade.integerValue;
        NSArray<AudioTrack *> *tracks = @[[AudioTrack withURL:urls[0]], [AudioTrack withURL:urls[1]]];
        [self playParked:tracks];
        XCTAssertFalse(_player.gaplessArmed, @"a long crossfade never splices");
        NSData *capture = [self renderSeconds:5.5];
        NSMutableArray<NSNumber *> *a = [NSMutableArray array], *b = [NSMutableArray array];
        [self levelsOf:capture first:a second:b];
        double fade = crossfade.doubleValue / 1000;
        NSUInteger firstHeard = NSNotFound, overlapping = 0;
        for (NSUInteger w = 2; w < a.count; w++) { // past the startup declick
            double ta = a[w].doubleValue, tb = b[w].doubleValue, t = w * 0.05;
            XCTAssertEqualWithAccuracy(hypot(ta, tb), 0.5, 0.05, @"%@ ms: power dips at %.2f s (%.3f, %.3f)", crossfade, t, ta, tb);
            if (tb > 0.05 && firstHeard == NSNotFound) firstHeard = w;
            if (ta > 0.1 && tb > 0.1) overlapping++;
            if (t > 4.05) XCTAssertLessThan(ta, 0.01, @"the outgoing track still sounds at %.2f s", t);
        }
        XCTAssertNotEqual(firstHeard, NSNotFound);
        double started = firstHeard * 0.05;
        XCTAssertGreaterThan(started, 4 - fade - 0.25, @"%@ ms: started too early", crossfade);
        XCTAssertLessThan(started, 4 - fade + 0.1, @"%@ ms: started at %.2f s, after its crossfade was due", crossfade, started);
        XCTAssertGreaterThanOrEqual(overlapping * 0.05, fade / 2, @"%@ ms: the tracks barely overlapped", crossfade);
        XCTAssertEqual([self count:@"advance"], 1u); XCTAssertEqual([self count:@"finish"], 0u);
        XCTAssertEqual(_player.currentTrack, tracks[1]);
        XCTAssertTrue(_player.isPlaying);
        XCTAssertEqualWithAccuracy(_player.position, 5.5 - started, 0.1);
        XCTAssertEqual([_player.debugRenderCounts[@"retiredFades"] unsignedIntegerValue], 0u, @"the outgoing voice retired");
    }
}

- (void)testATrackEndWithTheCrossfadeOffIsGapless {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO]; _blockSize = 512;
    NSArray<AudioTrack *> *tracks = [self toneTracksOfSeconds:1 and:1];
    NSMutableData *reference = [VibePCM([self read:tracks[0].url]) mutableCopy];
    [reference appendData:VibePCM([self read:tracks[1].url])];
    [self playParked:tracks];
    XCTAssertTrue(_player.gaplessArmed);
    [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    XCTAssertEqual([self count:@"advance"], 1u); XCTAssertEqual([self count:@"finish"], 1u);
}

// The setting moves under a playing track: raising it drops the splice and
// crossfades the end; lowering it again splices.
- (void)testChangingTheCrossfadeMidTrackSwitchesHowItEnds {
    NSArray<NSURL *> *urls = [[self toneTracksOfSeconds:3 and:3] valueForKey:@"url"];
    for (NSNumber *raise in @[@YES, @NO]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO]; _blockSize = 512;
        _player.crossfadeMilliseconds = raise.boolValue ? 10 : 1000;
        NSArray<AudioTrack *> *tracks = @[[AudioTrack withURL:urls[0]], [AudioTrack withURL:urls[1]]];
        [self playParked:tracks];
        [self render:48000];
        _player.crossfadeMilliseconds = raise.boolValue ? 1000 : 10;
        [self settleUntil:^BOOL { return self->_player.gaplessArmed != raise.boolValue; }];
        NSData *capture = [self renderSeconds:2.5]; // from 1 s to 3.5 s
        NSMutableArray<NSNumber *> *a = [NSMutableArray array], *b = [NSMutableArray array];
        [self levelsOf:capture first:a second:b];
        NSUInteger overlapping = 0;
        for (NSUInteger w = 0; w < a.count; w++) if (a[w].doubleValue > 0.1 && b[w].doubleValue > 0.1) overlapping++;
        if (raise.boolValue) XCTAssertGreaterThanOrEqual(overlapping, 8u, @"raised: the end crossfades");
        else XCTAssertLessThanOrEqual(overlapping, 1u, @"lowered: the end splices");
        XCTAssertEqual([self count:@"advance"], 1u, @"raise %@", raise);
        XCTAssertEqual(_player.currentTrack, tracks[1]);
    }
}

- (void)testAShortTrackIsHeardBeforeItsCrossfade {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO]; _blockSize = 512;
    _player.crossfadeMilliseconds = 3000;
    NSArray<AudioTrack *> *tracks = [self toneTracksOfSeconds:1 and:2];
    [self playParked:tracks];
    NSData *capture = [self renderSeconds:1.5];
    XCTAssertEqualWithAccuracy(VibeToneAmplitude(capture, 2, 0, 48000, 440, NSMakeRange(4800, 12000)), 0.5, 0.02, @"the first 0.35 s is the short track alone");
    XCTAssertLessThan(VibeToneAmplitude(capture, 2, 0, 48000, 1000, NSMakeRange(4800, 12000)), 0.01);
    XCTAssertEqual([self count:@"advance"], 1u);
}

- (void)testATrackEndWithNothingParkedFinishes {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _player.crossfadeMilliseconds = 2000;
    [self play:[self toneTracksOfSeconds:1 and:1][0].url paused:NO position:0];
    [self render:48000 + 9600];
    [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
    XCTAssertEqual([self count:@"advance"], 0u);
    XCTAssertTrue(_player.isStopped);
}

#pragma mark - Cue rows

// 640 file frames per CD frame at 48 kHz: CD frames 30-105 are file frames
// 19200-67200, one second of the two-second fixture.
- (void)testACueRowPlaysItsWindowAsTheWholeTrack {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:url]);
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    AudioTrack *row = VibeCueRow(url, 30, 105);
    [_player play:row atPosition:0 startPaused:NO];
    [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
    XCTAssertEqualWithAccuracy(_player.duration, 1.0, 0);
    XCTAssertEqualWithAccuracy(row.duration, 1.0, 0);
    NSData *window = [reference subdataWithRange:NSMakeRange(19200 * 8, 48000 * 8)];
    [self assertReference:window capture:[self renderSeconds:1.2] skip:[self startupSkip] tolerance:0];
    [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
}

- (void)testTheLastCueRowRunsToItsFilesEnd {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:url]);
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    [_player play:VibeCueRow(url, 75, 0) atPosition:0 startPaused:NO];
    [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
    XCTAssertEqualWithAccuracy(_player.duration, 1.0, 0);
    [self assertReference:[reference subdataWithRange:NSMakeRange(48000 * 8, 48000 * 8)]
                  capture:[self renderSeconds:1.2] skip:[self startupSkip] tolerance:0];
    [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
}

- (void)testContiguousCueRowsPlayAsOneRecording {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:url]);
    for (NSNumber *block in @[@63, @1024, @4096]) for (NSNumber *mode in @[@NO, @YES]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:mode.boolValue automatic:NO];
        _blockSize = block.unsignedIntegerValue;
        NSArray<AudioTrack *> *rows = @[VibeCueRow(url, 0, 30), VibeCueRow(url, 30, 75), VibeCueRow(url, 75, 0)];
        _chain = rows; _nextPrefetch = 1;
        [_player play:rows[0]];
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
        XCTAssertEqual([self count:@"advance"], 2u, @"block %@ bit-perfect %@", block, mode);
        XCTAssertEqual([self count:@"finish"], 1u);
        XCTAssertEqualObjects(_player.currentTrack, rows.lastObject);
        XCTAssertEqualWithAccuracy(_player.duration, 1.0, 0);
    }
}

- (void)testACueRowSplicesIntoItsOwnWindow {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:url]);
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    _blockSize = 1024;
    AudioTrack *row = VibeCueRow(url, 30, 105);
    _chain = @[row, row, row]; _nextPrefetch = 1;
    [_player play:row];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    NSData *window = [reference subdataWithRange:NSMakeRange(19200 * 8, 48000 * 8)];
    NSMutableData *thrice = [window mutableCopy];
    [thrice appendData:window];
    [thrice appendData:window];
    [self assertReference:thrice capture:[self renderSeconds:3.1] skip:[self startupSkip] tolerance:0];
    XCTAssertEqual([self count:@"advance"], 2u);
    XCTAssertEqual([self count:@"finish"], 1u);
}

- (void)testContiguousCueRowsContinueTheResampler {
    NSURL *url = [self fixture:@"noise-44100-24-2.wav"];
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self play:url paused:NO position:0];
    NSData *reference = [self renderSeconds:2.1];
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSArray<AudioTrack *> *rows = @[VibeCueRow(url, 0, 37), VibeCueRow(url, 37, 0)];
    _chain = rows; _nextPrefetch = 1;
    [_player play:rows[0]];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0.0001f];
    XCTAssertEqual([self count:@"advance"], 1u);
}

// One recording is never crossfaded with itself: the next row of the file
// arms whatever the crossfade, and any other row does not.
- (void)testAContiguousCueRowArmsUnderALongCrossfade {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:url]);
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _player.crossfadeMilliseconds = 2000;
    NSArray<AudioTrack *> *rows = @[VibeCueRow(url, 0, 75), VibeCueRow(url, 75, 0)];
    _chain = rows; _nextPrefetch = 1;
    [_player play:rows[0]];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    XCTAssertEqual([self count:@"advance"], 1u);

    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _player.crossfadeMilliseconds = 2000;
    [_player play:VibeCueRow(url, 0, 30) atPosition:0 startPaused:NO];
    [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
    [_player prefetchTrack:VibeCueRow(url, 75, 0)];
    (void)_player.audioPathSnapshot; // a player-queue round trip: the prefetch was handled
    [self render:4800];
    XCTAssertFalse(_player.gaplessArmed, @"a row that skips part of the file crossfades like any track");
}

// With the next row queued under a long crossfade, an explicit play of it
// retires a voice that may already be reading that row's handle through its
// fade: the new voice must open its own, or the two move one cursor.
- (void)testAnExplicitPlayOfAQueuedContiguousRowOpensItsOwnHandle {
    NSData *noise = VibeUniqueNoise(6 * 48000, 0xCAFE);
    NSURL *url = [self write:noise rate:48000 channels:2 name:@"image.wav"];
    NSData *reference = VibePCM([self read:url]);
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _player.crossfadeMilliseconds = 2000;
    AudioTrack *first = VibeCueRow(url, 0, 150), *second = VibeCueRow(url, 150, 0);
    [_player play:first];
    [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
    [_player prefetchTrack:second];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    [self render:48000]; // the decoder, a ring ahead, has switched into the second row
    [_player play:second];
    [self settleUntil:^BOOL { return [self count:@"start"] == 2; }];
    [self render:2 * 48000 + 4800]; // past the crossfade
    [_capture setLength:0];
    NSUInteger at = (NSUInteger)llround(_player.position * 48000);
    [self render:48000];
    NSData *expected = [reference subdataWithRange:NSMakeRange((96000 + at) * 8, 48000 * 8)];
    [self assertReference:expected capture:[_capture copy] skip:0 tolerance:0];
}

- (void)testASeekInsideACueRowLandsInItsWindow {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:url]);
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    [_player play:VibeCueRow(url, 30, 105) atPosition:0.5 startPaused:YES];
    [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
    XCTAssertEqualWithAccuracy(_player.position, 0.5, 1 / _rate);
    [_player seekToPosition:5];
    [self render:480];
    [self settleUntil:^BOOL { return [self count:@"seek"] == 1; }];
    XCTAssertEqualWithAccuracy(_player.position, 1.0 - 1 / _rate, 1 / _rate, @"past the window: its last frame");
    [_player seekToPosition:0.25];
    [self render:480];
    [self settleUntil:^BOOL { return [self count:@"seek"] == 2; }];
    XCTAssertEqualWithAccuracy(_player.position, 0.25, 1 / _rate);
    [_player resume];
    NSData *tail = [reference subdataWithRange:NSMakeRange((19200 + 12000) * 8, 36000 * 8)];
    [self assertReference:tail capture:[self renderSeconds:0.8] skip:2400 tolerance:0];
    [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
}

// What pause-at-track-end leaves the player: no successor, so the row ends
// at its window's end and nothing of the next row sounds.
- (void)testACueRowEndsAtItsWindowWithNoSuccessor {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    for (NSNumber *resampled in @[@NO, @YES]) {
        [self startPlayerAt:resampled.boolValue ? 44100 : 48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [_player play:VibeCueRow(url, 0, 75) atPosition:0 startPaused:NO];
        [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
        NSData *capture = [self renderSeconds:1.5];
        [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
        NSUInteger end = (NSUInteger)llround(_rate * 1.01);
        XCTAssertEqual(VibeRMS(capture, 2, 0, NSMakeRange(end, capture.length / 8 - end)), 0,
                       @"the next row sounded, resampled %@", resampled);
        XCTAssertEqual([self count:@"advance"], 0u);
    }
}

- (void)testAnOutputRateChangeKeepsACueRowInsideItsWindow {
    [self startPlayerAt:44100 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSURL *url = [self fixture:@"1000.wav"];
    AudioTrack *row = VibeCueRow(url, 75, 225);
    [_player play:row atPosition:0 startPaused:NO];
    [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
    [self render:22050];
    double before = _player.position;
    XCTAssertTrue([_player debugSetOutputRate:96000]);
    _rate = 96000;
    XCTAssertEqual(_player.currentTrack, row);
    XCTAssertEqualWithAccuracy(_player.position, before, 0.01);
    XCTAssertEqualWithAccuracy(_player.duration, 2.0, 0.0001);
    [self renderSeconds:1.7];
    [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
    XCTAssertLessThanOrEqual(_player.position, 2.0);
}

// Another row of the file an open is waiting on rebinds that open, and plays
// its own window when it lands: one open, the latest row.
- (void)testAPickOfAnotherRowOfTheFileBeingOpenedRebindsTheOpen {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:url]);
    dispatch_semaphore_t opened = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    __block BOOL held = NO;
    SEL selector = @selector(initForReading:interleaved:interrupted:error:);
    Method initializer = class_getInstanceMethod(AudioFileHandle.class, selector);
    __block IMP original;
    IMP holding = imp_implementationWithBlock(^id(id receiver, NSURL *opening, BOOL interleaved, BOOL (^interrupted)(void), NSError **error) {
        id handle = ((id (*)(id, SEL, NSURL *, BOOL, BOOL (^)(void), NSError **))original)(receiver, selector, opening, interleaved, interrupted, error);
        if ([opening.path isEqualToString:url.path] && !held) {
            held = YES;
            dispatch_semaphore_signal(opened);
            dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        }
        return handle;
    });
    original = method_setImplementation(initializer, holding);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        AudioFileMaterializationCoordinator *coordinator = AudioFileMaterializationCoordinator.sharedCoordinator;
        uint64_t started = coordinator.stateSnapshotForTesting.handleOpensStarted;
        [_player play:VibeCueRow(url, 0, 30) atPosition:0 startPaused:NO];
        XCTAssertEqual(dispatch_semaphore_wait(opened, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        AudioTrack *picked = VibeCueRow(url, 75, 0);
        [_player play:picked atPosition:0 startPaused:NO];
        (void)_player.audioPathSnapshot; // a player-queue round trip: the pick was handled
        dispatch_semaphore_signal(release);
        [self settleUntil:^BOOL { return [self count:@"start"] >= 1; }];
        XCTAssertEqual(coordinator.stateSnapshotForTesting.handleOpensStarted, started + 1, @"one open for both picks");
        XCTAssertEqual(_player.currentTrack, picked);
        [self assertReference:[reference subdataWithRange:NSMakeRange(48000 * 8, 48000 * 8)]
                      capture:[self renderSeconds:1.2] skip:[self startupSkip] tolerance:0];
    } @finally {
        dispatch_semaphore_signal(release);
        method_setImplementation(initializer, original);
        imp_removeBlock(holding);
    }
}

// The next row's prefetch, asked while its file's open is in flight, waits
// behind that open rather than joining it — joining would leave it never
// parked — and arms once the play lands.
- (void)testTheNextRowsPrefetchDuringItsFilesOpenParksAndArms {
    NSURL *url = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:url]);
    dispatch_semaphore_t opened = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    __block BOOL held = NO;
    SEL selector = @selector(initForReading:interleaved:interrupted:error:);
    Method initializer = class_getInstanceMethod(AudioFileHandle.class, selector);
    __block IMP original;
    IMP holding = imp_implementationWithBlock(^id(id receiver, NSURL *opening, BOOL interleaved, BOOL (^interrupted)(void), NSError **error) {
        id handle = ((id (*)(id, SEL, NSURL *, BOOL, BOOL (^)(void), NSError **))original)(receiver, selector, opening, interleaved, interrupted, error);
        if ([opening.path isEqualToString:url.path] && !held) {
            held = YES;
            dispatch_semaphore_signal(opened);
            dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        }
        return handle;
    });
    original = method_setImplementation(initializer, holding);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        [_player play:VibeCueRow(url, 0, 75) atPosition:0 startPaused:NO];
        XCTAssertEqual(dispatch_semaphore_wait(opened, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        [_player prefetchTrack:VibeCueRow(url, 75, 0)];
        (void)_player.audioPathSnapshot; // a player-queue round trip: the prefetch was handled
        dispatch_semaphore_signal(release);
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
        XCTAssertEqual([self count:@"advance"], 1u);
    } @finally {
        dispatch_semaphore_signal(release);
        method_setImplementation(initializer, original);
        imp_removeBlock(holding);
    }
}

// Rows cut mid-packet (1152 frames each) continue exactly through dr_mp3's
// seek; FLAC's are the original PCM; AAC's the decode within its tolerance.
- (void)testContiguousCueRowsOfCompressedFiles {
    NSDictionary<NSString *, NSNumber *> *files = @{@"cbr.mp3": @0, @"lossless.flac": @0,
                                                    @"lossy.m4a": @(kVibeAACDecodeTolerance)};
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *name in files) {
        NSURL *url = [self fixture:name];
        // The MP3 needs ffmpeg; one missing skips the test only once the rest has run.
        if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
            [missing addObject:name];
            continue;
        }
        NSData *decoded = VibePCM([self read:url]);
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        NSArray<AudioTrack *> *rows = @[VibeCueRow(url, 0, 3), VibeCueRow(url, 3, 50), VibeCueRow(url, 50, 0)];
        _chain = rows; _nextPrefetch = 1;
        [_player play:rows[0]];
        [self settleUntil:^BOOL { return self->_player.gaplessArmed || [self count:@"advance"] > 0; }];
        [self assertReference:decoded capture:[self renderSeconds:decoded.length / 8 / _rate + 0.1]
                         skip:[self startupSkip] tolerance:files[name].floatValue];
        XCTAssertEqual([self count:@"advance"], 2u, @"%@", name);
    }
    XCTSkipIf(missing.count, @"Optional encoder fixtures %@ unavailable; install ffmpeg and regenerate", missing);
}

- (void)testGaplessShortSuccessorAndFormatMismatch {
    NSData *reference=VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    for (NSNumber *length in @[@1,@63,@255,@257]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        NSUInteger split=96000-length.unsignedIntegerValue;
        NSURL *first=[self write:[reference subdataWithRange:NSMakeRange(0,split*8)] rate:48000 channels:2 name:@"first.wav"];
        NSURL *second=[self write:[reference subdataWithRange:NSMakeRange(split*8,length.unsignedIntegerValue*8)] rate:48000 channels:2 name:@"second.wav"];
        [self play:first paused:NO position:0]; [_player prefetchTrack:[AudioTrack withURL:second]];
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
        XCTAssertEqual([self count:@"advance"],1u); XCTAssertEqual([self count:@"finish"],1u);
    }
    for (NSString *next in @[@"noise-44100-24-2.wav",@"noise-48000-24-1.wav"]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
        [_player prefetchTrack:[AudioTrack withURL:[self fixture:next]]];
        [self renderSeconds:2.1]; XCTAssertFalse(_player.gaplessArmed);
        XCTAssertEqual([self count:@"advance"],0u); XCTAssertEqual([self count:@"finish"],1u);
    }
}
- (void)testArmedSuccessorCancellation {
    for (NSString *action in @[@"stop",@"seek",@"cancel",@"replace",@"crossfade",@"replay",@"pause"]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        NSURL *url=[self fixture:@"noise-48000-24-2.wav"];
        AudioTrack *current=[self play:url paused:NO position:0];
        AudioTrack *next=[AudioTrack withURL:[self fixture:@"1000.wav"]];
        [_player prefetchTrack:next]; [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        [self render:12000];
        if ([action isEqual:@"stop"]) [_player stop];
        else if ([action isEqual:@"seek"]) { [_player prefetchTrack:nil]; [_player seekToPosition:1]; }
        else if ([action isEqual:@"cancel"]) [_player prefetchTrack:nil];
        else if ([action isEqual:@"replace"]) [_player prefetchTrack:[AudioTrack withURL:[self fixture:@"silence.wav"]]];
        else if ([action isEqual:@"crossfade"]) _player.crossfadeMilliseconds=500;
        else if ([action isEqual:@"replay"]) [_player play:current];
        else { [_player pause]; [self render:2048]; [_player prefetchTrack:nil]; [_player resume]; }
        [self renderSeconds:2.2];
        XCTAssertNotEqualObjects(_player.currentTrack,next,@"%@",action);
        for (NSDictionary *event in _events) XCTAssertFalse([event[@"track"] isEqual:next.url.path],@"%@ leaked successor",action);
        [self assertFinite:_capture peak:0.51];
        XCTAssertLessThan(VibeToneAmplitude(_capture,2,0,48000,1000,NSMakeRange(48000,48000)),0.01);
    }
}
- (void)testCancellingABufferedSuccessorRevoicesTheCurrentTrack {
    self.continueAfterFailure = YES;
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    AudioTrack *current = [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
    AudioTrack *next = [AudioTrack withURL:[self fixture:@"1000.wav"]];
    [_player prefetchTrack:next];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    [self render:72000];
    [_player prefetchTrack:nil];
    [_player runSyncOnQueue:^{}];
    XCTAssertFalse(_player.gaplessArmed);
    NSData *tail = [self renderSeconds:1.5];
    XCTAssertEqualObjects(_player.currentTrack, current);
    XCTAssertEqual([self count:@"advance"], 0u);
    [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
    XCTAssertEqual([self count:@"finish"], 1u, @"The current track must finish after the cancelled boundary");
    XCTAssertLessThan(VibeToneAmplitude(tail, 2, 0, 48000, 1000, NSMakeRange(36000, 24000)), 0.01,
                     @"Cancelled successor must not be audible");
}


// The old decoder can already be reading the parked file when crossfade
// cancels its splice. Re-arming must wait out that read without waiting for
// the paused output to resume and render the old voice's retirement.
- (void)testRearmingABufferedSuccessorWaitsForItsOldReader {
    self.continueAfterFailure = YES;
    NSData *reference = [self sourcePCM:[self fixture:@"noise-48000-24-2.wav"]];
    NSURL *first = [self write:[reference subdataWithRange:NSMakeRange(0, 12000 * 8)] rate:48000 channels:2 name:@"rearm-first.wav"];
    NSURL *second = [self write:[reference subdataWithRange:NSMakeRange(12000 * 8, reference.length - 12000 * 8)] rate:48000 channels:2 name:@"rearm-second.wav"];
    [self playOnTheDecodePool:^{
        self->_player.declick = NO;
        [self play:first paused:YES position:0];
    }];
    AudioTrack *next = [AudioTrack withURL:second];
    __block AudioVoiceBus *bus;
    __block VibeVoiceID old;
    [_player runSyncOnQueue:^{
        bus = [self->_player valueForKey:@"voiceBus"];
        old = [[self->_player valueForKey:@"voice"] unsignedLongLongValue];
    }];
    dispatch_semaphore_t release = dispatch_semaphore_create(0), entered = dispatch_semaphore_create(0);
    Method produce = class_getInstanceMethod(AudioVoiceBus.class, @selector(produceChunkForSlot:final:));
    // TRAP: atomic, and stored before the swizzle goes live. The first track's
    // decode is already running, so a turn can enter the block while the
    // swizzle is installed. A plain variable assigned from
    // method_setImplementation's return is a race (and a NULL call).
    __block _Atomic(IMP) originalProduce;
    __block _Atomic(BOOL) held = NO;
    IMP blocked = imp_implementationWithBlock(^uint32_t(id receiver, NSUInteger slot, BOOL *final) {
        if (receiver == bus && slot == 0 && [bus snapshotOfVoice:old].boundary == 12000 && !atomic_exchange(&held, YES)) {
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
        }
        return ((uint32_t (*)(id, SEL, NSUInteger, BOOL *))atomic_load(&originalProduce))(receiver, @selector(produceChunkForSlot:final:), slot, final);
    });
    atomic_store(&originalProduce, method_getImplementation(produce));
    method_setImplementation(produce, blocked);
    @try {
        [_player prefetchTrack:next];
        [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
        XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        _player.crossfadeMilliseconds = 500;
        [_player runSyncOnQueue:^{}];
        XCTAssertFalse(_player.gaplessArmed);
        _player.crossfadeMilliseconds = 0;
        [_player runSyncOnQueue:^{}];
        __block VibeVoiceID current;
        [_player runSyncOnQueue:^{ current = [[self->_player valueForKey:@"voice"] unsignedLongLongValue]; }];
        [self settleUntil:^BOOL { return [bus snapshotOfVoice:current].written == 12000; }];
        XCTAssertEqual([bus snapshotOfVoice:current].boundary, UINT64_MAX, @"the old reader still owns the parked file");
        dispatch_semaphore_signal(release);
        [self settleUntil:^BOOL { return [bus snapshotOfVoice:current].written >= 48000; }];
        XCTAssertTrue(_player.gaplessArmed);
        [_player resume];
        [_player runSyncOnQueue:^{}];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:0 tolerance:0];
        [self settleUntil:^BOOL { return [self count:@"advance"] >= 1; }];
        XCTAssertEqual([self count:@"advance"], 1u);
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"], 1u);
        XCTAssertEqualObjects(_player.currentTrack, next);
    } @finally {
        dispatch_semaphore_signal(release);
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        [_player runSyncOnQueue:^{ [bus stopReadingThen:^{ dispatch_semaphore_signal(stopped); }]; }];
        XCTAssertEqual(dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        method_setImplementation(produce, atomic_load(&originalProduce));
        imp_removeBlock(blocked);
    }
}

// The seek's replacement voice reads the same AudioFileHandle as the voice it
// retires: the old voice's reads must stop before the new voice positions the
// shared cursor, or an old turn queued between the two advances it and the new
// voice skips a chunk. The retire is held open with the decoder running.
- (void)testSeekStopsTheOldVoiceReadingBeforeItsFileIsHandedOn {
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
    XCTAssertNotNil(decoder);
    [self settleUntil:^BOOL { return [bus snapshotOfVoice:old].written >= 65536; }];
    dispatch_semaphore_t reading = dispatch_semaphore_create(0), letRead = dispatch_semaphore_create(0);
    Method produce = class_getInstanceMethod(AudioVoiceBus.class, @selector(produceChunkForSlot:final:));
    Method retire = class_getInstanceMethod(AudioPlayer.class, @selector(retireVoiceOnQueue:milliseconds:));
    // The decode is already running, so the produce IMP is stored atomically
    // before the swizzle goes live, as in the test above.
    __block _Atomic(IMP) originalProduce;
    __block IMP originalRetire;
    __block _Atomic(BOOL) heldRead = NO; // the decoder writes it, the render loop below polls it
    __block BOOL heldRetire = NO;
    IMP heldProduce = imp_implementationWithBlock(^uint32_t(id receiver, NSUInteger slot, BOOL *final) {
        if (receiver == bus && !heldRead) {
            heldRead = YES;
            dispatch_semaphore_signal(reading);
            dispatch_semaphore_wait(letRead, DISPATCH_TIME_FOREVER);
        }
        return ((uint32_t (*)(id, SEL, NSUInteger, BOOL *))atomic_load(&originalProduce))(receiver, @selector(produceChunkForSlot:final:), slot, final);
    });
    IMP heldRetirement = imp_implementationWithBlock(^(id receiver, VibeVoiceID voice, uint64_t milliseconds) {
        if (receiver == self->_player && !heldRetire) {
            heldRetire = YES;
            // Let the serial decoder run while the seek is between its two
            // halves, before the old voice's reads are stopped.
            dispatch_semaphore_signal(letRead);
            dispatch_sync(decoder, ^{}); // the held read has actually returned before retirement proceeds
        }
        ((void (*)(id, SEL, VibeVoiceID, uint64_t))originalRetire)(receiver, @selector(retireVoiceOnQueue:milliseconds:), voice, milliseconds);
    });
    atomic_store(&originalProduce, method_getImplementation(produce));
    method_setImplementation(produce, heldProduce);
    originalRetire = method_setImplementation(retire, heldRetirement);
    @try {
        // The play's settle filled the ring to the top, so render it down past
        // the low-water mark until the drain asks for a chunk and the hold takes.
        for (int i = 0; i < 64 && !heldRead; i++) {
            [self render:1024];
        }
        XCTAssertEqual(dispatch_semaphore_wait(reading, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)), 0L);
        [_player seekToPosition:0.5];
        [_player runSyncOnQueue:^{}];
        XCTAssertTrue(heldRetire);
        __block VibeVoiceID current;
        [_player runSyncOnQueue:^{ current = [[self->_player valueForKey:@"voice"] unsignedLongLongValue]; }];
        [self settleUntil:^BOOL { return [bus snapshotOfVoice:current].written >= 16384; }];
        [_capture setLength:0];
        [self render:16384];
        NSData *whole = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
        NSData *expected = [whole subdataWithRange:NSMakeRange(24000 * 8, 16384 * 8)];
        NSDictionary *comparison = VibeComparePCM(expected, _capture, 2, 0, 0);
        XCTAssertTrue([comparison[@"pass"] boolValue], @"seek output differs: %@", comparison);
    } @finally {
        dispatch_semaphore_signal(letRead);
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        [bus stopReadingThen:^{ dispatch_semaphore_signal(stopped); }];
        dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)); // the swizzled read must be over before its IMP goes
        method_setImplementation(produce, atomic_load(&originalProduce));
        method_setImplementation(retire, originalRetire);
        imp_removeBlock(heldProduce);
        imp_removeBlock(heldRetirement);
    }
}

@end
