//
//  AudioPlayerRenderStreamTests.m
//

#import "AudioPlayerRenderTestCase.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "PlaceholderFiles.h"
#import "PlaceholderFiles+Debug.h"

// A file still downloading: holds at its download's edge, stalls, failed transfers and the open deadline.
@interface AudioPlayerRenderStreamTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderStreamTests

- (void)testAStalledDatalessProbeDoesNotBlockStopOrTheOpenDeadline {
    for (NSNumber *timeout in @[@NO, @YES]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        if (timeout.boolValue) [self shortenTheOpenDeadline];
        NSURL *url = [_temporary URLByAppendingPathComponent:[NSString stringWithFormat:@"held-%@.wav", timeout]];
        XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:[self fixture:@"noise-48000-24-2.wav"]
                                                         toURL:url error:NULL]);
        dispatch_semaphore_t entered = dispatch_semaphore_create(0);
        dispatch_semaphore_t release = dispatch_semaphore_create(0);
        [PlaceholderFiles setDatalessProbe:^BOOL(NSURL *probed) {
            if ([probed.lastPathComponent isEqual:url.lastPathComponent]) {
                dispatch_semaphore_signal(entered);
                dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
            }
            return NO;
        }];
        @try {
            [_player play:[AudioTrack withURL:url] atPosition:0 startPaused:NO];
            XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
            if (timeout.boolValue) {
                [self settleUntil:^BOOL { return self->_playError != nil; }];
                XCTAssertEqual(_playError.code, VibeAudioErrorFileOpenTimedOut);
            } else {
                [_player stop];
                [self settleUntil:^BOOL { return self->_player.isStopped; }];
            }
            XCTAssertTrue(_player.isStopped);
            _playError = nil;
            [self play:[self fixture:@"noise-48000-16-2.wav"] paused:NO position:0];
            XCTAssertEqual([self count:@"start"], 1u, @"an unrelated file still opens");
        } @finally {
            [PlaceholderFiles setDatalessProbe:nil];
            // Twice: frees a second probe of this file, should one ever run.
            dispatch_semaphore_signal(release);
            dispatch_semaphore_signal(release);
        }
    }
}

// A remote file readable with too little of its head to open: the open waits
// at the download's edge, the deadline cancels it, and the cancel ends that
// wait, so the player times out, the run leaves the ceiling, and the transfer
// nobody reads is cancelled.
- (void)testTheOpenDeadlineStopsAStreamingOpenParkedAtTheEdge {
    NSData *bytes = [NSData dataWithContentsOfURL:[self fixture:@"noise-48000-24-2.wav"]];
    NSURL *url = [_temporary URLByAppendingPathComponent:@"streaming.wav"];
    XCTAssertTrue([NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:@{NSFilePosixPermissions: @0}]);
    NSURL *part = [PlaceholderFiles remotePlaceholderPartURL:url];
    XCTAssertTrue([[bytes subdataWithRange:NSMakeRange(0, 16)] writeToURL:part atomically:NO]);
    CloudFileAvailability *availability = [[CloudFileAvailability alloc] initWithPartURL:part size:bytes.length];
    [availability noteWrittenBytes:16];
    dispatch_semaphore_t cancelled = dispatch_semaphore_create(0);
    __block _Atomic NSUInteger cancels = 0;
    NSError *cancellation = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
    [CloudFileMaterializer setRemoteRoot:_temporary fetch:^BOOL(NSURL *fetched, dispatch_block_t onReadable,
                                                                 void (^onCancel)(dispatch_block_t), NSError **error) {
        onCancel(^{
            atomic_fetch_add(&cancels, 1);
            dispatch_semaphore_signal(cancelled);
        });
        onReadable();
        dispatch_semaphore_wait(cancelled, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        dispatch_semaphore_signal(cancelled);
        [availability finishWithError:cancellation];
        if (error) *error = cancellation;
        return NO;
    } read:^NSData *(NSURL *read, uint64_t offset, uint64_t length, NSError **error) {
        return nil;
    } availability:^CloudFileAvailability *(NSURL *candidate) {
        return [candidate.path isEqualToString:url.path] ? availability : nil;
    }];
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self shortenTheOpenDeadline];
        AudioFileMaterializationCoordinator *coordinator = AudioFileMaterializationCoordinator.sharedCoordinator;
        uint64_t started = coordinator.stateSnapshotForTesting.handleOpensStarted;
        [_player play:[AudioTrack withURL:url] atPosition:0 startPaused:NO];
        [self settleUntil:^BOOL { return self->_playError != nil; }];
        XCTAssertEqual(_playError.code, VibeAudioErrorFileOpenTimedOut, @"%@", _playError);
        XCTAssertEqual(coordinator.stateSnapshotForTesting.handleOpensStarted, started + 1, @"the open began, on the part file");
        [self settleUntil:^BOOL {
            VibeAudioFileMaterializationCoordinatorSnapshot snapshot = coordinator.stateSnapshotForTesting;
            return snapshot.handleOpensCompleted == snapshot.handleOpensStarted && snapshot.handleRunCount == 0
                    && snapshot.claimCount == 0 && snapshot.interactiveRunningCount == 0 && atomic_load(&cancels) == 1;
        }];
        XCTAssertEqual([self count:@"start"], 0u);
    } @finally {
        dispatch_semaphore_signal(cancelled); // a failed run must not strand the fetch
        [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    }
}

// A 48 kHz 24-bit stereo noise file behind a stream with `seconds` of it
// downloaded: the ordinary pipeline on the decode pool, Declick off, so every
// edge is a cut and the capture is the file's own samples.
- (NSURL *)playStreamOf:(NSString *)fixture seconds:(double)seconds {
    NSURL *source = [self fixture:fixture];
    AVAudioPCMBuffer *decoded = [self read:source];
    NSUInteger frameBytes = decoded.format.channelCount * 3;
    NSUInteger header = [NSData dataWithContentsOfURL:source].length - decoded.frameLength * frameBytes;
    XCTAssertEqual(header, 44u);
    NSURL *url = [self streamingCopyOf:source prefix:header + (NSUInteger)(seconds * 48000) * frameBytes name:@"streaming.wav"];
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:url paused:NO position:0];
    }];
    // Rendering from a ring the pool has filled to the download's edge.
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].waitingForBytes; }];
    return url;
}

// A download behind the audio: the voice holds silent in place, still Playing,
// for as long as the bytes take, the output running past its idle stop, and
// plays on once at the frame it stopped at. The whole capture, silences taken
// out, is the file: nothing skipped, nothing repeated, no underrun.
- (void)testAStreamHoldsWhileItsDownloadIsBehindAndResumesOnceExactly {
    [self playStreamOf:@"noise-48000-24-2.wav" seconds:0.6];
    NSData *reference = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    [_capture setLength:0];
    for (int stall = 0; stall < 2; stall++) {
        XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }], @"hold %d", stall);
        XCTAssertEqual([_player.debugRenderCounts[@"underrunFrames"] unsignedIntegerValue], 0u, @"held before the ring ran dry");
        NSTimeInterval held = _player.position;
        NSUInteger before = _capture.length / 8;
        [self render:stall == 0 ? 48000 * 7 : 9600]; // past the 6 s idle stop the first time
        XCTAssertEqual(_player.position, held, @"the hold keeps its place");
        XCTAssertEqual(VibeRMS(_capture, 2, 0, NSMakeRange(before, _capture.length / 8 - before)), 0);
        XCTAssertTrue(_player.isPlaying);
        XCTAssertTrue(_player.isBuffering);
        XCTAssertFalse(_player.outputAudioActive, @"a held voice is not output");
        XCTAssertFalse(_player.outputIdle, @"a hold keeps the output running");
        XCTAssertEqual([self count:@"finish"], 0u);
        if (stall == 0) {
            [self streamTo:44 + 67200 * 6];
        }
        else {
            XCTAssertTrue([self finishStream:VibeStreamCompleted]);
        }
        XCTAssertTrue([self renderUntil:^BOOL { return !self->_player.isBuffering; }], @"release %d", stall);
    }
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1; }]);
    [self settleUntil:^BOOL { return [self count:@"buffered"] == 2; }];
    XCTAssertEqual([self count:@"buffering"], 2u, @"one hold, and one resume, per stall");
    XCTAssertEqual([self count:@"idle"], 0u);
    XCTAssertNil(_playError);
    NSDictionary *comparison = VibeComparePCM(VibeAudibleFrames(reference, 2), VibeAudibleFrames(_capture, 2), 2, 0, 0);
    XCTAssertTrue([comparison[@"pass"] boolValue], @"%@", comparison);
}

// A seek while the decode waits at the download's edge: the waiting read is
// interrupted, the new voice takes the file at once and plays from the target.
- (void)testASeekWhileParkedAtTheEdgeLandsAndPlaysOn {
    [self playStreamOf:@"noise-48000-24-2.wav" seconds:0.6];
    NSData *reference = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    [_player seekToPosition:0.2];
    [self settleUntil:^BOOL { return [self count:@"seek"] == 1; }];
    XCTAssertFalse(_player.isBuffering);
    // Its first read waits behind no one: the old voice's turn has returned.
    // A read waits for all it asks, so the pool stops a chunk short of the
    // edge: four chunks, of which less than the grace may play before a hold.
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].written >= 16384; }];
    [_capture setLength:0];
    [self render:3200];
    XCTAssertFalse(_player.isBuffering);
    [self assertReference:[reference subdataWithRange:NSMakeRange(9600 * 8, 3200 * 8)] capture:_capture skip:0 tolerance:0];
    XCTAssertNil(_playError);
    XCTAssertTrue([self finishStream:VibeStreamCompleted]);
}

// Buffering… rises only once a hold has lasted the delay, on the player's
// clock. A pause ends it, and so does the hold's release. A hold that ends
// sooner never raises it.
- (void)testBufferingNoticeWaitsOutTheDelayAndEndsWithItsHold {
    [self playStreamOf:@"noise-48000-24-2.wav" seconds:0.6];
    for (int pass = 0; pass < 2; pass++) {
        XCTAssertTrue([self renderUntil:^BOOL { return self->_player.bufferingNoticeShown; }], @"pass %d", pass);
        XCTAssertTrue(_player.isBuffering);
        XCTAssertGreaterThanOrEqual([_player.debugBufferingRecord[@"heldSeconds"] doubleValue], kWaitIndicatorDelaySeconds);
        if (pass == 0) {
            [_player pause];
            XCTAssertTrue([self renderUntil:^BOOL { return !self->_player.bufferingNoticeShown; }], @"the pause ends it");
            [_player resume];
        }
    }
    [self streamTo:44 + 57600 * 6];
    XCTAssertTrue([self renderUntil:^BOOL { return !self->_player.isBuffering; }]);
    XCTAssertFalse(_player.bufferingNoticeShown, @"the release ends it");

    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    XCTAssertTrue([self finishStream:VibeStreamCompleted]);
    XCTAssertTrue([self renderUntil:^BOOL { return !self->_player.isBuffering; }]);
    NSTimeInterval held = [_player.debugBufferingRecord[@"heldSeconds"] doubleValue];
    [self settleUntil:^BOOL { return [self count:@"buffered"] == 3; }];
    XCTAssertTrue([self count:@"notice"] == 2 || held >= kWaitIndicatorDelaySeconds, @"a %.3f s hold raised it", held);
    XCTAssertEqual([self count:@"noticeEnded"], [self count:@"notice"]);
    XCTAssertNil(_playError);
}

// A seek during a shown hold keeps Buffering… up. The hold ends with the old
// voice, and the new voice holds at once. A seek back into what has arrived
// ends it once the new voice plays.
- (void)testASeekDuringAShownHoldKeepsTheNoticeUpUntilTheNewVoicePlays {
    [self playStreamOf:@"noise-48000-24-2.wav" seconds:0.6];
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.bufferingNoticeShown; }]);
    for (NSNumber *target in @[@1.4, @1.6]) {
        NSUInteger seeks = [self count:@"seek"], holds = [self count:@"buffering"];
        [_player seekToPosition:target.doubleValue];
        [self settleUntil:^BOOL { return [self count:@"seek"] == seeks + 1; }];
        XCTAssertTrue(_player.bufferingNoticeShown, @"the seek to %@ s", target);
        XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"buffering"] == holds + 1; }], @"the new voice holds");
        XCTAssertTrue(_player.bufferingNoticeShown);
    }
    XCTAssertEqual([self count:@"noticeEnded"], 0u);
    [self streamTo:44 + 48000 * 6];
    [_player seekToPosition:0.2];
    XCTAssertTrue([self renderUntil:^BOOL { return !self->_player.bufferingNoticeShown; }], @"the new voice plays");
    XCTAssertFalse(_player.isBuffering);
    [self settleUntil:^BOOL { return [self count:@"noticeEnded"] == 1; }];
    XCTAssertEqual([self count:@"notice"], 1u);
    XCTAssertNil(_playError);
    XCTAssertTrue([self finishStream:VibeStreamCompleted]);
}

// A stop, then a skip, each while a decode waits at its download's edge: no
// hang, the waiting read interrupted, the handle let go, and the coordinator
// cancels the transfer nobody reads. The stop's voice is resampled, so its
// read waits inside the converter's pull.
- (void)testAStopOrASkipWhileParkedAtTheEdgeLetsTheStreamGo {
    NSURL *url = [self streamingCopyOf:[self fixture:@"noise-44100-16-2.wav"] prefix:44 + 26460 * 4 name:@"stopped.wav"];
    CloudFileAvailability *stream = _stream;
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:url paused:NO position:0];
    }];
    XCTAssertNotNil(_player.debugCurrentConversion, @"resampled");
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].waitingForBytes; }];
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    [_player stop];
    XCTAssertTrue([self renderUntil:^BOOL {
        return atomic_load(&self->_streamCancels) == 1 && stream.readerCount == 0;
    }], @"cancels %lu, readers %lu", (unsigned long)atomic_load(&_streamCancels), (unsigned long)stream.readerCount);
    XCTAssertTrue(_player.isStopped);
    XCTAssertFalse(_player.isBuffering);

    NSURL *skipped = [self streamingCopyOf:[self fixture:@"noise-48000-24-2.wav"] prefix:44 + 28800 * 6 name:@"skipped.wav"];
    stream = _stream;
    [self play:skipped paused:NO position:0];
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].waitingForBytes; }];
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    NSURL *local = [self fixture:@"noise-48000-16-2.wav"];
    [self play:local paused:NO position:0];
    [_capture setLength:0];
    XCTAssertTrue([self renderUntil:^BOOL {
        return atomic_load(&self->_streamCancels) == 1 && stream.readerCount == 0;
    }], @"cancels %lu, readers %lu", (unsigned long)atomic_load(&_streamCancels), (unsigned long)stream.readerCount);
    [self render:4800];
    XCTAssertEqual([self assertExactExcerptsOf:@[VibePCM([self read:local])] inCapture:_capture rampFrames:0 ramped:NULL], 1u,
                   @"the next track plays its own samples, from its start");
    XCTAssertEqual([self count:@"finish"], 0u);
    XCTAssertNil(_playError);
}

// The transfer failing under a hold is a read failure: the voice plays what it
// buffered and ends through the failure path, never as a clean track end.
- (void)testAStreamWhoseTransferFailsEndsInAnErrorNotATrackEnd {
    [self playStreamOf:@"noise-48000-24-2.wav" seconds:0.6];
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    _streamFailure = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil];
    XCTAssertTrue([self finishStream:VibeStreamFailed]);
    XCTAssertTrue([self renderUntil:^BOOL { return self->_playError != nil; }]);
    XCTAssertEqual(_playError.code, VibeAudioErrorEngineStartFailed, @"%@", _playError);
    NSError *underlying = _playError.userInfo[NSUnderlyingErrorKey];
    XCTAssertEqualObjects(underlying.domain, NSURLErrorDomain);
    XCTAssertEqual(underlying.code, NSURLErrorNetworkConnectionLost);
    XCTAssertTrue(_player.isStopped);
    XCTAssertFalse(_player.isBuffering);
    XCTAssertEqual([self count:@"finish"], 0u);
}

// A hold the download makes no progress under for the deadline pauses in
// place with the stall's error: never a track end, Paused where it stopped,
// the stream let go and cancelled. Play then replays from there through the
// ordinary path, which fetches afresh.
- (void)testAStallPausesInPlaceAndPlayReplaysFromThere {
    NSURL *source = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = VibePCM([self read:source]);
    [self streamingCopyOf:source prefix:44 + 28800 * 6 name:@"stalled.wav"];
    CloudFileAvailability *stream = _stream;
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:self->_streamURL paused:NO position:0];
        [self shortenTheOpenDeadline];
    }];
    NSTimeInterval held = [self stallTheStream];
    XCTAssertGreaterThan(_player.duration, 1.9);
    XCTAssertTrue([self renderUntil:^BOOL {
        return atomic_load(&self->_streamCancels) == 1 && stream.readerCount == 0;
    }], @"cancels %lu, readers %lu", (unsigned long)atomic_load(&_streamCancels), (unsigned long)stream.readerCount);

    _playError = nil;
    [_player playPause];
    [self settleUntil:^BOOL { return [self count:@"start"] == 2 || self->_playError; }];
    XCTAssertNil(_playError);
    XCTAssertEqual(atomic_load(&_streamFetches), 2u, @"the replay fetched afresh");
    XCTAssertTrue(_player.isPlaying);
    [self assertTheReplayOf:reference startsAt:held];
}

// The resume that replays a stalled stream keeps its place among the
// transport commands: a stop submitted right after it leaves the player
// Stopped, with no voice, no replay and no second fetch; and a play of
// another track submitted right after it is the one that plays.
- (void)testAResumeThatReplaysAStallYieldsToALaterStopOrPlay {
    NSURL *source = [self fixture:@"noise-48000-24-2.wav"];
    [self streamingCopyOf:source prefix:44 + 28800 * 6 name:@"stalled.wav"];
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:self->_streamURL paused:NO position:0];
        [self shortenTheOpenDeadline];
    }];
    [self stallTheStream];
    // Both submitted before the queue takes the resume.
    [self withPlayerQueueHeld:^{
        [self->_player resume];
        [self->_player stop];
    }];
    [_player runSyncOnQueue:^{}];
    [_player runSyncOnQueue:^{}];
    [self render:4800];
    [_player runSyncOnQueue:^{}];
    XCTAssertTrue(_player.isStopped, @"the stop, submitted last, wins");
    XCTAssertEqual([[_player valueForKey:@"voice"] unsignedLongLongValue], 0u);
    XCTAssertEqual([self count:@"start"], 1u, @"no replay");
    XCTAssertEqual(atomic_load(&_streamFetches), 1u, @"no second fetch");

    [self streamingCopyOf:source prefix:44 + 28800 * 6 name:@"stalled-again.wav"];
    _playError = nil;
    [self play:_streamURL paused:NO position:0];
    [self stallTheStream];
    NSURL *local = [self fixture:@"noise-48000-16-2.wav"];
    AudioTrack *other = [AudioTrack withURL:local];
    NSUInteger starts = [self count:@"start"];
    [self withPlayerQueueHeld:^{
        [self->_player resume];
        [self->_player play:other atPosition:0 startPaused:NO];
    }];
    [self settleUntil:^BOOL { return [self count:@"start"] > starts; }];
    [_player runSyncOnQueue:^{}];
    [_player runSyncOnQueue:^{}];
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].written >= 16384; }];
    [_capture setLength:0];
    [self render:4800];
    [_player runSyncOnQueue:^{}];
    XCTAssertEqual(_player.currentTrack, other, @"the play, submitted last, wins");
    XCTAssertEqual([self count:@"start"], starts + 1, @"no replay after it");
    XCTAssertEqual([self assertExactExcerptsOf:@[VibePCM([self read:local])] inCapture:_capture rampFrames:0 ramped:NULL], 1u);
}

@end
