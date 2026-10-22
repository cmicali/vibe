//
//  AudioPlayerRenderTestCase.m
//

#import "AudioPlayerRenderTestCase.h"
#import "PlaceholderFiles.h"
#import <objc/runtime.h>

// Interleaved float PCM keeps the oracle independent of the render's buffers.
NSMutableData *VibePCM(AVAudioPCMBuffer *buffer) {
    NSMutableData *data = [NSMutableData data];
    VibeAppendPCM(data, buffer);
    return data;
}

// One alignment, every remaining source frame, every channel. The only skipped
// source interval is the explicitly requested startup declick. No gain fit,
// resampling, moving alignment, or overlap-only pass can conceal a defect.
NSDictionary *VibeComparePCM(NSData *reference, NSData *capture, NSUInteger channels,
                         NSUInteger skip, float tolerance) {
    if (!channels || reference.length % (sizeof(float) * channels)
            || capture.length % (sizeof(float) * channels))
        return @{@"pass": @NO, @"reason": @"Incomplete channel frames"};
    NSUInteger sourceFrames = reference.length / (sizeof(float) * channels);
    NSUInteger outputFrames = capture.length / (sizeof(float) * channels);
    const float *r = reference.bytes, *a = capture.bytes;
    if (skip + 32 >= sourceFrames || outputFrames < sourceFrames - skip)
        return @{@"pass": @NO, @"reason": @"Incomplete capture", @"sourceFrames": @(sourceFrames), @"outputFrames": @(outputFrames)};
    NSInteger aligned = -1;
    for (NSUInteger start = 0; start + 32 <= outputFrames && start <= skip + 4096; start++) {
        BOOL matches = YES;
        for (NSUInteger i = 0; i < 32 * channels; i++) {
            if (!isfinite(a[start * channels + i]) || fabsf(r[skip * channels + i] - a[start * channels + i]) > tolerance) { matches = NO; break; }
        }
        if (matches) { aligned = (NSInteger)start; break; }
    }
    if (aligned < 0) return @{@"pass": @NO, @"reason": @"No marker alignment"};
    NSUInteger count = sourceFrames - skip;
    if ((NSUInteger)aligned + count > outputFrames)
        return @{@"pass": @NO, @"reason": @"Truncated after alignment", @"aligned": @(aligned)};
    NSUInteger mismatches = 0, first = NSNotFound;
    double peak = 0, squared = 0;
    for (NSUInteger i = 0; i < count * channels; i++) {
        float actual = a[(NSUInteger)aligned * channels + i];
        double error = fabs((double)actual - r[skip * channels + i]);
        if (!isfinite(r[skip * channels + i]) || !isfinite(actual) || error > tolerance) {
            if (!mismatches) first = i / channels + skip;
            mismatches++;
        }
        peak = MAX(peak, error); squared += error * error;
    }
    NSUInteger unexpected = 0;
    for (NSUInteger i = ((NSUInteger)aligned + count) * channels; i < outputFrames * channels; i++)
        if (!isfinite(a[i]) || fabsf(a[i]) > tolerance) unexpected++;
    return @{@"pass": @(mismatches == 0 && unexpected == 0), @"unexpectedSamples": @(unexpected), @"mismatchedSamples": @(mismatches), @"firstBadFrame": @(first),
             @"maxError": @(peak), @"rmsError": @(sqrt(squared / (count * channels))),
             @"comparedFrames": @(count), @"aligned": @(aligned), @"sourceSkip": @(skip)};
}

// Float PCM can only be compared against a float32 reference, which carries
// the same narrowing as a float32 capture and so hides it. This compares the
// capture against the source at full width — doubles, which hold every
// integer to 32 bits and every float64 exactly — at the alignment ComparePCM
// found, counting every sample float32 did not carry.
NSDictionary *VibeCompareWidePCM(NSData *wide, NSData *capture, NSUInteger channels,
                             NSUInteger aligned, NSUInteger skip) {
    NSUInteger count = wide.length / sizeof(double) - skip * channels;
    if (!channels || (aligned * channels + count) * sizeof(float) > capture.length)
        return @{@"pass": @NO, @"reason": @"Incomplete capture"};
    const double *r = (const double *)wide.bytes + skip * channels;
    const float *a = (const float *)capture.bytes + aligned * channels;
    NSUInteger mismatches = 0;
    double peak = 0;
    for (NSUInteger i = 0; i < count; i++) {
        if ((double)a[i] != r[i]) mismatches++;
        peak = MAX(peak, fabs((double)a[i] - r[i]));
    }
    return @{@"pass": @(mismatches == 0), @"mismatchedSamples": @(mismatches), @"comparedSamples": @(count),
             @"maxError": @(peak)};
}

// Each sample rounded to the nearest float32, as a float capture would hold it.
NSData *VibeFloat32PCM(NSData *wide) {
    NSMutableData *pcm = [NSMutableData dataWithLength:wide.length / sizeof(double) * sizeof(float)];
    const double *in = wide.bytes;
    float *out = pcm.mutableBytes;
    for (NSUInteger i = 0; i < pcm.length / sizeof(float); i++) out[i] = (float)in[i];
    return pcm;
}

double VibeRMS(NSData *data, NSUInteger channels, NSUInteger channel, NSRange frames) {
    const float *p = data.bytes; double energy = 0;
    if (NSMaxRange(frames) * channels * sizeof(float) > data.length || frames.length == 0) return NAN;
    for (NSUInteger f = frames.location; f < NSMaxRange(frames); f++) energy += (double)p[f*channels+channel] * p[f*channels+channel];
    return sqrt(energy / frames.length);
}
double VibeToneAmplitude(NSData *data, NSUInteger channels, NSUInteger channel, double rate, double frequency, NSRange frames) {
    const float *p = data.bytes; double real = 0, imaginary = 0;
    for (NSUInteger f = frames.location; f < NSMaxRange(frames); f++) {
        double phase = 2 * M_PI * frequency * f / rate;
        real += p[f*channels+channel] * cos(phase); imaginary += p[f*channels+channel] * sin(phase);
    }
    return 2 * hypot(real, imaginary) / frames.length;
}

NSData *VibeStereoTone(NSUInteger frames, double rate, double frequency, float amplitude) {
    NSMutableData *data = [NSMutableData dataWithLength:frames * 2 * sizeof(float)];
    float *p = data.mutableBytes;
    for (NSUInteger f = 0; f < frames; f++) p[f*2] = p[f*2+1] = amplitude * (float)sin(2 * M_PI * frequency * f / rate);
    return data;
}

VibeTestTrack *VibeCueRow(NSURL *url, NSUInteger start, NSUInteger end) {
    return [[VibeTestTrack alloc] initWithURL:url cueStart:start cueEnd:end];
}

// Deterministic noise supplies distinct markers for alignment.
NSData *VibeUniqueNoise(NSUInteger frames, uint32_t seed) {
    NSMutableData *data = [NSMutableData dataWithLength:frames * 2 * sizeof(float)];
    float *p = data.mutableBytes;
    for (NSUInteger i = 0; i < frames * 2; i++) {
        seed = seed * 1664525u + 1013904223u;
        p[i] = ((float)(seed >> 8) / 8388608.0f - 1.0f) * 0.25f;
    }
    return data;
}

// The frames of `pcm` with every all-zero frame dropped: what a capture with
// holds in it plays, once its silences are taken out.
NSData *VibeAudibleFrames(NSData *pcm, NSUInteger channels) {
    NSMutableData *audible = [NSMutableData data];
    const float *p = pcm.bytes;
    for (NSUInteger f = 0; f < pcm.length / sizeof(float) / channels; f++) {
        BOOL silent = YES;
        for (NSUInteger c = 0; c < channels; c++) silent &= p[f * channels + c] == 0;
        if (!silent) [audible appendBytes:p + f * channels length:channels * sizeof(float)];
    }
    return audible;
}

@implementation AudioPlayerRenderTests
- (void)setUp {
    [super setUp]; self.continueAfterFailure = NO;
    _events = [NSMutableArray array]; _blockSize = 256;
    _temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_temporary withIntermediateDirectories:YES attributes:nil error:NULL];
}
- (void)tearDown {
    if (self.testRun.failureCount && _capture.length) {
        [self attach:_capture name:@"last-render"];
        XCTAttachment *trace=[XCTAttachment attachmentWithString:_events.description];
        trace.name=@"transport-events"; trace.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:trace];
    }
    [_player debugHoldRenderInside:NO]; // a failed hold test must not leave a render blocked
    [_player debugShutdown]; _player = nil;
    if (_streamURL) {
        [self finishStream:VibeStreamCancelled]; // a failed test must not strand the fetch
        [CloudFileMaterializer setRemoteRoot:nil fetch:nil read:nil availability:nil];
    }
    [NSFileManager.defaultManager removeItemAtURL:_temporary error:NULL];
    [super tearDown];
}
- (NSURL *)fixture:(NSString *)name {
    NSString *root = NSProcessInfo.processInfo.environment[@"VIBE_AUDIO_FIXTURES"];
    XCTAssertNotNil(root, @"Run make test-audio or the VibeAudioTests scheme");
    return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:name]];
}
// A fixture only ffmpeg makes: the test skips when the generator ran without it.
- (NSURL *)optionalFixture:(NSString *)name {
    NSURL *url = [self fixture:name];
    XCTSkipUnless([NSFileManager.defaultManager fileExistsAtPath:url.path], @"Optional encoder fixture %@ unavailable; install ffmpeg and regenerate", name);
    return url;
}
- (AudioFileHandle *)open:(NSURL *)url decoder:(NSString *)decoder {
    NSError *error = nil;
    AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:url error:&error];
    XCTAssertNotNil(file, @"%@: %@", url.lastPathComponent, error);
    XCTAssertEqualObjects(file.decoderName, decoder, @"%@", url.lastPathComponent);
    return file;
}
- (AVAudioPCMBuffer *)read:(NSURL *)url {
    NSError *error = nil;
    AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:url error:&error];
    XCTAssertNotNil(file, @"%@: %@", url, error);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:(AVAudioFrameCount)file.length];
    AVAudioPCMBuffer *chunk = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:4096];
    NSUInteger total = 0;
    while (total < (NSUInteger)file.length) {
        XCTAssertTrue([file readIntoBuffer:chunk frameCount:(AVAudioFrameCount)MIN(4096, file.length-total) error:&error], @"%@", error);
        XCTAssertGreaterThan(chunk.frameLength,0u,@"Premature EOF: %@",url);
        for (AVAudioChannelCount c=0;c<file.processingFormat.channelCount;c++)
            memcpy(buffer.floatChannelData[c]+total,chunk.floatChannelData[c],chunk.frameLength*sizeof(float));
        total += chunk.frameLength;
    }
    buffer.frameLength=(AVAudioFrameCount)total;
    return buffer;
}
- (NSURL *)write:(NSData *)data rate:(double)rate channels:(NSUInteger)channels name:(NSString *)name {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:(AVAudioChannelCount)channels];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)(data.length / channels / sizeof(float))];
    buffer.frameLength = buffer.frameCapacity;
    const float *p = data.bytes;
    for (NSUInteger f=0;f<buffer.frameLength;f++) for (NSUInteger c=0;c<channels;c++) buffer.floatChannelData[c][f]=p[f*channels+c];
    return [self writeBuffer:buffer name:name];
}
- (NSURL *)writeBuffer:(AVAudioPCMBuffer *)buffer name:(NSString *)name {
    NSURL *url = [_temporary URLByAppendingPathComponent:name];
    NSError *error = nil;
    XCTAssertNotNil(VibeWriteFixture(url, buffer, &error), @"%@", error);
    return url;
}
- (NSURL *)writeBytes:(NSData *)bytes name:(NSString *)name {
    NSURL *url = [_temporary URLByAppendingPathComponent:name];
    XCTAssertTrue([bytes writeToURL:url atomically:YES]);
    return url;
}
// A generated fixture's samples from its own bytes (a fixed 44-byte RIFF
// header), so the handle is not its own decode oracle: integers to 32 bits
// scaled by their full scale, float32 or float64 as stored.
- (NSData *)wideSourcePCM:(NSURL *)url {
    NSData *wav=[NSData dataWithContentsOfURL:url];
    XCTAssertGreaterThan(wav.length,44u);
    XCTAssertEqual(memcmp(wav.bytes,"RIFF",4),0);
    uint16_t format=0, bits=0;
    memcpy(&format,(const uint8_t *)wav.bytes+20,2); memcpy(&bits,(const uint8_t *)wav.bytes+34,2);
    const uint8_t *bytes=(const uint8_t *)wav.bytes+44;
    NSUInteger width=bits/8, count=(wav.length-44)/width;
    NSMutableData *pcm=[NSMutableData dataWithLength:count*sizeof(double)];
    double *out=pcm.mutableBytes;
    for (NSUInteger i=0;i<count;i++) {
        if (format==3 && bits==64) memcpy(out+i,bytes+i*8,8); // little endian host
        else if (format==3) { float value; memcpy(&value,bytes+i*4,4); out[i]=value; }
        else {
            int64_t value=0;
            for(NSUInteger b=0;b<width;b++) value|=(int64_t)bytes[i*width+b]<<(b*8);
            if (value & ((int64_t)1<<(bits-1))) value-=(int64_t)1<<bits;
            out[i]=(double)value/(double)((int64_t)1<<(bits-1));
        }
    }
    return pcm;
}
- (NSData *)sourcePCM:(NSURL *)url {
    NSData *pcm=VibeFloat32PCM([self wideSourcePCM:url]);
    XCTAssertEqualObjects(pcm,VibePCM([self read:url]),@"Lossless decode %@",url.lastPathComponent);
    return pcm;
}
// TRAP: delegate events arrive asynchronously on main.
// Settle a count that must rise before asserting it.
- (NSUInteger)count:(NSString *)event {
    NSUInteger count=0; for (NSDictionary *entry in _events) if ([entry[@"event"] isEqual:event]) count++; return count;
}
- (void)settleUntil:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.0001]];
    XCTAssertTrue(condition(), @"Timed out; events %@; error %@", _events, _playError);
}
// The render drain queues its delegate calls before returning.
// A main-queue marker behind them waits for every delivery.
- (void)landMainQueue {
    __block BOOL landed = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ landed = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!landed && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.0001]];
    XCTAssertTrue(landed, @"the main queue did not drain");
}
- (void)withPlayerQueueHeld:(dispatch_block_t)submissions {
    dispatch_queue_t queue = [_player valueForKey:@"queue"];
    dispatch_suspend(queue);
    @try { submissions(); } @finally { dispatch_resume(queue); }
}
// The probe's poll rides the player's clock, which the frame-driven pump
// advances only while frames render, so no poll may be left to finish the
// capture: wait for the signal, render a poll's worth, then read the settled
// snapshot.
- (NSDictionary *)settledSignalSnapshot {
    __block NSDictionary *signal;
    BOOL (^read)(void) = ^BOOL {
        [self->_player runSyncOnQueue:^{ signal = [[self->_player debugLevelMeter] signalDiagnosticSnapshot]; }];
        return [signal[@"aboveThreshold"] boolValue];
    };
    [self settleUntil:read];
    [self render:(NSUInteger)(_rate * 0.15)];
    read();
    return signal;
}
- (void)startPlayerAt:(double)rate channels:(NSUInteger)channels fx:(BOOL)fx bitPerfect:(BOOL)bitPerfect automatic:(BOOL)automatic {
    [_player debugShutdown]; _player = nil; [_events removeAllObjects]; _playError = nil; _chain = nil;
    _rate=rate; _channels=channels; _capture=[NSMutableData data];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:(AVAudioChannelCount)channels];
    _player = [[AudioPlayer alloc] initForManualRendering:format enableFX:fx automatic:automatic delegate:self];
    [self settleUntil:^BOOL { return [self count:@"init"] == 1; }];
    XCTAssertTrue(_player.manualRenderingActive);
    XCTAssertEqualWithAccuracy([_player.debugRenderCounts[@"outputRate"] doubleValue], rate, 0);
    [_player setBitPerfectOutput:bitPerfect exclusiveOutput:NO enableFX:fx allowAnyDevice:NO];
    [_player runSyncOnQueue:^{}]; // Land setup before a test replaces the mode provider.
}
- (VibeTestTrack *)play:(NSURL *)url paused:(BOOL)paused position:(double)position {
    VibeTestTrack *track = [VibeTestTrack withURL:url];
    NSUInteger before = [self count:@"start"];
    [_player play:track atPosition:position startPaused:paused];
    [self settleUntil:^BOOL { return [self count:@"start"] > before || self->_playError; }];
    XCTAssertNil(_playError);
    return track;
}
- (void)render:(NSUInteger)frames {
    while (frames) {
        AVAudioFrameCount count = (AVAudioFrameCount)MIN(frames, _blockSize);
        NSError *error = nil;
        AVAudioPCMBuffer *buffer = [_player debugRenderFrames:count error:&error];
        XCTAssertNotNil(buffer, @"%@", error);
        XCTAssertEqual(buffer.frameLength, count);
        [_capture appendData:VibePCM(buffer)];
        frames-=count;
        [self landMainQueue];
        if (_chain && _nextPrefetch < _chain.count) {
            [self settleUntil:^BOOL { return self->_nextPrefetch >= self->_chain.count || self->_player.gaplessArmed || self->_playError; }];
        }
    }
}
- (NSData *)renderSeconds:(double)seconds {
    [_capture setLength:0]; [self render:(NSUInteger)llround(seconds*_rate)]; return [_capture copy];
}
- (void)attach:(NSData *)data name:(NSString *)name {
    NSURL *url=[self write:data rate:_rate channels:_channels name:[name stringByAppendingPathExtension:@"wav"]];
    XCTAttachment *attachment=[XCTAttachment attachmentWithContentsOfFileAtURL:url];
    attachment.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:attachment];
}
// The 10 ms declick and the settling after it; nothing with Declick off, which
// cuts, so the first sample must already be exact.
- (NSUInteger)startupSkip {
    return _player.declick ? (NSUInteger)(_rate * 0.05) : 0;
}
- (void)assertReference:(NSData *)reference capture:(NSData *)capture skip:(NSUInteger)skip tolerance:(float)tolerance {
    NSDictionary *result=VibeComparePCM(reference,capture,_channels,skip,tolerance);
    if (![result[@"pass"] boolValue]) {
        [self attach:reference name:@"reference"]; [self attach:capture name:@"capture"];
        NSMutableData *difference=[capture mutableCopy]; float *d=difference.mutableBytes; const float *r=reference.bytes;
        NSInteger delta=[result[@"aligned"] integerValue]-(NSInteger)skip;
        for (NSUInteger f=0;f<capture.length/sizeof(float)/_channels;f++) for(NSUInteger c=0;c<_channels;c++) {
            NSInteger rf=(NSInteger)f-delta;
            d[f*_channels+c]-=rf>=0 && (NSUInteger)rf<reference.length/sizeof(float)/_channels ? r[rf*_channels+c] : 0;
        }
        [self attach:difference name:@"difference"];
        XCTAttachment *trace=[XCTAttachment attachmentWithString:[NSString stringWithFormat:@"%@\n%@\n%@",result,_events,_player.debugRenderCounts]];
        trace.name=@"render-events"; trace.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:trace];
    }
    XCTAssertTrue([result[@"pass"] boolValue], @"%@",result);
}
- (void)assertFinite:(NSData *)data peak:(float)peak {
    const float *p=data.bytes;
    for (NSUInteger i=0;i<data.length/sizeof(float);i++) { XCTAssertTrue(isfinite(p[i])); XCTAssertLessThanOrEqual(fabsf(p[i]),peak); }
}


// An excerpt's start, keyed by its first frame's bits, so a search tries only
// the starts that can match. A key collision costs one more memcmp.
typedef struct { uint64_t key; NSUInteger start; } VibeExcerptStart;
static uint64_t VibeFrameKey(const float *frame, NSUInteger channels) {
    uint64_t key = 1469598103934665603ull;
    for (NSUInteger c = 0; c < channels; c++) {
        uint32_t bits; memcpy(&bits, frame + c, sizeof bits);
        key = (key ^ bits) * 1099511628211ull;
    }
    return key;
}
static int VibeCompareExcerptStarts(const void *a, const void *b) {
    const VibeExcerptStart *x = a, *y = b;
    if (x->key != y->key) return x->key < y->key ? -1 : 1;
    return x->start < y->start ? -1 : x->start > y->start;
}

// Every audible frame of capture must continue an exact excerpt of one of the
// references: bit-perfect output may cut between excerpts, never scale a
// sample. Each excerpt is found by an exact 32-frame match, so a ramp's scaled
// samples match nothing; with declick on, a run of up to `rampFrames` of them
// is allowed between excerpts and counted in `ramped`. Returns the excerpts found.
- (NSUInteger)assertExactExcerptsOf:(NSArray<NSData *> *)references inCapture:(NSData *)capture
                         rampFrames:(NSUInteger)rampFrames ramped:(NSUInteger *)ramped {
    NSUInteger channels = _channels, frames = capture.length / sizeof(float) / channels, excerpts = 0, run = 0;
    const float *a = capture.bytes;
    const float *r = NULL;
    NSUInteger at = 0, length = 0; // the current excerpt's next reference frame
    // Sorted by key, then start, so the first match is the earliest start, as
    // a scan from the reference's head would find it.
    NSMutableArray<NSData *> *indexes = [NSMutableArray array];
    for (NSData *reference in references) {
        NSUInteger candidateFrames = reference.length / sizeof(float) / channels;
        NSUInteger count = candidateFrames >= 32 ? candidateFrames - 31 : 0;
        NSMutableData *index = [NSMutableData dataWithLength:count * sizeof(VibeExcerptStart)];
        VibeExcerptStart *entries = index.mutableBytes;
        const float *candidate = reference.bytes;
        for (NSUInteger start = 0; start < count; start++) {
            entries[start] = (VibeExcerptStart){ VibeFrameKey(candidate + start * channels, channels), start };
        }
        qsort(entries, count, sizeof *entries, VibeCompareExcerptStarts);
        [indexes addObject:index];
    }
    for (NSUInteger f = 0; f < frames; f++) {
        const float *frame = a + f * channels;
        BOOL silent = YES;
        for (NSUInteger c = 0; c < channels; c++) silent &= frame[c] == 0;
        if (r && at < length && memcmp(frame, r + at * channels, channels * sizeof(float)) == 0) {
            at++; run = 0;
            continue;
        }
        r = NULL;
        if (silent) { run = 0; continue; }
        uint64_t key = VibeFrameKey(frame, channels);
        for (NSUInteger i = 0; !r && i < references.count; i++) {
            const float *candidate = references[i].bytes;
            NSUInteger candidateFrames = references[i].length / sizeof(float) / channels;
            const VibeExcerptStart *entries = indexes[i].bytes;
            NSUInteger count = indexes[i].length / sizeof(VibeExcerptStart), lo = 0, hi = count;
            while (lo < hi) {
                NSUInteger mid = lo + (hi - lo) / 2;
                if (entries[mid].key < key) lo = mid + 1; else hi = mid;
            }
            for (NSUInteger e = lo; !r && f + 32 <= frames && e < count && entries[e].key == key; e++) {
                NSUInteger start = entries[e].start;
                if (memcmp(frame, candidate + start * channels, 32 * channels * sizeof(float)) == 0) {
                    r = candidate; at = start + 1; length = candidateFrames;
                }
            }
        }
        if (!r) {
            if (++run <= rampFrames) {
                if (ramped) (*ramped)++;
                continue;
            }
            XCTFail(@"Frame %lu is audible but continues no exact excerpt: %g", (unsigned long)f, frame[0]);
            return excerpts;
        }
        run = 0;
        excerpts++;
    }
    return excerpts;
}

// A bit-perfect 48 kHz player whose bus reads on its real decode queues under
// the frame-driven pump, the pump's inline fill starved so only they fill.
// The bus is made by the first play, so `play` runs with the init still forced.
- (void)playOnTheDecodePool:(void (^)(void))play {
    [self playOnTheDecodePoolBitPerfect:YES play:play];
}

- (void)playOnTheDecodePoolBitPerfect:(BOOL)bitPerfect play:(void (^)(void))play {
    Method initializer = class_getInstanceMethod(AudioVoiceBus.class, @selector(initWithFormat:queue:inlineDecoding:));
    __block IMP originalInit;
    IMP asyncInit = imp_implementationWithBlock(^id(id receiver, AVAudioFormat *format, dispatch_queue_t queue, BOOL inlineDecoding) {
        return ((id (*)(id, SEL, AVAudioFormat *, dispatch_queue_t, BOOL))originalInit)(receiver, @selector(initWithFormat:queue:inlineDecoding:), format, queue, NO);
    });
    originalInit = method_setImplementation(initializer, asyncInit);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:bitPerfect automatic:NO];
        [_player debugStarveDecoder:YES];
        play();
    } @finally {
        method_setImplementation(initializer, originalInit);
        imp_removeBlock(asyncInit);
    }
}

#pragma mark - A file still downloading

// A copy of `source` behind a remote placeholder named `name`, whose first
// fetch streams it: `prefix` bytes in its part file, reported readable, the
// rest written as the test says (streamTo:), then completed or failed
// (finishStream:) or cancelled by the coordinator once nothing reads it. A
// later fetch, a replay's, installs the whole file at once. Opens need the
// decode pool: a read waiting for bytes would hold the inline fill's thread.
- (NSURL *)streamingCopyOf:(NSURL *)source prefix:(NSUInteger)prefix name:(NSString *)name {
    if (_streamURL) {
        [self finishStream:VibeStreamCancelled];
    }
    _streamBytes = [NSData dataWithContentsOfURL:source];
    _streamURL = [_temporary URLByAppendingPathComponent:name];
    XCTAssertTrue([NSFileManager.defaultManager createFileAtPath:_streamURL.path contents:nil
                                                      attributes:@{NSFilePosixPermissions: @0}]);
    NSURL *part = [PlaceholderFiles remotePlaceholderPartURL:_streamURL];
    XCTAssertTrue([[_streamBytes subdataWithRange:NSMakeRange(0, prefix)] writeToURL:part atomically:NO]);
    _stream = [[CloudFileAvailability alloc] initWithPartURL:part size:_streamBytes.length];
    [_stream noteWrittenBytes:prefix];
    _streamVerdict = dispatch_semaphore_create(0);
    atomic_store(&_streamOutcome, VibeStreamRunning);
    atomic_store(&_streamFetches, 0);
    atomic_store(&_streamCancels, 0);
    dispatch_semaphore_t verdict = _streamVerdict;
    NSData *bytes = _streamBytes;
    NSURL *url = _streamURL;
    __weak AudioPlayerRenderTests *weakSelf = self;
    [CloudFileMaterializer setRemoteRoot:_temporary fetch:^BOOL(NSURL *fetched, dispatch_block_t onReadable,
                                                                 void (^onCancel)(dispatch_block_t), NSError **error) {
        AudioPlayerRenderTests *test = weakSelf;
        if (!test || atomic_fetch_add(&test->_streamFetches, 1) > 0) {
            NSURL *staging = [url URLByAppendingPathExtension:@"whole"];
            return [bytes writeToURL:staging atomically:NO]
                    && rename(staging.fileSystemRepresentation, url.fileSystemRepresentation) == 0;
        }
        onCancel(^{
            AudioPlayerRenderTests *cancelling = weakSelf;
            if ([cancelling finishStream:VibeStreamCancelled]) {
                atomic_fetch_add(&cancelling->_streamCancels, 1);
            }
        });
        onReadable();
        dispatch_semaphore_wait(verdict, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC)));
        dispatch_semaphore_signal(verdict); // a fetch after the verdict answers at once
        int outcome = atomic_load(&test->_streamOutcome);
        if (outcome == VibeStreamCompleted) {
            return YES;
        }
        if (error) {
            *error = outcome == VibeStreamFailed ? test->_streamFailure
                                                 : [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
        }
        return NO;
    } read:^NSData *(NSURL *read, uint64_t offset, uint64_t length, NSError **error) {
        return nil;
    } availability:^CloudFileAvailability *(NSURL *candidate) {
        AudioPlayerRenderTests *test = weakSelf;
        return test && [candidate.path isEqualToString:url.path] && atomic_load(&test->_streamOutcome) == VibeStreamRunning
                ? test->_stream : nil;
    }];
    return _streamURL;
}

- (void)streamTo:(NSUInteger)end {
    NSUInteger written = (NSUInteger)_stream.writtenBytes;
    NSFileHandle *part = [NSFileHandle fileHandleForWritingToURL:_stream.partURL error:NULL];
    [part seekToEndOfFile];
    [part writeData:[_streamBytes subdataWithRange:NSMakeRange(written, MIN(end, _streamBytes.length) - written)]];
    [part closeFile];
    [_stream noteWrittenBytes:end];
}

// The stream's last `window` bytes as the tail window. An MP3's open reads its
// last 8 KB (its ID3v1 check).
- (void)installTailWindow:(NSUInteger)window {
    NSUInteger at = _streamBytes.length - window;
    [_stream installWindow:[_streamBytes subdataWithRange:NSMakeRange(at, window)] atOffset:at];
}

// The first fetch's verdict, once, in the mirror's order: the rest written,
// the rename and the finish; or the part deleted and its readers failed.
- (BOOL)finishStream:(VibeStreamOutcome)outcome {
    int running = VibeStreamRunning;
    if (!_stream || !atomic_compare_exchange_strong(&_streamOutcome, &running, outcome)) {
        return NO;
    }
    if (outcome == VibeStreamCompleted) {
        [self streamTo:_streamBytes.length];
        rename(_stream.partURL.fileSystemRepresentation, _streamURL.fileSystemRepresentation);
        [_stream finishWithError:nil];
    }
    else {
        [NSFileManager.defaultManager removeItemAtURL:_stream.partURL error:NULL];
        [_stream finishWithError:outcome == VibeStreamFailed ? _streamFailure
                : [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    }
    dispatch_semaphore_signal(_streamVerdict);
    return YES;
}

// No bus answers no voice. A message to nil that returns a struct this large
// leaves the struct unset.
- (VibeVoiceSnapshot)currentVoiceSnapshot {
    __block VibeVoiceSnapshot snapshot = {0};
    [_player runSyncOnQueue:^{
        AudioVoiceBus *bus = [self->_player valueForKey:@"voiceBus"];
        if (bus) {
            snapshot = [bus snapshotOfVoice:[[self->_player valueForKey:@"voice"] unsignedLongLongValue]];
        }
    }];
    return snapshot;
}

// A live voice a decode turn is filling: its next block is close. Held,
// paused, waiting for bytes, ended or idle, nothing fills it soon.
- (BOOL)voiceIsFilling:(VibeVoiceSnapshot)voice {
    return (voice.state == VibeVoiceStateArmed || voice.state == VibeVoiceStateLive) && !voice.paused
            && voice.ended == VibeVoiceEndNone && !voice.waitingForBytes && voice.decoding
            && voice.written < voice.endOfStream;
}

// Run main between slices so deliveries and wall-clock deadlines progress.
// Wait for active decode work to fill the next block before pulling it.
// The pump's frame clock advances independently of wall time.
- (BOOL)renderUntil:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [self render:_blockSize];
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate date]];
        VibeVoiceSnapshot voice = [self currentVoiceSnapshot];
        if (![self voiceIsFilling:voice]) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
            continue;
        }
        while ([self voiceIsFilling:voice] && voice.written < voice.consumed + _blockSize
                && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.0001]];
            voice = [self currentVoiceSnapshot];
        }
    }
    return condition();
}

// Apply after open settles so only the subsequent stall uses this deadline.
- (void)shortenTheOpenDeadline {
    VibeAudioLoadingConfigurationValues values = VibeAudioLoadingProductionConfigurationValues();
    values.openTimeouts = VibeAudioOpenTimeoutConfigurationMake(0.5, 0.5);
    [_player applyLoadingConfiguration:[[AudioLoadingConfiguration alloc] initWithValues:values error:NULL]];
}

// The stream playing on the decode pool under the short deadline, rendered to
// its hold, stalls: Paused in place with the stall's error, never a track
// end. Answers the position held.
- (NSTimeInterval)stallTheStream {
    XCTAssertTrue([self renderUntil:^BOOL { return self->_player.isBuffering; }]);
    NSTimeInterval held = _player.position;
    NSUInteger pauses = [self count:@"pause"];
    XCTAssertTrue([self renderUntil:^BOOL { return self->_playError != nil; }]);
    XCTAssertEqual(_playError.code, VibeAudioErrorConnectionLost, @"%@", _playError);
    XCTAssertTrue(_player.isPaused);
    XCTAssertFalse(_player.isBuffering);
    XCTAssertFalse(_player.bufferingNoticeShown, @"a stall ends Buffering…");
    XCTAssertEqual(_player.position, held, @"paused where it stopped");
    XCTAssertEqual([self count:@"finish"], 0u);
    [self settleUntil:^BOOL { return [self count:@"pause"] == pauses + 1; }];
    return held;
}

// Allow the two-frame search margin for seconds-to-frame conversion.
- (void)assertTheReplayOf:(NSData *)reference startsAt:(NSTimeInterval)held {
    [self settleUntil:^BOOL { return [self currentVoiceSnapshot].written >= 16384; }];
    [_capture setLength:0];
    [self render:4800];
    NSUInteger expected = (NSUInteger)llround(held * 48000), found = NSNotFound;
    for (NSUInteger start = expected - 2; start <= expected + 2 && found == NSNotFound; start++) {
        if (memcmp(_capture.bytes, (const float *)reference.bytes + start * 2, 32 * 8) == 0) found = start;
    }
    XCTAssertNotEqual(found, (NSUInteger)NSNotFound, @"the replay starts where the stall held, %.3f s", held);
    if (found != NSNotFound) {
        [self assertReference:[reference subdataWithRange:NSMakeRange(found * 8, 4800 * 8)] capture:_capture skip:0 tolerance:0];
    }
}

- (void)record:(NSString *)event track:(VibeTestTrack *)track {
    [_events addObject:@{@"event":event,@"track":track.url.path?:@"",@"position":@(_player.position),@"render":_player.debugRenderCounts?:@{}}];
}
- (void)audioPlayerDidInitialize:(AudioPlayer *)p { [self record:@"init" track:nil]; }
- (void)audioPlayer:(AudioPlayer *)p didStartPlaying:(VibeTestTrack *)t {
    [self record:@"start" track:t];
    if (_chain && _nextPrefetch<_chain.count) [p prefetchTrack:_chain[_nextPrefetch]];
}

- (void)audioPlayer:(AudioPlayer *)p didPausePlaying:(VibeTestTrack *)t { [self record:@"pause" track:t]; }
// What the iOS shell's session reads at this edge: the answer now, not the edge's.
- (void)audioPlayerOutputDidBecomeIdle:(AudioPlayer *)p {
    [_events addObject:@{@"event": @"idle", @"outputIdle": @(p.outputIdle)}];
}
- (void)audioPlayer:(AudioPlayer *)p didResumePlaying:(VibeTestTrack *)t { [self record:@"resume" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didFinishSeeking:(VibeTestTrack *)t { [self record:@"seek" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didFinishPlaying:(VibeTestTrack *)t { [self record:@"finish" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didAutoAdvanceFromTrack:(VibeTestTrack *)a toTrack:(VibeTestTrack *)b {
    [self record:@"advance" track:b];
    _nextPrefetch++;
    if (_chain && _nextPrefetch<_chain.count) [p prefetchTrack:_chain[_nextPrefetch]];
}
- (void)audioPlayer:(AudioPlayer *)p didBeginLoading:(VibeTestTrack *)t openRequestIdentifier:(uint64_t)i { [self record:@"loading" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didChangeBuffering:(BOOL)buffering forTrack:(VibeTestTrack *)t {
    [self record:buffering ? @"buffering" : @"buffered" track:t];
}
- (void)audioPlayer:(AudioPlayer *)p didChangeBufferingNotice:(BOOL)shown forTrack:(VibeTestTrack *)t {
    [self record:shown ? @"notice" : @"noticeEnded" track:t];
}
- (void)audioPlayer:(AudioPlayer *)p didChangeLoadingPaused:(BOOL)paused forTrack:(VibeTestTrack *)t {}
- (void)audioPlayer:(AudioPlayer *)p didSettleDurationOfTrack:(VibeTestTrack *)t {
    [_events addObject:@{@"event": @"settled", @"duration": @(p.duration), @"position": @(p.position)}];
}
- (void)audioPlayer:(AudioPlayer *)player outputModesForDeviceUID:(NSString *)uid
  bitPerfectOutput:(BOOL *)bitPerfect exclusiveOutput:(BOOL *)exclusive {
    if (_outputModesProvider) _outputModesProvider(uid, bitPerfect, exclusive);
}
- (void)audioPlayer:(AudioPlayer *)p didChangeOutputDevice:(NSInteger)d involuntaryFallbackUID:(NSString *)fallbackUID
involuntaryFallbackName:(NSString *)fallbackName carriedModesFromUID:(NSString *)carriedUID {
    [_events addObject:@{@"event": @"device", @"device": @(d),
            @"fallback": fallbackUID ?: @"",
            @"carriedModes": carriedUID ?: @""}];
}
- (void)audioPlayer:(AudioPlayer *)p error:(NSError *)error { _playError=error; [self record:@"error" track:nil]; }

@end
