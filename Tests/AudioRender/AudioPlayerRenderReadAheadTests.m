//
//  AudioPlayerRenderReadAheadTests.m
//

#import "AudioPlayerRenderTestCase.h"
#import "AudioFileHandle+Debug.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "VibeReadAheadScript.h"

// A file on a network share, read ahead: throttled, stalled and failing reads, and the queue meanwhile.
@interface AudioPlayerRenderReadAheadTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderReadAheadTests {
    // The read-ahead tests' network share: files under it read ahead, their
    // reads as the script says.
    NSURL *_network;
    VibeReadAheadScript *_script;
}

// The read-ahead counts are process-wide. The player and its handles go
// first, then every stalled read is released, so every thread is gone before
// the next test counts.
- (void)tearDown {
    if (_script) {
        self.continueAfterFailure = YES;
        [_player debugShutdown]; _player = nil;
        [_script releaseEverything];
        [self settleUntil:^BOOL { return VibeReadAheadScript.threadsGone; }];
        [VibeReadAheadScript removeHook];
        _script = nil;
    }
    [super tearDown];
}

// Files on the test's network share read ahead, as a file on a network mount
// does when the coordinator opens it. Every other file asks the real rule,
// which sends a local temporary directory down the direct road.
- (VibeReadAheadScript *)readAhead {
    if (!_script) {
        _network = [_temporary URLByAppendingPathComponent:@"network" isDirectory:YES];
        XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:_network withIntermediateDirectories:YES
                                                              attributes:nil error:NULL]);
        // Either spelling of the temporary directory.
        _script = [[VibeReadAheadScript alloc] initForPathsContaining:
                           [NSString stringWithFormat:@"/%@/network/", _temporary.lastPathComponent]];
    }
    return _script;
}

- (NSURL *)networkCopyOf:(NSURL *)source {
    [self readAhead];
    NSURL *url = [_network URLByAppendingPathComponent:source.lastPathComponent];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:source toURL:url error:NULL], @"%@", source);
    return url;
}

// `seconds` of nonperiodic float32 stereo noise at 48 kHz on the network
// share, 384000 bytes a second after a 44-byte header.
- (NSURL *)networkNoiseOfSeconds:(NSUInteger)seconds name:(NSString *)name {
    NSData *pcm = VibeUniqueNoise(seconds * 48000, 0x9E3779B9u);
    [self readAhead];
    return VibeWriteWAV([_network URLByAppendingPathComponent:name], pcm, 48000, 2, 32, (uint32_t)pcm.length);
}

// The noise fixture, its read-ahead stalled at its second block, about 0.9 s
// in, playing on the decode pool with Declick off.
- (NSURL *)playStalledReadAheadShortDeadline:(BOOL)shortDeadline {
    NSURL *url = [self networkCopyOf:[self fixture:@"noise-48000-24-2.wav"]];
    [[self readAhead] stallFrom:kReadAheadBlock];
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        if (shortDeadline) [self shortenTheOpenDeadline];
        [self play:url paused:NO position:0];
    }];
    XCTAssertTrue([self await:_script.stalled], @"the read-ahead stalls");
    return url;
}

- (BOOL)await:(dispatch_semaphore_t)semaphore {
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) == 0;
}

// The player queue answers another thread within the hang guard.
- (void)assertTheQueueAnswers:(NSString *)context {
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    AudioPlayer *player = _player;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [player runSyncOnQueue:^{ dispatch_semaphore_signal(answered); }];
    });
    XCTAssertTrue([self await:answered], @"the player queue waited on a stalled read: %@", context);
}

// A read-ahead throttled behind the audio plays the file exactly: the whole
// capture, silences taken out, is the direct open's decode.
- (void)testAThrottledReadAheadPlaysExactlyAsTheDirectOpen {
    NSURL *url = [self networkNoiseOfSeconds:4 name:@"throttled.wav"];
    NSData *reference = VibePCM([self read:url]);
    [self readAhead].throttle = 100000;
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:url paused:NO position:0];
    }];
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1; }]);
    [self settleUntil:^BOOL { return [self count:@"buffered"] == [self count:@"buffering"]; }];
    XCTAssertNil(_playError);
    XCTAssertEqual([_script readsOf:url.lastPathComponent at:0], 1u, @"it read ahead");
    NSDictionary *comparison = VibeComparePCM(VibeAudibleFrames(reference, 2), VibeAudibleFrames(_capture, 2), 2, 0, 0);
    XCTAssertTrue([comparison[@"pass"] boolValue], @"%@", comparison);
}

// Seeks beyond, inside and behind the blocks a read-ahead holds each land on
// their frame. Beyond waits for a block never read, inside reads nothing,
// and behind reads again a block the read-ahead dropped.
- (void)testSeeksAroundAReadAheadsBlocksLandExactly {
    NSURL *url = [self networkNoiseOfSeconds:8 name:@"seeks.wav"];
    NSString *name = url.lastPathComponent;
    NSData *reference = VibePCM([self read:url]);
    VibeReadAheadScript *script = [self readAhead];
    [script stallFrom:6 * kReadAheadBlock];
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:url paused:NO position:0];
    }];
    XCTAssertTrue([self await:script.stalled]);
    [self render:48000];
    // Each seek lands on its frame. 6.0 s is in block 8, 7.5 s in block 10,
    // the last but one, and 1.0 s in block 1. A seek whose bytes are not yet
    // here holds until a drain sees them.
    void (^land)(double, NSUInteger) = ^(double seconds, NSUInteger seeks) {
        [self settleUntil:^BOOL { return [self count:@"seek"] == seeks; }];
        [self settleUntil:^BOOL { return [self currentVoiceSnapshot].written >= 16384; }];
        XCTAssertTrue([self renderUntil:^BOOL { return !self->_player.isBuffering; }]);
        [self->_capture setLength:0];
        [self render:3200];
        NSUInteger frame = (NSUInteger)llround(seconds * 48000);
        [self assertReference:[reference subdataWithRange:NSMakeRange(frame * 8, 3200 * 8)] capture:self->_capture
                         skip:0 tolerance:0];
    };
    [_player seekToPosition:6.0];
    // The thread drops blocks only after it installs one, at the reader's
    // position from before that read. The seek's read must wait at 6.0 s
    // before the stall is released. Otherwise the thread can fetch to the end
    // at the old position, drop nothing, and still hold block 1 for the seek
    // behind.
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].waitingForBytes; }];
    XCTAssertEqual([script readsOf:name at:8 * kReadAheadBlock], 0u, @"beyond what is held");
    [script releaseStalls];
    land(6.0, 1);
    [self settleUntil:^BOOL { return [script readsOf:name at:11 * kReadAheadBlock] == 1; }];
    XCTAssertEqual([script readsOf:name at:10 * kReadAheadBlock], 1u);
    [_player seekToPosition:7.5];
    land(7.5, 2);
    XCTAssertEqual([script readsOf:name at:10 * kReadAheadBlock], 1u, @"inside what is held");
    XCTAssertEqual([script readsOf:name at:kReadAheadBlock], 1u);
    [_player seekToPosition:1.0];
    land(1.0, 3);
    XCTAssertEqual([script readsOf:name at:kReadAheadBlock], 2u, @"behind, dropped and read again");
    XCTAssertNil(_playError);
}

// A read-ahead stalled ahead of the decode holds the voice silent in place,
// still Playing, and plays on once at the frame it stopped at once the read
// returns. The whole capture, silences taken out, is the file.
- (void)testAStalledReadAheadHoldsAndPlaysOnOnceExactly {
    NSData *reference = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    [self playStalledReadAheadShortDeadline:NO];
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    XCTAssertEqual([_player.debugRenderCounts[@"underrunFrames"] unsignedIntegerValue], 0u, @"held before the ring ran dry");
    NSTimeInterval held = _player.position;
    NSUInteger before = _capture.length / 8;
    [self render:48000];
    XCTAssertEqual(_player.position, held, @"the hold keeps its place");
    XCTAssertEqual(VibeRMS(_capture, 2, 0, NSMakeRange(before, _capture.length / 8 - before)), 0);
    XCTAssertTrue(_player.isPlaying);
    XCTAssertTrue(_player.isBuffering);
    XCTAssertFalse(_player.outputAudioActive, @"a held voice is not output");
    [self settleUntil:^BOOL { return [self count:@"buffering"] == 1; }];
    [_script releaseStalls];
    XCTAssertTrue([self renderUntil:^BOOL { return !self->_player.isBuffering; }]);
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1; }]);
    [self settleUntil:^BOOL { return [self count:@"buffered"] == 1; }];
    XCTAssertEqual([self count:@"buffering"], 1u, @"one hold, and one resume");
    XCTAssertNil(_playError);
    NSDictionary *comparison = VibeComparePCM(VibeAudibleFrames(reference, 2), VibeAudibleFrames(_capture, 2), 2, 0, 0);
    XCTAssertTrue([comparison[@"pass"] boolValue], @"%@", comparison);
}

// A read-ahead stalled past the deadline pauses in place with the stall's
// error, never a track end. Its handle goes, leaving the thread inside its
// read. Play then replays from there on a new read-ahead.
- (void)testAReadAheadStalledPastTheDeadlinePausesAndPlayReplaysFromThere {
    NSData *reference = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    [self playStalledReadAheadShortDeadline:YES];
    NSTimeInterval held = [self stallTheStream];
    XCTAssertTrue([self renderUntil:^BOOL { return AudioFileHandle.debugOrphanedReadAheads == 1; }],
                  @"orphans %ld", (long)AudioFileHandle.debugOrphanedReadAheads);
    [_script releaseStalls];
    [self settleUntil:^BOOL { return VibeReadAheadScript.threadsGone; }];
    _playError = nil;
    [_player playPause];
    [self settleUntil:^BOOL { return [self count:@"start"] == 2 || self->_playError; }];
    XCTAssertNil(_playError);
    XCTAssertTrue(_player.isPlaying);
    [self assertTheReplayOf:reference startsAt:held];
}

// A server that fails every read for longer than the deadline ends in the
// same pause. Its thread, pausing between retries, ends with its handle.
// Play then replays from there.
- (void)testAReadErrorPastTheDeadlinePausesAndPlayReplaysFromThere {
    NSURL *source = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:source]);
    NSURL *url = [self networkCopyOf:source];
    [_script fail:EIO from:kReadAheadBlock always:YES];
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self shortenTheOpenDeadline];
        [self play:url paused:NO position:0];
    }];
    XCTAssertTrue([self await:_script.failed]);
    NSTimeInterval held = [self stallTheStream];
    [_script stopFailing];
    XCTAssertTrue([self renderUntil:^BOOL { return VibeReadAheadScript.threadsGone; }],
                  @"live %ld", (long)AudioFileHandle.debugLiveReadAheads);
    _playError = nil;
    [_player playPause];
    [self settleUntil:^BOOL { return [self count:@"start"] == 2 || self->_playError; }];
    XCTAssertNil(_playError);
    [self assertTheReplayOf:reference startsAt:held];
}

// A server back within the span: reads that fail long enough to hold the
// voice, then answer again, release the hold, and the file plays on exactly.
- (void)testABriefReadErrorHoldsAndPlaysOnExactly {
    NSURL *source = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:source]);
    NSURL *url = [self networkCopyOf:source];
    [_script fail:EIO from:kReadAheadBlock always:YES];
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:url paused:NO position:0];
    }];
    XCTAssertTrue([self await:_script.failed]);
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    [_script stopFailing];
    XCTAssertTrue([self renderUntil:^BOOL { return !self->_player.isBuffering; }], @"the retry releases the hold");
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1; }]);
    [self settleUntil:^BOOL { return [self count:@"buffered"] == 1; }];
    XCTAssertEqual([self count:@"buffering"], 1u);
    XCTAssertNil(_playError);
    NSDictionary *comparison = VibeComparePCM(VibeAudibleFrames(reference, 2), VibeAudibleFrames(_capture, 2), 2, 0, 0);
    XCTAssertTrue([comparison[@"pass"] boolValue], @"%@", comparison);
}

// A seek, a stop and a skip, each while the read-ahead's read is stalled: the
// player queue answers at once, the seek lands, and the stop and the skip let
// the handle go with its thread still inside the read. Released, every
// thread ends.
- (void)testASeekStopOrSkipDuringAStalledReadAheadKeepsTheQueueResponsive {
    NSData *reference = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    NSURL *url = [self playStalledReadAheadShortDeadline:NO];
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    [_player seekToPosition:0.5];
    [self assertTheQueueAnswers:@"seek"];
    [self settleUntil:^BOOL { return [self count:@"seek"] == 1; }];
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].written >= 16384; }];
    [_capture setLength:0];
    [self render:3200];
    [self assertReference:[reference subdataWithRange:NSMakeRange(24000 * 8, 3200 * 8)] capture:_capture skip:0 tolerance:0];

    [_player stop];
    [self assertTheQueueAnswers:@"stop"];
    XCTAssertTrue([self renderUntil:^BOOL { return AudioFileHandle.debugOrphanedReadAheads == 1; }],
                  @"orphans %ld", (long)AudioFileHandle.debugOrphanedReadAheads);
    XCTAssertTrue(_player.isStopped);
    XCTAssertFalse(_player.isBuffering);

    [self play:url paused:NO position:0];
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    NSURL *local = [self fixture:@"noise-48000-16-2.wav"];
    [self play:local paused:NO position:0];
    [self assertTheQueueAnswers:@"skip"];
    XCTAssertTrue([self renderUntil:^BOOL { return AudioFileHandle.debugOrphanedReadAheads == 2; }],
                  @"orphans %ld", (long)AudioFileHandle.debugOrphanedReadAheads);
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].written >= 16384; }];
    [_capture setLength:0];
    [self render:4800];
    XCTAssertEqual([self assertExactExcerptsOf:@[VibePCM([self read:local])] inCapture:_capture rampFrames:0 ramped:NULL], 1u,
                   @"the next track plays its own samples, from its start");
    XCTAssertEqual([self count:@"finish"], 0u);
    XCTAssertNil(_playError);
    [_script releaseStalls];
    [self settleUntil:^BOOL { return VibeReadAheadScript.threadsGone; }];
}

// An open whose read-ahead stalls on its first block: the deadline cancels
// it, the player times out, the run leaves the ceiling and the queue answers.
// The thread, orphaned inside its read, ends once the read returns.
- (void)testTheOpenDeadlineStopsAnOpenParkedInAReadAhead {
    NSURL *url = [self networkCopyOf:[self fixture:@"noise-48000-24-2.wav"]];
    [_script stallFrom:0];
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self shortenTheOpenDeadline];
    AudioFileMaterializationCoordinator *coordinator = AudioFileMaterializationCoordinator.sharedCoordinator;
    uint64_t started = coordinator.stateSnapshotForTesting.handleOpensStarted;
    [_player play:[AudioTrack withURL:url] atPosition:0 startPaused:NO];
    XCTAssertTrue([self await:_script.stalled]);
    [self settleUntil:^BOOL { return self->_playError != nil; }];
    XCTAssertEqual(_playError.code, VibeAudioErrorFileOpenTimedOut, @"%@", _playError);
    [self assertTheQueueAnswers:@"the open deadline"];
    XCTAssertEqual(coordinator.stateSnapshotForTesting.handleOpensStarted, started + 1);
    [self settleUntil:^BOOL {
        VibeAudioFileMaterializationCoordinatorSnapshot snapshot = coordinator.stateSnapshotForTesting;
        return snapshot.handleOpensCompleted == snapshot.handleOpensStarted && snapshot.handleRunCount == 0
                && snapshot.claimCount == 0 && AudioFileHandle.debugOrphanedReadAheads == 1;
    }];
    XCTAssertEqual([self count:@"start"], 0u);
    [_script releaseStalls];
    [self settleUntil:^BOOL { return VibeReadAheadScript.threadsGone; }];
    _playError = nil;
    [self play:[self fixture:@"noise-48000-16-2.wav"] paused:NO position:0];
    XCTAssertEqual([self count:@"start"], 1u, @"an unrelated file still opens");
}

// A parked prefetch reads ahead as the playing file does: both threads live,
// and the park's file read past its first block, before the first track
// ends. The splice is exact.
- (void)testAParkedPrefetchReadsAheadAndSplicesExactly {
    NSData *reference = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    NSUInteger split = 48001;
    NSURL *first = [self networkCopyOf:[self write:[reference subdataWithRange:NSMakeRange(0, split * 8)]
                                              rate:48000 channels:2 name:@"first.wav"]];
    NSURL *second = [self networkCopyOf:[self write:[reference subdataWithRange:NSMakeRange(split * 8, reference.length - split * 8)]
                                               rate:48000 channels:2 name:@"second.wav"]];
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:first paused:NO position:0];
    }];
    // Named once the first track decodes: a successor queued before its first
    // drain leaves the pool idle until a render.
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].written >= 16384; }];
    [_player prefetchTrack:[AudioTrack withURL:second]];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    [self settleUntil:^BOOL {
        return AudioFileHandle.debugLiveReadAheads == 2 && [self->_script readsOf:@"second.wav" at:kReadAheadBlock] == 1;
    }];
    XCTAssertEqual([self count:@"advance"], 0u);
    XCTAssertEqualObjects(_player.currentTrack.url, first);
    [self assertReference:reference capture:[self renderSeconds:2.1] skip:0 tolerance:0];
    [self settleUntil:^BOOL { return [self count:@"advance"] >= 1 && [self count:@"finish"] >= 1; }];
    XCTAssertEqual([self count:@"advance"], 1u);
    XCTAssertEqual([self count:@"finish"], 1u);
    XCTAssertNil(_playError);
}

// A stream that stops still stalls while its queued successor, on a slow
// share, keeps reading ahead. Only the file the voice reads counts as
// progress. The successor's would hold the voice for as long as it fetched.
- (void)testAStalledTrackStallsWhileItsQueuedSuccessorReadsAhead {
    [self streamingCopyOf:[self fixture:@"noise-48000-24-2.wav"] prefix:44 + 28800 * 6 name:@"stalled.wav"];
    NSURL *successor = [self networkNoiseOfSeconds:20 name:@"successor.wav"];
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:successor.path error:NULL];
    uint64_t lastBlock = (attributes.fileSize - 1) / kReadAheadBlock * kReadAheadBlock;
    _script.throttle = 250000;
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self shortenTheOpenDeadline];
        [self play:self->_streamURL paused:NO position:0];
    }];
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].written >= 16384; }];
    [_player prefetchTrack:[AudioTrack withURL:successor]];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    [self stallTheStream];
    XCTAssertGreaterThan([_script readsOf:successor.lastPathComponent at:kReadAheadBlock], 0u, @"the successor read ahead");
    XCTAssertEqual([_script readsOf:successor.lastPathComponent at:lastBlock], 0u,
                   @"the stall came while the successor still read ahead");
}

@end
