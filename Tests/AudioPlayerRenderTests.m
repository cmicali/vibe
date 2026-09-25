#import <XCTest/XCTest.h>
#import "AudioPlayer+Debug.h"
#import "AudioFX+Debug.h"
#import "AudioLevelTap+Debug.h"
#import "AudioTrack.h"
#import "AudioPlayer+Devices.h"
#import "AudioPlayerInternal.h"
#import "AudioFX.h"
#import "CoreAudioUtil.h"
#import "AudioDevice.h"
#import "VibeManualRenderPump.h"
#import "AudioVoiceBusInternal.h"
#import <objc/runtime.h>
#include <float.h>
#include <stdatomic.h>

// Independent Apple AAC decodes can differ by a few float rounding bits.
// Lossless paths still require exact samples; AAC stays below -126 dBFS.
static const float kVibeAACDecodeTolerance = 4 * FLT_EPSILON;

// Interleaved float PCM keeps the oracle independent of the render's buffers.
static NSMutableData *PCM(AVAudioPCMBuffer *buffer) {
    NSUInteger channels = buffer.format.channelCount;
    NSMutableData *data = [NSMutableData dataWithLength:buffer.frameLength * channels * sizeof(float)];
    float *out = data.mutableBytes;
    for (NSUInteger f = 0; f < buffer.frameLength; f++)
        for (NSUInteger c = 0; c < channels; c++) out[f * channels + c] = buffer.floatChannelData[c][f];
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

@interface AudioPlayerRenderTests : XCTestCase <AudioPlayerDelegate>
@end
@implementation AudioPlayerRenderTests {
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
}
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
    [NSFileManager.defaultManager removeItemAtURL:_temporary error:NULL];
    [super tearDown];
}
- (NSURL *)fixture:(NSString *)name {
    NSString *root = NSProcessInfo.processInfo.environment[@"VIBE_AUDIO_FIXTURES"];
    XCTAssertNotNil(root, @"Run make test-audio or the VibeAudioTests scheme");
    return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:name]];
}
- (AVAudioPCMBuffer *)read:(NSURL *)url {
    NSError *error = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&error];
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
    NSMutableDictionary *settings=[buffer.format.settings mutableCopy];
    settings[AVLinearPCMIsNonInterleaved]=@NO;
    AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url settings:settings error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertTrue([file writeFromBuffer:buffer error:&error], @"%@", error);
    return url;
}
// The generator emits a fixed 44-byte RIFF header. Read those bytes directly
// for the lossless matrix so AVAudioFile is not its own decode oracle.
- (NSData *)sourcePCM:(NSURL *)url bits:(NSUInteger)bits {
    NSData *wav=[NSData dataWithContentsOfURL:url];
    XCTAssertGreaterThan(wav.length,44u);
    XCTAssertEqual(memcmp(wav.bytes,"RIFF",4),0);
    const uint8_t *bytes=(const uint8_t *)wav.bytes+44;
    NSUInteger width=bits/8, count=(wav.length-44)/width;
    NSMutableData *pcm=[NSMutableData dataWithLength:count*sizeof(float)];
    float *out=pcm.mutableBytes;
    for (NSUInteger i=0;i<count;i++) {
        if (bits==32) memcpy(out+i,bytes+i*4,4); // float32 fixtures, little endian host
        else {
            uint32_t value=0;
            for(NSUInteger b=0;b<width;b++) value|=(uint32_t)bytes[i*width+b]<<(b*8);
            int32_t signedValue=(value & (1u<<(bits-1))) ? (int32_t)value-(1<<bits) : (int32_t)value;
            out[i]=(float)signedValue/(float)(1u<<(bits-1));
        }
    }
    XCTAssertEqualObjects(pcm,PCM([self read:url]),@"Lossless decode %@",url.lastPathComponent);
    return pcm;
}
- (NSUInteger)count:(NSString *)event {
    NSUInteger count=0; for (NSDictionary *entry in _events) if ([entry[@"event"] isEqual:event]) count++; return count;
}
- (void)settleUntil:(BOOL (^)(void))condition {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!condition() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.0001]];
    XCTAssertTrue(condition(), @"Timed out; events %@; error %@", _events, _playError);
}
// The tap delivers on its own thread, and the probe's poll rides the player's
// clock, which the frame-driven pump advances only while frames render: on a
// slow runner the signal can reach the tap after the last slice, with no poll
// left to finish the capture. So wait for the tap thread to see it, then
// render a poll's worth, and read the settled snapshot.
- (NSDictionary *)settledSignalSnapshot {
    __block NSDictionary *signal;
    BOOL (^read)(void) = ^BOOL {
        [self->_player runSyncOnQueue:^{ signal = [[self->_player debugLevelTap] signalDiagnosticSnapshot]; }];
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
    XCTAssertEqualWithAccuracy([_player.debugEngineCounts[@"outputRate"] doubleValue], rate, 0);
    [_player setBitPerfectOutput:bitPerfect exclusiveOutput:NO enableFX:fx];
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
// The startup the comparison may skip: the 10 ms declick and the settling
// after it, and nothing at all with Declick off, which cuts, so the first
// sample must already be exact.
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
        XCTAttachment *trace=[XCTAttachment attachmentWithString:[NSString stringWithFormat:@"%@\n%@\n%@",result,_events,_player.debugEngineCounts]];
        trace.name=@"render-events"; trace.lifetime=XCTAttachmentLifetimeKeepAlways; [self addAttachment:trace];
    }
    XCTAssertTrue([result[@"pass"] boolValue], @"%@",result);
}
- (void)assertFinite:(NSData *)data peak:(float)peak {
    const float *p=data.bytes;
    for (NSUInteger i=0;i<data.length/sizeof(float);i++) { XCTAssertTrue(isfinite(p[i])); XCTAssertLessThanOrEqual(fabsf(p[i]),peak); }
}

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
}
- (void)testBitPerfectRateDepthAndChannelMatrix {
    for (NSNumber *rate in @[@44100,@48000,@88200,@96000,@176400,@192000])
    for (NSNumber *bits in @[@16,@24,@32]) for (NSNumber *channels in @[@1,@2]) {
        @autoreleasepool {
            [self startPlayerAt:rate.doubleValue channels:channels.unsignedIntegerValue fx:NO bitPerfect:YES automatic:NO];
            NSURL *url=[self fixture:[NSString stringWithFormat:@"noise-%@-%@-%@.wav",rate,bits,channels]];
            NSData *reference=[self sourcePCM:url bits:bits.unsignedIntegerValue]; [self play:url paused:NO position:0];
            NSData *capture=[self renderSeconds:2.1];
            [self assertReference:reference capture:capture skip:[self startupSkip] tolerance:0];
            XCTAssertFalse([_player.debugEngineCounts[@"varispeed"] boolValue]);
            XCTAssertEqual([self count:@"finish"],1u);
        }
    }
}
- (void)testRegularPlaybackAndInactiveFXAreTransparent {
    for (NSNumber *fx in @[@NO,@YES]) for (NSNumber *rate in @[@44100,@48000,@96000]) {
        [self startPlayerAt:rate.doubleValue channels:2 fx:fx.boolValue bitPerfect:NO automatic:NO];
        NSURL *url=[self fixture:[NSString stringWithFormat:@"noise-%@-24-2.wav",rate]];
        NSData *reference=PCM([self read:url]); [self play:url paused:NO position:0];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
        // Transparent because nothing renders: the varispeed is out of the
        // chain at zero pitch, and an idle segment's units are at rest.
        NSDictionary *counts=_player.debugEngineCounts;
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
    NSURL *url=[self fixture:name];
    XCTSkipUnless([NSFileManager.defaultManager fileExistsAtPath:url.path],@"Optional encoder fixture %@ unavailable; install ffmpeg and regenerate",name);
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
- (void)testQuickTimeAudio { [self checkLossy:@"lossy.qta" tolerance:kVibeAACDecodeTolerance]; }
// A bit-perfect lossy source on a 16-bit device is decoded straight to 16-bit
// integers. Only the device boundary is faked (the prepared format); the real
// rule and graph run. MP3 and MP2 decode onto the 16-bit grid already, so no
// sample may change; AAC rounds once to the nearest step; lossless stays float.
- (void)testSixteenBitDeviceDecodesLossySourcesToInteger16 {
    XCTSkipUnless([NSFileManager.defaultManager fileExistsAtPath:[self fixture:@"cbr.mp3"].path],
                  @"Optional encoder fixtures unavailable; install ffmpeg and regenerate");
    Method method = class_getInstanceMethod(AudioPlayer.class, @selector(decodesAsInteger16OnQueueForFile:));
    IMP replacement = imp_implementationWithBlock(^BOOL(AudioPlayer *player, AVAudioFile *file) {
        AudioStreamBasicDescription sixteen = {0};
        sixteen.mSampleRate = file.processingFormat.sampleRate;
        sixteen.mFormatID = kAudioFormatLinearPCM;
        sixteen.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        sixteen.mBitsPerChannel = 16;
        return VibeBitPerfectDecodesAsInteger16(*file.fileFormat.streamDescription, sixteen);
    });
    IMP original = method_setImplementation(method, replacement);
    @try {
        for (NSString *name in @[@"cbr.mp3", @"vbr.mp3", @"lossy.mp2", @"lossy.m4a", @"lossless.flac"]) {
            NSURL *url = [self fixture:name];
            if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) continue;
            BOOL aac = [name hasSuffix:@".m4a"], lossless = [name hasSuffix:@".flac"];
            AVAudioPCMBuffer *decoded = [self read:url];
            [self startPlayerAt:decoded.format.sampleRate channels:decoded.format.channelCount fx:NO bitPerfect:YES automatic:NO];
            [self play:url paused:NO position:0];
            XCTAssertEqual(_player.debugCurrentDecodeFormat.commonFormat,
                           lossless ? AVAudioPCMFormatFloat32 : AVAudioPCMFormatInt16, @"%@", name);
            NSMutableData *reference = PCM(decoded);
            float *r = reference.mutableBytes;
            for (NSUInteger i = 0; aac && i < reference.length / sizeof(float); i++) {
                r[i] = fminf(32767, fmaxf(-32768, roundf(r[i] * 32768))) / 32768;
            }
            // Two AAC decodes can differ by float rounding bits, which may move a
            // sample sitting on a rounding boundary by one 16-bit step.
            [self assertReference:reference capture:[self renderSeconds:decoded.frameLength / _rate + 0.1]
                             skip:[self startupSkip] tolerance:aac ? 1.0f / 32768 : 0];
        }
    } @finally {
        [_player debugShutdown]; _player = nil;
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
    }
}
- (void)testFloatLimitsSilenceAndInteger32Precision {
    for (NSString *name in @[@"limits.wav",@"silence.wav",@"integer32.wav"]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        AVAudioPCMBuffer *source=[self read:[self fixture:name]];
        [self play:[self fixture:name] paused:NO position:0];
        NSData *capture=[self renderSeconds:source.frameLength/_rate+0.1];
        if ([name isEqual:@"silence.wav"]) XCTAssertEqual(RMS(capture,2,0,NSMakeRange(0,capture.length/8)),0);
        else [self assertReference:PCM(source) capture:capture skip:[self startupSkip] tolerance:0];
        [self assertFinite:capture peak:1];
    }
    // Float32's precision is an explicit limit; decoded equality above does
    // not claim the integer source's low bits survive the AVAudioFile boundary.
    volatile int32_t sample=16777217; float converted=(float)sample;
    XCTAssertNotEqual((int32_t)converted,(int32_t)sample);
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

// The default: every edge is the 10 ms declick, and nothing else is touched.
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

// Declick is every mode's: off, ordinary playback cuts its declick-length
// edges too, while a crossfade longer than the declick is the user's choice
// and still fades.
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
    XCTAssertEqual([_player.debugEngineCounts[@"retiredFades"] unsignedIntegerValue], 0u, @"a cut voice is killed, not faded");
    [_player stop];
    NSUInteger stopped = _capture.length / sizeof(float) / 2;
    [self render:14400]; XCTAssertTrue(_player.isStopped);
    XCTAssertGreaterThanOrEqual([self assertExactExcerptsOf:references inCapture:_capture rampFrames:0 ramped:NULL], 3u);
    // The varispeed, bypassed but in the chain, delays the cut by its latency.
    NSUInteger latency = (NSUInteger)llround([_player.debugEngineCounts[@"varispeedLatency"] doubleValue] * _rate) + _blockSize;
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
    XCTAssertEqual([_player.debugEngineCounts[@"retiredFades"] unsignedIntegerValue], 1u, @"the crossfade fades with Declick off");
}

// A skip past the end reaches finishPlaybackOnQueue with the voice still at
// full amplitude, and it fades like every other edge: the transport
// publishes Stopped before it retires the voice, so the retire must read the
// voice's own state, not the player's. Every adjacent sample of the tail is
// inspected, the command boundary included.
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
    XCTAssertFalse([_player.debugEngineCounts[@"running"] boolValue]);
    XCTAssertEqualWithAccuracy(_player.position,position,0);
    XCTAssertEqual([self count:@"finish"],0u);
    [_player resume];
    NSData *tail=[reference subdataWithRange:NSMakeRange(sourceFrame*8,reference.length-sourceFrame*8)];
    [self assertReference:tail capture:[self renderSeconds:2.1-position] skip:[self startupSkip] tolerance:0];
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
        XCTAssertEqual([self count:@"finish"],1u);
    }
}
// A continuous 44.1 kHz signal split across two tracks, played at 48 kHz:
// the resampler carries across the gapless boundary, whether the successor
// was named while the first track was decoding or once it had been decoded
// whole, so the output is the unsplit file's.
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
        XCTAssertEqual([[AVAudioFile alloc] initForReading:url error:NULL].processingFormat.channelLayout.layoutTag, tags[i].unsignedIntValue);
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
    XCTAssertEqual([self count:@"finish"], 1u, @"The current track must finish after the cancelled boundary");
    XCTAssertLessThan(ToneAmplitude(tail, 2, 0, 48000, 1000, NSMakeRange(36000, 24000)), 0.01,
                     @"Cancelled successor must not be audible");
}

// The seek's replacement voice reads the same AVAudioFile as the voice it
// retires, on the production decode queue: the old voice's reads must stop
// before the new voice positions the shared cursor, or a turn of the old
// voice queued between the two advances it and the new voice skips a chunk.
// The retire is held open with the decoder running, so a start before it
// loses its second chunk.
- (void)testSeekStopsTheOldVoiceReadingBeforeItsFileIsHandedOn {
    self.continueAfterFailure = YES;
    Method initializer = class_getInstanceMethod(AudioVoiceBus.class, @selector(initWithFormat:queue:inlineDecoding:));
    __block IMP originalInit;
    IMP asyncInit = imp_implementationWithBlock(^id(id receiver, AVAudioFormat *format, dispatch_queue_t queue, BOOL inlineDecoding) {
        return ((id (*)(id, SEL, AVAudioFormat *, dispatch_queue_t, BOOL))originalInit)(receiver, @selector(initWithFormat:queue:inlineDecoding:), format, queue, NO);
    });
    originalInit = method_setImplementation(initializer, asyncInit);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        [_player debugStarveDecoder:YES]; // only the production decode queue fills
        _player.declick = NO;
        [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
    } @finally {
        method_setImplementation(initializer, originalInit);
        imp_removeBlock(asyncInit);
    }
    __block AudioVoiceBus *bus;
    [_player runSyncOnQueue:^{ bus = [self->_player valueForKey:@"voiceBus"]; }];
    dispatch_queue_t decoder = bus.decodeQueue;
    XCTAssertNotNil(decoder);
    for (int i = 0; i < 20; i++) dispatch_sync(decoder, ^{});
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
            for (int i = 0; i < 30; i++) dispatch_sync(decoder, ^{});
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
        XCTAssertEqual(dispatch_semaphore_wait(reading, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L);
        [_player seekToPosition:0.5];
        [_player runSyncOnQueue:^{}];
        XCTAssertTrue(heldRetire);
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
        dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)); // the swizzled read must be over before its IMP goes
        method_setImplementation(produce, originalProduce);
        method_setImplementation(retire, originalRetire);
        imp_removeBlock(heldProduce);
        imp_removeBlock(heldRetirement);
    }
}

// The meter is kept across demand toggles, so an install must forget the
// audio before it: the accumulator, and the analyzer's partial window and
// references with it. Tone, remove, install, silence — the new session's
// first publication is silence, however often the demand toggles.
- (void)testMeterReinstallPublishesNoEarlierAudio {
    AVAudioPCMBuffer *tone = [self read:[self fixture:@"1000.wav"]];
    AudioLevelPublisher *publisher = [[AudioLevelPublisher alloc] init];
    AudioLevelTap *tap = [[AudioLevelTap alloc] initWithFormat:tone.format publisher:publisher
                                         normalizationMode:kLevelDefaultNormalizationMode];
    UInt32 count = VibeLevelTapBufferFrameCount(tone.format.sampleRate);
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

// A meter callback that began before a remove-and-reinstall — the demand
// toggling under it — publishes into the session it began, which has ended,
// so the new session opens on none of its audio.
- (void)testAMeterCallbackStalledAcrossAReinstallPublishesNothingIntoTheNewSession {
    AVAudioPCMBuffer *tone = [self read:[self fixture:@"1000.wav"]];
    AudioLevelPublisher *publisher = [[AudioLevelPublisher alloc] init];
    AudioLevelTap *tap = [[AudioLevelTap alloc] initWithFormat:tone.format publisher:publisher
                                         normalizationMode:kLevelDefaultNormalizationMode];
    UInt32 count = VibeLevelTapBufferFrameCount(tone.format.sampleRate);
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
    XCTAssertEqual(dispatch_group_wait(stalled, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L,
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
        __block AudioLevelTap *tap;
        [_player runSyncOnQueue:^{
            tap = [self->_player debugLevelTap];
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
        [self assertReference:reference capture:_capture skip:[self startupSkip] tolerance:fx.boolValue?1e-10f:0];
    }
}
- (void)testSignalDiagnosticsBoundSilentCaptureAndRearm {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self play:[self fixture:@"silence.wav"] paused:NO position:0];
    _player.levelsEnabled=YES;
    __block AudioLevelTap *tap;
    __block uint64_t request;
    __block NSDictionary *signal;
    NSMutableArray<NSDictionary *> *completed = [NSMutableArray array];
    [_player runSyncOnQueue:^{
        tap = [self->_player debugLevelTap];
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
    for (NSString *action in @[@"tap removed", @"superseded"]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        _player.levelsEnabled=YES;
        [self play:[self fixture:@"silence.wav"] paused:NO position:0];
        NSMutableArray<NSDictionary *> *completed = [NSMutableArray array];
        __block AudioLevelTap *tap;
        __block uint64_t request;
        [_player runSyncOnQueue:^{
            tap = [self->_player debugLevelTap];
            request = [tap beginSignalDiagnosticsAtTime:[self->_player outputRenderTimeOnQueue] waitingForRetiredAudio:NO completion:^(NSDictionary *snapshot) { [completed addObject:snapshot]; }];
        }];
        [self render:16000];
        [_player runSyncOnQueue:^{
            NSDictionary *partial = [tap signalDiagnosticSnapshot];
            XCTAssertGreaterThan([partial[@"frames"] unsignedLongLongValue], 0u);
            XCTAssertFalse([partial[@"aboveThreshold"] boolValue]);
            if ([action isEqual:@"tap removed"]) [tap remove];
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
                XCTAssertEqualObjects(completed.lastObject[@"completion"], @"tap removed");
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
        AudioLevelTap *tap = [self->_player debugLevelTap];
        XCTAssertEqualObjects([tap signalDiagnosticSnapshot], signal);
    }];
}
- (void)testSignalDiagnosticsExcludePreviousTrack {
    for (NSNumber *rate in @[@44100, @48000]) for (NSNumber *fx in @[@NO, @YES])
    for (NSNumber *fade in @[@10, @500]) for (NSNumber *silence in @[@300, @700, @1500]) {
        // Bit-perfect output cuts the old track rather than fading it, and
        // under the pump the output cannot follow the file's rate, so the bus's
        // converter resampling the 48 kHz fixtures carries a few milliseconds
        // of it past the cut in its history. Real bit-perfect output sets the
        // device to the file's rate, so nothing resamples; test that case.
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
    XCTAssertFalse([_player.debugEngineCounts[@"running"] boolValue]);
    [self play:[self fixture:@"quiet-intro-700.wav"] paused:NO position:0]; [self render:48000];
    NSDictionary *signal = [self settledSignalSnapshot];
    XCTAssertTrue([signal[@"aboveThreshold"] boolValue], @"%@", signal);
    XCTAssertEqualWithAccuracy([signal[@"firstSignalAfterStartMS"] doubleValue], 700, 2, @"%@", signal);
    XCTAssertEqualWithAccuracy([signal[@"observedLeadingSilenceMS"] doubleValue], 700, 2);
}
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
    [self assertReference:rest capture:[self renderSeconds:0.6] skip:0 tolerance:1e-10f];
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
        [self render:(NSUInteger)(48000*(4/ratio-1+0.1))]; XCTAssertEqual([self count:@"finish"],1u);
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
    uint64_t renders=[_player.debugEngineCounts[@"varispeedRenders"] unsignedLongLongValue];
    [self render:24000];
    XCTAssertEqual([_player.debugEngineCounts[@"varispeedRenders"] unsignedLongLongValue],renders);
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
        [self render:(NSUInteger)(_rate*3.1)]; XCTAssertEqual([self count:@"finish"],1u);
        [self startPlayerAt:rate.doubleValue channels:2 fx:NO bitPerfect:YES automatic:NO];
        [self play:[self fixture:@"23000.wav"] paused:NO position:0]; data=[self renderSeconds:1];
        if (_rate<48000) XCTAssertLessThan(RMS(data,2,0,window),0.000032); // -90 dBFS alias ceiling
    }
}
// A render stuck inside the pipeline past the wait's bound — blocked after
// it read the bus, on a thread of its own, which is what a stuck render is —
// must not let a withdrawal free or reset what it is inside, and no later
// render may clear the evidence that it is: the pipeline admits one render
// at a time, so the rebuilt output's callbacks render silence while it is
// inside. A rate change replaces the meter, the bus, the varispeed hosting
// and the FX chain, and every one of them stays allocated until the first
// drain that sees the render outside; playback carries on at the new rate.
- (void)testAStuckRenderDefersEveryTeardownUntilItLeaves {
    [self startPlayerAt:48000 channels:2 fx:YES bitPerfect:NO automatic:NO];
    _player.levelsEnabled = YES;
    [self play:[self fixture:@"100.wav"] paused:NO position:0];
    [self render:4096];
    __weak AudioLevelTap *tap = nil;
    __weak AudioVoiceBus *bus = nil;
    @autoreleasepool {
        tap = _player.debugLevelTap;
        bus = [_player valueForKey:@"voiceBus"]; // the ivar, read between renders
        XCTAssertNotNil(tap);
        XCTAssertNotNil(bus);
    }
    XCTAssertEqual([_player.debugEngineCounts[@"renderRefusals"] unsignedIntegerValue], 0u);
    [_player debugHoldRenderInside:YES];
    dispatch_group_t stuck = dispatch_group_create();
    dispatch_group_async(stuck, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        [self->_player debugRenderOnCallerThread:256]; // a carrier's callback, blocked inside the old bus
    });
    [self settleUntil:^BOOL { return [self->_player.debugEngineCounts[@"rendersHeld"] unsignedIntegerValue] == 1; }];
    XCTAssertTrue([_player debugSetOutputRate:96000]);
    XCTAssertGreaterThanOrEqual([_player.debugEngineCounts[@"renderLeaveWork"] unsignedIntegerValue], 4u,
                                @"the tap, the bus, the varispeed hosting and the FX chain wait for the render");
    XCTAssertNotNil(tap, @"the meter was freed under a render");
    XCTAssertNotNil(bus, @"the bus was freed under a render");
    XCTAssertTrue(_player.isPlaying);
    XCTAssertEqualWithAccuracy([_player.debugEngineCounts[@"outputRate"] doubleValue], 96000, 0);
    // The rebuilt output's renders find a render inside: silence, and the
    // parked teardowns stay parked, since the render they wait for is inside.
    [_capture setLength:0];
    @autoreleasepool { [self render:512]; }
    const float *refused = _capture.bytes;
    for (NSUInteger i = 0; i < _capture.length / sizeof(float); i++) {
        XCTAssertEqual(refused[i], 0.0f, @"a refused render wrote sound at sample %lu", (unsigned long)i);
    }
    XCTAssertGreaterThanOrEqual([_player.debugEngineCounts[@"renderRefusals"] unsignedIntegerValue], 2u);
    XCTAssertGreaterThanOrEqual([_player.debugEngineCounts[@"renderLeaveWork"] unsignedIntegerValue], 4u,
                                @"a refused render ran the teardowns of the render still inside");
    XCTAssertNotNil(tap, @"the meter was freed under a render another render followed");
    XCTAssertNotNil(bus, @"the bus was freed under a render another render followed");
    [_player debugHoldRenderInside:NO];
    XCTAssertEqual(dispatch_group_wait(stuck, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L,
                   @"the held render did not leave once the hold lifted");
    XCTAssertEqual([_player.debugEngineCounts[@"rendersHeld"] unsignedIntegerValue], 0u);
    NSUInteger refusals = [_player.debugEngineCounts[@"renderRefusals"] unsignedIntegerValue];
    @autoreleasepool { [self render:256]; } // the render left; the drain after this one runs the parked teardowns
    XCTAssertEqual([_player.debugEngineCounts[@"renderLeaveWork"] unsignedIntegerValue], 0u);
    // The beta signal probe's poll holds the old tap until its next 100 ms
    // tick of the pump's clock finds it removed; nothing else may.
    @autoreleasepool { [self render:9600]; }
    XCTAssertNil(tap, @"the meter outlived the render it waited for");
    XCTAssertNil(bus, @"the bus outlived the render it waited for");
    [self assertFinite:[self renderSeconds:0.1] peak:1.0f];
    XCTAssertEqual([_player.debugEngineCounts[@"renderRefusals"] unsignedIntegerValue], refusals,
                   @"a render was refused with none inside");
}

- (void)testFormatChangesAndModeToggles {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    for (NSString *file in @[@"noise-44100-16-1.wav",@"noise-96000-24-2.wav",@"noise-48000-32-1.wav",@"noise-48000-24-2.wav"]) {
        [self play:[self fixture:file] paused:NO position:0]; [self assertFinite:[self renderSeconds:0.1] peak:0.6];
    }
    [_player setBitPerfectOutput:YES exclusiveOutput:NO enableFX:NO];
    // A new play settles on the mode's chain even without a HAL destination.
    [self play:[self fixture:@"noise-48000-24-2.wav"] paused:NO position:0];
    XCTAssertFalse([_player.debugEngineCounts[@"varispeed"] boolValue]);
    [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:NO]; [self render:2048];
    XCTAssertTrue([_player.debugEngineCounts[@"varispeed"] boolValue]);
    XCTAssertFalse(_player.bitPerfectReport.enabled);
}
- (void)testLiveFXAndBitPerfectRouting {
    for (NSNumber *rate in @[@44100, @48000, @96000]) for (NSNumber *initialFX in @[@NO, @YES]) {
        [self startPlayerAt:rate.doubleValue channels:2 fx:initialFX.boolValue bitPerfect:NO automatic:NO];
        if (!initialFX.boolValue) {
            XCTAssertLessThanOrEqual([_player.debugEngineCounts[@"hostedUnits"] unsignedIntegerValue], 1u);
        }
        NSURL *url = [self fixture:[NSString stringWithFormat:@"noise-%@-24-2.wav", rate]];
        AudioTrack *track = [self play:url paused:YES position:0.25];
        NSUInteger installedNodes = 0;
        for (int i = 0; i < 8; i++) {
            BOOL bitPerfect = i % 2;
            [_player setBitPerfectOutput:bitPerfect exclusiveOutput:NO enableFX:YES];
            NSDictionary *counts = _player.debugEngineCounts;
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
            [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:enabled.boolValue];
            NSDictionary *counts = _player.debugEngineCounts;
            XCTAssertEqual([counts[@"fxConnected"] boolValue], enabled.boolValue);
            XCTAssertTrue(_player.isPlaying);
            XCTAssertEqual(_player.currentTrack, track);
            XCTAssertEqualWithAccuracy(_player.position, position, 1.0 / _rate);
            [self assertFinite:[self renderSeconds:0.1] peak:0.3];
        }
        XCTAssertEqual([self count:@"finish"], 0u);
        XCTAssertEqual([self count:@"start"], 1u);
        [_player setBitPerfectOutput:YES exclusiveOutput:NO enableFX:YES];
        [self play:url paused:NO position:0];
        [self assertReference:PCM([self read:url]) capture:[self renderSeconds:2.1]
                         skip:[self startupSkip] tolerance:0];
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
            XCTAssertEqual([_player.debugEngineCounts[@"retiredFades"] unsignedIntegerValue], 0u,
                           @"Bit-perfect playback retained a two-second crossfade: %@", _player.debugEngineCounts);
            XCTAssertEqualWithAccuracy([_player.debugEngineCounts[@"gain"] doubleValue], 1, 1e-6);
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
    AudioDeviceManager *devices = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) {
        return @[];
    } retryScheduler:nil];
    // Replace only the device I/O boundaries; the real rebuild and PCM path run.
    __block BOOL defaultReadSucceeds = NO;
    __block BOOL defaultBindRefused = NO;
    Method methods[] = {
        class_getClassMethod(AudioDeviceManager.class, @selector(sharedInstance)),
        class_getClassMethod(CoreAudioUtil.class, @selector(systemDefaultOutputDeviceID)),
        class_getClassMethod(CoreAudioUtil.class, @selector(readSystemDefaultOutputDeviceID:)),
        class_getInstanceMethod(AudioPlayer.class, @selector(setOutputUnitDevice:)),
    };
    IMP replacements[] = {
        imp_implementationWithBlock(^AudioDeviceManager *(id cls) { return devices; }),
        imp_implementationWithBlock(^AudioDeviceID(id cls) { return 1; }),
        imp_implementationWithBlock(^BOOL(id cls, AudioDeviceID *device) {
            *device = defaultBindRefused ? 1 : kAudioObjectUnknown;
            return defaultReadSucceeds;
        }),
        imp_implementationWithBlock(^BOOL(id player, AudioDeviceID device) { return NO; }),
    };
    IMP originals[4];
    for (NSUInteger i = 0; i < 4; i++) originals[i] = method_setImplementation(methods[i], replacements[i]);
    @try {
        for (NSString *failure in @[@"concrete", @"system-refused", @"system-unreadable", @"system-missing"])
        for (NSString *state in @[@"stopped", @"paused", @"playing"]) {
            BOOL systemOutput = [failure hasPrefix:@"system-"];
            defaultBindRefused = [failure isEqualToString:@"system-refused"];
            defaultReadSucceeds = defaultBindRefused || [failure isEqualToString:@"system-missing"];
            BOOL committedSystemOutput = systemOutput && !defaultBindRefused;
            [self startPlayerAt:44100 channels:2 fx:YES bitPerfect:YES automatic:NO];
            NSURL *url = [self fixture:@"noise-44100-24-2.wav"];
            if (![state isEqualToString:@"stopped"]) {
                [self play:url paused:[state isEqualToString:@"paused"] position:0];
                [self render:4096];
            }
            XCTAssertFalse([_player.debugEngineCounts[@"fxConnected"] boolValue]);
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
            XCTAssertNotNil(_playError);
            XCTAssertEqual(_player.currentlyRequestedAudioDeviceId, committedSystemOutput ? -1 : requestedDevice);
            XCTAssertEqual(_player.bitPerfectReport.enabled, !committedSystemOutput);
            XCTAssertEqual([_player.debugEngineCounts[@"fxConnected"] boolValue], committedSystemOutput);
            if (committedSystemOutput && ![state isEqualToString:@"stopped"]) {
                XCTAssertEqual(_player.currentTrack, track);
                XCTAssertEqualWithAccuracy(_player.position, position, 1.0 / _rate);
                XCTAssertEqual(_player.isPaused, defaultReadSucceeds || [state isEqualToString:@"paused"]);
                XCTAssertTrue([_player.debugEngineCounts[@"varispeed"] boolValue]);
            } else {
                XCTAssertTrue(_player.isStopped);
            }
            // Unchanged modes stay a no-op; replay must still render exact PCM.
            [_player setBitPerfectOutput:!committedSystemOutput exclusiveOutput:NO enableFX:YES];
            _playError = nil;
            [self play:url paused:NO position:0];
            XCTAssertEqual([_player.debugEngineCounts[@"fxConnected"] boolValue], committedSystemOutput);
            XCTAssertEqual([_player.debugEngineCounts[@"varispeed"] boolValue], committedSystemOutput);
            [self assertReference:PCM([self read:url]) capture:[self renderSeconds:2.1]
                             skip:[self startupSkip] tolerance:(committedSystemOutput ? 1e-10 : 0)];
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
    [_player setBitPerfectOutput:YES exclusiveOutput:NO enableFX:YES];
    [self render:2048];
    [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:YES];
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
        (void)_player.debugEngineCounts;
        // Hold engine work until the later UI actions have published their intent.
        dispatch_queue_t queue = [_player valueForKey:@"queue"];
        dispatch_suspend(queue);
        @try {
            [_player setBitPerfectOutput:bitPerfect.boolValue exclusiveOutput:NO enableFX:bitPerfect.boolValue];
            XCTAssertFalse(_player.fx.lowKillEnabled);
            XCTAssertFalse(_player.fx.lowKillBoostActive);
            XCTAssertFalse(_player.fx.reverbSendEnabled);
            XCTAssertFalse(_player.fx.delaySendEnabled);
            XCTAssertFalse(_player.fx.shortDelaySendEnabled);
            [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:YES];
            _player.fx.lowKillEnabled = YES;
            _player.fx.lowKillBoostActive = YES;
            _player.fx.reverbSendEnabled = YES;
            _player.fx.delaySendEnabled = YES;
            _player.fx.shortDelaySendEnabled = YES;
        }
        @finally {
            dispatch_resume(queue);
        }
        XCTAssertTrue([_player.debugEngineCounts[@"fxConnected"] boolValue]);
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
        XCTAssertEqual([self count:@"finish"],0u); XCTAssertEqual([_player.debugEngineCounts[@"hostedUnits"] unsignedIntegerValue],0u);
        XCTAssertEqual([_player.debugEngineCounts[@"retiredFades"] unsignedIntegerValue],0u);
    }
}
// Ordinary playback converts a file at another rate inside the bus, on the
// decode queue; bit-perfect output plays each file at its own rate, so the
// bus's converter is measured here and nowhere else: gain flat within 0.01 dB,
// duration exact, and a tone above the bus's Nyquist below -90 dBFS.
- (void)testOrdinaryPlaybackConvertsRateInTheBus {
    for (NSArray<NSNumber *> *rates in @[@[@48000,@44100],@[@44100,@48000],@[@96000,@44100]]) {
        NSNumber *rate=rates[1];
        NSString *tone=[NSString stringWithFormat:@"tone-%@.wav",rates[0]];
        [self startPlayerAt:rate.doubleValue channels:2 fx:NO bitPerfect:NO automatic:NO];
        [self play:[self fixture:tone] paused:NO position:0]; NSData *data=[self renderSeconds:1];
        XCTAssertTrue([_player.debugEngineCounts[@"varispeed"] boolValue]);
        NSRange window=NSMakeRange((NSUInteger)(_rate*0.25),(NSUInteger)(_rate*0.5));
        double amplitude=ToneAmplitude(data,2,0,_rate,1000,window);
        XCTAssertLessThan(fabs(20*log10(amplitude/0.25)),0.01);
        XCTAssertEqualWithAccuracy(_player.position,1,0.02);
        double signal=amplitude/sqrt(2), rms=RMS(data,2,0,window);
        XCTAssertLessThan(fabs(rms-signal),0.00001);
        [self render:(NSUInteger)(_rate*3.1)]; XCTAssertEqual([self count:@"finish"],1u);
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
        XCTAssertLessThanOrEqual([_player.debugEngineCounts[@"retiredFades"] unsignedIntegerValue],8u);
        XCTAssertLessThanOrEqual([_player.debugEngineCounts[@"liveVoices"] unsignedIntegerValue],8u);
    }
    NSData *tail=[self renderSeconds:2.2];
    [self assertFinite:tail peak:2.0];
    XCTAssertEqual([_player.debugEngineCounts[@"retiredFades"] unsignedIntegerValue],0u);
    XCTAssertEqual([_player.debugEngineCounts[@"liveVoices"] unsignedIntegerValue],1u);
    XCTAssertEqual([self count:@"start"],31u); XCTAssertEqual([self count:@"finish"],0u);
    XCTAssertTrue(_player.isPlaying); XCTAssertEqualObjects(_player.currentTrack.url,urls[0]); // the thirtieth skip landed on a
}
// A decoder that gets no turn: the voice plays what its ring holds, then
// zero-fills, holds its position and counts the frames it could not fill;
// fed again, it continues from the exact frame it stopped at.
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
    XCTAssertEqual([_player.debugEngineCounts[@"underrunFrames"] unsignedIntegerValue],96000u-held);
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
// Ordinary playback declicks both edges, and so does bit-perfect output by
// default; with Declick off it writes no volume, so its first sample is the
// file's and a stop cuts at once. Modes: 0 ordinary, 1 bit-perfect, 2
// bit-perfect with Declick off.
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
        // The node is retired only after its ramp; no full-amplitude discontinuity.
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
        XCTAssertEqual([_player.debugEngineCounts[@"retiredFades"] unsignedIntegerValue],0u);
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

- (void)record:(NSString *)event track:(AudioTrack *)track {
    [_events addObject:@{@"event":event,@"track":track.url.path?:@"",@"position":@(_player.position),@"render":_player.debugEngineCounts?:@{}}];
}
- (void)audioPlayerDidInitialize:(AudioPlayer *)p { [self record:@"init" track:nil]; }
- (void)audioPlayer:(AudioPlayer *)p didStartPlaying:(AudioTrack *)t {
    [self record:@"start" track:t];
    if (_chain && _nextPrefetch<_chain.count) [p prefetchTrack:_chain[_nextPrefetch]];
}
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
        XCTAssertEqual(binds, 1u, @"One failed HAL bind must return; regression guard capped recursion at four");
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
        [self waitForExpectations:@[published] timeout:2];
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
        XCTAssertFalse([_player.debugEngineCounts[@"running"] boolValue]);
        AudioTrack *lateTrack = [[AudioTrack alloc] initWithURL:[self fixture:@"noise-48000-24-2.wav"]];
        [_player play:lateTrack];
        [_player prefetchTrack:lateTrack];
        [_player setBitPerfectOutput:YES exclusiveOutput:YES enableFX:NO];
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
        dispatch_semaphore_wait(publish, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
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

- (void)audioPlayer:(AudioPlayer *)p didPausePlaying:(AudioTrack *)t { [self record:@"pause" track:t]; }
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
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
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
        [_player runSyncOnQueue:^{}];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
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
            [self->_player setBitPerfectOutput:YES exclusiveOutput:YES enableFX:YES];
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
        [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:YES];
        [_player runSyncOnQueue:^{}];
        XCTAssertFalse([_player.outputDeviceDiagnosticSnapshot[@"bitPerfectWanted"] boolValue], @"Once persisted, the destination's later edits must win");
    } @finally {
        [_player debugShutdown]; _player=nil;
        for(NSUInteger i=0;i<3;i++) { method_setImplementation(methods[i],originals[i]); imp_removeBlock(replacements[i]); }
    }
}

#pragma mark - The varispeed at zero, the output's rate, the 16-bit decode, disabled FX, the path

// At zero pitch the varispeed is hosted but not in the chain: the bus renders
// straight into the output, sample-exact, and the unit renders nothing. The
// fader leaving and returning to zero engages and disengages it without a
// click or a skip: on a 100 Hz tone every transition keeps the waveform
// continuous and its envelope full, the file advances exactly as far as the
// rates played, and back at zero the output is the file again, exactly, with
// the unit idle.
- (void)testZeroPitchRendersTheBusDirectlyAndTogglesAreClickFree {
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    NSURL *noise = [self fixture:@"noise-48000-24-2.wav"];
    [self play:noise paused:NO position:0];
    [self assertReference:PCM([self read:noise]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    NSDictionary *counts = _player.debugEngineCounts;
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
        NSDictionary *counts = _player.debugEngineCounts;
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
    uint64_t historyWrites = [_player.debugEngineCounts[@"varispeedHistoryWrites"] unsignedLongLongValue];
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
    uint64_t renders = [_player.debugEngineCounts[@"varispeedRenders"] unsignedLongLongValue];
    XCTAssertGreaterThan(renders, 0ull, @"the varispeed rendered while the pitch was off zero");
    [self play:noise paused:NO position:0];
    [self assertReference:PCM([self read:noise]) capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
    counts = _player.debugEngineCounts;
    XCTAssertEqual([counts[@"varispeedRenders"] unsignedLongLongValue], renders, @"the varispeed rendered at zero pitch");
    XCTAssertEqual([counts[@"varispeedHistoryWrites"] unsignedLongLongValue], historyWrites, @"the history ring was written at zero pitch");
}

// The output's rate moves under the pipeline — a device's would under the
// unit, the route's under the iOS engine; here the pump's — and the pipeline
// follows it, keeping the track: playing, the tone continues at the new rate
// from the same position; paused, the position holds through the change and
// the resume continues there.
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
    XCTAssertEqual([_player.debugEngineCounts[@"outputRate"] doubleValue], 96000.0);
    XCTAssertTrue([_player.debugEngineCounts[@"varispeed"] boolValue], @"the varispeed was hosted again at the new rate");
    NSData *data = [self renderSeconds:0.5];
    XCTAssertEqualWithAccuracy(ToneAmplitude(data, 2, 0, 96000, 1000, NSMakeRange(9600, 24000)), 0.25, 0.005);
    XCTAssertEqualWithAccuracy(_player.position, before + 0.5, 0.01);
    XCTAssertEqual([self count:@"finish"], 0u);
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

// A lossy source read as 16-bit integers for a 16-bit device is read at the
// bus's rate and width, not the file's: a 48 kHz file on a 96 kHz bus plays
// at its own speed, a mono one lands in both channels, and every sample sits
// on the 16-bit grid after the one rounding, the converter's last step. The
// reference is the decode resampled the same way and rounded.
- (void)testSixteenBitLossyDecodeFollowsTheBusRateAndChannels {
    XCTSkipUnless([NSFileManager.defaultManager fileExistsAtPath:[self fixture:@"cbr.mp3"].path],
                  @"Optional encoder fixtures unavailable; install ffmpeg and regenerate");
    NSURL *mono = [self writeMonoAAC];
    Method method = class_getInstanceMethod(AudioPlayer.class, @selector(decodesAsInteger16OnQueueForFile:));
    IMP replacement = imp_implementationWithBlock(^BOOL(AudioPlayer *player, AVAudioFile *file) {
        AudioStreamBasicDescription sixteen = {0};
        sixteen.mSampleRate = file.processingFormat.sampleRate;
        sixteen.mFormatID = kAudioFormatLinearPCM;
        sixteen.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        sixteen.mBitsPerChannel = 16;
        return VibeBitPerfectDecodesAsInteger16(*file.fileFormat.streamDescription, sixteen);
    });
    IMP original = method_setImplementation(method, replacement);
    @try {
        for (NSURL *url in @[[self fixture:@"cbr.mp3"], mono]) {
            AVAudioPCMBuffer *decoded = [self read:url];
            [self startPlayerAt:96000 channels:2 fx:NO bitPerfect:YES automatic:NO];
            [self play:url paused:NO position:0];
            AVAudioFormat *decodeFormat = _player.debugCurrentDecodeFormat;
            XCTAssertEqual(decodeFormat.commonFormat, AVAudioPCMFormatInt16, @"%@", url.lastPathComponent);
            XCTAssertEqual(decodeFormat.sampleRate, 96000.0, @"%@", url.lastPathComponent);
            XCTAssertEqual(decodeFormat.channelCount, 2u, @"%@", url.lastPathComponent);
            NSDictionary *conversion = _player.debugCurrentConversion;
            XCTAssertEqualObjects(conversion[@"algorithm"], AVSampleRateConverterAlgorithm_Mastering, @"%@", url.lastPathComponent);
            XCTAssertEqual([conversion[@"quality"] integerValue], (NSInteger)AVAudioQualityMax);
            XCTAssertEqualObjects(conversion[@"toSampleFormat"], @"int16");
            XCTAssertEqual([conversion[@"mixed"] boolValue], decoded.format.channelCount == 1);
            NSData *capture = [self renderSeconds:decoded.frameLength / decoded.format.sampleRate + 0.1];
            XCTAssertEqual([self count:@"finish"], 1u, @"%@ played at its own speed", url.lastPathComponent);
            // Past the startup declick, which ramps the first 10 ms, every
            // sample sits on the grid.
            const float *p = capture.bytes;
            NSUInteger offGrid = 0;
            for (NSUInteger i = [self startupSkip] * 2; i < capture.length / sizeof(float); i++) {
                if (fabs(p[i] * 32768 - round(p[i] * 32768)) > 1e-3) offGrid++;
            }
            XCTAssertEqual(offGrid, 0u, @"%@: samples off the 16-bit grid", url.lastPathComponent);
            NSData *reference = [self int16Grid:[self resample:[self stereo:decoded] to:96000]];
            [self assertReference:reference capture:capture skip:[self startupSkip] tolerance:2.0f / 32768];
        }
    } @finally {
        [_player debugShutdown]; _player = nil;
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
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
    AVAudioFile *file = [[AVAudioFile alloc] initForWriting:url
            settings:@{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @44100, AVNumberOfChannelsKey: @1, AVEncoderBitRateKey: @128000}
            error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertTrue([file writeFromBuffer:buffer error:&error], @"%@", error);
    file = nil;
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

// The same conversion the bus makes: mastering quality, the whole buffer.
- (AVAudioPCMBuffer *)resample:(AVAudioPCMBuffer *)buffer to:(double)rate {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:buffer.format.channelCount];
    AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:buffer.format toFormat:format];
    converter.sampleRateConverterQuality = AVAudioQualityMax;
    converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering;
    AVAudioFrameCount capacity = (AVAudioFrameCount)(buffer.frameLength * rate / buffer.format.sampleRate) + 4096;
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:capacity];
    __block BOOL supplied = NO;
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [converter convertToBuffer:out error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount packets, AVAudioConverterInputStatus *inputStatus) {
        if (supplied) { *inputStatus = AVAudioConverterInputStatus_EndOfStream; return nil; }
        supplied = YES;
        *inputStatus = AVAudioConverterInputStatus_HaveData;
        return buffer;
    }];
    XCTAssertNotEqual(status, AVAudioConverterOutputStatus_Error, @"%@", error);
    return out;
}

- (NSData *)int16Grid:(AVAudioPCMBuffer *)buffer {
    NSMutableData *pcm = PCM(buffer);
    float *p = pcm.mutableBytes;
    for (NSUInteger i = 0; i < pcm.length / sizeof(float); i++) p[i] = fminf(32767, fmaxf(-32768, roundf(p[i] * 32768))) / 32768;
    return pcm;
}

// FX disabled with the reverb and a delay still ringing out: the segment
// leaves the render at once — its units render nothing more, and the output
// is the file, sample for sample, from where playback stood.
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
    XCTAssertGreaterThan([_player.debugEngineCounts[@"unitRenders"] unsignedLongLongValue], 0ull, @"the sends rendered");
    [_player setBitPerfectOutput:NO exclusiveOutput:NO enableFX:NO];
    [_player runSyncOnQueue:^{}];
    NSDictionary *counts = _player.debugEngineCounts;
    XCTAssertFalse([counts[@"fxConnected"] boolValue]);
    XCTAssertTrue(_player.isPlaying);
    uint64_t rested = [counts[@"unitRenders"] unsignedLongLongValue];
    NSUInteger from = (NSUInteger)llround(_player.position * 48000);
    NSData *capture = [self renderSeconds:1.0];
    XCTAssertEqual([_player.debugEngineCounts[@"unitRenders"] unsignedLongLongValue], rested, @"a disabled segment rendered a unit");
    NSData *excerpt = [reference subdataWithRange:NSMakeRange(from * 2 * sizeof(float), 48000 * 2 * sizeof(float))];
    [self assertReference:excerpt capture:capture skip:0 tolerance:0];
    // The tails' pending rests fire without touching a unit.
    [self render:48000 * 12];
    XCTAssertEqual([_player.debugEngineCounts[@"unitRenders"] unsignedLongLongValue], rested);
}

// A lossless codec's depth is the one it declares, not the container's 0,
// and its flags are never read as PCM's: FLAC's and ALAC's 24-bit flag
// carries the float bit, and the row once read them as 32-bit float.
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

// The player's half of the reopen wait's bound: a rebuild's stopReading
// joins the decoder while a late successor's reopen waits for a render held
// inside the bus, and completes at the new rate with the render still held.
- (void)testARebuildCompletesWhileAVoiceRenderIsStuck {
    self.continueAfterFailure = YES;
    // The real decode queue under the frame-driven pump, as the seek test does.
    Method initializer = class_getInstanceMethod(AudioVoiceBus.class, @selector(initWithFormat:queue:inlineDecoding:));
    __block IMP originalInit;
    IMP asyncInit = imp_implementationWithBlock(^id(id receiver, AVAudioFormat *format, dispatch_queue_t queue, BOOL inlineDecoding) {
        return ((id (*)(id, SEL, AVAudioFormat *, dispatch_queue_t, BOOL))originalInit)(receiver, @selector(initWithFormat:queue:inlineDecoding:), format, queue, NO);
    });
    originalInit = method_setImplementation(initializer, asyncInit);
    @try {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        [_player debugStarveDecoder:YES];
        NSData *pcm = PCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
        [self play:[self write:[pcm subdataWithRange:NSMakeRange(0, 2000 * 8)] rate:48000 channels:2 name:@"ended-short.wav"] paused:NO position:0];
    } @finally {
        method_setImplementation(initializer, originalInit);
        imp_removeBlock(asyncInit);
    }
    __block AudioVoiceBus *bus;
    __block VibeVoiceID voice;
    [_player runSyncOnQueue:^{
        bus = [self->_player valueForKey:@"voiceBus"];
        voice = [[self->_player valueForKey:@"voice"] unsignedLongLongValue];
    }];
    dispatch_sync(bus.decodeQueue, ^{});
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
        XCTAssertEqual(dispatch_group_wait(rebuild, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0L,
                       @"the rebuild joined a decoder waiting for the stuck render");
        XCTAssertEqual(bus.debugRendersHeld, 1u, @"the render was still stuck when the rebuild completed");
        XCTAssertEqualWithAccuracy([_player.debugEngineCounts[@"outputRate"] doubleValue], 96000, 0);
    } @finally {
        [bus debugHoldRender:NO];
        XCTAssertEqual(dispatch_group_wait(stuck, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L);
        XCTAssertEqual(dispatch_group_wait(rebuild, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L);
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
    Method read = class_getInstanceMethod(AVAudioFile.class, @selector(readIntoBuffer:frameCount:error:));
    __block IMP original;
    __block _Atomic(BOOL) held = NO;
    IMP blocked = imp_implementationWithBlock(^BOOL(AVAudioFile *file, AVAudioPCMBuffer *buffer, AVAudioFrameCount frames, NSError **error) {
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
        XCTAssertEqual(dispatch_semaphore_wait(reading, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), 0L);
        AudioPlayer *player = _player;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            XCTAssertTrue([player debugSetOutputRate:96000]);
            dispatch_semaphore_signal(rebuilt);
        });
        rebuildWait = dispatch_semaphore_wait(rebuilt, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [player runSyncOnQueue:^{ dispatch_semaphore_signal(responsive); }];
        });
        queueWait = dispatch_semaphore_wait(responsive, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        XCTAssertEqual(rebuildWait, 0L, @"the rate change waited on the stalled read");
        XCTAssertEqual(queueWait, 0L, @"the player queue waited on the stalled read");
        XCTAssertEqualWithAccuracy([_player.debugEngineCounts[@"outputRate"] doubleValue], 96000, 0);
        XCTAssertTrue(_player.isPlaying);
        // The re-voiced track reads nothing while the retired decoder may be
        // inside its file: the pump runs, and the position holds.
        NSTimeInterval before = _player.position;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        XCTAssertEqualWithAccuracy(_player.position, before, 0.0001, @"the file was read under the stalled decoder");
    } @finally {
        dispatch_semaphore_signal(releaseRead);
        if (rebuildWait) dispatch_semaphore_wait(rebuilt, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        if (queueWait) dispatch_semaphore_wait(responsive, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        [_player runSyncOnQueue:^{}];
    }
    // The read released, the retired decoder leaves and the track plays on.
    NSTimeInterval resumedFrom = _player.position;
    [self settleUntil:^BOOL { return self->_player.position > resumedFrom + 0.1; }];
    XCTAssertGreaterThan(_player.position, resumedFrom + 0.1, @"the track never played after the decoder left");
    XCTAssertNil(_playError);
    method_setImplementation(read, original);
    imp_removeBlock(blocked);
}

// A failed effect render is silence, not audio, and the status reaches the
// carrier; a rebuild hosts the units again and the chain renders.
- (void)testAFailedEffectSilencesTheSliceAndReachesTheCarrier {
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
        XCTAssertNil(output, @"unit %@: the carrier received a failed slice as audio", unit);
        XCTAssertNotNil(error, @"unit %@", unit);
        XCTAssertTrue([_player debugSetOutputRate:96000], @"unit %@", unit);
        [self assertFinite:[self renderSeconds:0.1] peak:1.0f];
    }
}

// A production player with no carrier — the output unit could not be made —
// fails the start with an error instead of publishing Playing over nothing.
- (void)testAMissingOutputUnitFailsTheStart {
    self.continueAfterFailure = YES;
    Method initializer = class_getInstanceMethod(AudioOutputUnit.class, @selector(init));
    IMP failure = imp_implementationWithBlock(^id(id receiver) { return nil; });
    IMP original = method_setImplementation(initializer, failure);
    @try {
        _player = [[AudioPlayer alloc] initWithDeviceUID:@"" name:@"" enableFX:NO delegate:self
                                  loadingConfiguration:[AudioLoadingConfiguration productionConfiguration]];
        [self settleUntil:^BOOL { return [self count:@"init"] == 1; }];
        XCTAssertFalse(_player.manualRenderingActive);
        [_player play:[AudioTrack withURL:[self fixture:@"noise-48000-24-2.wav"]]];
        [self settleUntil:^BOOL { return [self count:@"start"] > 0 || self->_playError; }];
        XCTAssertNotNil(_playError, @"a missing carrier must fail the start");
        XCTAssertEqual(_playError.code, VibeAudioErrorEngineStartFailed);
        XCTAssertTrue(_player.isStopped);
        XCTAssertFalse(_player.outputAudioActive);
        XCTAssertEqual([self count:@"start"], 0u);
    } @finally {
        method_setImplementation(initializer, original);
        imp_removeBlock(failure);
    }
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
    XCTAssertEqualObjects(decode[@"algorithm"], AVSampleRateConverterAlgorithm_Mastering);
    XCTAssertEqual([decode[@"quality"] integerValue], (NSInteger)AVAudioQualityMax);
    XCTAssertEqualObjects(decode[@"toSampleFormat"], @"float32");
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
    XCTAssertEqualObjects(output[@"carrier"], @"pump");
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

@end
