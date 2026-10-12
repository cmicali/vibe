//
//  AudioPlayerRenderPitchTests.m
//

#import "AudioPlayerRenderTestCase.h"

// The pitch fader's varispeed: exact at zero, its edges, its quality and the position it keeps.
@interface AudioPlayerRenderPitchTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderPitchTests

// At zero pitch the varispeed is a bit-perfect pass-through: it is hosted but
// not in the chain, so the output is the file exactly, and so is a track that
// plays on after the fader returns to zero. Leaving and returning to zero
// engages and disengages it with no click: on a 100 Hz tone every transition
// keeps the waveform continuous and its envelope full. Every edge is read to
// the frame by testPitchEngagesAndDisengagesAtTheExactFrame.
- (void)testZeroPitchIsBitPerfectAndTogglesAreClickFree {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSURL *noise = [self fixture:@"noise-48000-24-2.wav"];
    [self play:noise paused:NO position:0];
    [self assertReference:VibePCM([self read:noise]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    NSDictionary *counts = _player.debugRenderCounts;
    XCTAssertTrue([counts[@"varispeed"] boolValue], @"ordinary playback hosts the varispeed");
    XCTAssertFalse([counts[@"varispeedEngaged"] boolValue]);
    XCTAssertEqual([counts[@"varispeedRenders"] unsignedLongLongValue], 0ull, @"the varispeed rendered at zero pitch");
    XCTAssertEqual([counts[@"varispeedHistoryWrites"] unsignedLongLongValue], 0ull, @"the history ring was written at zero pitch");
    XCTAssertEqual([counts[@"varispeedLatency"] doubleValue], 0.0);

    NSArray<NSNumber *> *pitches = @[@0, @4, @0, @-4, @0, @8, @-8, @0];
    [self play:[self fixture:@"100.wav"] paused:NO position:0];
    [_capture setLength:0];
    for (NSNumber *pitch in pitches) {
        _player.pitch = pitch.floatValue;
        [self render:9600];
        XCTAssertEqual([_player.debugRenderCounts[@"varispeedEngaged"] boolValue], pitch.floatValue != 0, @"pitch %@", pitch);
    }
    uint64_t historyWrites = [_player.debugRenderCounts[@"varispeedHistoryWrites"] unsignedLongLongValue];
    XCTAssertGreaterThan(historyWrites, 0ull, @"the engages recorded their history");
    // A 100 Hz tone at 0.25 moves 0.0033 per frame at most; a skipped or
    // repeated millisecond, or a cold unit's ramp from silence, moves ten
    // times that or empties a window.
    const float *out = _capture.bytes;
    NSUInteger frames = _capture.length / sizeof(float) / 2, skip = [self startupSkip];
    float step = 0.25f * 2 * (float)M_PI * 108 / 48000;
    for (NSUInteger f = skip + 1; f < frames; f++) {
        for (NSUInteger c = 0; c < 2; c++) {
            float jump = fabsf(out[f * 2 + c] - out[(f - 1) * 2 + c]);
            XCTAssertLessThan(jump, 6 * step, @"a jump at frame %lu channel %lu", (unsigned long)f, (unsigned long)c);
            if (jump >= 6 * step) return;
        }
    }
    double nominal = 0.25 / sqrt(2);
    for (NSUInteger f = skip; f + 480 <= frames; f += 240) {
        double rms = VibeRMS(_capture, 2, 0, NSMakeRange(f, 480));
        XCTAssertGreaterThan(rms, nominal * 0.93, @"a dip in the window at frame %lu", (unsigned long)f);
        if (rms <= nominal * 0.93) return;
    }
    // Back at zero mid-track: from the first frame after the fader returns,
    // the replay of what the converter pulled ahead included, the track that
    // plays on is the file bit for bit, one unbroken excerpt.
    [self play:noise paused:NO position:0];
    [self render:12000];
    _player.pitch = 4;
    [self render:12000];
    _player.pitch = 0;
    [_capture setLength:0];
    [self render:24000];
    XCTAssertEqual([self assertExactExcerptsOf:@[VibePCM([self read:noise])] inCapture:[_capture copy] rampFrames:0 ramped:NULL], 1u,
                   @"the track after the fader returned to zero is the file exactly");
    // Settled at zero: the converter is idle, nothing is copied, and a fresh
    // play is the file, exactly.
    uint64_t renders = [_player.debugRenderCounts[@"varispeedRenders"] unsignedLongLongValue];
    historyWrites = [_player.debugRenderCounts[@"varispeedHistoryWrites"] unsignedLongLongValue];
    XCTAssertGreaterThan(renders, 0ull, @"the varispeed rendered while the pitch was off zero");
    [self play:noise paused:NO position:0];
    [self assertReference:VibePCM([self read:noise]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    counts = _player.debugRenderCounts;
    XCTAssertEqual([counts[@"varispeedRenders"] unsignedLongLongValue], renders, @"the varispeed rendered at zero pitch");
    XCTAssertEqual([counts[@"varispeedHistoryWrites"] unsignedLongLongValue], historyWrites, @"the history ring was written at zero pitch");
}

// The converter joins and leaves at the exact frame, at every rate from 44.1
// to 192 kHz in stereo, and at 48 kHz in mono.
// On a linear ramp each sample's value is its frame in the file, the
// converter's output included, since its kernel passes DC and is symmetric,
// so every edge can be read off the output. Joining, a slice after the fader
// leaves zero (the direct path plays it while it records the kernel's past),
// the first converted frame is the frame after the last direct one. Leaving,
// the first direct frame is the converter's next position rounded, and the
// file runs on from it exactly. A frame skipped or repeated at either edge
// moves it by one. Five toggles at different pitches and lengths land the
// edges at different fractions. The test reads a position to about
// frame × 2^-23, whatever the rate, so the file is the same frames long at
// every rate.
- (void)testPitchEngagesAndDisengagesAtTheExactFrame {
    const double step = 1.0 / (1 << 20); // a frame's rise: exact in float32 at every frame of the file
    const NSUInteger length = 192000;
    NSArray<NSNumber *> *pitches = @[@4, @-4, @8, @-8, @1];
    NSArray<NSNumber *> *engaged = @[@9600, @10000, @7681, @12345, @8888];
    NSArray<NSArray<NSNumber *> *> *configurations = @[@[@44100, @2], @[@48000, @2], @[@88200, @2], @[@96000, @2],
                                                       @[@176400, @2], @[@192000, @2], @[@48000, @1]];
    for (NSArray<NSNumber *> *configuration in configurations) {
        NSNumber *rate = configuration[0];
        NSUInteger channels = configuration[1].unsignedIntegerValue;
        NSMutableData *ramp = [NSMutableData dataWithLength:length * channels * sizeof(float)];
        float *samples = ramp.mutableBytes;
        for (NSUInteger i = 0; i < length * channels; i++) samples[i] = (float)(i / channels * step);
        [self startPlayerAt:rate.doubleValue channels:channels fx:NO bitPerfect:NO automatic:NO];
        NSString *name = [NSString stringWithFormat:@"ramp-%@-%lu.wav", rate, (unsigned long)channels];
        [self play:[self write:ramp rate:rate.doubleValue channels:channels name:name] paused:NO position:0];
        [self render:12000]; // past the declick
        NSUInteger at = 12000;
        for (NSUInteger s = 0; s < pitches.count; s++) {
            NSUInteger on = engaged[s].unsignedIntegerValue, off = 6000 + 333 * s;
            double ratio = 1 + pitches[s].doubleValue / 100;
            _player.pitch = pitches[s].floatValue;
            [self render:on];
            _player.pitch = 0;
            [self render:off];
            const float *out = _capture.bytes;
            NSString *label = [NSString stringWithFormat:@"%@ Hz, %lu channel(s), pitch %@", rate, (unsigned long)channels, pitches[s]];
            NSUInteger join = at + _blockSize;
            double lastDirect = out[(join - 1) * channels] / step, firstConverted = out[join * channels] / step;
            XCTAssertEqual(lastDirect, round(lastDirect), @"%@: the frame before the converter joins is the file's", label);
            XCTAssertEqualWithAccuracy(firstConverted, lastDirect + 1, 0.05, @"%@: the converter joins at the next frame", label);
            NSUInteger leave = at + on;
            double lastConverted = out[(leave - 1) * channels] / step, firstDirect = out[leave * channels] / step;
            XCTAssertEqual(firstDirect, round(firstDirect), @"%@: the frame after the converter leaves is the file's", label);
            XCTAssertEqualWithAccuracy(firstDirect, lastConverted + ratio, 0.55,
                                       @"%@: the direct path resumes at the converter's next position", label);
            for (NSUInteger n = 1; n < off; n++) {
                if (out[(leave + n) * channels] != (float)((firstDirect + n) * step)) {
                    XCTFail(@"%@: frame %lu after the converter left is not the file's next frame", label, (unsigned long)n);
                    break;
                }
            }
            at = leave + off;
        }
    }
}

// The sawtooth the pitched transport and long-play tests read: file frame i
// is (i mod 65536 − 32768) / 32768, exact in 16 bits and in float32, so a
// file whose first frame is another's next continues it. The converter
// passes a ramp through, so each output frame reads back as the file frame it
// plays, to about 0.002 of a frame. Near the wrap it rings on the step, and
// the frames on the step itself read anywhere, so a frame is read only when
// its value is kSawGuard clear of the wrap and the frame it should play is
// kSawStep clear of it.
static const double kSawPeriod = 65536, kSawGuard = 8000, kSawStep = 256;

static NSData *SawPCM(NSUInteger first, NSUInteger frames, NSUInteger channels, uint16_t bits) {
    NSMutableData *data = [NSMutableData dataWithLength:frames * channels * bits / 8];
    int16_t *integers = data.mutableBytes;
    float *floats = data.mutableBytes;
    for (NSUInteger f = 0; f < frames; f++) {
        int value = (int)((first + f) % (NSUInteger)kSawPeriod) - 32768;
        for (NSUInteger c = 0; c < channels; c++) {
            if (bits == 16) integers[f * channels + c] = (int16_t)value;
            else floats[f * channels + c] = value / 32768.0f;
        }
    }
    return data;
}

// A frame of the sawtooth read: the file frame it played, and its output
// frame from the start of the capture being read.
typedef struct {
    double frame, at;
} SawReading;

// Reads `capture` on from `last`: every frame read must play the file frame
// `step` per output frame on from the last one read, within 0.05. With
// `loose`, the first frame read may be anywhere within half a period of that,
// but must step on to the next frame by `step`, so silence or a frame on the
// wrap's step is not taken for it. Stops at the first frame that would play
// `end` or past it. Returns the last frame read.
- (SawReading)readSaw:(NSData *)capture from:(SawReading)last loose:(BOOL)loose step:(double)step end:(double)end
                label:(NSString *)label {
    const float *p = capture.bytes;
    NSUInteger frames = capture.length / sizeof(float) / _channels;
    double (^phaseAt)(NSUInteger) = ^double(NSUInteger n) {
        double phase = p[n * self->_channels] * 32768.0 + 32768;
        return phase < kSawGuard || phase > kSawPeriod - kSawGuard ? NAN : phase;
    };
    for (NSUInteger n = 0; n < frames; n++) {
        double predicted = last.frame + ((double)n - last.at) * step;
        if (predicted >= end) break;
        if (_channels == 2 && p[n * 2] != p[n * 2 + 1]) {
            XCTFail(@"%@: output frame %lu, the channels differ", label, (unsigned long)n);
            break;
        }
        double phase = phaseAt(n), wrap = fmod(predicted, kSawPeriod);
        if (isnan(phase) || (!loose && (wrap < kSawStep || wrap > kSawPeriod - kSawStep))) continue;
        if (loose && (n + 1 == frames || isnan(phaseAt(n + 1)) || fabs(phaseAt(n + 1) - phase - step) > 0.05)) continue;
        double offset = remainder(phase - predicted, kSawPeriod);
        if (!loose && fabs(offset) > 0.05) {
            XCTFail(@"%@: output frame %lu plays file frame %.3f, not %.3f", label, (unsigned long)n, predicted + offset, predicted);
            break;
        }
        last = (SawReading){ predicted + offset, (double)n };
        loose = NO;
    }
    if (loose) XCTFail(@"%@: no frame of the sawtooth was read", label);
    return last;
}

// What the stage holds at a steady ratio: the bus leads the file frame the
// capture's last frame plays by the kernel's half-width and one or two bus
// frames, the half-width read from the latency the player reports. The bus's
// next frame is the player's position into a 48 kHz sawtooth whose first
// frame is `firstFrame`; `step` is file frames per output frame.
- (BOOL)assertBusLeadsSaw:(SawReading)last capture:(NSData *)capture step:(double)step ratio:(double)ratio
               firstFrame:(double)firstFrame label:(NSString *)label {
    double half = round([_player.debugRenderCounts[@"varispeedLatency"] doubleValue] * _rate * ratio);
    double frames = capture.length / sizeof(float) / _channels;
    double heard = last.frame + (frames - 1 - last.at) * step;
    double lead = (firstFrame + _player.position * 48000 - heard) * _rate / 48000;
    XCTAssertEqual(half, ceil(64 * ratio), @"%@", label);
    BOOL held = lead > half + 0.9 && lead < half + 2.1;
    XCTAssertTrue(held, @"%@: the bus leads by %.3f frames, the half-width %.0f", label, lead, half);
    return held;
}

// The pitch fader held at +8% through the transport: a seek, a pause past
// the idle stop and its resume, a gapless track change and a change of the
// output's rate. After each, once the kernel is past the edge, the output is
// the sawtooth again at the ratio. The bus leads what plays by exactly what
// the stage holds: its kernel's half-width and one or two frames, so no file
// frame is skipped or repeated, and the position is what is heard.
- (void)testPitchedTransportKeepsThePositionHeard {
    const double ratio = 1.08;
    const NSUInteger lengthA = 4 * 48000, lengthB = 3 * 48000, settle = 4096;
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    _player.declick = NO;
    _player.pitch = 8;
    NSURL *a = VibeWriteWAV([_temporary URLByAppendingPathComponent:@"saw-a.wav"], SawPCM(0, lengthA, 2, 32), 48000, 2, 32,
                            (uint32_t)(lengthA * 8));
    NSURL *b = VibeWriteWAV([_temporary URLByAppendingPathComponent:@"saw-b.wav"], SawPCM(lengthA, lengthB, 2, 32), 48000, 2, 32,
                            (uint32_t)(lengthB * 8));
    NSArray<AudioTrack *> *tracks = @[[AudioTrack withURL:a], [AudioTrack withURL:b]];
    [_player play:tracks[0]];
    [self settleUntil:^BOOL { return [self count:@"start"] == 1; }];
    [_player prefetchTrack:tracks[1]];
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];
    NSData *capture = [self renderSeconds:1];
    // Each edge's output, read from `settle` frames on, from near the file
    // frame `near`, in the track whose first frame is `first`.
    SawReading (^readAfterEdge)(NSData *, double, double, double, NSString *) =
        ^SawReading(NSData *data, double step, double near, double first, NSString *label) {
        NSUInteger skip = settle * self->_channels * sizeof(float);
        NSData *settled = [data subdataWithRange:NSMakeRange(skip, data.length - skip)];
        SawReading reading = [self readSaw:settled from:(SawReading){ near, 0 } loose:YES step:step end:INFINITY label:label];
        [self assertBusLeadsSaw:reading capture:settled step:step ratio:ratio firstFrame:first label:label];
        return reading;
    };
    readAfterEdge(capture, ratio, settle * ratio, 0, @"the start");

    [_player seekToPosition:2];
    [self settleUntil:^BOOL { return [self count:@"seek"] == 1; }];
    readAfterEdge([self renderSeconds:0.5], ratio, 2 * 48000 + settle * ratio, 0, @"the seek");

    [_player pause];
    [self renderSeconds:6.1];
    XCTAssertFalse([_player.debugRenderCounts[@"running"] boolValue], @"the pause reached the idle stop");
    double paused = _player.position;
    [_player resume];
    [self settleUntil:^BOOL { return [self count:@"resume"] == 1; }];
    capture = [self renderSeconds:0.5];
    SawReading reading = readAfterEdge(capture, ratio, paused * 48000 + settle * ratio, 0, @"the resume");
    [self settleUntil:^BOOL { return self->_player.gaplessArmed; }];

    // Through the splice: B continues A's sawtooth, read on unbroken.
    reading.at -= capture.length / sizeof(float) / 2 - settle;
    capture = [self renderSeconds:1.5];
    reading = [self readSaw:capture from:reading loose:NO step:ratio end:INFINITY label:@"the splice"];
    [self settleUntil:^BOOL { return [self count:@"advance"] >= 1; }];
    XCTAssertEqual([self count:@"advance"], 1u);
    XCTAssertEqual(_player.currentTrack, tracks[1]);
    [self assertBusLeadsSaw:reading capture:capture step:ratio ratio:ratio firstFrame:lengthA label:@"the splice"];

    // At 96 kHz the stage is hosted again, and the file is resampled before
    // it, so each output frame plays half as many file frames on. The
    // resampler adds nothing to the lead, since the position counts the bus.
    double before = _player.position;
    XCTAssertTrue([_player debugSetOutputRate:96000]);
    _rate = 96000;
    readAfterEdge([self renderSeconds:0.5], ratio / 2, lengthA + before * 48000 + settle * ratio / 2, lengthA, @"the rate change");
    XCTAssertTrue([_player.debugRenderCounts[@"varispeedEngaged"] boolValue]);
}

// Six and a half minutes at +8%, every frame read. The output plays the file
// at exactly the ratio. The bus leads it by what the stage holds at every
// second. The duration is the file's. The track ends as the bus reaches the
// file's last frame. So nothing drifts over a long play. The length puts the
// file and the output both past 2^24 frames, where a float32 frame count stops
// being exact.
- (void)testALongPitchedPlayKeepsItsPosition {
    const double ratio = 1.08, rate = 48000;
    const NSUInteger length = 390 * 48000;
    XCTAssertGreaterThan(length / ratio, (double)(1u << 24));
    [self startPlayerAt:rate channels:1 fx:NO bitPerfect:NO automatic:NO];
    _blockSize = 4096;
    _player.pitch = 8;
    NSURL *url = VibeWriteWAV([_temporary URLByAppendingPathComponent:@"saw-long.wav"], SawPCM(0, length, 1, 16), 48000, 1, 16,
                              (uint32_t)(length * 2));
    [self play:url paused:NO position:0];
    XCTAssertEqual(_player.duration, length / rate);
    [self render:2 * _blockSize]; // the engage, then the ratio's ramp from 1
    double half = ceil(64 * ratio), rendered = 2 * _blockSize;
    SawReading reading = { 0, 0 }, anchor = { NAN, NAN };
    // The output frame where the bus reaches the file's end: where the output
    // plays the file frame the lead short of it.
    double ends = INFINITY, finishedAt = NAN;
    while (isnan(finishedAt) && rendered < length / ratio + rate) {
        [_capture setLength:0];
        [self render:rendered + rate < ends - rate ? (NSUInteger)rate : _blockSize]; // a slice at a time near the end
        NSData *capture = [_capture copy];
        double frames = capture.length / sizeof(float);
        reading = [self readSaw:capture from:reading loose:isnan(anchor.frame) step:ratio end:length - 2 * half label:@"the long play"];
        if (isnan(anchor.frame)) {
            anchor = (SawReading){ reading.frame, rendered + reading.at };
            ends = anchor.at + (length - half - 1.5 - anchor.frame) / ratio;
        }
        if ([self count:@"finish"]) {
            finishedAt = rendered + frames;
        }
        else if (![self assertBusLeadsSaw:reading capture:capture step:ratio ratio:ratio firstFrame:0
                                    label:[NSString stringWithFormat:@"at %.0f s", rendered / rate]]) {
            return;
        }
        reading.at -= frames;
        rendered += frames;
    }
    XCTAssertFalse(isnan(finishedAt), @"the track never ended");
    // Read against the first frame read: no drift.
    XCTAssertEqualWithAccuracy(reading.frame, anchor.frame + (rendered + reading.at - anchor.at) * ratio, 0.05);
    // The drain after the slice that reached the end reports it.
    XCTAssertGreaterThanOrEqual(finishedAt, ends, @"the end was reported early");
    XCTAssertLessThan(finishedAt, ends + 2 * _blockSize, @"the end was reported late");
}

// The pitch fader's converter, measured through the player in the style of
// ResamplerQualityTests, at 48 and 96 kHz. The source is a file at the bus
// rate of segments, each built so that at the fader's ratio its output is
// known: one tone at −1 dBFS, twenty tones at once, or, speeding up, an input
// the output's Nyquist cannot carry. The tones are the same at both rates;
// what is placed against the kernel's edges scales with the rate.
// The middle of each segment's output is fitted at exactly its frequencies,
// gain and phase free, so the residual is everything that is not the tones.
// The float32 file and capture set the floor, about −150 dB. Each bound sits
// a few dB above what the converter measured. The table is attached as
// "pitch quality"; docs/audio-quality.md compares it with Apple's Varispeed.
- (void)testPitchQuality {
    self.continueAfterFailure = YES; // every bound reports, and the table attaches
    const NSUInteger segment = 32768, window = 8192;
    const double full = pow(10, -1 / 20.0);
    NSArray<NSNumber *> *tones = @[@20, @100, @1000, @5000, @10000, @15000, @18000, @20000];
    NSMutableString *table = [@"| rate | pitch | D+N 1 kHz dB | D+N 10 kHz dB | D+N 20 kHz dB | twenty tones dB | false tones dB "
                              "| flatness dB | gain at 20 kHz dB |\n|---|---|---|---|---|---|---|---|---|\n" mutableCopy];
    _blockSize = 4096;
    for (NSNumber *busRate in @[@48000, @96000]) for (NSNumber *percent in @[@-16, @-8, @-1, @1, @8, @16]) {
        double ratio = 1 + percent.doubleValue / 100, rate = busRate.doubleValue, scale = rate / 48000;
        NSString *label = [NSString stringWithFormat:@"%@ Hz, %@%%", busRate, percent];
        // Each segment's input frequencies.
        NSMutableArray<NSArray<NSNumber *> *> *segments = [NSMutableArray array];
        for (NSNumber *tone in tones) [segments addObject:@[@(tone.doubleValue / ratio)]];
        double twenty[20], top = MIN(19500, ratio < 1 ? 23500 * scale * ratio : 19500);
        NSMutableArray<NSNumber *> *twentyIn = [NSMutableArray array];
        for (int k = 0; k < 20; k++) {
            twenty[k] = 40 * pow(top / 40, k / 19.0);
            [twentyIn addObject:@(twenty[k] / ratio)];
        }
        [segments addObject:twentyIn];
        NSUInteger falseFirst = segments.count;
        if (ratio > 1) {
            double nyquist = rate / 2, edge = nyquist / ratio;
            for (NSNumber *f in @[@(edge + 150 * scale), @((edge + nyquist) / 2), @(nyquist - 200 * scale)]) [segments addObject:@[f]];
        }
        NSUInteger length = (NSUInteger)ceil(segment * ratio);
        NSMutableData *source = [NSMutableData dataWithLength:length * segments.count * 2 * sizeof(float)];
        float *s = source.mutableBytes;
        [segments enumerateObjectsUsingBlock:^(NSArray<NSNumber *> *frequencies, NSUInteger index, BOOL *stop) {
            double amplitude = frequencies.count == 1 ? full : 0.045;
            for (NSUInteger m = 0; m < length; m++) {
                double v = 0;
                for (NSUInteger k = 0; k < frequencies.count; k++) {
                    v += amplitude * sin(2 * M_PI * frequencies[k].doubleValue * m / rate + 0.7 * k);
                }
                s[(index * length + m) * 2] = s[(index * length + m) * 2 + 1] = (float)v;
            }
        }];
        NSURL *url = [self write:source rate:rate channels:2 name:[NSString stringWithFormat:@"pitch%@-%@.wav", percent, busRate]];
        [self startPlayerAt:rate channels:2 fx:NO bitPerfect:NO automatic:NO];
        _player.maxPitch = 16;
        _player.pitch = percent.floatValue;
        [self play:url paused:NO position:0];
        NSData *capture = [self renderSeconds:(length * segments.count / ratio + window) / rate];
        const float *out = capture.bytes;
        double *x = malloc(window * sizeof(double));
        // The window at the middle of segment `index`'s output.
        NSUInteger (^windowOf)(NSUInteger) = ^NSUInteger(NSUInteger index) {
            NSUInteger first = (NSUInteger)llround((index * length + length / 2.0) / ratio) - window / 2;
            for (NSUInteger n = 0; n < window; n++) x[n] = out[(first + n) * 2];
            return first;
        };
        // Distortion + noise at 1, 10 and 20 kHz, where 20 kHz's input is below
        // the kernel's −6 dB point.
        NSMutableDictionary<NSNumber *, NSNumber *> *distortion = [NSMutableDictionary dictionary];
        double flatness = 0, gain20k = 0, falseTones = NAN;
        for (NSUInteger index = 0; index < tones.count; index++) {
            double f = tones[index].doubleValue;
            VibeToneFit fit = VibeFitTone(x, window, f, rate, windowOf(index), 0);
            double gain = 20 * log10(fit.amplitude / full);
            // Slowing down, the input of an output tone near 20 kHz sits in the
            // kernel's transition band, above its passband edge of 20 kHz × the ratio
            // at 48 kHz.
            if (f <= 20000 * scale * MIN(1, ratio)) flatness = MAX(flatness, fabs(gain));
            if (f == 20000) gain20k = gain;
            if (f == 1000 || f == 10000 || (f == 20000 && f / ratio < 22000 * scale)) {
                double dn = VibeDB(fit.residualPower / (fit.amplitude * fit.amplitude / 2));
                distortion[tones[index]] = @(dn);
                XCTAssertLessThan(dn, -145, @"%@: distortion + noise at %@ Hz", label, tones[index]);
            }
        }
        double a[20], b[20], signal = 0;
        NSUInteger first = windowOf(tones.count);
        double residual = VibeFitTones(x, window, twenty, 20, rate, first, 0, a, b);
        for (int k = 0; k < 20; k++) signal += (a[k] * a[k] + b[k] * b[k]) / 2;
        double twentyTones = VibeDB(residual / signal);
        for (NSUInteger index = falseFirst; index < segments.count; index++) {
            double rms = VibeRMS(capture, 2, 0, NSMakeRange(windowOf(index), window));
            double level = VibeDB(rms * rms / (full * full / 2));
            falseTones = isnan(falseTones) ? level : MAX(falseTones, level);
        }
        free(x);
        [table appendFormat:@"| %@ | %+g%% | %.1f | %.1f | %.1f | %.1f | %.1f | %.6f | %.4f |\n", busRate, percent.doubleValue,
         (distortion[@1000] ?: @(NAN)).doubleValue, (distortion[@10000] ?: @(NAN)).doubleValue,
         (distortion[@20000] ?: @(NAN)).doubleValue, twentyTones, falseTones, flatness, gain20k];
        XCTAssertLessThan(twentyTones, -145, @"%@: twenty tones", label);
        if (ratio > 1) XCTAssertLessThan(falseTones, -145, @"%@: false tones", label);
        XCTAssertLessThan(flatness, 0.0001, @"%@: passband flatness", label);
        if (20000 / ratio < 20250 * scale) XCTAssertLessThan(fabs(gain20k), 0.0001, @"%@: flat at 20 kHz", label);
    }
    XCTAttachment *attachment = [XCTAttachment attachmentWithString:table];
    attachment.name = @"pitch quality";
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}

@end
