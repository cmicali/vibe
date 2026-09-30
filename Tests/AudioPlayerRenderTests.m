#import <XCTest/XCTest.h>
#import "AudioPlayer+Debug.h"
#import "AudioFX+Debug.h"
#import "AudioLevelMeter+Debug.h"
#import "AudioTrack.h"
#import "AudioPlayer+Devices.h"
#import "AudioPlayerInternal.h"
#import "AudioFX.h"
#import "AudioFXMath.h"
#import "CoreAudioUtil.h"
#import "AudioDevice.h"
#import "VibeManualRenderPump.h"
#import "AudioVoiceBusInternal.h"
#import "AudioOutputUnitInternal.h"
#import "AudioFixtures.h"
#import <objc/runtime.h>
#import "AudioFileMaterializationCoordinatorInternal.h"
#include <float.h>
#include <stdatomic.h>

// Independent Apple AAC decodes can differ by a few float rounding bits.
// Lossless paths still require exact samples; AAC stays below -126 dBFS.
static const float kVibeAACDecodeTolerance = 4 * FLT_EPSILON;

// Interleaved float PCM keeps the oracle independent of the render's buffers.
static NSMutableData *PCM(AVAudioPCMBuffer *buffer) {
    NSMutableData *data = [NSMutableData data];
    VibeAppendPCM(data, buffer);
    return data;
}

// One alignment, every remaining source frame, every channel. The only skipped
// source interval is the explicitly requested startup declick. No gain fit,
// resampling, moving alignment, or overlap-only pass can conceal a defect.
static NSDictionary *ComparePCM(NSData *reference, NSData *capture, NSUInteger channels,
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
static NSDictionary *CompareWidePCM(NSData *wide, NSData *capture, NSUInteger channels,
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
static NSData *Float32PCM(NSData *wide) {
    NSMutableData *pcm = [NSMutableData dataWithLength:wide.length / sizeof(double) * sizeof(float)];
    const double *in = wide.bytes;
    float *out = pcm.mutableBytes;
    for (NSUInteger i = 0; i < pcm.length / sizeof(float); i++) out[i] = (float)in[i];
    return pcm;
}

static double RMS(NSData *data, NSUInteger channels, NSUInteger channel, NSRange frames) {
    const float *p = data.bytes; double energy = 0;
    if (NSMaxRange(frames) * channels * sizeof(float) > data.length || frames.length == 0) return NAN;
    for (NSUInteger f = frames.location; f < NSMaxRange(frames); f++) energy += (double)p[f*channels+channel] * p[f*channels+channel];
    return sqrt(energy / frames.length);
}
static double ToneAmplitude(NSData *data, NSUInteger channels, NSUInteger channel, double rate, double frequency, NSRange frames) {
    const float *p = data.bytes; double real = 0, imaginary = 0;
    for (NSUInteger f = frames.location; f < NSMaxRange(frames); f++) {
        double phase = 2 * M_PI * frequency * f / rate;
        real += p[f*channels+channel] * cos(phase); imaginary += p[f*channels+channel] * sin(phase);
    }
    return 2 * hypot(real, imaginary) / frames.length;
}
static float PeakLevel(const float levels[kLevelBandCount]) {
    float peak = 0; for (NSUInteger i = 0; i < kLevelBandCount; i++) peak = MAX(peak, levels[i]); return peak;
}

// The shared fixture: capture, comparisons, the delegate trace and setup.
// It holds no tests, so it runs none; each subclass below is one topic, and
// the runner spreads the subclasses across its processes.
@interface AudioPlayerRenderTests : XCTestCase <AudioPlayerDelegate> {
    AudioPlayer *_player;
    NSMutableArray<NSDictionary *> *_events;
    NSError *_playError;
    NSURL *_temporary;
    double _rate;
    NSUInteger _channels;
    NSUInteger _blockSize;
    NSMutableData *_capture;
    NSArray<AudioTrack *> *_chain;
    NSUInteger _nextPrefetch;
    void (^_outputModesProvider)(NSString *, BOOL *, BOOL *);
    BOOL _priorAppleMPEGDecoder; // a test's choice is undone at tearDown
}
@end

@implementation AudioPlayerRenderTests
- (void)setUp {
    [super setUp]; self.continueAfterFailure = NO;
    _events = [NSMutableArray array]; _blockSize = 256;
    _temporary = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:_temporary withIntermediateDirectories:YES attributes:nil error:NULL];
    _priorAppleMPEGDecoder = AudioFileHandle.appleMPEGDecoder;
}
- (void)tearDown {
    if (self.testRun.failureCount && _capture.length) {
        [self attach:_capture name:@"last-render"];
        XCTAttachment *trace=[XCTAttachment attachmentWithString:_events.description];
        trace.name=@"transport-events"; trace.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:trace];
    }
    [_player debugHoldRenderInside:NO]; // a failed hold test must not leave a render blocked
    [_player debugShutdown]; _player = nil;
    AudioFileHandle.appleMPEGDecoder = _priorAppleMPEGDecoder;
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
    NSData *pcm=Float32PCM([self wideSourcePCM:url]);
    XCTAssertEqualObjects(pcm,PCM([self read:url]),@"Lossless decode %@",url.lastPathComponent);
    return pcm;
}
- (NSUInteger)count:(NSString *)event {
    NSUInteger count=0; for (NSDictionary *entry in _events) if ([entry[@"event"] isEqual:event]) count++; return count;
}
- (void)settleUntil:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:VIBE_TEST_HANG_TIMEOUT];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.0001]];
    XCTAssertTrue(condition(), @"Timed out; events %@; error %@", _events, _playError);
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
- (AudioTrack *)play:(NSURL *)url paused:(BOOL)paused position:(double)position {
    AudioTrack *track = [AudioTrack withURL:url];
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
        [_capture appendData:PCM(buffer)];
        frames-=count;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.00001]];
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
    NSDictionary *result=ComparePCM(reference,capture,_channels,skip,tolerance);
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
        for (NSData *reference in references) {
            const float *candidate = reference.bytes;
            NSUInteger candidateFrames = reference.length / sizeof(float) / channels;
            for (NSUInteger start = 0; !r && f + 32 <= frames && start + 32 <= candidateFrames; start++) {
                if (memcmp(frame, candidate + start * channels, 32 * channels * sizeof(float)) == 0) {
                    r = candidate; at = start + 1; length = candidateFrames;
                }
            }
            if (r) break;
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
    Method initializer = class_getInstanceMethod(AudioVoiceBus.class, @selector(initWithFormat:queue:inlineDecoding:));
    __block IMP originalInit;
    IMP asyncInit = imp_implementationWithBlock(^id(id receiver, AVAudioFormat *format, dispatch_queue_t queue, BOOL inlineDecoding) {
        return ((id (*)(id, SEL, AVAudioFormat *, dispatch_queue_t, BOOL))originalInit)(receiver, @selector(initWithFormat:queue:inlineDecoding:), format, queue, NO);
    });
    originalInit = method_setImplementation(initializer, asyncInit);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        [_player debugStarveDecoder:YES];
        play();
    } @finally {
        method_setImplementation(initializer, originalInit);
        imp_removeBlock(asyncInit);
    }
}

- (void)record:(NSString *)event track:(AudioTrack *)track {
    [_events addObject:@{@"event":event,@"track":track.url.path?:@"",@"position":@(_player.position),@"render":_player.debugRenderCounts?:@{}}];
}
- (void)audioPlayerDidInitialize:(AudioPlayer *)p { [self record:@"init" track:nil]; }
- (void)audioPlayer:(AudioPlayer *)p didStartPlaying:(AudioTrack *)t {
    [self record:@"start" track:t];
    if (_chain && _nextPrefetch<_chain.count) [p prefetchTrack:_chain[_nextPrefetch]];
}

- (void)audioPlayer:(AudioPlayer *)p didPausePlaying:(AudioTrack *)t { [self record:@"pause" track:t]; }
// What the iOS shell's session reads at this edge: the answer now, not the edge's.
- (void)audioPlayerOutputDidBecomeIdle:(AudioPlayer *)p {
    [_events addObject:@{@"event": @"idle", @"outputIdle": @(p.outputIdle)}];
}
- (void)audioPlayer:(AudioPlayer *)p didResumePlaying:(AudioTrack *)t { [self record:@"resume" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didFinishSeeking:(AudioTrack *)t { [self record:@"seek" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didFinishPlaying:(AudioTrack *)t { [self record:@"finish" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didAutoAdvanceFromTrack:(AudioTrack *)a toTrack:(AudioTrack *)b {
    [self record:@"advance" track:b];
    _nextPrefetch++;
    if (_chain && _nextPrefetch<_chain.count) [p prefetchTrack:_chain[_nextPrefetch]];
}
- (void)audioPlayer:(AudioPlayer *)p didBeginLoading:(AudioTrack *)t openRequestIdentifier:(uint64_t)i { [self record:@"loading" track:t]; }
- (void)audioPlayer:(AudioPlayer *)p didChangeLoadingPaused:(BOOL)paused forTrack:(AudioTrack *)t {}
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

// The oracle itself, the bit-perfect matrix, every container and codec, float limits and wide sources.
@interface AudioPlayerRenderFidelityTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderFidelityTests

- (void)testOracleRejectsCorruption {
    _channels=2;
    NSData *reference=PCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    XCTAssertTrue([ComparePCM(reference,reference,2,0,0)[@"pass"] boolValue]);
    for (NSString *mutation in @[@"drop",@"duplicate",@"swap",@"polarity",@"gain",@"clip",@"truncate",@"silence",@"nan",@"lsb",@"shortMatch",@"tail",@"partialFrame"]) {
        NSMutableData *bad=[reference mutableCopy]; float *p=bad.mutableBytes;
        NSUInteger samples=bad.length/sizeof(float), at=24000;
        if ([mutation isEqual:@"drop"]) [bad replaceBytesInRange:NSMakeRange(at*4,8) withBytes:NULL length:0];
        else if ([mutation isEqual:@"duplicate"]) { float pair[2]={p[at],p[at+1]}; [bad replaceBytesInRange:NSMakeRange(at*4,0) withBytes:pair length:8]; }
        else if ([mutation isEqual:@"truncate"]) [bad setLength:bad.length-8];
        else if ([mutation isEqual:@"shortMatch"]) [bad setLength:128*8];
        else if ([mutation isEqual:@"tail"]) [bad appendData:[reference subdataWithRange:NSMakeRange(0,8)]];
        else if ([mutation isEqual:@"partialFrame"]) [bad setLength:bad.length+1];
        else if ([mutation isEqual:@"swap"]) for (NSUInteger i=at;i<samples;i+=2) { float v=p[i];p[i]=p[i+1];p[i+1]=v; }
        else if ([mutation isEqual:@"polarity"]) for(NSUInteger i=at;i<samples;i++) p[i]=-p[i];
        else if ([mutation isEqual:@"gain"]) for(NSUInteger i=at;i<samples;i++) p[i]*=0.999f;
        else if ([mutation isEqual:@"clip"]) for(NSUInteger i=at;i<samples;i++) p[i]=fmaxf(-0.1f,fminf(0.1f,p[i]));
        else if ([mutation isEqual:@"silence"]) memset(p+at,0,(samples-at)*4);
        else if ([mutation isEqual:@"nan"]) p[at]=NAN;
        else p[at]+=1.0f/8388608;
        XCTAssertFalse([ComparePCM(reference,bad,2,0,0)[@"pass"] boolValue],@"%@ escaped",mutation);
    }
    // One bit below float32's significand, which no float reference can hold.
    NSData *wide=[self wideSourcePCM:[self fixture:@"integer32.wav"]], *capture=Float32PCM(wide);
    XCTAssertTrue([CompareWidePCM(wide,capture,2,0,0)[@"pass"] boolValue]);
    NSMutableData *bad=[wide mutableCopy];
    ((double *)bad.mutableBytes)[24000]+=1.0/2147483648;
    XCTAssertEqual([CompareWidePCM(bad,capture,2,0,0)[@"mismatchedSamples"] unsignedIntegerValue],1u);
}
- (void)testBitPerfectRateDepthAndChannelMatrix {
    for (NSNumber *rate in @[@44100,@48000,@88200,@96000,@176400,@192000])
    for (NSNumber *bits in @[@16,@24,@32]) for (NSNumber *channels in @[@1,@2]) {
        @autoreleasepool {
            [self startPlayerAt:rate.doubleValue channels:channels.unsignedIntegerValue fx:NO bitPerfect:YES automatic:NO];
            NSURL *url=[self fixture:[NSString stringWithFormat:@"noise-%@-%@-%@.wav",rate,bits,channels]];
            NSData *reference=[self sourcePCM:url]; [self play:url paused:NO position:0];
            NSData *capture=[self renderSeconds:2.1];
            [self assertReference:reference capture:capture skip:[self startupSkip] tolerance:0];
            XCTAssertFalse([_player.debugRenderCounts[@"varispeed"] boolValue]);
            [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
            XCTAssertEqual([self count:@"finish"],1u);
        }
    }
}
- (void)testRegularPlaybackAndInactiveFXAreTransparent {
    for (NSNumber *fx in @[@NO,@YES]) for (NSNumber *rate in @[@44100,@48000,@96000]) {
        [self startPlayerAt:rate.doubleValue channels:2 fx:fx.boolValue bitPerfect:NO automatic:NO];
        _player.levelsEnabled=YES; // the equalizer's meter reads the output, never writes it
        NSURL *url=[self fixture:[NSString stringWithFormat:@"noise-%@-24-2.wav",rate]];
        NSData *reference=PCM([self read:url]); [self play:url paused:NO position:0];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
        // Transparent because nothing renders: the varispeed is out of the
        // chain at zero pitch, and an idle segment's units are at rest.
        NSDictionary *counts=_player.debugRenderCounts;
        XCTAssertEqual([counts[@"varispeedRenders"] unsignedLongLongValue],0ull);
        XCTAssertEqual([counts[@"unitRenders"] unsignedLongLongValue],0ull);
    }
}
- (void)testLosslessContainersAndExtensionAliases {
    NSData *original=PCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    for (NSString *name in @[@"lossless.flac",@"lossless.m4a",@"lossless.aiff",@"alias.aif",@"alias.wave",@"alias.bwf"]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        NSURL *url=[self fixture:name]; NSData *decoded=PCM([self read:url]);
        XCTAssertEqualObjects(original,decoded,@"Lossless fixture %@",name);
        [self play:url paused:NO position:0];
        [self assertReference:original capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    }
}
- (void)checkLossy:(NSString *)name tolerance:(float)tolerance {
    NSURL *url=[self optionalFixture:name];
    AVAudioPCMBuffer *decoded=[self read:url];
    [self startPlayerAt:decoded.format.sampleRate channels:decoded.format.channelCount fx:NO bitPerfect:YES automatic:NO];
    [self play:url paused:NO position:0];
    [self assertReference:PCM(decoded) capture:[self renderSeconds:decoded.frameLength/_rate+0.1] skip:[self startupSkip] tolerance:tolerance];
}
- (void)testAACContainer { [self checkLossy:@"lossy.m4a" tolerance:kVibeAACDecodeTolerance]; }
- (void)testAACElementary { [self checkLossy:@"lossy.aac" tolerance:kVibeAACDecodeTolerance]; }
- (void)testMP4 { [self checkLossy:@"alias.mp4" tolerance:kVibeAACDecodeTolerance]; }
- (void)testMP3CBR { [self checkLossy:@"cbr.mp3" tolerance:0]; }
- (void)testMP3VBR { [self checkLossy:@"vbr.mp3" tolerance:0]; }
- (void)testMP2 { [self checkLossy:@"lossy.mp2" tolerance:0]; }
// Layer III's synthesis delay: dr_mp3's drain and Apple's zero fill differ
// over this many frames at a file's end, and the handle skips it at the start.
static const NSUInteger kLayer3DecoderDelay = 529;
// The ISO/IEC 11172-4 Layer III compliance stream, scored on its Annex A
// thresholds against the reference decode: full accuracy is an RMS error
// below 2^-15/sqrt(12) with no sample off by more than 2^-14. dr_mp3 passes with
// the margin of a float decoder (about 140x measured, 50x required), so a
// regression to 16-bit output fails here. Apple's decoder is 16-bit on arm64
// and sits on the line, within limited accuracy; its x86_64 build decodes to
// float and passes as dr_mp3 does (about 150x). The handle drops the decoder's
// 529-frame delay, so its frame 0 is the reference's frame 529. The last 529
// frames are left out of both scores: the stream ends in a truncated frame the
// reference decoder decoded and CoreAudio's parser does not serve, so there
// dr_mp3's drain and Apple's zero fill both meet audio the file does not hold.
- (void)testDrMP3PassesTheISOComplianceStreamAtFullAccuracy {
    NSURL *url = [self fixture:@"iso-compl.mp3"];
    NSString *referencePath = [self fixture:@"iso-compl.f32"].path;
    XCTSkipUnless([NSFileManager.defaultManager fileExistsAtPath:referencePath],
                  @"The ISO compliance stream was not fetched (FFmpeg's FATE mirror unreachable); regenerate");
    NSData *referenceBytes = [NSData dataWithContentsOfFile:referencePath];
    const float *reference = referenceBytes.bytes;
    NSUInteger referenceFrames = referenceBytes.length / sizeof(float) - kLayer3DecoderDelay;
    const double fullRMS = 1.0 / 32768 / sqrt(12), fullMax = 1.0 / 16384, limitedRMS = 1.0 / 2048 / sqrt(12);
    double rms[2], worst[2];
    for (NSUInteger apple = 0; apple < 2; apple++) {
        AudioFileHandle.appleMPEGDecoder = apple;
        AVAudioPCMBuffer *decoded = [self read:url];
        XCTAssertEqual(decoded.format.channelCount, 1u);
        NSUInteger frames = MIN(decoded.frameLength - kLayer3DecoderDelay, referenceFrames);
        XCTAssertGreaterThan(frames, 200000u);
        double sum = 0, max = 0;
        for (NSUInteger f = 0; f < frames; f++) {
            double error = (double)decoded.floatChannelData[0][f] - reference[f + kLayer3DecoderDelay];
            sum += error * error;
            max = fmax(max, fabs(error));
        }
        rms[apple] = sqrt(sum / frames);
        worst[apple] = max;
    }
    XCTAssertLessThan(rms[0], fullRMS / 50, @"dr_mp3 RMS error %g", rms[0]);
    XCTAssertLessThanOrEqual(worst[0], fullMax, @"dr_mp3 max error %g", worst[0]);
    XCTAssertLessThan(rms[1], limitedRMS, @"Apple RMS error %g", rms[1]);
#if defined(__arm64__)
    XCTAssertGreaterThan(rms[1], fullRMS / 4, @"Apple's decoder is no longer 16-bit: RMS error %g", rms[1]);
#else
    XCTAssertLessThan(rms[1], fullRMS / 50, @"Apple's x86_64 decoder is no longer float: RMS error %g", rms[1]);
#endif
}

// dr_mp3's decode is what Apple's rounds to 16 bits on arm64, and what its
// x86_64 float decode is to a tenth of an LSB: one length, samples within
// Apple's four LSBs but for the last 529 frames, which Apple zero-fills where
// dr_mp3 drains its filterbank, and overs kept that Apple clips at full scale
// on both. A seek decodes exactly what the continuous read did at that frame.
- (void)testDrMP3DecodesWhatAppleRoundsTo16Bits {
    for (NSString *name in @[@"cbr.mp3", @"vbr.mp3", @"lossy.mp2", @"hot.mp3", @"mp3-in.wav", @"mp2-in.wav"]) {
        NSURL *url = [self optionalFixture:name];
        AudioFileHandle.appleMPEGDecoder = YES;
        AVAudioPCMBuffer *apple = [self read:url];
        AudioFileHandle.appleMPEGDecoder = NO;
        AudioFileHandle *file = [self open:url decoder:@"dr_mp3"];
        AVAudioPCMBuffer *decoded = [self read:url];
        XCTAssertEqual(decoded.frameLength, apple.frameLength, @"%@", name);
        NSUInteger channels = decoded.format.channelCount, compared = MIN(decoded.frameLength, apple.frameLength) - kLayer3DecoderDelay;
        NSUInteger far = 0, offGrid = 0, overs = 0, appleOvers = 0;
        for (NSUInteger c = 0; c < channels; c++) for (NSUInteger f = 0; f < compared; f++) {
            float d = decoded.floatChannelData[c][f], a = apple.floatChannelData[c][f];
            BOOL clipped = fabsf(a) >= 32767.0f / 32768 && fabsf(d) > fabsf(a);
            if (!clipped && fabsf(d - a) > 4.0f / 32768) far++;
            if (d * 32768 != rintf(d * 32768)) offGrid++;
            overs += fabsf(d) > 1;
            appleOvers += fabsf(a) > 1;
        }
        XCTAssertEqual(far, 0u, @"%@ strays from Apple's rounding", name);
        XCTAssertGreaterThan(offGrid, compared * channels / 2, @"%@ decoded to a 16-bit grid", name);
        XCTAssertEqual(appleOvers, 0u, @"%@: Apple's decode was expected to clip", name);
        if ([name isEqual:@"hot.mp3"]) XCTAssertGreaterThan(overs, 0u, @"the overs a float decode keeps");
        [self assertSeeksOf:file match:PCM(decoded) block:1152 name:name];
        // A partial download declares more packets than it holds; both end at
        // the last one it does. A truncated WAV serves none: CoreAudio counts
        // zero packets, so there is nothing to compare.
        if ([url.pathExtension isEqualToString:@"wav"]) continue;
        NSData *bytes = [NSData dataWithContentsOfURL:url];
        NSURL *truncated = [self writeBytes:[bytes subdataWithRange:NSMakeRange(0, bytes.length / 2)] name:[@"truncated-" stringByAppendingString:name]];
        NSUInteger frames[2];
        for (NSUInteger apple = 0; apple < 2; apple++) {
            AudioFileHandle.appleMPEGDecoder = apple;
            AudioFileHandle *partial = [[AudioFileHandle alloc] initForReading:truncated error:NULL];
            AVAudioPCMBuffer *chunk = [[AVAudioPCMBuffer alloc] initWithPCMFormat:partial.processingFormat frameCapacity:4096];
            frames[apple] = 0;
            while ([partial readIntoBuffer:chunk error:NULL] && chunk.frameLength) frames[apple] += chunk.frameLength;
        }
        XCTAssertEqual(frames[0], frames[1], @"%@ truncated", name);
        XCTAssertGreaterThan(frames[0], 0u);
        XCTAssertLessThan(frames[0], decoded.frameLength);
    }
}
// The byte offset of every packet CoreAudio's parser serves: for an MP3, each
// audio frame, the LAME tag's frame not among them; for a FLAC, each frame.
// Each is found by its bytes in the file, since macOS 26's MP3 parser answers
// kAudioFilePropertyPacketToByte with kAudioFileInvalidPacketOffsetError.
- (NSArray<NSNumber *> *)packetOffsetsOf:(NSURL *)url {
    NSData *file = [NSData dataWithContentsOfURL:url];
    AudioFileID parser = NULL;
    XCTAssertEqual(AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadPermission, 0, &parser), noErr);
    UInt64 packets = 0;
    UInt32 bound = 0, size = sizeof(packets);
    AudioFileGetProperty(parser, kAudioFilePropertyAudioDataPacketCount, &size, &packets);
    size = sizeof(bound);
    AudioFileGetProperty(parser, kAudioFilePropertyPacketSizeUpperBound, &size, &bound);
    NSMutableData *packet = [NSMutableData dataWithLength:MAX(bound, 4096u)];
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray array];
    NSUInteger from = 0;
    for (UInt64 p = 0; p < packets; p++) {
        UInt32 bytes = (UInt32)packet.length, count = 1;
        AudioStreamPacketDescription description = {0};
        OSStatus status = AudioFileReadPacketData(parser, false, &bytes, &description, (SInt64)p, &count, packet.mutableBytes);
        XCTAssertTrue(status == noErr || status == kAudioFileEndOfFileError, @"packet %llu: %d", p, (int)status);
        if (count == 0) break;
        NSRange found = [file rangeOfData:[packet subdataWithRange:NSMakeRange(0, bytes)] options:0 range:NSMakeRange(from, file.length - from)];
        XCTAssertNotEqual(found.location, (NSUInteger)NSNotFound, @"packet %llu is not in the file", p);
        if (found.location == NSNotFound) break;
        [offsets addObject:@(found.location)];
        from = NSMaxRange(found);
    }
    AudioFileClose(parser);
    return offsets;
}
// An MPEG-1 Layer III frame's private bits are its encoder's to use, so a file
// with them set in every frame decodes exactly as the file does. dr_mp3
// upstream read them as the first granule's scfsi, which then reused the
// previous granule's scalefactors and misread the rest.
- (void)testDrMP3IgnoresPrivateBits {
    AudioFileHandle.appleMPEGDecoder = NO;
    for (NSString *name in @[@"cbr.mp3", @"mono.mp3"]) {
        NSURL *url = [self optionalFixture:name];
        NSMutableData *bytes = [[NSData dataWithContentsOfURL:url] mutableCopy];
        NSArray<NSNumber *> *offsets = [self packetOffsetsOf:url];
        XCTAssertGreaterThan(offsets.count, 50u);
        for (NSNumber *offset in offsets) {
            uint8_t *frame = (uint8_t *)bytes.mutableBytes + offset.unsignedIntegerValue;
            XCTAssertEqual(frame[1], 0xFB, @"%@: MPEG-1 Layer III without a CRC", name);
            // After main_data_begin's 9 bits: 5 private bits in mono, 3 otherwise.
            frame[5] |= (frame[3] >> 6) == 3 ? 0x7C : 0x70;
        }
        NSURL *marked = [self writeBytes:bytes name:[@"private-" stringByAppendingString:name]];
        XCTAssertEqualObjects(PCM([self read:marked]), PCM([self read:url]), @"%@", name);
    }
}
// At 8 kbps an MPEG-2 frame carries a few bytes of payload, so the reservoir
// one frame reads from reaches back tens of frames, past the preroll MPEG-1
// seeks need: every seek still reads what the continuous decode holds there.
- (void)testDrMP3SeeksExactlyWhereTheReservoirReachesFurthest {
    NSURL *url = [self optionalFixture:@"lsf-8k.mp3"];
    AudioFileHandle.appleMPEGDecoder = NO;
    AudioFileHandle *file = [self open:url decoder:@"dr_mp3"];
    XCTAssertEqual(file.fileFormat.streamDescription->mFramesPerPacket, 576u);
    [self assertSeeksOf:file match:[self readToEnd:file] block:576 name:@"8 kbps MPEG-2"];
}
// Mixed blocks at 8 kHz (MPEG 2.5), which the generator codes directly since no
// encoder writes them, decode as FFmpeg's float decoder does, its frame 529 the
// handle's frame 0. Upstream's band table there reordered past the granule and
// scaled three bands by stale scalefactors. The generator leaves the blocks'
// long part empty, since decoders transform it differently at this rate.
- (void)testDrMP3DecodesMixedBlocksAt8kHzAsFFmpegDoes {
    NSString *referencePath = [self optionalFixture:@"mixed-8k.f32"].path;
    AudioFileHandle.appleMPEGDecoder = NO;
    AVAudioPCMBuffer *decoded = [self read:[self fixture:@"mixed-8k.mp3"]];
    XCTAssertEqual(decoded.format.sampleRate, 8000);
    NSData *referenceBytes = [NSData dataWithContentsOfFile:referencePath];
    const float *reference = referenceBytes.bytes;
    NSUInteger frames = MIN(decoded.frameLength, referenceBytes.length / sizeof(float) - kLayer3DecoderDelay) - kLayer3DecoderDelay;
    XCTAssertGreaterThan(frames, 20000u);
    float worst = 0;
    for (NSUInteger f = 0; f < frames; f++) {
        worst = fmaxf(worst, fabsf(decoded.floatChannelData[0][f] - reference[f + kLayer3DecoderDelay]));
    }
    XCTAssertLessThan(worst, 1e-5f, @"max error %g", worst);
}
// dr_mp3 never clamps, so one frame whose global gain a flipped bit raised by
// 64 (+96 dB) would decode far past full scale; the handle bounds it at
// +12 dBFS and changes nothing else: only that frame, the granule its IMDCT
// overlap reaches and the filterbank's 480 frames of history differ.
- (void)testDrMP3BoundsADamagedFrame {
    NSURL *url = [self optionalFixture:@"cbr.mp3"];
    AudioFileHandle.appleMPEGDecoder = NO;
    NSMutableData *bytes = [[NSData dataWithContentsOfURL:url] mutableCopy];
    NSArray<NSNumber *> *offsets = [self packetOffsetsOf:url];
    uint8_t *frame = (uint8_t *)bytes.mutableBytes + offsets[offsets.count / 2].unsignedIntegerValue;
    XCTAssertEqual(frame[1], 0xFB);
    XCTAssertNotEqual(frame[3] >> 6, 3, @"stereo side info");
    // Stereo side info: 20 bits of main_data_begin, private bits and scfsi,
    // then 59 bits a granule and channel, global_gain 21 bits in; its 64 is
    // its second bit.
    for (NSUInteger g = 0; g < 4; g++) {
        NSUInteger bit = 32 + 20 + g * 59 + 21 + 1;
        frame[bit / 8] |= 0x80 >> (bit % 8);
    }
    NSURL *damagedURL = [self writeBytes:bytes name:@"damaged.mp3"];
    AVAudioPCMBuffer *clean = [self read:url], *damaged = [self read:damagedURL];
    XCTAssertEqual(damaged.frameLength, clean.frameLength);
    float peak = 0;
    NSUInteger first = NSNotFound, last = 0;
    for (NSUInteger c = 0; c < 2; c++) for (NSUInteger f = 0; f < damaged.frameLength; f++) {
        float sample = damaged.floatChannelData[c][f];
        peak = fmaxf(peak, fabsf(sample));
        if (sample != clean.floatChannelData[c][f]) {
            first = MIN(first, f);
            last = MAX(last, f);
        }
    }
    XCTAssertEqual(peak, 4.0f, @"the damaged frame, bounded at +12 dBFS");
    XCTAssertNotEqual(first, NSNotFound);
    XCTAssertLessThan(last - first, 1152u + 576 + 480);
}
// Every frame the handle delivers, interleaved, to the end of the file, which
// may come before its declared length.
- (NSData *)readToEnd:(AudioFileHandle *)file {
    NSMutableData *pcm = [NSMutableData data];
    AVAudioPCMBuffer *chunk = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:4096];
    NSError *error = nil;
    for (;;) {
        XCTAssertTrue([file readIntoBuffer:chunk error:&error], @"%@", error);
        if (chunk.frameLength == 0) break;
        VibeAppendPCM(pcm, chunk);
    }
    return pcm;
}
// A seek reads what the continuous decode holds at its target, up to 2048
// frames of it, and nothing past its end.
- (void)assertSeekOf:(AudioFileHandle *)file to:(NSUInteger)at match:(NSData *)continuous name:(NSString *)name {
    NSUInteger channels = file.processingFormat.channelCount, frames = continuous.length / sizeof(float) / channels;
    AVAudioPCMBuffer *slice = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:2048];
    XCTAssertTrue([file seekToFrame:(AVAudioFramePosition)at error:NULL], @"%@ seek to %lu", name, (unsigned long)at);
    XCTAssertTrue([file readIntoBuffer:slice error:NULL]);
    NSMutableData *read = [NSMutableData data];
    VibeAppendPCM(read, slice);
    NSUInteger from = MIN(at, frames), expected = MIN(2048, frames - from);
    XCTAssertEqual(slice.frameLength, expected, @"%@ seek to %lu", name, (unsigned long)at);
    XCTAssertEqualObjects(read, [continuous subdataWithRange:NSMakeRange(from * channels * sizeof(float), expected * channels * sizeof(float))],
                          @"%@ seek to %lu", name, (unsigned long)at);
}
// Seeks to the edges of the first frames, the end, and targets across the file.
- (void)assertSeeksOf:(AudioFileHandle *)file match:(NSData *)continuous block:(NSUInteger)block name:(NSString *)name {
    NSUInteger frames = continuous.length / sizeof(float) / file.processingFormat.channelCount;
    NSMutableArray<NSNumber *> *targets = [@[@0, @1, @(block - 1), @(block), @(block + 1), @(frames / 2), @(frames - 1), @(frames - 2048)] mutableCopy];
    srand48(7);
    for (NSUInteger i = 0; i < 40; i++) [targets addObject:@((NSUInteger)(drand48() * frames))];
    for (NSNumber *target in targets) [self assertSeekOf:file to:target.unsignedIntegerValue match:continuous name:name];
}
// Zeroes STREAMINFO's total samples, the low 36 bits of its bytes 13 to 17, as
// a streamed encode leaves them.
- (void)clearLengthOfFLAC:(NSMutableData *)flac {
    XCTAssertEqual(memcmp(flac.bytes, "fLaC", 4), 0);
    uint8_t *streaminfo = (uint8_t *)flac.mutableBytes + 8;
    streaminfo[13] &= 0xF0;
    memset(streaminfo + 14, 0, 4);
}
// dr_flac plays legal FLACs Apple's codec refuses, and ones the upstream copy
// could not seek (every frame's first residual partition empty) or decode
// (Rice partition orders past 8, in a 24-bit stream and in a 32-bit one's
// 33-bit side channel), bit for bit: each decodes to the PCM it was encoded
// from, a 32-bit one rounded once to float32 in each side-channel mode, and
// every seek reads what the continuous decode holds there. The empty-partition file is played again with no length
// in STREAMINFO, as a streamed encode leaves it, and again with a megabyte of
// zeros after it, as a download that reserved its size leaves it: dr_flac
// finds the length from its last frames, and the player plays all of it.
- (void)testDrFLACDecodesWhatTheFileHolds {
    NSDictionary<NSString *, NSString *> *sources = @{
        @"flac-zero-residual.flac": @"noise-48000-24-2.wav", @"flac-block16.flac": @"noise-48000-24-2.wav",
        @"flac-block65535.flac": @"noise-48000-24-2.wav", @"flac-705600.flac": @"noise-705600-24-2.wav",
        @"flac-32-mid_side.flac": @"integer32-low-bits.wav", @"flac-32-left_side.flac": @"integer32-low-bits.wav",
        @"flac-32-right_side.flac": @"integer32-low-bits.wav", @"lossless-8ch.flac": @"noise-48000-24-8.wav",
        @"flac-partition-orders.flac": @"noise-48000-24-2.wav", @"flac-32-partition-order.flac": @"integer32-low-bits.wav"};
    for (NSString *name in [sources.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        AudioFileHandle *file = [self open:[self optionalFixture:name] decoder:@"dr_flac"];
        NSData *decoded = [self readToEnd:file];
        XCTAssertEqualObjects(decoded, Float32PCM([self wideSourcePCM:[self fixture:sources[name]]]), @"%@", name);
        [self assertSeeksOf:file match:decoded block:4096 name:name];
    }
    NSMutableData *unknown = [NSMutableData dataWithContentsOfURL:[self fixture:@"flac-zero-residual.flac"]];
    [self clearLengthOfFLAC:unknown];
    NSData *source = Float32PCM([self wideSourcePCM:[self fixture:@"noise-48000-24-2.wav"]]);
    NSUInteger frames = source.length / sizeof(float) / 2;
    NSURL *unknownURL = [self writeBytes:unknown name:@"unknown-length.flac"];
    [unknown increaseLengthBy:1 << 20];
    for (NSURL *url in @[unknownURL, [self writeBytes:unknown name:@"unknown-length-reserved.flac"]]) {
        NSString *name = url.lastPathComponent;
        AudioFileHandle *file = [self open:url decoder:@"dr_flac"];
        XCTAssertEqual(file.length, (AVAudioFramePosition)frames, @"%@", name);
        NSData *decoded = [self readToEnd:file];
        XCTAssertEqualObjects(decoded, source, @"%@", name);
        [self assertSeeksOf:file match:decoded block:4096 name:name];
        [self assertSeekOf:file to:frames + 5000 match:decoded name:[name stringByAppendingString:@", past the end"]];
    }
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    [self play:unknownURL paused:NO position:0];
    [self assertReference:source capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
}
// A seek from inside a FLAC frame to 2^32 frames or more past it, forward and
// back, lands at its target, where a 32-bit distance would wrap to a target
// inside the frame. flac-long.flac is 65538 FLAC frames of 65535, each the
// constant ((frame * 7919) & 0xFFFF) - 32768.
- (void)testDrFLACSeeksFurtherThanThirtyTwoBitsOfFrames {
    AudioFileHandle *file = [self open:[self fixture:@"flac-long.flac"] decoder:@"dr_flac"];
    XCTAssertEqual(file.length, (AVAudioFramePosition)65538 * 65535);
    AVAudioPCMBuffer *slice = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:32];
    XCTAssertTrue([file readIntoBuffer:slice error:NULL]);
    for (NSNumber *target in @[@(((AVAudioFramePosition)1 << 32) + 64), @64]) {
        XCTAssertTrue([file seekToFrame:target.longLongValue error:NULL]);
        XCTAssertTrue([file readIntoBuffer:slice error:NULL]);
        XCTAssertEqual(slice.frameLength, 32u);
        int64_t frame = target.longLongValue / 65535;
        XCTAssertEqual(slice.floatChannelData[0][0], (float)(((frame * 7919) & 0xFFFF) - 32768) / 32768, @"seek to %@", target);
    }
}
// What damages files in the wild, done to lossless.flac, Apple's encode: an
// ID3v2 tag in front, a seek table two frames stale and one with a garbage
// offset decode and seek as the clean file does. A damaged frame, one lost with
// its header, the first frame's header and bytes lost inside a frame are each
// silence in its place with every other frame where it was, as libFLAC does.
// A file cut short inside a frame ends at its last whole frame, and a seek past
// the cut lands at the end, as Apple's decode does.
- (void)testDrFLACSurvivesWhatDamagesFiles {
    self.continueAfterFailure = YES;
    NSURL *url = [self fixture:@"lossless.flac"];
    NSData *bytes = [NSData dataWithContentsOfURL:url];
    const uint8_t *b = bytes.bytes;
    // CoreAudio's parser serves a FLAC frame as a packet.
    NSArray<NSNumber *> *offsets = [self packetOffsetsOf:url];
    AudioFileHandle *clean = [self open:url decoder:@"dr_flac"];
    NSUInteger block = clean.fileFormat.streamDescription->mFramesPerPacket, k = offsets.count / 2;
    XCTAssertGreaterThan(offsets.count, 8u);
    XCTAssertEqual(b[offsets[k].unsignedIntegerValue], 0xFF, @"frame %lu is not at a sync code", (unsigned long)k);
    NSUInteger frameStart = offsets[k].unsignedIntegerValue, frameMiddle = (frameStart + offsets[k + 1].unsignedIntegerValue) / 2;
    NSData *reference = [self readToEnd:clean];
    NSUInteger channels = clean.processingFormat.channelCount, frameBytes = channels * sizeof(float);
    XCTAssertEqual(reference.length, (NSUInteger)clean.length * frameBytes);
    AudioFileHandle *interleaved = [[AudioFileHandle alloc] initForReading:url commonFormat:AVAudioPCMFormatFloat32 interleaved:YES error:NULL];
    XCTAssertEqualObjects([self readToEnd:interleaved], reference, @"interleaved, as the waveform reads");

    AudioFileHandle *(^open)(NSData *, NSString *) = ^AudioFileHandle *(NSData *stream, NSString *name) {
        return [self open:[self writeBytes:stream name:name] decoder:@"dr_flac"];
    };

    // An ID3v2 tag in front.
    static const uint8_t tag[] = {'I','D','3',4,0,0, 0,0,0,16, 'T','I','T','2', 0,0,0,6, 0,0, 3,'t','i','t','l','e'};
    NSMutableData *tagged = [NSMutableData dataWithBytes:tag length:sizeof(tag)];
    [tagged appendData:bytes];
    AudioFileHandle *file = open(tagged, @"id3.flac");
    XCTAssertEqualObjects([self readToEnd:file], reference, @"ID3v2 in front");
    [self assertSeeksOf:file match:reference block:block name:@"ID3v2 in front"];

    // A seek table after STREAMINFO, a point every third frame, each claiming the frame lead after the one it points at, and the
    // point at frame garbage offset to where no stream reaches.
    XCTAssertEqual(memcmp(b, "fLaC", 4), 0);
    XCTAssertEqual(b[4] & 0x7F, 0, @"STREAMINFO first");
    NSData *(^withSeekTable)(NSData *, NSUInteger, NSUInteger) = ^NSData *(NSData *stream, NSUInteger lead, NSUInteger garbage) {
        NSMutableData *table = [NSMutableData data];
        for (NSUInteger frame = 0; frame + 2 < offsets.count; frame += 3) {
            uint64_t sample = CFSwapInt64HostToBig((uint64_t)(frame + lead) * block);
            uint64_t offset = CFSwapInt64HostToBig(frame == garbage ? (uint64_t)1 << 62 : offsets[frame].unsignedLongLongValue - offsets[0].unsignedLongLongValue);
            uint16_t count = CFSwapInt16HostToBig((uint16_t)block);
            [table appendBytes:&sample length:8]; [table appendBytes:&offset length:8]; [table appendBytes:&count length:2];
        }
        NSMutableData *out = [NSMutableData dataWithBytes:stream.bytes length:42];
        ((uint8_t *)out.mutableBytes)[4] &= 0x7F;
        uint8_t header[4] = {(uint8_t)(3 | (b[4] & 0x80)), (uint8_t)(table.length >> 16), (uint8_t)(table.length >> 8), (uint8_t)table.length};
        [out appendBytes:header length:4];
        [out appendData:table];
        [out appendData:[stream subdataWithRange:NSMakeRange(42, stream.length - 42)]];
        return out;
    };
    file = open(withSeekTable(bytes, 2, NSNotFound), @"stale-seektable.flac");
    XCTAssertEqualObjects([self readToEnd:file], reference, @"stale seek table");
    [self assertSeeksOf:file match:reference block:block name:@"stale seek table"];
    // An exabyte offset has a seek step toward it 2 GB at a time: seconds of work, not these milliseconds.
    NSUInteger garbage = (k / 3 + 1) * 3;
    file = open(withSeekTable(bytes, 0, garbage), @"garbage-seekpoint.flac");
    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    [self assertSeeksOf:file match:reference block:block name:@"garbage seekpoint"];
    [self assertSeekOf:file to:(garbage + 1) * block + 7 match:reference name:@"garbage seekpoint"];
    XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 1.0, @"garbage seekpoint: seeks near the point take no longer than any other");

    // Damage, each alone: a damaged frame in the middle; the same frame's header wiped; the first frame's header wiped; bytes lost
    // inside a frame; and a damaged frame a seek point points at. Silence takes each damaged frame's place, and every other frame is
    // where it was. A seek into the one at a seek point decodes it where it is.
    void (^assertSilenced)(NSData *, NSUInteger, NSString *) = ^(NSData *stream, NSUInteger silent, NSString *name) {
        AudioFileHandle *damaged = open(stream, [name stringByAppendingString:@".flac"]);
        NSData *decoded = [self readToEnd:damaged];
        XCTAssertEqual(decoded.length, reference.length, @"%@: the timeline keeps its length", name);
        NSMutableData *expected = [reference mutableCopy];
        memset((uint8_t *)expected.mutableBytes + silent * block * frameBytes, 0, block * frameBytes);
        XCTAssertEqualObjects(decoded, expected, @"%@: silence in its place, every other frame where it was", name);
        [self assertSeeksOf:damaged match:decoded block:block name:name];
        [self assertSeekOf:damaged to:silent * block + block / 2 match:decoded name:name];
    };
    NSData *(^overwritten)(NSUInteger, uint8_t) = ^NSData *(NSUInteger at, uint8_t fill) {
        NSMutableData *damaged = [bytes mutableCopy];
        memset((uint8_t *)damaged.mutableBytes + at, fill, 16);
        return damaged;
    };
    NSMutableData *lost = [bytes mutableCopy];
    [lost replaceBytesInRange:NSMakeRange(frameMiddle, 64) withBytes:NULL length:0];
    NSUInteger atPoint = k / 3 * 3, pointMiddle = (offsets[atPoint].unsignedIntegerValue + offsets[atPoint + 1].unsignedIntegerValue) / 2;
    assertSilenced(overwritten(frameMiddle, 0x55), k, @"damaged frame");
    assertSilenced(overwritten(frameStart, 0x00), k, @"damaged header");
    assertSilenced(overwritten(offsets[0].unsignedIntegerValue, 0x00), 0, @"damaged first header");
    assertSilenced(lost, k, @"lost bytes");
    assertSilenced(withSeekTable(overwritten(pointMiddle, 0x55), 0, NSNotFound), atPoint, @"damaged frame at a seek point");

    // A download cut short inside that frame, at points across it, which ends at its last whole frame: a seek past the cut lands at
    // the end, and after reading there, a seek back reads the frames before the cut.
    NSUInteger frameEnd = offsets[k + 1].unsignedIntegerValue;
    NSData *whole = [reference subdataWithRange:NSMakeRange(0, k * block * frameBytes)];
    for (NSUInteger cut = frameStart + 1; cut < frameEnd; cut += (frameEnd - frameStart) / 37 + 1) {
        NSString *name = [NSString stringWithFormat:@"cut at %lu", (unsigned long)cut];
        file = open([bytes subdataWithRange:NSMakeRange(0, cut)], @"cut.flac");
        XCTAssertEqualObjects([self readToEnd:file], whole, @"%@ ends at the last whole frame", name);
        [self assertSeekOf:file to:(k - 1) * block + block / 2 match:whole name:name];
    }
    file = open([bytes subdataWithRange:NSMakeRange(0, frameMiddle)], @"cut.flac");
    [self assertSeekOf:file to:(k + 2) * block match:whole name:@"cut, past the end"];
    [self assertSeekOf:file to:(k - 1) * block match:whole name:@"cut, after the end"];

    // A STREAMINFO allowing no block has no frame dr_flac could play, and is left to Apple's decoder at once, never searched for a length.
    NSMutableData *noBlocks = [bytes mutableCopy];
    [self clearLengthOfFLAC:noBlocks];
    memset((uint8_t *)noBlocks.mutableBytes + 8 + 2, 0, 2);
    AudioFileHandle *refused = [[AudioFileHandle alloc] initForReading:[self writeBytes:noBlocks name:@"no-blocks.flac"] error:NULL];
    XCTAssertFalse([refused.decoderName isEqualToString:@"dr_flac"], @"no blocks");

    // A file of unknown length, as a streamed encode leaves it, with a stray 8-channel frame header past its last frame: the length found
    // ends at the last frame, and after reading to the end, a seek back reads the last frame.
    static const uint8_t stray[16] = {0xFF, 0xF8, 0xC9, 0x78, 0x05, 0x00};
    NSMutableData *trailing = [bytes mutableCopy];
    [self clearLengthOfFLAC:trailing];
    [trailing appendBytes:stray length:sizeof(stray)];
    file = open(trailing, @"trailing-header.flac");
    XCTAssertEqual(file.length, clean.length);
    XCTAssertEqualObjects([self readToEnd:file], reference, @"stray header past the end");
    [self assertSeekOf:file to:reference.length / frameBytes - 100 match:reference name:@"stray header past the end, after the end"];
}
// Apple's decode of a file, through AVAudioFile rather than the handle, interleaved.
- (NSData *)appleDecodeOf:(NSURL *)url {
    NSError *error = nil;
    AVAudioPCMBuffer *whole = VibeReadWithAVAudioFile(url, &error);
    XCTAssertNotNil(whole, @"%@: %@", url.lastPathComponent, error);
    return PCM(whole);
}
// dr_wav decodes every coding a WAV or an AIFF(-C) holds as Apple's decoder
// does, and every seek reads what the continuous decode holds there. An MS
// ADPCM stream ends at its fact chunk's count, short of the last block's padding
// Apple plays. An ima4 packet's decode depends on every packet before it, and
// its seeks still land where a read from the start does, where Apple's do not.
// A WAV holding MPEG goes to dr_mp3, or to Apple's decoder when it is chosen.
- (void)testDrWAVDecodesAsAppleDoes {
    self.continueAfterFailure = YES;
    NSArray<NSString *> *names = @[@"noise-44100-16-1.wav", @"noise-96000-24-2.wav", @"noise-48000-32-2.wav", @"noise-48000-24-8.wav",
        @"integer32.wav", @"float64-low-bits.wav", @"alias.bwf", @"lossless.aiff", @"aiff-BEI8.aif",
        @"wav-UI8.wav", @"wav-ulaw.wav", @"wav-alaw.wav", @"aifc-BEI8.aif", @"aifc-BEI16.aif", @"aifc-BEI24.aif", @"aifc-BEI32.aif",
        @"aifc-BEF32.aif", @"aifc-BEF64.aif", @"aifc-ulaw.aif", @"aifc-alaw.aif", @"aifc-ima4.aif", @"aifc-ima4-mono.aif",
        @"wav-ima-adpcm.wav", @"wav-ms-adpcm.wav"];
    for (NSString *name in names) {
        NSURL *url = [name containsString:@"adpcm"] ? [self optionalFixture:name] : [self fixture:name];
        AudioFileHandle *file = [self open:url decoder:@"dr_wav"];
        NSData *decoded = [self readToEnd:file], *apple = [self appleDecodeOf:url];
        NSUInteger frameBytes = file.processingFormat.channelCount * sizeof(float);
        XCTAssertEqual(decoded.length, (NSUInteger)file.length * frameBytes, @"%@", name);
        if ([name isEqualToString:@"wav-ms-adpcm.wav"]) {
            XCTAssertLessThan(decoded.length, apple.length, @"%@ ends at its fact count", name);
            apple = [apple subdataWithRange:NSMakeRange(0, decoded.length)];
        }
        XCTAssertEqualObjects(decoded, apple, @"%@", name);
        [self assertSeeksOf:file match:decoded block:[name containsString:@"ima4"] ? 64 : 4096 name:name];
    }
    AudioFileHandle *interleaved = [[AudioFileHandle alloc] initForReading:[self fixture:@"lossless.aiff"] commonFormat:AVAudioPCMFormatFloat32 interleaved:YES error:NULL];
    XCTAssertEqualObjects([self readToEnd:interleaved], [self appleDecodeOf:[self fixture:@"lossless.aiff"]], @"interleaved, as the waveform reads");
    NSURL *mpeg = [self optionalFixture:@"mp3-in.wav"];
    [self open:mpeg decoder:@"dr_mp3"];
    AudioFileHandle.appleMPEGDecoder = YES;
    [self open:mpeg decoder:@"apple"];
}
// The body of a RIFF or IFF file's first chunk of that ID.
- (NSRange)chunk:(const char *)name of:(NSData *)file bigEndian:(BOOL)bigEndian {
    const uint8_t *b = file.bytes;
    for (NSUInteger at = 12; at + 8 <= file.length;) {
        uint32_t size = *(const uint32_t *)(b + at + 4);
        size = bigEndian ? CFSwapInt32BigToHost(size) : CFSwapInt32LittleToHost(size);
        if (memcmp(b + at, name, 4) == 0) return NSMakeRange(at + 8, size);
        at += 8 + size + (size & 1);
    }
    XCTFail(@"no %s chunk", name);
    return NSMakeRange(0, 0);
}
// Sets a RIFF or FORM file's size field to what follows it.
- (void)setContainerSizeOf:(NSMutableData *)file bigEndian:(BOOL)bigEndian {
    uint32_t size = bigEndian ? CFSwapInt32HostToBig((uint32_t)file.length - 8) : CFSwapInt32HostToLittle((uint32_t)file.length - 8);
    [file replaceBytesInRange:NSMakeRange(4, 4) withBytes:&size];
}
// What damages WAVs and AIFFs in the wild, done to lossless.aiff and
// noise-48000-24-2.wav. A chunk after the audio, as Ableton Live writes its
// tags, leaves every seek where a read from the start is: dr_wav upstream took
// SSND's offset and block size fields for audio, and landed forward seeks late.
// A file cut short plays what it holds, and a COMM count past it or a data
// size of 0xFFFFFFFF, as a recording never finalized leaves it, is capped at
// it. A fmt chunk after the data is found. A damaged ADPCM block is silence in
// its place, every other frame where it was.
- (void)testDrWAVSurvivesWhatDamagesFiles {
    self.continueAfterFailure = YES;
    NSData *aiff = [NSData dataWithContentsOfURL:[self fixture:@"lossless.aiff"]];
    AudioFileHandle *clean = [self open:[self fixture:@"lossless.aiff"] decoder:@"dr_wav"];
    NSData *reference = [self readToEnd:clean];
    NSUInteger frameBytes = clean.processingFormat.channelCount * sizeof(float), frames = reference.length / frameBytes;
    AudioFileHandle *(^open)(NSData *, NSString *) = ^AudioFileHandle *(NSData *stream, NSString *name) {
        return [self open:[self writeBytes:stream name:name] decoder:@"dr_wav"];
    };

    static const uint8_t id3[] = {'I','D','3',' ', 0,0,0,10, 'I','D','3',4,0,0, 0,0,0,0};
    NSMutableData *tagged = [aiff mutableCopy];
    [tagged appendBytes:id3 length:sizeof(id3)];
    [self setContainerSizeOf:tagged bigEndian:YES];
    AudioFileHandle *file = open(tagged, @"tagged.aif");
    XCTAssertEqualObjects([self readToEnd:file], reference, @"a chunk after SSND");
    [self assertSeeksOf:file match:reference block:4096 name:@"a chunk after SSND"];

    NSRange ssnd = [self chunk:"SSND" of:aiff bigEndian:YES];
    NSUInteger audio = ssnd.location + 8, held = frames * 3 / 5, sampleBytes = 3 * clean.processingFormat.channelCount;
    NSData *cut = [aiff subdataWithRange:NSMakeRange(0, audio + held * sampleBytes + 2)];
    file = open(cut, @"cut.aif");
    XCTAssertEqual(file.length, (AVAudioFramePosition)held, @"cut short: the frames it holds");
    NSData *prefix = [reference subdataWithRange:NSMakeRange(0, held * frameBytes)];
    XCTAssertEqualObjects([self readToEnd:file], prefix, @"cut short");
    [self assertSeeksOf:file match:prefix block:4096 name:@"cut short"];
    [self assertSeekOf:file to:frames - 10 match:prefix name:@"cut short, past the cut"];

    NSMutableData *counted = [aiff mutableCopy];
    NSRange comm = [self chunk:"COMM" of:aiff bigEndian:YES];
    uint32_t count = CFSwapInt32HostToBig((uint32_t)frames * 2);
    [counted replaceBytesInRange:NSMakeRange(comm.location + 2, 4) withBytes:&count];
    file = open(counted, @"counted.aif");
    XCTAssertEqual(file.length, (AVAudioFramePosition)frames, @"a COMM count past the audio");
    XCTAssertEqualObjects([self readToEnd:file], reference, @"a COMM count past the audio");

    NSURL *waveURL = [self fixture:@"noise-48000-24-2.wav"];
    NSData *wave = [NSData dataWithContentsOfURL:waveURL], *waveReference = [self readToEnd:[self open:waveURL decoder:@"dr_wav"]];
    NSRange data = [self chunk:"data" of:wave bigEndian:NO], fmt = [self chunk:"fmt " of:wave bigEndian:NO];
    NSMutableData *unfinalized = [wave mutableCopy];
    uint32_t placeholder = 0xFFFFFFFF;
    [unfinalized replaceBytesInRange:NSMakeRange(4, 4) withBytes:&placeholder];
    [unfinalized replaceBytesInRange:NSMakeRange(data.location - 4, 4) withBytes:&placeholder];
    XCTAssertEqualObjects([self readToEnd:open(unfinalized, @"unfinalized.wav")], waveReference, @"sizes of 0xFFFFFFFF");
    NSMutableData *fmtLast = [[wave subdataWithRange:NSMakeRange(0, 12)] mutableCopy];
    [fmtLast appendData:[wave subdataWithRange:NSMakeRange(data.location - 8, data.length + 8)]];
    [fmtLast appendData:[wave subdataWithRange:NSMakeRange(fmt.location - 8, fmt.length + 8)]];
    [self setContainerSizeOf:fmtLast bigEndian:NO];
    XCTAssertEqualObjects([self readToEnd:open(fmtLast, @"fmt-last.wav")], waveReference, @"fmt after the data");

    NSURL *imaURL = [self optionalFixture:@"wav-ima-adpcm.wav"];
    NSData *ima = [NSData dataWithContentsOfURL:imaURL];
    AudioFileHandle *imaClean = [self open:imaURL decoder:@"dr_wav"];
    NSData *imaReference = [self readToEnd:imaClean];
    NSRange imaData = [self chunk:"data" of:ima bigEndian:NO], imaFmt = [self chunk:"fmt " of:ima bigEndian:NO];
    uint16_t blockAlign = CFSwapInt16LittleToHost(*(const uint16_t *)((const uint8_t *)ima.bytes + imaFmt.location + 12));
    NSUInteger channels = imaClean.processingFormat.channelCount, blockFrames = (blockAlign - 4 * channels) * 2 / channels + 1, damagedBlock = 3;
    NSMutableData *damaged = [ima mutableCopy];
    for (NSUInteger c = 0; c < channels; c++) {
        ((uint8_t *)damaged.mutableBytes)[imaData.location + damagedBlock * blockAlign + 4 * c + 2] = 0xFF; // a step index past 88
    }
    file = open(damaged, @"damaged-block.wav");
    NSData *decoded = [self readToEnd:file];
    XCTAssertEqual(decoded.length, imaReference.length, @"a damaged ADPCM block: the timeline keeps its length");
    NSMutableData *expected = [imaReference mutableCopy];
    memset((uint8_t *)expected.mutableBytes + damagedBlock * blockFrames * channels * sizeof(float), 0, blockFrames * channels * sizeof(float));
    XCTAssertEqualObjects(decoded, expected, @"a damaged ADPCM block: silence in its place, every other frame where it was");
    [self assertSeeksOf:file match:decoded block:blockFrames name:@"a damaged ADPCM block"];
}
- (void)testQuickTimeAudio { [self checkLossy:@"lossy.qta" tolerance:kVibeAACDecodeTolerance]; }
- (void)testFloatLimitsAndSilence {
    for (NSString *name in @[@"limits.wav",@"silence.wav"]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        AVAudioPCMBuffer *source=[self read:[self fixture:name]];
        [self play:[self fixture:name] paused:NO position:0];
        NSData *capture=[self renderSeconds:source.frameLength/_rate+0.1];
        if ([name isEqual:@"silence.wav"]) XCTAssertEqual(RMS(capture,2,0,NSMakeRange(0,capture.length/8)),0);
        else [self assertReference:PCM(source) capture:capture skip:[self startupSkip] tolerance:0];
        [self assertFinite:capture peak:1];
    }
}
// A 32-bit file on float32's grid plays exactly. Integer32 and float64 samples
// finer than float32's significand arrive rounded once to the nearest float32,
// and the wide comparison counts every one: the loss the report calls
// DepthInsufficient, visible to the oracle rather than shared by its reference.
- (void)testWideSourcesArriveRoundedOnceToFloat32 {
    for (NSString *name in @[@"integer32.wav",@"integer32-low-bits.wav",@"float64-low-bits.wav"]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        NSURL *url=[self fixture:name];
        NSData *wide=[self wideSourcePCM:url], *rounded=Float32PCM(wide);
        [self play:url paused:NO position:0];
        NSData *capture=[self renderSeconds:wide.length/sizeof(double)/2/_rate+0.1];
        [self assertReference:rounded capture:capture skip:[self startupSkip] tolerance:0];
        NSUInteger aligned=[ComparePCM(rounded,capture,2,[self startupSkip],0)[@"aligned"] unsignedIntegerValue];
        NSDictionary *full=CompareWidePCM(wide,capture,2,aligned,[self startupSkip]);
        NSUInteger mismatched=[full[@"mismatchedSamples"] unsignedIntegerValue], compared=[full[@"comparedSamples"] unsignedIntegerValue];
        if ([name isEqual:@"integer32.wav"]) XCTAssertEqual(mismatched,0u,@"%@",full);
        else XCTAssertGreaterThan(mismatched,compared/2,@"%@: %@",name,full);
    }
}

@end

// Transport edges, declick, gapless handoffs and successor cancellation.
@interface AudioPlayerRenderTransportTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderTransportTests

- (void)testBitPerfectTransportCutsWithoutChangingSamples {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    _player.crossfadeMilliseconds = 2000; // bit-perfect output ignores it
    _player.declick = NO; // the cut rule; the default, which ramps, is the next test
    NSURL *first = [self fixture:@"noise-48000-24-2.wav"], *second = [self fixture:@"noise-48000-16-2.wav"];
    NSArray *references = @[PCM([self read:first]), PCM([self read:second])];
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
    NSArray *references = @[PCM([self read:first]), PCM([self read:second])];
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
    NSArray *references = @[PCM([self read:first]), PCM([self read:second])];
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
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=PCM([self read:url]);
    [self play:url paused:NO position:0]; [self render:24000];
    [_player pause]; [self render:2048]; XCTAssertTrue(_player.isPaused);
    double position=_player.position; NSUInteger sourceFrame=(NSUInteger)llround(position*_rate);
    NSData *silence=[self renderSeconds:6.1];
    XCTAssertEqual(RMS(silence,2,0,NSMakeRange(0,silence.length/8)),0);
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
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=PCM([self read:url]);
    for (NSNumber *block in @[@63,@256,@1024,@4096]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO]; _blockSize=block.unsignedIntegerValue;
        AudioTrack *track=[self play:url paused:NO position:0]; [self render:12000];
        [_player stop]; [self render:2048]; XCTAssertTrue(_player.isStopped);
        XCTAssertNil(_player.currentTrack); XCTAssertEqual([self count:@"finish"],0u);
        NSData *silence=[self renderSeconds:0.1]; XCTAssertEqual(RMS(silence,2,0,NSMakeRange(0,4800)),0);
        NSUInteger starts=[self count:@"start"]; [_player play:track];
        [self settleUntil:^BOOL { return [self count:@"start"]>starts; }];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
        [self settleUntil:^BOOL { return [self count:@"finish"] == 1; }];
    }
}
- (void)testSeekPlayingPausedAndNearEnd {
    for (NSNumber *paused in @[@NO,@YES]) for (NSNumber *target in @[@0.125,@1.5,@1.95]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=PCM([self read:url]);
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
    NSData *whole = [PCM([self read:[self fixture:@"noise-44100-24-2.wav"]]) subdataWithRange:NSMakeRange(0, 44100 * 8)];
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
    SEL selector = @selector(initForReading:commonFormat:interleaved:error:);
    Method initializer = class_getInstanceMethod(AudioFileHandle.class, selector);
    __block IMP original;
    IMP holding = imp_implementationWithBlock(^id(id receiver, NSURL *url, AVAudioCommonFormat format, BOOL interleaved, NSError **error) {
        id handle = ((id (*)(id, SEL, NSURL *, AVAudioCommonFormat, BOOL, NSError **))original)(receiver, selector, url, format, interleaved, error);
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
    SEL selector = @selector(initForReading:commonFormat:interleaved:error:);
    Method initializer = class_getInstanceMethod(AudioFileHandle.class, selector);
    __block IMP original;
    IMP holding = imp_implementationWithBlock(^id(id receiver, NSURL *url, AVAudioCommonFormat format, BOOL interleaved, NSError **error) {
        id handle = ((id (*)(id, SEL, NSURL *, AVAudioCommonFormat, BOOL, NSError **))original)(receiver, selector, url, format, interleaved, error);
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
        XCTAssertGreaterThan(RMS(capture, 2, 0, NSMakeRange(4800, 12000)), 0.05, @"%@", url.lastPathComponent);
        XCTAssertGreaterThan(RMS(capture, 2, 1, NSMakeRange(4800, 12000)), 0.05, @"%@", url.lastPathComponent);
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
        XCTAssertGreaterThan(RMS(capture, 2, 0, NSMakeRange(4800, 12000)), 0.05, @"bit-perfect %@", bitPerfect);
        XCTAssertGreaterThan(RMS(capture, 2, 1, NSMakeRange(4800, 12000)), 0.05, @"bit-perfect %@", bitPerfect);
    }
}

- (void)testGaplessSplitSignalAcrossRenderBlocks {
    NSData *reference=PCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
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
- (void)testGaplessShortSuccessorAndFormatMismatch {
    NSData *reference=PCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
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
        XCTAssertLessThan(ToneAmplitude(_capture,2,0,48000,1000,NSMakeRange(48000,48000)),0.01);
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
    XCTAssertLessThan(ToneAmplitude(tail, 2, 0, 48000, 1000, NSMakeRange(36000, 24000)), 0.01,
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
    __block IMP originalProduce;
    __block _Atomic(BOOL) held = NO;
    IMP blocked = imp_implementationWithBlock(^uint32_t(id receiver, NSUInteger slot, BOOL *final) {
        if (receiver == bus && slot == 0 && [bus snapshotOfVoice:old].boundary == 12000 && !atomic_exchange(&held, YES)) {
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
        }
        return ((uint32_t (*)(id, SEL, NSUInteger, BOOL *))originalProduce)(receiver, @selector(produceChunkForSlot:final:), slot, final);
    });
    originalProduce = method_setImplementation(produce, blocked);
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
        method_setImplementation(produce, originalProduce);
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
    __block IMP originalProduce, originalRetire;
    __block _Atomic(BOOL) heldRead = NO; // the decoder writes it, the render loop below polls it
    __block BOOL heldRetire = NO;
    IMP heldProduce = imp_implementationWithBlock(^uint32_t(id receiver, NSUInteger slot, BOOL *final) {
        if (receiver == bus && !heldRead) {
            heldRead = YES;
            dispatch_semaphore_signal(reading);
            dispatch_semaphore_wait(letRead, DISPATCH_TIME_FOREVER);
        }
        return ((uint32_t (*)(id, SEL, NSUInteger, BOOL *))originalProduce)(receiver, @selector(produceChunkForSlot:final:), slot, final);
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
    originalProduce = method_setImplementation(produce, heldProduce);
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
        NSData *whole = PCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
        NSData *expected = [whole subdataWithRange:NSMakeRange(24000 * 8, 16384 * 8)];
        NSDictionary *comparison = ComparePCM(expected, _capture, 2, 0, 0);
        XCTAssertTrue([comparison[@"pass"] boolValue], @"seek output differs: %@", comparison);
    } @finally {
        dispatch_semaphore_signal(letRead);
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        [bus stopReadingThen:^{ dispatch_semaphore_signal(stopped); }];
        dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC)); // the swizzled read must be over before its IMP goes
        method_setImplementation(produce, originalProduce);
        method_setImplementation(retire, originalRetire);
        imp_removeBlock(heldProduce);
        imp_removeBlock(heldRetirement);
    }
}

@end

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
        NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=PCM([self read:url]);
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
        XCTAssertFalse([tap pollSignalDiagnostics:request]);
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
        XCTAssertFalse([tap pollSignalDiagnostics:request]);
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
            XCTAssertFalse([tap pollSignalDiagnostics:request]);
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
        // Under the pump the output cannot follow the file's rate, so a
        // bit-perfect cut at another rate carries a few milliseconds of the old
        // track past the cut in the converter's history. Real bit-perfect
        // output sets the device to the file's rate; test only that case.
        if (!fx.boolValue && rate.doubleValue != 48000) continue;
        [self startPlayerAt:rate.doubleValue channels:2 fx:fx.boolValue bitPerfect:!fx.boolValue automatic:NO];
        _player.crossfadeMilliseconds = fade.integerValue;
        _player.declick = fx.boolValue; // the bit-perfect case is the cut, which nothing overlaps
        _player.levelsEnabled=YES;
        [self play:[self fixture:@"1000.wav"] paused:NO position:0];
        [self render:12123];
        AudioTrack *next = [AudioTrack withURL:[self fixture:[NSString stringWithFormat:@"quiet-intro-%@.wav", silence]]];
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
    AudioTrack *next = [AudioTrack withURL:[self fixture:@"quiet-intro-700.wav"]];
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

// FX, pitch and SRC quality, stuck renders, routing, device switches, and transport under stress.
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
        double gain=RMS(cut,2,0,NSMakeRange(12000,12000))/RMS(dry,2,0,NSMakeRange(12000,12000));
        if ([tone isEqual:@"20.wav"]) XCTAssertLessThan(gain,0.02);
        if ([tone isEqual:@"8000.wav"]) XCTAssertEqualWithAccuracy(gain,1,0.02);
        _player.fx.lowKillBoostActive=YES; NSData *boost=[self renderSeconds:0.5];
        if ([tone isEqual:@"100.wav"]) XCTAssertLessThan(RMS(boost,2,0,NSMakeRange(12000,12000)),RMS(cut,2,0,NSMakeRange(12000,12000)));
        _player.fx.lowKillEnabled=NO; [self renderSeconds:0.5]; XCTAssertFalse(_player.fx.lowKillBoostActive);
        NSData *restored=[self renderSeconds:0.5];
        XCTAssertEqualWithAccuracy(RMS(restored,2,0,NSMakeRange(0,24000)),RMS(dry,2,0,NSMakeRange(12000,12000)),0.00001);
    }
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=PCM([self read:url]);
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
    NSData *reference = PCM([self read:url]);
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
        double left=RMS(output,2,0,NSMakeRange(impulse+tap,256));
        double right=RMS(output,2,1,NSMakeRange(impulse+tap,256));
        XCTAssertGreaterThan(left,right*1.9); XCTAssertGreaterThan(left,0.00001);
        XCTAssertGreaterThan(RMS(output,2,1,NSMakeRange(impulse+2*tap,256)),RMS(output,2,0,NSMakeRange(impulse+2*tap,256))*1.9);
        XCTAssertLessThan(RMS(output,2,0,NSMakeRange(impulse+5*tap,256)),left);
        _player.fx.delaySendEnabled=NO; _player.fx.shortDelaySendEnabled=NO;
        NSData *tail=[self renderSeconds:4]; [self assertFinite:tail peak:1];
        XCTAssertLessThan(RMS(tail,2,0,NSMakeRange(3*48000,48000)),0.0001);
    }
}
- (void)testReverbTailAndRapidFXChanges {
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    _player.fx.reverbSendEnabled=YES; [self play:[self fixture:@"impulse.wav"] paused:NO position:0];
    NSData *first=[self renderSeconds:0.6];
    _player.fx.reverbSendEnabled=NO; NSData *tail=[self renderSeconds:5];
    XCTAssertGreaterThan(RMS(first,2,0,NSMakeRange(24000,4800)),0.000001);
    XCTAssertGreaterThan(RMS(tail,2,0,NSMakeRange(0,4800)),0.000001);
    XCTAssertLessThan(RMS(tail,2,0,NSMakeRange(4*48000,48000)),RMS(tail,2,0,NSMakeRange(0,48000)));
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
        XCTAssertEqualWithAccuracy(ToneAmplitude(data,2,0,48000,1000*ratio,NSMakeRange(12000,24000)),0.25,0.002);
        XCTAssertEqualWithAccuracy(_player.position,ratio,0.02);
        [self render:(NSUInteger)(48000*(4/ratio-1+0.1))];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u);
    }
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"1000.wav"] paused:NO position:0];
    _player.pitch=4;
    NSData *shifted=[self renderSeconds:0.5];
    XCTAssertEqualWithAccuracy(ToneAmplitude(shifted,2,0,48000,1040,NSMakeRange(12000,12000)),0.25,0.002);
    _player.pitch=0;
    NSData *restored=[self renderSeconds:0.5];
    XCTAssertEqualWithAccuracy(ToneAmplitude(restored,2,0,48000,1000,NSMakeRange(12000,12000)),0.25,0.002);
    // Back at zero the unit leaves the chain: it renders no more.
    uint64_t renders=[_player.debugRenderCounts[@"varispeedRenders"] unsignedLongLongValue];
    [self render:24000];
    XCTAssertEqual([_player.debugRenderCounts[@"varispeedRenders"] unsignedLongLongValue],renders);
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; [self play:url paused:NO position:0];
    [self assertReference:PCM([self read:url]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
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
        double amplitude=ToneAmplitude(data,2,0,_rate,1000,window);
        XCTAssertLessThan(fabs(20*log10(amplitude/0.25)),0.01);
        XCTAssertEqualWithAccuracy(_player.position,1,0.02);
        double signal=amplitude/sqrt(2), rms=RMS(data,2,0,window);
        XCTAssertLessThan(fabs(rms-signal),0.00001);
        [self render:(NSUInteger)(_rate*3.1)];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u);
        [self startPlayerAt:rate.doubleValue channels:2 fx:NO bitPerfect:YES automatic:NO];
        [self play:[self fixture:@"23000.wav"] paused:NO position:0]; data=[self renderSeconds:1];
        if (_rate<48000) XCTAssertLessThan(RMS(data,2,0,window),0.000032); // -90 dBFS alias ceiling
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
        [self assertReference:PCM([self read:url]) capture:[self renderSeconds:2.1]
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
            [self assertReference:PCM([self read:[self fixture:@"noise-44100-16-2.wav"]])
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
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getClassMethod(CoreAudioUtil.class, @selector(readSystemDefaultOutputDeviceID:)),
        class_getInstanceMethod(AudioPlayer.class, @selector(setOutputUnitDevice:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *device) { *device = 1; return YES; }),
        imp_implementationWithBlock(^BOOL(id player, AudioDeviceID device) { return NO; }),
    };
    IMP originals[4];
    for (NSUInteger i = 0; i < 4; i++) originals[i] = method_setImplementation(methods[i], replacements[i]);
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
            [self assertReference:PCM([self read:url]) capture:[self renderSeconds:2.1]
                             skip:[self startupSkip] tolerance:0];
        }
        }
    } @finally {
        [_player debugShutdown]; _player = nil;
        for (NSUInteger i = 0; i < 4; i++) {
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
    XCTAssertGreaterThan(RMS(wet, 2, 0, NSMakeRange(24000, 4800)), 0.000001);
    [_player setBitPerfectOutput:YES exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
    [self render:2048];
    [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
    NSData *dry = [self renderSeconds:1];
    XCTAssertFalse(_player.fx.reverbSendEnabled);
    XCTAssertFalse(_player.fx.delaySendEnabled);
    XCTAssertFalse(_player.fx.shortDelaySendEnabled);
    XCTAssertEqual(RMS(dry, 2, 0, NSMakeRange(0, dry.length / 8)), 0);
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
        dispatch_queue_t queue = [_player valueForKey:@"queue"];
        dispatch_suspend(queue);
        @try {
            [_player setBitPerfectOutput:bitPerfect.boolValue exclusiveOutput:NO enableFX:bitPerfect.boolValue allowAnyDevice:NO];
            XCTAssertFalse(_player.fx.lowKillEnabled);
            XCTAssertFalse(_player.fx.lowKillBoostActive);
            XCTAssertFalse(_player.fx.reverbSendEnabled);
            XCTAssertFalse(_player.fx.delaySendEnabled);
            XCTAssertFalse(_player.fx.shortDelaySendEnabled);
            [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
            _player.fx.lowKillEnabled = YES;
            _player.fx.lowKillBoostActive = YES;
            _player.fx.reverbSendEnabled = YES;
            _player.fx.delaySendEnabled = YES;
            _player.fx.shortDelaySendEnabled = YES;
        }
        @finally {
            dispatch_resume(queue);
        }
        XCTAssertTrue([_player.debugRenderCounts[@"fxConnected"] boolValue]);
        XCTAssertTrue(_player.fx.lowKillEnabled);
        XCTAssertTrue(_player.fx.lowKillBoostActive);
        XCTAssertTrue(_player.fx.reverbSendEnabled);
        XCTAssertTrue(_player.fx.delaySendEnabled);
        XCTAssertTrue(_player.fx.shortDelaySendEnabled);
        [self play:[self fixture:@"impulse.wav"] paused:NO position:0];
        NSData *wet = [self renderSeconds:0.6];
        XCTAssertGreaterThan(RMS(wet, 2, 0, NSMakeRange(24000, 4800)), 0.000001);
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
        XCTAssertGreaterThan(RMS([self renderSeconds:0.1],2,0,NSMakeRange(960,3840)),0.1);
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
        double amplitude=ToneAmplitude(data,2,0,_rate,1000,window);
        XCTAssertLessThan(fabs(20*log10(amplitude/0.25)),0.01);
        XCTAssertEqualWithAccuracy(_player.position,1,0.02);
        double signal=amplitude/sqrt(2), rms=RMS(data,2,0,window);
        XCTAssertLessThan(fabs(rms-signal),0.00001);
        [self render:(NSUInteger)(_rate*3.1)];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u);
        [self startPlayerAt:rate.doubleValue channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:[self fixture:@"23000.wav"] paused:NO position:0]; data=[self renderSeconds:1];
        if (_rate<48000) XCTAssertLessThan(RMS(data,2,0,window),0.000032); // -90 dBFS alias ceiling
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
    NSData *noise=PCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
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
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"]; NSData *reference=PCM([self read:url]);
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
    XCTAssertEqual(RMS(starved,2,0,NSMakeRange(held-24000,96000-held)),0);
    [_player debugStarveDecoder:NO];
    NSData *resumed=[self renderSeconds:(double)(sourceFrames-held)/_rate+0.1];
    [self assertReference:[reference subdataWithRange:NSMakeRange(held*8,(sourceFrames-held)*8)]
                  capture:resumed skip:0 tolerance:0];
    [self settleUntil:^BOOL { return [self count:@"finish"]==1; }];
}
- (void)testRealTimerPumpAndFade {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:YES];
    NSMutableData *captured=[NSMutableData data];
    [_player debugSetCapture:^(AVAudioPCMBuffer *buffer) { [captured appendData:PCM(buffer)]; }];
    [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
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
        XCTAssertEqual(RMS(paused,2,0,NSMakeRange(2400,2400)),0);
        XCTAssertEqual(RMS(paused,2,1,NSMakeRange(2400,2400)),0);
        XCTAssertEqual([self count:@"finish"],0u);
    }
}
- (void)testTruncatedPCMAndBoundaryLengths {
    NSURL *source=[self fixture:@"noise-48000-24-2.wav"];
    NSData *reference=PCM([self read:source]);
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
    if (!_playError) { [self renderSeconds:2.1]; XCTAssertTrue(_player.isStopped); XCTAssertEqual([self count:@"finish"],1u); }
    _playError=nil; [self play:source paused:NO position:0];
    [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
}
- (void)testPausedLoadStaysSilentAndPendingCommandsSettle {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
    NSURL *url=[self fixture:@"noise-48000-24-2.wav"];
    [self play:url paused:YES position:0.25];
    XCTAssertEqual(RMS([self renderSeconds:0.1],2,0,NSMakeRange(0,4800)),0);
    XCTAssertTrue(_player.isPaused);
    [_player resume]; [_player pause]; [_player resume]; [self render:4096];
    XCTAssertTrue(_player.isPlaying); XCTAssertEqual([self count:@"finish"],0u);
    [_player stop]; [_player play:[AudioTrack withURL:url]]; [_player stop]; [self render:2048];
    [self settleUntil:^BOOL { return self->_player.isStopped; }];
    XCTAssertEqual(RMS([self renderSeconds:0.1],2,0,NSMakeRange(0,4800)),0);
}

@end

// Saved, fallback and launch devices, and the modes carried between them.
@interface AudioPlayerRenderDeviceTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderDeviceTests

- (void)testSavedDeviceFailureDoesNotReenter {
    AudioDevice *device = [[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"saved" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[device]; } retryScheduler:nil];
    (void)devices.outputDevices;
    __block NSUInteger binds = 0;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getInstanceMethod(AudioPlayer.class, @selector(setOutputUnitDevice:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(AudioPlayer *player, AudioDeviceID deviceID) {
            binds++;
            if (binds == 4) {
                [player setValue:nil forKey:@"pendingSavedDeviceUID"];
                [player setValue:nil forKey:@"pendingSavedDeviceName"];
            }
            return NO;
        }),
    };
    IMP originals[3];
    for (NSUInteger i=0;i<3;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"saved" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"pendingSavedDeviceName"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
        }];
        XCTAssertEqual(binds, 1u, @"a refused saved-device bind is tried once: the guard held across it keeps the reset to Stopped from resolving again (the stub ends a regression at four)");
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testFallbackSurvivesDefaultChange {
    AudioDevice *device = [[AudioDevice alloc] initWithName:@"Speakers" uid:@"speakers" deviceId:1 isSystemDefault:YES transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[device]; } retryScheduler:nil];
    (void)devices.outputDevices;
    NSMutableArray *announcements = [NSMutableArray array];
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getClassMethod(CoreAudioUtil.class, @selector(readSystemDefaultOutputDeviceID:)),
        class_getInstanceMethod(AudioPlayerRenderTests.class, @selector(audioPlayer:didChangeOutputDevice:involuntaryFallbackUID:involuntaryFallbackName:carriedModesFromUID:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *out) { *out=1; return YES; }),
        imp_implementationWithBlock(^(id test, AudioPlayer *player, NSInteger deviceID, NSString *fallbackUID, NSString *fallbackName, NSString *carriedUID) {
            [announcements addObject:@{@"device":@(deviceID), @"fallback":fallbackUID ?: @""}];
        }),
    };
    IMP originals[4];
    for(NSUInteger i=0;i<4;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [_player runSyncOnQueue:^{
            self->_player.currentlyRequestedAudioDeviceId=2;
            [self->_player setValue:@"saved" forKey:@"boundDeviceUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"boundDeviceName"];
        }];
        [_player audioOutputDevicesDidChange];
        [self settleUntil:^BOOL { return announcements.count >= 1; }];
        XCTAssertEqualObjects(announcements[0][@"fallback"], @"saved");
        [_player systemDefaultOutputDeviceDidChange];
        [self settleUntil:^BOOL { return announcements.count >= 2; }];
        XCTAssertEqualObjects(announcements[1][@"fallback"], @"saved", @"A second involuntary notification must not look like user-selected System Output");
        __block BOOL selected = NO;
        [_player setOutputDevice:-1 completion:^{ selected = YES; }];
        [self settleUntil:^BOOL { return selected; }];
        XCTAssertEqualObjects(announcements.lastObject[@"fallback"], @"");
        XCTAssertEqualObjects(_player.outputDeviceDiagnosticSnapshot[@"pendingDeviceUID"], @"");
    } @finally {
        [_player runSyncOnQueue:^{
            [self->_player setValue:nil forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:nil forKey:@"pendingSavedDeviceName"];
        }];
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<4;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testModelMatchRespectsDestinationModes {
    AudioDevice *device = [[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"port-b" modelUID:@"model" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[device]; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method method=class_getClassMethod(AudioDeviceManager.class,@selector(sharedInstance));
    IMP replacement=imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; });
    IMP original=method_setImplementation(method,replacement);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        _outputModesProvider=^(NSString *uid, BOOL *bitPerfect, BOOL *exclusive) {
            *bitPerfect=YES;
            *exclusive=[uid isEqualToString:@"port-a"];
        };
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"port-a" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"model" forKey:@"pendingSavedDeviceModelUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"pendingSavedDeviceName"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
        }];
        __block BOOL exclusive;
        [_player runSyncOnQueue:^{ exclusive=[[self->_player valueForKey:@"exclusiveOutputWanted"] boolValue]; }];
        XCTAssertFalse(exclusive, @"Port B already has bit-perfect on and exclusive off");
        [self settleUntil:^BOOL { return [self count:@"device"] == 1; }];
        XCTAssertEqualObjects(_events.lastObject[@"carriedModes"], @"");
        // An unconfigured destination inherits only on automatic re-adoption.
        _outputModesProvider = ^(NSString *uid, BOOL *bitPerfect, BOOL *exclusive) {
            *bitPerfect = *exclusive = [uid isEqualToString:@"port-a"];
        };
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"port-a" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"model" forKey:@"pendingSavedDeviceModelUID"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
        }];
        [self settleUntil:^BOOL { return [self count:@"device"] == 2; }];
        XCTAssertTrue([_player.outputDeviceDiagnosticSnapshot[@"exclusiveOutputWanted"] boolValue]);
        XCTAssertEqualObjects(_events.lastObject[@"carriedModes"], @"port-a");
        __block BOOL selected = NO;
        [_player setOutputDevice:2 completion:^{ selected = YES; }];
        [self settleUntil:^BOOL { return selected; }];
        XCTAssertFalse([_player.outputDeviceDiagnosticSnapshot[@"exclusiveOutputWanted"] boolValue]);
        XCTAssertEqualObjects(_events.lastObject[@"carriedModes"], @"");
    } @finally {
        [_player debugShutdown]; _player=nil;
        method_setImplementation(method,original); imp_removeBlock(replacement);
    }
}

- (void)testAbsentLaunchDeviceRemainsPending {
    __block NSArray *snapshot = @[];
    AudioDeviceManager *devices=[[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return snapshot; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method methods[]={class_getClassMethod(AudioDeviceManager.class,@selector(sharedInstance)), class_getClassMethod(CoreAudioUtil.class,@selector(readSystemDefaultOutputDeviceID:))};
    IMP replacements[]={imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }), imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *out) { *out=0; return YES; })};
    IMP originals[2]; for(NSUInteger i=0;i<2;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"saved" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"pendingSavedDeviceName"];
            [self->_player setValue:@YES forKey:@"bitPerfectWanted"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
        }];
        [self settleUntil:^BOOL {
            __block BOOL pending;
            [self->_player runSyncOnQueue:^{ pending=[[self->_player valueForKey:@"pendingSavedDeviceLookupInFlight"] boolValue]; }];
            return !pending;
        }];
        __block NSString *wanted;
        [_player runSyncOnQueue:^{ wanted=[self->_player valueForKey:@"pendingSavedDeviceUID"]; }];
        XCTAssertEqualObjects(wanted,@"saved",@"Device must be re-adoptable when powered on later this session");
        snapshot = @[[[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"saved" deviceId:2
                isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual]];
        XCTestExpectation *published = [self expectationWithDescription:@"device returned"];
        [devices refreshOutputDevicesWithCompletion:^(BOOL success) { [published fulfill]; }];
        [self waitForExpectations:@[published] timeout:VIBE_TEST_HANG_TIMEOUT];
        [_player audioOutputDevicesDidChange];
        [_player runSyncOnQueue:^{}];
        XCTAssertEqual(_player.currentlyRequestedAudioDeviceId, 2);
        XCTAssertEqualObjects(_player.outputDeviceDiagnosticSnapshot[@"pendingDeviceUID"], @"");
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<2;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}
- (void)testTerminationCannotRestartOnDeviceCallbacks {
    AudioDevice *device=[[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"saved" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices=[[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[device]; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method methods[]={class_getClassMethod(AudioDeviceManager.class,@selector(sharedInstance)),class_getClassMethod(CoreAudioUtil.class,@selector(deviceIsConfirmedDead:))};
    IMP replacements[]={imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),imp_implementationWithBlock(^BOOL(id cls,AudioDeviceID deviceID) { return NO; })};
    IMP originals[2]; for(NSUInteger i=0;i<2;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
        [self render:4096];
        [_player runSyncOnQueue:^{
            self->_player.currentlyRequestedAudioDeviceId=2;
            [self->_player setValue:@2 forKey:@"preparedDeviceID"];
        }];
        XCTAssertTrue(_player.isPlaying);
        XCTAssertEqual([self count:@"finish"],0u);
        [_player prepareForTermination];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        XCTAssertEqual([self count:@"finish"],0u,@"Termination must not deliver natural track-end and auto-advance during NSTerminateLater");
        XCTAssertFalse([_player.debugRenderCounts[@"running"] boolValue]);
        AudioTrack *lateTrack = [[AudioTrack alloc] initWithURL:[self fixture:@"noise-48000-24-2.wav"]];
        [_player play:lateTrack];
        [_player prefetchTrack:lateTrack];
        [_player setBitPerfectOutput:YES exclusiveOutput:YES enableFX:NO allowAnyDevice:NO];
        [_player audioOutputDevicesDidChange];
        [_player systemDefaultOutputDeviceDidChange];
        [_player runSyncOnQueue:^{}];
        XCTAssertTrue(_player.isStopped);
        XCTAssertFalse([_player.outputDeviceDiagnosticSnapshot[@"outputRunning"] boolValue]);
        XCTAssertNil([_player valueForKey:@"playOpenToken"]);
        XCTAssertNil([_player valueForKey:@"prefetchOpenToken"]);
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<2;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testSavedDeviceDiscoveryCannotUndoExplicitSystemOutput {
    AudioDevice *device = [[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"saved" deviceId:2
            isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    dispatch_semaphore_t publish = dispatch_semaphore_create(0);
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) {
        dispatch_semaphore_wait(publish, dispatch_time(DISPATCH_TIME_NOW, VIBE_TEST_GATE_TIMEOUT * NSEC_PER_SEC));
        return @[device];
    } retryScheduler:nil];
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(readSystemDefaultOutputDeviceID:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *out) { *out = 0; return YES; }),
    };
    IMP originals[2];
    for (NSUInteger i = 0; i < 2; i++) originals[i] = method_setImplementation(methods[i], replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"saved" forKey:@"pendingSavedDeviceUID"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
        }];
        XCTAssertTrue([_player.outputDeviceDiagnosticSnapshot[@"savedDeviceLookupInFlight"] boolValue]);
        __block BOOL selected = NO;
        [_player setOutputDevice:-1 completion:^{ selected = YES; }];
        [self settleUntil:^BOOL { return selected; }];
        dispatch_semaphore_signal(publish);
        [self settleUntil:^BOOL {
            return ![self->_player.outputDeviceDiagnosticSnapshot[@"savedDeviceLookupInFlight"] boolValue];
        }];
        XCTAssertEqual(_player.currentlyRequestedAudioDeviceId, -1);
        XCTAssertEqualObjects(_player.outputDeviceDiagnosticSnapshot[@"pendingDeviceUID"], @"");
    } @finally {
        dispatch_semaphore_signal(publish);
        [_player debugShutdown]; _player = nil;
        for (NSUInteger i = 0; i < 2; i++) {
            method_setImplementation(methods[i], originals[i]);
            imp_removeBlock(replacements[i]);
        }
    }
}

- (void)testFailedManualSelectionDoesNotOverwriteReadoptedModes {
    AudioDevice *a = [[AudioDevice alloc] initWithName:@"A" uid:@"a" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDevice *b = [[AudioDevice alloc] initWithName:@"B" uid:@"b" deviceId:3 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[a,b]; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getInstanceMethod(AudioPlayer.class, @selector(setOutputUnitDevice:)),
    };
    NSMutableArray *binds = [NSMutableArray array];
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(AudioPlayer *p, AudioDeviceID d) { [binds addObject:@(d)]; return d != 3; }),
    };
    IMP originals[3];
    for (NSUInteger i=0;i<3;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
        [self render:4096];
        _outputModesProvider=^(NSString *uid, BOOL *bp, BOOL *exclusive) { *bp=*exclusive=[uid isEqualToString:@"a"]; };
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"a" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"A" forKey:@"pendingSavedDeviceName"];
        }];
        __block BOOL selected=NO;
        [_player setOutputDevice:3 completion:^{ selected=YES; }];
        [self settleUntil:^BOOL { return selected; }];
        NSDictionary *snapshot=_player.outputDeviceDiagnosticSnapshot;
        XCTAssertEqual(_player.currentlyRequestedAudioDeviceId, 2);
        XCTAssertTrue([snapshot[@"bitPerfectWanted"] boolValue], @"A was adopted with its modes but B's rollback overwrote them: %@, binds %@",snapshot,binds);
        XCTAssertTrue([snapshot[@"exclusiveOutputWanted"] boolValue]);
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testFailedReadoptionAtTrackEndStillDeliversFinish {
    AudioDevice *a = [[AudioDevice alloc] initWithName:@"A" uid:@"a" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[a]; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getInstanceMethod(AudioPlayer.class, @selector(setOutputUnitDevice:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(AudioPlayer *p, AudioDeviceID d) { return NO; }),
    };
    IMP originals[3];
    for(NSUInteger i=0;i<3;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
        [self render:4096];
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"a" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"A" forKey:@"pendingSavedDeviceName"];
        }];
        [self render:100000];
        [self settleUntil:^BOOL { return [self count:@"finish"] >= 1; }];
        XCTAssertEqual([self count:@"finish"],1u,@"Device bind failure must not eat the completed track's end: %@",_events);
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testMissingLastOutputParksWithoutFinishingTrack {
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[]; } retryScheduler:nil];
    (void)devices.outputDevices;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getClassMethod(CoreAudioUtil.class, @selector(readSystemDefaultOutputDeviceID:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return kAudioObjectUnknown; }),
        imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *out) { *out=kAudioObjectUnknown; return YES; }),
    };
    IMP originals[3];
    for(NSUInteger i=0;i<3;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
        [self render:4096];
        [_player runSyncOnQueue:^{
            self->_player.currentlyRequestedAudioDeviceId=2;
            [self->_player setValue:@"saved" forKey:@"boundDeviceUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"boundDeviceName"];
        }];
        [_player audioOutputDevicesDidChange];
        [self settleUntil:^BOOL { return self->_player.isPaused || [self count:@"finish"] > 0; }];
        [_player runSyncOnQueue:^{}];
        XCTAssertEqual([self count:@"finish"],0u,@"Losing the last output must park the track, not auto-advance: %@",_events);
        XCTAssertTrue(_player.isPaused,@"The track must remain resumable: %@",_events);
        double parked = _player.position;
        XCTAssertGreaterThan(parked, 0);
        [_player resume];
        [self settleUntil:^BOOL { return [self count:@"resume"] == 1; }];
        [self render:100000];
        XCTAssertEqual([self count:@"finish"],1u,@"The replacement schedule must finish exactly once after resume");
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

- (void)testQueuedFXEditKeepsModesCarriedToNewPort {
    AudioDevice *device = [[AudioDevice alloc] initWithName:@"Saved DAC" uid:@"port-b" modelUID:@"model" deviceId:2 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) { return @[device]; } retryScheduler:nil];
    (void)devices.outputDevices;
    NSMutableDictionary *savedModes = [@{@"port-a": @YES} mutableCopy];
    __block BOOL carryDelivered = NO;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getInstanceMethod(AudioPlayerRenderTests.class, @selector(audioPlayer:didChangeOutputDevice:involuntaryFallbackUID:involuntaryFallbackName:carriedModesFromUID:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^(id test, AudioPlayer *player, NSInteger deviceID, NSString *fallbackUID, NSString *fallbackName, NSString *source) {
            if (source.length) {
                @synchronized(savedModes) { savedModes[@"port-b"] = savedModes[source]; }
                carryDelivered = YES;
            }
        }),
    };
    IMP originals[3];
    for(NSUInteger i=0;i<3;i++) originals[i]=method_setImplementation(methods[i],replacements[i]);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
        _outputModesProvider=^(NSString *uid, BOOL *bp, BOOL *exclusive) {
            @synchronized(savedModes) { *bp=*exclusive=[savedModes[uid ?: @""] boolValue]; }
        };
        [_player runSyncOnQueue:^{
            [self->_player setValue:@"port-a" forKey:@"pendingSavedDeviceUID"];
            [self->_player setValue:@"model" forKey:@"pendingSavedDeviceModelUID"];
            [self->_player setValue:@"Saved DAC" forKey:@"pendingSavedDeviceName"];
            [self->_player resolvePendingSavedOutputDeviceOnQueue];
            [self->_player setBitPerfectOutput:YES exclusiveOutput:YES enableFX:YES allowAnyDevice:NO];
        }];
        // Keep main occupied until the previously queued settings edit lands.
        [_player runSyncOnQueue:^{}];
        [self settleUntil:^BOOL { return carryDelivered; }];
        XCTAssertEqual(_player.currentlyRequestedAudioDeviceId,2);
        XCTAssertTrue([savedModes[@"port-b"] boolValue]);
        NSDictionary *snapshot=_player.outputDeviceDiagnosticSnapshot;
        XCTAssertTrue([snapshot[@"bitPerfectWanted"] boolValue],@"A queued global edit must preserve adopted modes even before their main-thread persistence: %@",snapshot);
        XCTAssertTrue([snapshot[@"exclusiveOutputWanted"] boolValue]);
        @synchronized(savedModes) { savedModes[@"port-b"] = @NO; }
        [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:YES allowAnyDevice:NO];
        [_player runSyncOnQueue:^{}];
        XCTAssertFalse([_player.outputDeviceDiagnosticSnapshot[@"bitPerfectWanted"] boolValue], @"Once persisted, the destination's later edits must win");
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

@end

// The varispeed at zero, the output's rate and path, output-unit failures, idle stop and decode failures.
@interface AudioPlayerRenderOutputTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderOutputTests

// At zero pitch the varispeed is hosted but not in the chain, so the output is
// the file exactly. Leaving and returning to zero engages and disengages it
// with no click or skip: on a 100 Hz tone every transition keeps the waveform
// continuous and its envelope full, and the file advances exactly as far as
// the rates played.
- (void)testZeroPitchRendersTheBusDirectlyAndTogglesAreClickFree {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSURL *noise = [self fixture:@"noise-48000-24-2.wav"];
    [self play:noise paused:NO position:0];
    [self assertReference:PCM([self read:noise]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    NSDictionary *counts = _player.debugRenderCounts;
    XCTAssertTrue([counts[@"varispeed"] boolValue], @"ordinary playback hosts the varispeed");
    XCTAssertFalse([counts[@"varispeedEngaged"] boolValue]);
    XCTAssertEqual([counts[@"varispeedRenders"] unsignedLongLongValue], 0ull, @"the varispeed rendered at zero pitch");
    XCTAssertEqual([counts[@"varispeedHistoryWrites"] unsignedLongLongValue], 0ull, @"the history ring was written at zero pitch");
    XCTAssertEqual([counts[@"varispeedLatency"] doubleValue], 0.0);

    NSArray<NSNumber *> *pitches = @[@0, @4, @0, @-4, @0, @8, @-8, @0];
    [self play:[self fixture:@"100.wav"] paused:NO position:0];
    [_capture setLength:0];
    // Each segment advances the file by its own rate, within a few frames.
    // An engage first plays the slice in which the unit's history is
    // recorded directly, at rate 1, then pulls the unit's latency ahead of
    // its output; a disengage plays that pulled-ahead latency from the ring
    // without consuming. So the two segments carry those frames each way.
    double expected = 0, latency = 0;
    BOOL wasEngaged = NO;
    for (NSNumber *pitch in pitches) {
        double before = _player.position, rate = 1 + pitch.doubleValue / 100;
        _player.pitch = pitch.floatValue;
        [self render:9600];
        NSDictionary *counts = _player.debugRenderCounts;
        BOOL engaged = [counts[@"varispeedEngaged"] boolValue];
        XCTAssertEqual(engaged, pitch.floatValue != 0, @"pitch %@", pitch);
        if (engaged) latency = [counts[@"varispeedLatency"] doubleValue];
        double direct = ceil(2 * latency * 48000 / _blockSize) * _blockSize / 48000;
        double advance = 0.2 * rate + (engaged && !wasEngaged ? latency + direct * (1 - rate) : 0) - (!engaged && wasEngaged ? latency : 0);
        XCTAssertEqualWithAccuracy(_player.position - before, advance, 0.0002, @"the file advanced at pitch %@", pitch);
        expected += advance;
        wasEngaged = engaged;
    }
    XCTAssertGreaterThan(latency, 0.0005, @"the unit's declared latency, read while engaged");
    XCTAssertEqualWithAccuracy(_player.position, expected, 0.0002, @"the file advanced as far as the rates played");
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
        double rms = RMS(_capture, 2, 0, NSMakeRange(f, 480));
        XCTAssertGreaterThan(rms, nominal * 0.93, @"a dip in the window at frame %lu", (unsigned long)f);
        if (rms <= nominal * 0.93) return;
    }
    // Back at zero: the unit is idle, nothing is copied, and the output is
    // the file, exactly.
    uint64_t renders = [_player.debugRenderCounts[@"varispeedRenders"] unsignedLongLongValue];
    XCTAssertGreaterThan(renders, 0ull, @"the varispeed rendered while the pitch was off zero");
    [self play:noise paused:NO position:0];
    [self assertReference:PCM([self read:noise]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    counts = _player.debugRenderCounts;
    XCTAssertEqual([counts[@"varispeedRenders"] unsignedLongLongValue], renders, @"the varispeed rendered at zero pitch");
    XCTAssertEqual([counts[@"varispeedHistoryWrites"] unsignedLongLongValue], historyWrites, @"the history ring was written at zero pitch");
}

// The volume is the render's last stage, after the meter. At full volume the
// output is the file exactly; at half the fader it is the file times 1/8, the
// cube, exactly, since that is a power of two; at zero it is silence while
// the meter before it still sees the signal; and back at full volume every
// frame continues the file exactly, mid-stream. Each change ramps across one
// slice, which the captures skip.
- (void)testVolumeIsExactAtFullAndSilentAtZero {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSURL *noise = [self fixture:@"noise-48000-24-2.wav"];
    NSData *reference = PCM([self read:noise]);
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
    NSData *reference = PCM([self read:noise]);
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
    XCTAssertEqualWithAccuracy(ToneAmplitude(data, 2, 0, 96000, 1000, NSMakeRange(9600, 24000)), 0.25, 0.005);
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
    XCTAssertEqual(RMS([self renderSeconds:0.2], 2, 0, NSMakeRange(0, 9600)), 0.0, @"paused stays silent across the change");
    XCTAssertEqualWithAccuracy(_player.position, paused, 0.01);
    [_player resume];
    data = [self renderSeconds:0.5];
    XCTAssertTrue(_player.isPlaying);
    XCTAssertEqualWithAccuracy(ToneAmplitude(data, 2, 0, 48000, 1000, NSMakeRange(4800, 12000)), 0.25, 0.005);
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
        [self assertReference:PCM(VibeReferenceResample([self stereo:decoded], 96000)) capture:capture
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
    NSData *reference = PCM([self read:url]);
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
        NSData *pcm = PCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
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
    XCTAssertEqual([varispeed[@"quality"] intValue], 127, @"the varispeed at its highest render quality");
    XCTAssertGreaterThan([varispeed[@"latencyFrames"] intValue], 0);
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
    NSData *pcm = PCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
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
