//
//  AudioPlayerRenderEstimatedTests.m
//

#import "AudioPlayerRenderTestCase.h"

// Headerless streams played on an estimated length, and the duration each settles.
@interface AudioPlayerRenderEstimatedTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderEstimatedTests

// An MP3's audio frames, its ID3v2 tag left off.
static NSData *MP3Frames(NSData *mp3) {
    const uint8_t *b = mp3.bytes;
    NSUInteger start = mp3.length > 10 && !memcmp(b, "ID3", 3)
            ? 10 + ((NSUInteger)(b[6] & 0x7F) << 21 | (b[7] & 0x7F) << 14 | (b[8] & 0x7F) << 7 | (b[9] & 0x7F)) : 0;
    return [mp3 subdataWithRange:NSMakeRange(start, mp3.length - start)];
}

// `bytes`, an MP3 with no VBR header, streaming on `prefix` bytes and an 8 KB
// tail window, played on the decode pool with Declick off. Answers the whole
// file.
- (NSURL *)playEstimatedStreamOf:(NSData *)bytes prefix:(NSUInteger)prefix name:(NSString *)name {
    NSURL *source = [self streamEstimated:bytes prefix:prefix name:name];
    [self playTheEstimatedStream];
    return source;
}

// The hold at the download's edge, which these streams put a tail window
// short of the end, past half of the file's `frames`. TRAP: not any hold.
// streamTo: lands a stream's bytes at once, and on a slow machine the first
// drain can still find the decoder waiting at the prefix's edge, not yet
// woken, with little buffered: a hold of one drain at the prefix, well under
// half of every file here.
- (BOOL)heldPastHalfOf:(NSUInteger)frames {
    return _player.isBuffering && [self currentVoiceSnapshot].consumed * 2 >= frames;
}

// The stream streamEstimated: made, played from its start on the decode pool.
- (void)playTheEstimatedStream {
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:self->_streamURL paused:NO position:0];
    }];
}

// `bytes` streaming as playEstimatedStreamOf: does, not yet played. Answers
// the whole file.
- (NSURL *)streamEstimated:(NSData *)bytes prefix:(NSUInteger)prefix name:(NSString *)name {
    AudioFileHandle.appleMPEGDecoder = NO;
    NSURL *source = [self writeBytes:bytes name:[@"whole-" stringByAppendingString:name]];
    [self streamingCopyOf:source prefix:prefix name:name];
    [self installTailWindow:8192];
    return source;
}

// A headerless MP3 whose head is one rate and the rest another: 50 silent
// 320 kbps frames, 1.2 s, then four runs of a 192 kbps encode. A stream
// opening on less than its head walks only 320 kbps frames, whose rate's
// count, 6.1 s, is over three seconds short of the file's 9.4.
- (NSData *)constantHeadMP3 {
    NSData *encoded = MP3Frames([NSData dataWithContentsOfURL:[self optionalFixture:@"cbr-noinfo.mp3"]]);
    NSMutableData *bytes = [VibeMP3WithoutVBRHeader(50, 48000, ^uint8_t(uint32_t frame) { return 14; }) mutableCopy];
    for (int i = 0; i < 4; i++) [bytes appendData:encoded];
    return bytes;
}

- (NSDictionary *)settledEvent {
    for (NSDictionary *event in _events) if ([event[@"event"] isEqual:@"settled"]) return event;
    return nil;
}

// A VBR MP3 with no VBR header, four runs of an encode, plays while it
// streams on a duration estimated from its head, within 2% here. A seek
// inside what has arrived lands exactly; the download completing, with the
// decode parked at its edge early in the file, settles the exact duration
// within the hang guard and republishes it once, to the track too, the
// position carrying on rather than jumping; a seek after it lands exactly;
// and the track plays to its true end, every audible frame the whole file's,
// and ends once.
- (void)testAnEstimatedStreamSettlesItsDurationOnceItsDownloadCompletes {
    NSData *encoded = MP3Frames([NSData dataWithContentsOfURL:[self optionalFixture:@"vbr-noxing.mp3"]]);
    NSMutableData *bytes = [NSMutableData data];
    for (int i = 0; i < 4; i++) [bytes appendData:encoded];
    NSURL *source = [self playEstimatedStreamOf:bytes prefix:32 * 1024 name:@"estimated.mp3"];
    NSData *reference = VibePCM([self read:source]);
    double exact = (double)[self open:source decoder:@"dr_mp3"].length / 48000;
    AudioTrack *track = _player.currentTrack;
    XCTAssertTrue(((AudioFileHandle *)[_player valueForKey:@"file"]).lengthIsEstimated);
    XCTAssertEqualWithAccuracy(_player.duration, exact, exact * 0.02);
    XCTAssertEqual(track.duration, _player.duration);

    [_player seekToPosition:0.2];
    [self settleUntil:^BOOL { return [self count:@"seek"] == 1; }];
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].written >= 16384; }];
    [_capture setLength:0];
    [self render:2400];
    [self assertReference:[reference subdataWithRange:NSMakeRange(9600 * 8, 2400 * 8)] capture:_capture skip:0 tolerance:0];
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].waitingForBytes; }];
    XCTAssertEqual([self count:@"settled"], 0u);

    NSTimeInterval before = _player.position;
    NSUInteger rendered = _capture.length;
    XCTAssertTrue([self finishStream:VibeStreamCompleted]);
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"settled"] == 1; }]);
    XCTAssertEqual([[self settledEvent][@"duration"] doubleValue], exact);
    XCTAssertEqual([[self settledEvent][@"trackDuration"] doubleValue], exact);
    XCTAssertEqual(_player.duration, exact);
    XCTAssertGreaterThanOrEqual(_player.position, before);
    XCTAssertLessThanOrEqual(_player.position - before, (_capture.length - rendered) / 8 / 48000.0 + 1e-9, @"no jump");

    double target = floor(exact) - 1;
    NSUInteger frame = (NSUInteger)target * 48000;
    [_player seekToPosition:target];
    [self settleUntil:^BOOL { return [self count:@"seek"] == 2; }];
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].written >= 16384; }];
    [_capture setLength:0];
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1; }]);
    [self render:4800];
    NSData *tail = [reference subdataWithRange:NSMakeRange(frame * 8, reference.length - frame * 8)];
    [self assertReference:[tail subdataWithRange:NSMakeRange(0, 3200 * 8)] capture:[_capture subdataWithRange:NSMakeRange(0, 3200 * 8)]
                     skip:0 tolerance:0];
    NSDictionary *comparison = VibeComparePCM(VibeAudibleFrames(tail, 2), VibeAudibleFrames(_capture, 2), 2, 0, 0);
    XCTAssertTrue([comparison[@"pass"] boolValue], @"to the true end: %@", comparison);
    XCTAssertEqual([self count:@"settled"], 1u, @"republished once");
    XCTAssertEqual([self count:@"finish"], 1u);
    XCTAssertNil(_playError);
}

// A VBR stream whose head is denser than the rest, its duration estimated
// short, one whose head is one rate and the rest another, estimated short on
// that rate's count, and one whose head is sparser, estimated long, each real
// frames either side of silent ones, played while they stream to just short
// of their end: the first two run on past their estimate with no track end,
// the clock following the audio past it, never held at it nor running back,
// and so does a seek back inside the first's; the third does not end at its
// estimate; and each, once its download completes, plays to its true end,
// every audible frame the whole file's, its duration settled there once and
// the track ending once.
- (void)testAShortOrLongEstimatedStreamPlaysToItsTrueEnd {
    NSData *encoded = MP3Frames([NSData dataWithContentsOfURL:[self optionalFixture:@"vbr-noxing.mp3"]]);
    NSData *silent = VibeMP3WithoutVBRHeader(600, 48000, ^uint8_t(uint32_t frame) { return 1 + frame % 2; });
    NSMutableData *dense = [encoded mutableCopy];
    [dense appendData:silent];
    [dense appendData:encoded];
    NSMutableData *sparse = [silent mutableCopy];
    for (int i = 0; i < 4; i++) [sparse appendData:encoded];
    NSDictionary<NSString *, NSData *> *streams = @{@"dense.mp3": dense, @"constant-head.mp3": [self constantHeadMP3], @"sparse.mp3": sparse};
    for (NSString *name in @[@"dense.mp3", @"constant-head.mp3", @"sparse.mp3"]) {
        BOOL denseHead = [name isEqual:@"dense.mp3"], shortEstimate = ![name isEqual:@"sparse.mp3"];
        NSURL *source = [self streamEstimated:streams[name] prefix:24576 name:name];
        double exact = (double)[self open:source decoder:@"dr_mp3"].length / 48000;
        NSData *reference = VibePCM([self read:source]);
        [self playTheEstimatedStream];
        _blockSize = 4096; // twenty seconds of audio inside the hang guard
        double estimate = _player.duration;
        XCTAssertTrue(((AudioFileHandle *)[_player valueForKey:@"file"]).lengthIsEstimated, @"%@", name);
        XCTAssertTrue(shortEstimate ? estimate < exact * 0.7 : estimate > exact * 1.5, @"%@: %g s of %g", name, estimate, exact);
        [self streamTo:_streamBytes.length - 8192 - 1];
        __block NSTimeInterval clock = 0;
        __block BOOL monotonic = YES;
        XCTAssertTrue([self renderUntil:^BOOL {
            NSTimeInterval position = self->_player.position;
            monotonic = monotonic && position >= clock;
            clock = position;
            return [self heldPastHalfOf:reference.length / 8];
        }], @"%@ played to the download's edge: consumed %llu of %lu", name,
            [self currentVoiceSnapshot].consumed, (unsigned long)(reference.length / 8));
        XCTAssertTrue(monotonic, @"%@: the clock never ran back", name);
        NSUInteger from = 0;
        if (shortEstimate) {
            [self render:4800];
            uint64_t consumed = [self currentVoiceSnapshot].consumed;
            XCTAssertGreaterThan(consumed, (uint64_t)(estimate * 48000), @"%@: past the estimate", name);
            XCTAssertEqualWithAccuracy(_player.position, consumed / 48000.0, 1e-9, @"%@: the clock follows the audio past the estimate", name);
        }
        if (denseHead) {
            // A seek back inside the estimate: a voice taking its end from it
            // would end there, short of the stream's end.
            double target = floor(estimate) - 1;
            from = (NSUInteger)target * 48000;
            [_player seekToPosition:target];
            [self settleUntil:^BOOL { return [self count:@"seek"] == 1; }];
            [_capture setLength:0];
        }
        XCTAssertEqual([self count:@"finish"], 0u, @"%@", name);
        XCTAssertEqual([self count:@"settled"], 0u, @"%@", name);
        XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }], @"%@ held at the download's edge", name);
        XCTAssertEqual([self count:@"finish"], 0u, @"%@", name);
        XCTAssertTrue([self finishStream:VibeStreamCompleted]);
        XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1; }], @"%@", name);
        [self render:4800];
        XCTAssertEqual([self count:@"settled"], 1u, @"%@", name);
        XCTAssertEqual([[self settledEvent][@"duration"] doubleValue], exact, @"%@", name);
        XCTAssertEqual([self count:@"finish"], 1u, @"%@", name);
        XCTAssertNil(_playError, @"%@", name);
        NSData *played = [reference subdataWithRange:NSMakeRange(from * 8, reference.length - from * 8)];
        NSDictionary *comparison = VibeComparePCM(VibeAudibleFrames(played, 2), VibeAudibleFrames(_capture, 2), 2, 0, 0);
        XCTAssertTrue([comparison[@"pass"] boolValue], @"%@: %@", name, comparison);
    }
}

// A stall once the audio has passed a short estimate keeps the position
// heard, not the estimate's end; and the replay, streaming afresh on an
// estimate of its own just as short, starts there rather than at its
// estimate, so nothing heard plays again.
- (void)testAStallPastAShortEstimateReplaysFromThePositionHeard {
    NSData *bytes = [self constantHeadMP3];
    NSURL *source = [self streamEstimated:bytes prefix:24576 name:@"stalled.mp3"];
    CloudFileAvailability *stream = _stream;
    NSData *reference = VibePCM([self read:source]);
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self play:self->_streamURL paused:NO position:0];
        [self shortenTheOpenDeadline];
    }];
    _blockSize = 4096;
    double estimate = _player.duration;
    [self streamTo:_streamBytes.length * 9 / 10];
    // The hold at the 90% edge, past the estimate: not a drain's transient at
    // the prefix (heldPastHalfOf:).
    XCTAssertTrue([self renderUntil:^BOOL {
        return self->_player.isBuffering && [self currentVoiceSnapshot].consumed > (estimate + 1) * 48000;
    }]);
    double heard = [self currentVoiceSnapshot].consumed / 48000.0;
    XCTAssertGreaterThan(heard, estimate + 1, @"held past the estimate");
    NSTimeInterval held = [self stallTheStream];
    XCTAssertEqualWithAccuracy(held, heard, 1e-9, @"the stall keeps the position heard");
    XCTAssertTrue([self renderUntil:^BOOL {
        return atomic_load(&self->_streamCancels) == 1 && stream.readerCount == 0;
    }], @"cancels %lu, readers %lu", (unsigned long)atomic_load(&_streamCancels), (unsigned long)stream.readerCount);

    [self streamingCopyOf:source prefix:24576 name:@"stalled.mp3"];
    [self installTailWindow:8192];
    _playError = nil;
    [_player playPause];
    [self settleUntil:^BOOL { return [self count:@"start"] == 2 || self->_playError; }];
    XCTAssertNil(_playError);
    XCTAssertTrue(((AudioFileHandle *)[_player valueForKey:@"file"]).lengthIsEstimated, @"the replay streams too");
    XCTAssertGreaterThanOrEqual(_player.position, held - 1.0 / 48000);
    [self streamTo:_streamBytes.length - 8192 - 1];
    [self assertTheReplayOf:reference startsAt:held];
    XCTAssertNil(_playError);
}

// A cue row of a headerless MP3 starting past the length its streaming head
// gives — 6.4 to 8 s of a 9.4 s file opened on a 6.1 s estimate — is not
// refused as empty: it plays from its start once the bytes arrive and on to
// its own end, not into the next row, and its duration, the window's, settles
// once the download completes.
- (void)testACueRowPastAShortEstimatePlaysFromItsStart {
    NSURL *source = [self streamEstimated:[self constantHeadMP3] prefix:24576 name:@"cue.mp3"];
    NSData *reference = VibePCM([self read:source]);
    AudioTrack *row = VibeCueRow(_streamURL, 480, 600);
    [self playOnTheDecodePoolBitPerfect:NO play:^{
        self->_player.declick = NO;
        [self->_player play:row atPosition:0 startPaused:NO];
        [self settleUntil:^BOOL { return [self count:@"start"] == 1 || self->_playError; }];
    }];
    XCTAssertNil(_playError, @"a row past the estimate is not refused");
    XCTAssertTrue(((AudioFileHandle *)[_player valueForKey:@"file"]).lengthIsEstimated);
    XCTAssertEqualWithAccuracy(_player.duration, 1.6, 1e-9);
    _blockSize = 4096;
    XCTAssertTrue([self finishStream:VibeStreamCompleted]);
    XCTAssertTrue([self renderUntil:^BOOL { return [self count:@"finish"] == 1 || self->_playError; }]);
    [self render:4800];
    XCTAssertNil(_playError);
    XCTAssertEqual([self count:@"settled"], 1u, @"its duration settles once");
    XCTAssertEqualWithAccuracy([[self settledEvent][@"duration"] doubleValue], 1.6, 1e-9);
    XCTAssertEqual([self count:@"finish"], 1u);
    NSData *window = [reference subdataWithRange:NSMakeRange(307200 * 8, 76800 * 8)];
    NSDictionary *comparison = VibeComparePCM(VibeAudibleFrames(window, 2), VibeAudibleFrames(_capture, 2), 2, 0, 0);
    XCTAssertTrue([comparison[@"pass"] boolValue], @"the row, from its start to its end: %@", comparison);
}

@end
