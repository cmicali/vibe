//
//  AudioPlayerRenderFidelityTests.m
//

#import "AudioPlayerRenderTestCase.h"
#import "AudioFX.h"
#import "OutputFormatRules.h"
#import <Accelerate/Accelerate.h>
#include <ogg/ogg.h>

// The oracle itself, the bit-perfect matrix, every container and codec, float limits and wide sources.
@interface AudioPlayerRenderFidelityTests : AudioPlayerRenderTests
@end
@implementation AudioPlayerRenderFidelityTests

- (void)testOracleRejectsCorruption {
    _channels=2;
    NSData *reference=VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    XCTAssertTrue([VibeComparePCM(reference,reference,2,0,0)[@"pass"] boolValue]);
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
        XCTAssertFalse([VibeComparePCM(reference,bad,2,0,0)[@"pass"] boolValue],@"%@ escaped",mutation);
    }
    // One bit below float32's significand, which no float reference can hold.
    NSData *wide=[self wideSourcePCM:[self fixture:@"integer32.wav"]], *capture=VibeFloat32PCM(wide);
    XCTAssertTrue([VibeCompareWidePCM(wide,capture,2,0,0)[@"pass"] boolValue]);
    NSMutableData *bad=[wide mutableCopy];
    ((double *)bad.mutableBytes)[24000]+=1.0/2147483648;
    XCTAssertEqual([VibeCompareWidePCM(bad,capture,2,0,0)[@"mismatchedSamples"] unsignedIntegerValue],1u);
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
        NSData *reference=VibePCM([self read:url]); [self play:url paused:NO position:0];
        [self assertReference:reference capture:[self renderSeconds:2.1] skip:[self startupSkip] tolerance:0];
        // Transparent because nothing renders: the varispeed is out of the
        // chain at zero pitch, and an idle segment's units are at rest.
        NSDictionary *counts=_player.debugRenderCounts;
        XCTAssertEqual([counts[@"varispeedRenders"] unsignedLongLongValue],0ull);
        XCTAssertEqual([counts[@"unitRenders"] unsignedLongLongValue],0ull);
    }
}
- (void)testLosslessContainersAndExtensionAliases {
    NSData *original=VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    for (NSString *name in @[@"lossless.flac",@"lossless.m4a",@"lossless.aiff",@"lossless.caf",@"wave64-LEI24.w64",
                             @"alias.aif",@"alias.wave",@"alias.bwf"]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        NSURL *url=[self fixture:name]; NSData *decoded=VibePCM([self read:url]);
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
    [self assertReference:VibePCM(decoded) capture:[self renderSeconds:decoded.frameLength/_rate+0.1] skip:[self startupSkip] tolerance:tolerance];
}
- (void)testAACContainer { [self checkLossy:@"lossy.m4a" tolerance:kVibeAACDecodeTolerance]; }
- (void)testAACElementary { [self checkLossy:@"lossy.aac" tolerance:kVibeAACDecodeTolerance]; }
- (void)testAACExtensionAliases {
    for (NSString *name in @[@"alias.mp4",@"alias.m4b",@"alias.m4r",@"alias.adts"]) {
        [self checkLossy:name tolerance:kVibeAACDecodeTolerance];
    }
}
// The shift in frames, within `range` either way, that lines the first
// channel of `decoded` up best with `source`'s.
static NSInteger VibeBestLag(NSData *decoded, NSData *source, NSUInteger channels, NSInteger range) {
    const float *d = decoded.bytes, *s = source.bytes;
    NSUInteger frames = MIN(decoded.length, source.length) / sizeof(float) / channels;
    NSInteger best = 0;
    double bestScore = -INFINITY;
    for (NSInteger lag = -range; lag <= range; lag++) {
        double score = 0;
        for (NSUInteger f = (NSUInteger)range; f + (NSUInteger)range < frames; f++) score += (double)s[f * channels] * d[(f + lag) * channels];
        if (score > bestScore) { bestScore = score; best = lag; }
    }
    return best;
}
// libvorbis decodes Ogg Vorbis, not CoreAudio. iOS has no Vorbis decoder,
// and macOS's starts each file 128 frames late (macOS 27). The player plays
// the decode exactly. The decode lines up with the source, with no shift.
// Apple's decode is libvorbis's own, sample for sample, 128 frames on. That
// comparison is the canary, and fails once Apple's lines up. Seeks land
// exactly, and an interleaved read matches the planar one.
- (void)testOggVorbis {
    NSData *source = VibePCM([self read:[self fixture:@"noise-48000-24-2.wav"]]);
    for (NSString *name in @[@"lossy.ogg", @"alias.oga"]) {
        [self checkLossy:name tolerance:0];
        NSURL *url = [self optionalFixture:name];
        AudioFileHandle *file = [self open:url decoder:@"libvorbis"];
        NSData *decoded = [self readToEnd:file];
        NSUInteger frames = decoded.length / sizeof(float) / 2, frameBytes = 2 * sizeof(float);
        XCTAssertEqual(file.length, (AVAudioFramePosition)frames, @"%@", name);
        XCTAssertEqual(VibeBestLag(decoded, source, 2, 256), 0, @"%@ lines up with its source", name);
        NSData *apple = [self appleDecodeOf:url];
        NSUInteger shared = MIN(frames - 128, apple.length / frameBytes);
        XCTAssertGreaterThan(shared, frames / 2, @"%@: Apple's decode", name);
        XCTAssertEqualObjects([decoded subdataWithRange:NSMakeRange(128 * frameBytes, shared * frameBytes)],
                              [apple subdataWithRange:NSMakeRange(0, shared * frameBytes)],
                              @"%@: Apple's Vorbis decode no longer starts 128 frames late. Re-measure it (docs/future/audio-quality-gaps.md).", name);
        [self assertSeeksOf:file match:decoded block:256 name:name];
        AudioFileHandle *interleaved = [[AudioFileHandle alloc] initForReading:url interleaved:YES error:NULL];
        XCTAssertTrue(interleaved.processingFormat.isInterleaved, @"%@", name);
        XCTAssertEqualObjects([self readToEnd:interleaved], decoded, @"%@ read interleaved", name);
    }
}
// vorbisfile reads the first audio page at open, for the stream's start, and
// the last, for its length, looking back 64 KB at most. So a file still
// downloading opens once its head has arrived, with its end from the tail
// window, which in production is 128 KB for an Ogg file
// (VibeAudioFileTailWindowBytes). The fixture's pages are 100 ms, so its head
// and its end lie apart. A seek lands exactly. A read that reaches the
// download's edge waits, and an interrupt ends it as an interruption, never
// as the stream's end. After a seek the whole decodes as the file does.
- (void)testOggVorbisOpensWhileItStreams {
    NSURL *source = [self optionalFixture:@"paged.ogg"];
    AudioFileHandle *whole = [self open:source decoder:@"libvorbis"];
    NSData *continuous = [self readToEnd:whole];
    NSURL *url = [self streamingCopyOf:source prefix:32 * 1024 name:@"streaming-paged.ogg"];
    [self installTailWindow:80 * 1024];
    AudioFileHandle *file = [self openWhileItStreams:url name:@"paged.ogg"];
    XCTAssertEqualObjects(file.decoderName, @"libvorbis");
    XCTAssertEqual(file.length, whole.length);
    [self assertSeekOf:file to:2048 match:continuous name:@"paged.ogg, downloading"];
    __block NSError *readError = nil;
    __block NSData *before = nil;
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *pcm = [NSMutableData data];
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:4096];
        NSError *error = nil;
        while ([file readIntoBuffer:buffer error:&error] && buffer.frameLength > 0) VibeAppendPCM(pcm, buffer);
        readError = error;
        before = pcm;
        dispatch_semaphore_signal(returned);
    });
    [self settleUntil:^BOOL { return file.waitingForBytes; }]; // the read waits at the download's edge
    [file interruptReads];
    XCTAssertEqual(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    XCTAssertTrue([AudioFileHandle isInterruption:readError], @"%@", readError);
    XCTAssertLessThan(before.length, continuous.length - 4096 * 2 * sizeof(float), @"stopped at the download's edge");
    XCTAssertEqualObjects(before, [continuous subdataWithRange:NSMakeRange(4096 * 2 * sizeof(float), before.length)], @"what it read before");
    [file allowReads];
    XCTAssertTrue([self finishStream:VibeStreamCompleted]);
    [self assertSeeksOf:file match:continuous block:256 name:@"paged.ogg"];
    XCTAssertTrue([file seekToFrame:0 error:NULL]);
    XCTAssertEqualObjects([self readToEnd:file], continuous);
}
// Opens `url` off the test's thread, as an open worker does, and asserts it
// returns before the download completes.
- (AudioFileHandle *)openWhileItStreams:(NSURL *)url name:(NSString *)name {
    __block AudioFileHandle *file = nil;
    dispatch_semaphore_t opened = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        file = [[AudioFileHandle alloc] initForReading:url error:NULL];
        dispatch_semaphore_signal(opened);
    });
    XCTAssertEqual(dispatch_semaphore_wait(opened, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0, @"%@ opened while it streams", name);
    return file;
}
// Vorbis I's 5.1 order is L, C, R, Ls, Rs, LFE. Each channel of the fixture
// holds a tone of its own, so the decode shows where each landed. The
// player's stereo fold shows the layout was read as labelled: the center in
// both sides at -3 dB, each surround in its own side, and no LFE.
- (void)testOggVorbisSurroundKeepsItsChannelOrder {
    NSURL *url = [self optionalFixture:@"surround.ogg"];
    AudioFileHandle *file = [self open:url decoder:@"libvorbis"];
    XCTAssertEqual(file.processingFormat.channelCount, 6u);
    const AudioChannelLayout *layout = file.processingFormat.channelLayout.layout;
    const AudioChannelLabel labels[] = {kAudioChannelLabel_Left, kAudioChannelLabel_Center, kAudioChannelLabel_Right,
                                        kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LFEScreen};
    const double tones[] = {500, 900, 700, 1300, 1700, 60}; // the generator's front left, center, front right, back left, back right, LFE
    XCTAssertEqual(layout->mNumberChannelDescriptions, 6u);
    NSData *decoded = [self readToEnd:file];
    double own[6] = {0}; // each channel's own tone
    for (NSUInteger c = 0; c < 6; c++) {
        XCTAssertEqual(layout->mChannelDescriptions[c].mChannelLabel, labels[c], @"channel %lu's label", (unsigned long)c);
        for (NSUInteger t = 0; t < 6; t++) {
            double amplitude = VibeToneAmplitude(decoded, 6, c, 48000, tones[t], NSMakeRange(4800, 48000));
            if (t == c) {
                own[c] = amplitude;
                XCTAssertGreaterThan(amplitude, 0.1, @"channel %lu holds %g Hz", (unsigned long)c, tones[t]);
            } else {
                XCTAssertLessThan(amplitude, 0.005, @"channel %lu holds %g Hz", (unsigned long)c, tones[t]);
            }
        }
    }
    [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:NO automatic:NO];
    [self play:url paused:NO position:0];
    NSData *capture = [self renderSeconds:1.5];
    const double folded[2][6] = {{1, M_SQRT1_2, 0, M_SQRT1_2, 0, 0}, {0, M_SQRT1_2, 1, 0, M_SQRT1_2, 0}};
    for (NSUInteger side = 0; side < 2; side++) {
        for (NSUInteger t = 0; t < 6; t++) {
            double amplitude = VibeToneAmplitude(capture, 2, side, 48000, tones[t], NSMakeRange(9600, 48000));
            double expected = folded[side][t] * own[t];
            XCTAssertEqualWithAccuracy(amplitude, expected, 0.005, @"side %lu, %g Hz", (unsigned long)side, tones[t]);
        }
    }
}
// A chained Ogg file is whole Ogg streams one after another. A chain whose
// streams share their rate and channels plays as one track: both streams'
// frames in order, their length together, every seek exact. The bus keeps
// one format per file. So a chain whose channels change goes to CoreAudio's
// parser, and libvorbis never decodes it. macOS 27's parser then plays the
// first stream alone, and iOS's refuses Vorbis.
- (void)testOggVorbisChains {
    NSURL *lossy = [self optionalFixture:@"lossy.ogg"], *paged = [self optionalFixture:@"paged.ogg"];
    NSURL *surround = [self optionalFixture:@"surround.ogg"];
    NSData *one = [self readToEnd:[self open:lossy decoder:@"libvorbis"]];
    NSMutableData *twice = [one mutableCopy];
    [twice appendData:one];
    NSMutableData *uniform = [[NSData dataWithContentsOfURL:lossy] mutableCopy];
    [uniform appendData:[NSData dataWithContentsOfURL:paged]]; // the same packets, under another serial number
    AudioFileHandle *chain = [self open:[self writeBytes:uniform name:@"chain.ogg"] decoder:@"libvorbis"];
    XCTAssertEqual(chain.length, (AVAudioFramePosition)(twice.length / (2 * sizeof(float))), @"the chain's length is both streams'");
    NSData *decoded = [self readToEnd:chain];
    XCTAssertEqualObjects(decoded, twice, @"a chain plays its streams one after the other");
    [self assertSeeksOf:chain match:decoded block:256 name:@"chain.ogg"];

    NSMutableData *changing = [[NSData dataWithContentsOfURL:lossy] mutableCopy];
    [changing appendData:[NSData dataWithContentsOfURL:surround]];
    AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:[self writeBytes:changing name:@"chain-2-then-6.ogg"] error:NULL];
    XCTAssertNotEqualObjects(file.decoderName, @"libvorbis", @"a chain whose channels change");
}
- (void)testOpus { [self checkLossy:@"lossy.opus" tolerance:0]; }
// The Opus file with its OpusHead output gain set to `q78` (dB × 256), and
// its first page's CRC made good again.
static NSData *VibeOpusWithOutputGain(NSData *opus, int16_t q78) {
    NSMutableData *patched = [opus mutableCopy];
    uint8_t *page = patched.mutableBytes;
    size_t packet = 27 + page[26], length = packet;
    for (uint8_t s = 0; s < page[26]; s++) length += page[27 + s];
    if (patched.length < length || memcmp(page + packet, "OpusHead", 8) != 0) return nil;
    page[packet + 16] = (uint8_t)q78;
    page[packet + 17] = (uint8_t)((uint16_t)q78 >> 8);
    ogg_page first = {.header = page, .header_len = (long)packet, .body = page + packet, .body_len = (long)(length - packet)};
    ogg_page_checksum_set(&first);
    return patched;
}
// RFC 7845's output gain, which Apple's decoder ignores. The handle applies
// it, and bounds the samples at +12 dBFS as it does a damaged MP3 frame's.
// The last check is a canary. It fails once CoreAudio applies the gain too.
- (void)testOpusPlaysAtItsHeaderOutputGain {
    NSURL *url = [self optionalFixture:@"lossy.opus"];
    NSData *bytes = [NSData dataWithContentsOfURL:url];
    NSData *plain = VibePCM([self read:url]);
    NSURL *quieter = nil;
    for (NSNumber *q78 in @[@(-6 * 256), @(3 * 256 + 128), @(40 * 256)]) {
        NSURL *gained = [self writeBytes:VibeOpusWithOutputGain(bytes, q78.shortValue) name:[NSString stringWithFormat:@"gain%@.opus", q78]];
        NSMutableData *expected = [plain mutableCopy];
        float factor = powf(10, q78.floatValue / 256 / 20), low = -4, high = 4; // kVibeDecodeSampleBound
        vDSP_vsmul(expected.mutableBytes, 1, &factor, expected.mutableBytes, 1, expected.length / sizeof(float));
        vDSP_vclip(expected.mutableBytes, 1, &low, &high, expected.mutableBytes, 1, expected.length / sizeof(float));
        XCTAssertEqualObjects(VibePCM([self read:gained]), expected, @"header gain %@ / 256 dB", q78);
        if (q78.intValue < 0) quieter = gained;
    }
    XCTAssertEqualObjects(VibePCM(VibeReadWithAVAudioFile(quieter, NULL)), plain,
                          @"CoreAudio now applies the Opus output gain: drop VibeOpusOutputGain and _opusGain");
}
// The stereo fold CoreAudio's mixer makes of `layout`, as the voice bus makes
// it (VibeMixMap). A file that states no layout folds as discrete channels.
static NSData *VibeStereoFold(const AudioChannelLayout *layout, UInt32 channels) {
    AudioChannelLayout discrete = {.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | channels};
    AudioChannelLayout stereo = {.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo};
    const AudioChannelLayout *layouts[2] = {layout ?: &discrete, &stereo};
    NSMutableData *map = [NSMutableData dataWithLength:channels * 2 * sizeof(Float32)];
    UInt32 size = (UInt32)map.length;
    return AudioFormatGetProperty(kAudioFormatProperty_MatrixMixMap, sizeof(layouts), layouts, &size, map.mutableBytes) == noErr ? map : nil;
}
// Asserts `file` states what CoreAudio's parser states of `url`: every field
// of the description, and for more than two channels a layout that folds to
// stereo as the parser's does. NO when CoreAudio refuses the file. `folds` is
// whether CoreAudio has a stereo fold for its layout.
- (BOOL)assertFactsOf:(AudioFileHandle *)file matchCoreAudioOf:(NSURL *)url folds:(BOOL *)folds {
    NSString *name = url.lastPathComponent;
    ExtAudioFileRef reader = NULL;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &reader) != noErr) {
        return NO;
    }
    AudioStreamBasicDescription parsed = {0};
    UInt32 size = sizeof(parsed);
    ExtAudioFileGetProperty(reader, kExtAudioFileProperty_FileDataFormat, &size, &parsed);
    NSMutableData *layout = nil;
    if (ExtAudioFileGetPropertyInfo(reader, kExtAudioFileProperty_FileChannelLayout, &size, NULL) == noErr && size > 0) {
        layout = [NSMutableData dataWithLength:size];
        ExtAudioFileGetProperty(reader, kExtAudioFileProperty_FileChannelLayout, &size, layout.mutableBytes);
        const AudioChannelLayout *stated = layout.bytes;
        if (!stated->mChannelLayoutTag && !stated->mChannelBitmap && !stated->mNumberChannelDescriptions) layout = nil;
    }
    ExtAudioFileDispose(reader);
    const AudioStreamBasicDescription *ours = file.fileFormat.streamDescription;
    XCTAssertEqual(ours->mSampleRate, parsed.mSampleRate, @"%@", name);
    XCTAssertEqual(ours->mFormatID, parsed.mFormatID, @"%@", name);
    XCTAssertEqual(ours->mFormatFlags, parsed.mFormatFlags, @"%@", name);
    // MPEG in a WAV: CoreAudio states the WAV's block as the packet size, and
    // opens one only when every frame is that size. The walk sizes each frame.
    BOOL wrapped = ours->mFramesPerPacket >= 384 && ours->mBytesPerPacket == 0 && [url.pathExtension isEqualToString:@"wav"];
    XCTAssertEqual(ours->mBytesPerPacket, wrapped ? 0 : parsed.mBytesPerPacket, @"%@", name);
    XCTAssertEqual(ours->mFramesPerPacket, parsed.mFramesPerPacket, @"%@", name);
    XCTAssertEqual(ours->mBytesPerFrame, parsed.mBytesPerFrame, @"%@", name);
    XCTAssertEqual(ours->mChannelsPerFrame, parsed.mChannelsPerFrame, @"%@", name);
    XCTAssertEqual(ours->mBitsPerChannel, parsed.mBitsPerChannel, @"%@", name);
    *folds = NO;
    if (parsed.mChannelsPerFrame > 2) {
        // Nil where CoreAudio has no fold for a layout, and the bus keeps the first channels.
        NSData *theirs = VibeStereoFold(layout.bytes, parsed.mChannelsPerFrame);
        XCTAssertEqualObjects(VibeStereoFold(file.processingFormat.channelLayout.layout, parsed.mChannelsPerFrame), theirs, @"%@ folds to stereo as CoreAudio's layout does", name);
        *folds = theirs != nil;
    }
    return YES;
}
// dr_flac, dr_wav and libvorbis answer a file's facts in place of CoreAudio's
// parser, and the MPEG open does for dr_mp3. dr_flac's, dr_wav's and the MPEG
// open's must be what the parser states, an AIFF's CHAN chunk included. A
// sowt AIFF-C and an extensible WAV's valid bits are two known differences
// (testDrWAVDescribesEachSampleAtItsWidth). No fixture has valid bits below
// its container. The MPEG open states CoreAudio's length too, but for a mono
// or an MPEG-2 file with an Info frame, which CoreAudio misses. It then
// trims the LAME tag's priming and remainder, and the two such fixtures play
// their source's two seconds exactly. A WAV past dr_wav's rates goes to the
// parser.
- (void)testOwnDecodersStateWhatCoreAudioStates {
    AudioFileHandle.appleMPEGDecoder = NO;
    NSURL *folder = [self fixture:@"noise-48000-24-2.wav"].URLByDeletingLastPathComponent;
    NSSet *extensions = [NSSet setWithArray:@[@"wav", @"wave", @"bwf", @"w64", @"aif", @"aiff", @"flac", @"mp3", @"mp2"]];
    NSUInteger compared = 0, wide = 0, mpeg = 0;
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:NULL]) {
        if (![extensions containsObject:url.pathExtension.lowercaseString]) continue;
        NSString *name = url.lastPathComponent;
        AudioFileHandle *file = [[AudioFileHandle alloc] initForReading:url error:NULL];
        if (!file) continue;
        const AudioStreamBasicDescription *ours = file.fileFormat.streamDescription;
        if (ours->mFormatID != kAudioFormatFLAC && ours->mSampleRate > 384000) { // dr_wav's DRWAV_MAX_SAMPLE_RATE
            XCTAssertEqualObjects(file.decoderName, @"apple", @"%@, past dr_wav's rates, goes to the parser", name);
            continue;
        }
        XCTAssertTrue([file.decoderName hasPrefix:@"dr_"], @"%@ opened with %@", name, file.decoderName);
        BOOL folds = NO;
        if ([self assertFactsOf:file matchCoreAudioOf:url folds:&folds]) {
            compared++;
            wide += folds;
        }
        if ([file.decoderName isEqualToString:@"dr_mp3"]) {
            ExtAudioFileRef reader = NULL;
            SInt64 length = -1;
            UInt32 size = sizeof(length);
            XCTAssertEqual(ExtAudioFileOpenURL((__bridge CFURLRef)url, &reader), noErr, @"%@", name);
            ExtAudioFileGetProperty(reader, kExtAudioFileProperty_FileLengthFrames, &size, &length);
            ExtAudioFileDispose(reader);
            BOOL missed = [@[@"mono.mp3", @"lsf-8k.mp3"] containsObject:name];
            XCTAssertEqual(file.length, missed ? 2 * (SInt64)ours->mSampleRate : length, @"%@", name);
            XCTAssertTrue(!missed || length > file.length, @"CoreAudio now reads %@'s Info frame", name);
            mpeg++;
        }
    }
    XCTAssertGreaterThan(compared, 90u);
    XCTAssertGreaterThan(wide, 15u);
    XCTAssertGreaterThan(mpeg, 12u);
}
// The parser open is the metadata fallback's, so a row never reads as a file
// playback refuses. The second half is the canary: once CoreAudio reports the
// length, re-check its decode and lift the refusal (AudioFileHandle.m).
- (void)testFLACInOggIsRefused {
    NSURL *url=[self optionalFixture:@"ogg-flac.oga"];
    NSError *error=nil;
    XCTAssertNil([[AudioFileHandle alloc] initForReading:url error:&error]);
    XCTAssertEqual(error.code,kAudioFileUnsupportedDataFormatError,@"%@",error);
    error=nil;
    XCTAssertNil([[AudioFileHandle alloc] initParserForReading:url error:&error]);
    XCTAssertEqual(error.code,kAudioFileUnsupportedDataFormatError,@"%@",error);
    NSURL *misnamed=[self writeBytes:[NSData dataWithContentsOfURL:url] name:@"ogg-flac.flac"];
    XCTAssertNil([[AudioFileHandle alloc] initParserForReading:misnamed error:NULL],@"refused by content, whatever its name");
    ExtAudioFileRef reader=NULL;
    XCTAssertEqual(ExtAudioFileOpenURL((__bridge CFURLRef)url,&reader),noErr);
    SInt64 length=-1; UInt32 size=sizeof(length);
    ExtAudioFileGetProperty(reader,kExtAudioFileProperty_FileLengthFrames,&size,&length);
    ExtAudioFileDispose(reader);
    XCTAssertEqual(length,0,@"CoreAudio now reports FLAC in Ogg's length: check whether it decodes in full");
}
- (void)testMP3CBR { [self checkLossy:@"cbr.mp3" tolerance:0]; }
- (void)testMP3VBR { [self checkLossy:@"vbr.mp3" tolerance:0]; }
- (void)testMP2 { [self checkLossy:@"lossy.mp2" tolerance:0]; }
// Layer III's synthesis delay: dr_mp3's drain and Apple's zero fill differ
// over this many frames at a file's end, and the handle skips it at the start.
static const NSUInteger kLayer3DecoderDelay = 529;
// Require a 50x margin below the full-accuracy RMS threshold to catch int16 output.
// Align past the 529-frame synthesis delay. Exclude the final 529 frames:
// CoreAudio does not serve the truncated final packet used by the reference.
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
        [self assertSeeksOf:file match:VibePCM(decoded) block:1152 name:name];
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
            // An Info frame states the whole file's bytes, so dr_mp3's
            // length is what the cut file holds.
            if (!apple) XCTAssertEqual(partial.length, (AVAudioFramePosition)frames[0], @"%@ truncated", name);
        }
        XCTAssertEqual(frames[0], frames[1], @"%@ truncated", name);
        XCTAssertGreaterThan(frames[0], 0u);
        XCTAssertLessThan(frames[0], decoded.frameLength);
    }
}
// An MP3 with no Xing, Info or VBRI frame opens while it streams, on its head
// and the tail window, on an estimate from its head's frames: a CBR one's the
// length its bit rate gives, the whole file's; a VBR one's within 2% for this
// encode. A seek inside what has arrived lands exactly while the download
// runs; the first read once it is complete settles either length; and either
// then decodes and seeks exactly as the whole file.
- (void)testAnMP3WithoutAVBRHeaderOpensWhileItStreams {
    AudioFileHandle.appleMPEGDecoder = NO;
    for (NSString *name in @[@"cbr-noinfo.mp3", @"vbr-noxing.mp3"]) {
        NSURL *source = [self optionalFixture:name];
        AudioFileHandle *whole = [self open:source decoder:@"dr_mp3"];
        NSData *continuous = [self readToEnd:whole];
        NSURL *url = [self streamingCopyOf:source prefix:24576 name:[@"streaming-" stringByAppendingString:name]];
        [self installTailWindow:8192];
        AudioFileHandle *file = [self openWhileItStreams:url name:name];
        XCTAssertEqualObjects(file.decoderName, @"dr_mp3", @"%@", name);
        BOOL variable = [name hasPrefix:@"vbr"];
        XCTAssertTrue(file.lengthIsEstimated, @"%@", name);
        XCTAssertEqualWithAccuracy((double)file.length, (double)whole.length, variable ? whole.length * 0.02 : 0, @"%@", name);
        [self assertSeekOf:file to:4800 match:continuous name:[name stringByAppendingString:@", downloading"]];
        XCTAssertTrue(file.lengthIsEstimated, @"%@", name);
        XCTAssertTrue([self finishStream:VibeStreamCompleted]);
        [self assertSeeksOf:file match:continuous block:1152 name:name];
        XCTAssertFalse(file.lengthIsEstimated, @"%@", name);
        XCTAssertEqual(file.length, whole.length, @"%@", name);
        XCTAssertTrue([file seekToFrame:0 error:NULL]);
        XCTAssertEqualObjects([self readToEnd:file], continuous, @"%@", name);
        XCTAssertEqual(file.length, whole.length, @"%@", name);
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
// Private bits must not be read as scfsi scalefactor-reuse flags.
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
        XCTAssertEqualObjects(VibePCM([self read:marked]), VibePCM([self read:url]), @"%@", name);
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
// The generator codes MPEG 2.5 mixed blocks directly. Leave the long part
// empty because decoders transform it differently at 8 kHz.
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
// The generator codes mixed blocks in intensity stereo, each short window with
// a bound of its own. dr_mp3 gave all three windows the highest one.
- (void)testDrMP3BoundsIntensityStereoPerWindowInMixedBlocks {
    NSString *referencePath = [self optionalFixture:@"mixed-is.f32"].path;
    AudioFileHandle.appleMPEGDecoder = NO;
    AVAudioPCMBuffer *decoded = [self read:[self fixture:@"mixed-is.mp3"]];
    XCTAssertEqual(decoded.format.channelCount, 2u);
    NSData *referenceBytes = [NSData dataWithContentsOfFile:referencePath];
    const float *reference = referenceBytes.bytes;
    NSUInteger frames = MIN(decoded.frameLength, referenceBytes.length / sizeof(float) / 2 - kLayer3DecoderDelay);
    XCTAssertGreaterThan(frames, 40000u);
    float worst = 0, peak = 0;
    for (NSUInteger c = 0; c < 2; c++) for (NSUInteger f = 0; f < frames; f++) {
        float expected = reference[(f + kLayer3DecoderDelay) * 2 + c];
        worst = fmaxf(worst, fabsf(decoded.floatChannelData[c][f] - expected));
        peak = fmaxf(peak, fabsf(expected));
    }
    XCTAssertGreaterThan(peak, 0.1f);
    XCTAssertLessThan(worst, 1e-5f, @"max error %g", worst);
}
// Where an MP3's ID3v2 tag ends: its first frame, in the generated fixtures.
static NSUInteger VibeID3v2End(NSData *file) {
    const uint8_t *b = file.bytes;
    if (file.length < 10 || memcmp(b, "ID3", 3) != 0) return 0;
    return 10 + ((NSUInteger)(b[6] & 0x7F) << 21 | (b[7] & 0x7F) << 14 | (b[8] & 0x7F) << 7 | (b[9] & 0x7F));
}
// A free format stream states no bit rate, and its frames are as long as the
// distance between headers. CoreAudio refuses one. Rewritten as free format,
// a CBR stream decodes exactly as it did, length included.
- (void)testDrMP3PlaysFreeFormat {
    NSURL *url = [self optionalFixture:@"cbr-noinfo.mp3"];
    AudioFileHandle.appleMPEGDecoder = NO;
    NSMutableData *bytes = [[NSData dataWithContentsOfURL:url] mutableCopy];
    uint8_t *b = bytes.mutableBytes;
    NSUInteger frames = 0;
    // 192 kbps at 48 kHz: every frame is 576 bytes, none padded.
    for (NSUInteger at = VibeID3v2End(bytes); at + 4 <= bytes.length; at += 576, frames++) {
        XCTAssertEqual(b[at], 0xFF);
        XCTAssertEqual(b[at + 2] >> 4, 11, @"192 kbps");
        b[at + 2] &= 0x0F;
    }
    XCTAssertGreaterThan(frames, 80u);
    NSURL *free = [self writeBytes:bytes name:@"free-format.mp3"];
    AudioFileID parser = NULL;
    XCTAssertNotEqual(AudioFileOpenURL((__bridge CFURLRef)free, kAudioFileReadPermission, 0, &parser), noErr,
                      @"CoreAudio now opens free format");
    if (parser) AudioFileClose(parser);
    AudioFileHandle *whole = [self open:url decoder:@"dr_mp3"], *file = [self open:free decoder:@"dr_mp3"];
    XCTAssertEqual(file.length, whole.length);
    NSData *continuous = [self readToEnd:file];
    XCTAssertEqualObjects(continuous, [self readToEnd:whole]);
    [self assertSeeksOf:file match:continuous block:1152 name:@"free format"];
}
// Every sixth frame of a CBR stream rewritten as free format, from the frame
// after its Info frame's next. Those frames are 3,456 bytes apart, more than
// dr_mp3's largest free format frame. The open took them for a free format
// stream of 3,456-byte frames, and dr_mp3's reservoir copy overran its
// buffer. They are damage: the stream plays its other frames.
- (void)testDrMP3NeverTakesFreeFormatFramesPastItsLargest {
    NSURL *url = [self optionalFixture:@"cbr.mp3"];
    AudioFileHandle.appleMPEGDecoder = NO;
    NSMutableData *bytes = [[NSData dataWithContentsOfURL:url] mutableCopy];
    uint8_t *b = bytes.mutableBytes;
    NSUInteger start = VibeID3v2End(bytes), rewritten = 0;
    for (NSUInteger at = start + 2 * 576; at + 4 <= bytes.length; at += 6 * 576, rewritten++) {
        XCTAssertEqual(b[at], 0xFF);
        b[at + 2] &= 0x0F;
    }
    XCTAssertGreaterThan(rewritten, 10u);
    AudioFileHandle *whole = [self open:url decoder:@"dr_mp3"];
    AudioFileHandle *file = [self open:[self writeBytes:bytes name:@"free-far-apart.mp3"] decoder:@"dr_mp3"];
    XCTAssertGreaterThan(file.length, whole.length / 2, @"the stream's own frames, not free format ones");
    XCTAssertGreaterThan([self readToEnd:file].length, 0u);
}
// A stream can change its mode from frame to frame. CoreAudio stops counting
// at the change. Vibe plays it with the most channels a frame holds, a mono
// frame in both. Here a mono stream runs into a stereo one: each decodes as
// it does alone, but where the stereo one's first frame overlaps the mono
// one's last, and for the filterbank's history after it.
- (void)testDrMP3PlaysAStreamThatChangesMode {
    NSURL *monoURL = [self optionalFixture:@"mono-noinfo.mp3"], *stereoURL = [self optionalFixture:@"cbr-noinfo.mp3"];
    AudioFileHandle.appleMPEGDecoder = NO;
    NSData *mono = [NSData dataWithContentsOfURL:monoURL], *stereo = [NSData dataWithContentsOfURL:stereoURL];
    NSUInteger monoStart = VibeID3v2End(mono), stereoStart = VibeID3v2End(stereo);
    NSMutableData *joined = [[mono subdataWithRange:NSMakeRange(monoStart, mono.length - monoStart)] mutableCopy];
    [joined appendData:[stereo subdataWithRange:NSMakeRange(stereoStart, stereo.length - stereoStart)]];
    NSURL *url = [self writeBytes:joined name:@"mode-change.mp3"];
    AudioFileID parser = NULL;
    UInt64 packets = 0;
    UInt32 size = sizeof(packets);
    XCTAssertEqual(AudioFileOpenURL((__bridge CFURLRef)url, kAudioFileReadPermission, 0, &parser), noErr);
    AudioFileGetProperty(parser, kAudioFilePropertyAudioDataPacketCount, &size, &packets);
    AudioFileClose(parser);
    XCTAssertLessThan(packets, 170u, @"CoreAudio now counts every frame of a stream that changes mode");
    AVAudioPCMBuffer *alone = [self read:monoURL], *after = [self read:stereoURL], *both = [self read:url];
    XCTAssertEqual(both.format.channelCount, 2u);
    XCTAssertEqual(both.frameLength, alone.frameLength + after.frameLength);
    NSUInteger junction = alone.frameLength - kLayer3DecoderDelay, settled = alone.frameLength + 1152 + 480;
    for (NSUInteger c = 0; c < 2; c++) {
        XCTAssertEqual(memcmp(both.floatChannelData[c], alone.floatChannelData[0], junction * sizeof(float)), 0, @"the mono frames, channel %lu", (unsigned long)c);
        XCTAssertEqual(memcmp(both.floatChannelData[c] + settled, after.floatChannelData[c] + settled - alone.frameLength,
                              (both.frameLength - settled) * sizeof(float)), 0, @"the stereo frames, channel %lu", (unsigned long)c);
    }
}
// A damaged frame three from the end, then an ID3v1 tag. The walk takes up
// again at the next frame that a chain follows. Only two frames follow, and
// the chain ends at the tag. Each variant keeps every undamaged frame.
- (void)testDrMP3KeepsTheFramesBetweenDamageAndATrailingTag {
    NSURL *url = [self optionalFixture:@"cbr-noinfo.mp3"];
    AudioFileHandle.appleMPEGDecoder = NO;
    NSMutableData *bytes = [[NSData dataWithContentsOfURL:url] mutableCopy];
    NSUInteger start = VibeID3v2End(bytes), frames = (bytes.length - start) / 576;
    XCTAssertEqual((bytes.length - start) % 576, 0u, @"192 kbps at 48 kHz: 576-byte frames");
    uint8_t *damaged = (uint8_t *)bytes.mutableBytes + start + (frames - 3) * 576;
    XCTAssertEqual(damaged[0], 0xFF);
    damaged[0] = 0;
    NSMutableData *id3v1 = [NSMutableData dataWithBytes:"TAG" length:3];
    [id3v1 increaseLengthBy:125];
    NSMutableData *ape = [NSMutableData dataWithBytes:"APETAGEX" length:8];
    [ape increaseLengthBy:24];
    for (NSData *tail in @[NSData.data, id3v1, ape]) {
        NSMutableData *file = [bytes mutableCopy];
        [file appendData:tail];
        NSURL *written = [self writeBytes:file name:[NSString stringWithFormat:@"damaged-end-%lu.mp3", (unsigned long)tail.length]];
        AudioFileHandle *handle = [self open:written decoder:@"dr_mp3"];
        XCTAssertEqual(handle.length, (AVAudioFramePosition)(frames - 1) * 1152, @"a tail of %lu bytes", (unsigned long)tail.length);
        XCTAssertEqual([self readToEnd:handle].length, (NSUInteger)handle.length * 2 * sizeof(float), @"a tail of %lu bytes", (unsigned long)tail.length);
    }
}
// A damaged ID3v2.3 frame size near 2^32 plus its header wrapped to 0, and
// the open's walk of the tag for iTunes' comment never moved. The open must
// finish and play the stream untrimmed.
- (void)testAnID3FrameSizePastItsTagEndsTheGaplessSearch {
    NSURL *url = [self optionalFixture:@"cbr-noinfo.mp3"];
    AudioFileHandle.appleMPEGDecoder = NO;
    NSData *source = [NSData dataWithContentsOfURL:url];
    NSUInteger start = VibeID3v2End(source);
    for (NSNumber *claimed in @[@0xFFFFFFF6u, @0x7FFFFFFFu, @64u]) {
        uint32_t size = CFSwapInt32HostToBig(claimed.unsignedIntValue);
        uint8_t frame[10] = {'T', 'I', 'T', '2'};
        memcpy(frame + 4, &size, sizeof(size));
        uint8_t header[10] = {'I', 'D', '3', 3, 0, 0, 0, 0, 0, sizeof(frame) + 20};
        NSMutableData *tagged = [NSMutableData dataWithBytes:header length:sizeof(header)];
        [tagged appendBytes:frame length:sizeof(frame)];
        [tagged increaseLengthBy:20];
        [tagged appendData:[source subdataWithRange:NSMakeRange(start, source.length - start)]];
        NSURL *damaged = [self writeBytes:tagged name:[NSString stringWithFormat:@"id3-size-%@.mp3", claimed]];
        dispatch_semaphore_t opened = dispatch_semaphore_create(0);
        __block AudioFileHandle *file = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            file = [[AudioFileHandle alloc] initForReading:damaged error:NULL];
            dispatch_semaphore_signal(opened);
        });
        XCTAssertEqual(dispatch_semaphore_wait(opened, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0,
                       @"a frame size of %@ hung the open", claimed);
        XCTAssertEqualObjects(file.decoderName, @"dr_mp3", @"%@", claimed);
        XCTAssertEqual(file.length, [self open:url decoder:@"dr_mp3"].length, @"%@", claimed);
    }
}
// iTunes states its priming and remainder in an iTunSMPB comment rather than
// a LAME tag, and CoreAudio honors it. Here the comment is a COMM frame
// before a stream with no Info frame, in four tags. The plain ID3v2.3 tag and
// the one only flagged unsynchronised are held to CoreAudio's length. In the
// third, a frame before the comment holds 0xFF 0xE0, which unsynchronisation
// writes as 0xFF 0x00 0xE0, and the frame sizes count the decoded bytes. In
// the fourth, an ID3v2.4 comment flags its own unsynchronisation and a data
// length.
- (void)testDrMP3ReadsTheITunesGaplessComment {
    NSURL *url = [self optionalFixture:@"cbr-noinfo.mp3"];
    AudioFileHandle.appleMPEGDecoder = NO;
    NSData *source = [NSData dataWithContentsOfURL:url];
    NSUInteger start = VibeID3v2End(source);
    NSData *audio = [source subdataWithRange:NSMakeRange(start, source.length - start)];
    const char text[] = " 00000000 00000240 00000540 0000000000017700 00000000 00000000";
    NSMutableData *comment = [NSMutableData dataWithBytes:"\0engiTunSMPB\0" length:13];
    [comment appendBytes:text length:sizeof(text) - 1];
    // A tag of `frames` bytes, its size syncsafe.
    NSData *(^tag)(uint8_t, uint8_t, NSData *) = ^NSData *(uint8_t version, uint8_t flags, NSData *frames) {
        uint32_t size = (uint32_t)frames.length;
        uint8_t header[10] = {'I', 'D', '3', version, 0, flags, 0, 0, (uint8_t)(size >> 7), (uint8_t)(size & 0x7F)};
        NSMutableData *bytes = [NSMutableData dataWithBytes:header length:sizeof(header)];
        [bytes appendData:frames];
        return bytes;
    };
    // A frame whose size field says `size`, followed by `body` as stored.
    NSData *(^frame)(const char *, uint32_t, uint8_t, NSData *) = ^NSData *(const char *name, uint32_t size, uint8_t flags, NSData *body) {
        uint8_t header[10] = {(uint8_t)name[0], (uint8_t)name[1], (uint8_t)name[2], (uint8_t)name[3], 0, 0, 0, (uint8_t)size, 0, flags};
        NSMutableData *bytes = [NSMutableData dataWithBytes:header length:sizeof(header)];
        [bytes appendData:body];
        return bytes;
    };
    NSData *plain = frame("COMM", (uint32_t)comment.length, 0, comment);
    NSMutableData *escaped = [frame("PRIV", 4, 0, [NSData dataWithBytes:"\xFF\x00\xE0\x01\x02" length:5]) mutableCopy];
    [escaped appendData:plain];
    NSMutableData *own = [NSMutableData dataWithBytes:"\0\0\0" length:3];
    uint8_t decodedLength = (uint8_t)comment.length;
    [own appendBytes:&decodedLength length:1];
    [own appendData:comment];
    NSDictionary<NSString *, NSData *> *variants = @{
        @"v2.3": tag(3, 0, plain),
        @"v2.3, flagged unsynchronised": tag(3, 0x80, plain),
        @"v2.3, unsynchronised": tag(3, 0x80, escaped),
        @"v2.4, a frame unsynchronised": tag(4, 0x80, frame("COMM", (uint32_t)own.length, 0x03, own)),
    };
    AVAudioPCMBuffer *whole = [self read:url];
    for (NSString *name in variants) {
        NSMutableData *tagged = [variants[name] mutableCopy];
        [tagged appendData:audio];
        NSURL *gapless = [self writeBytes:tagged name:[NSString stringWithFormat:@"itunes-gapless-%lu.mp3", (unsigned long)name.hash]];
        if ([name hasPrefix:@"v2.3"] && ![name isEqualToString:@"v2.3, unsynchronised"]) {
            ExtAudioFileRef reader = NULL;
            SInt64 length = -1;
            UInt32 size = sizeof(length);
            XCTAssertEqual(ExtAudioFileOpenURL((__bridge CFURLRef)gapless, &reader), noErr);
            ExtAudioFileGetProperty(reader, kExtAudioFileProperty_FileLengthFrames, &size, &length);
            ExtAudioFileDispose(reader);
            XCTAssertEqual(length, 96000, @"%@: CoreAudio trims the comment's 576 and 1344 frames", name);
        }
        XCTAssertEqual([self open:gapless decoder:@"dr_mp3"].length, 96000, @"%@", name);
        AVAudioPCMBuffer *trimmed = [self read:gapless];
        for (NSUInteger c = 0; c < 2; c++) {
            XCTAssertEqual(memcmp(trimmed.floatChannelData[c], whole.floatChannelData[c] + 576, 96000 * sizeof(float)), 0, @"%@", name);
        }
    }
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
// A fixed block size stream's frames are placed by their number times the
// block size. dr_flac takes the size from the first frame's header, not
// STREAMINFO's minimum, which damage can make anything. With the minimum at 1
// the file still decodes whole and seeks exactly, with its length stated and
// with it left unknown.
- (void)testDrFLACPlacesFramesByTheFirstFramesBlockSize {
    NSURL *url = [self optionalFixture:@"flac-block16.flac"];
    NSData *reference = [self readToEnd:[self open:url decoder:@"dr_flac"]];
    for (NSNumber *unknown in @[@NO, @YES]) {
        NSMutableData *flac = [[NSData dataWithContentsOfURL:url] mutableCopy];
        uint8_t *streaminfo = (uint8_t *)flac.mutableBytes + 8;
        streaminfo[0] = 0;
        streaminfo[1] = 1; // the minimum block size, which is 16
        if (unknown.boolValue) [self clearLengthOfFLAC:flac];
        NSString *name = unknown.boolValue ? @"minimum block 1, length unknown" : @"minimum block 1";
        AudioFileHandle *file = [self open:[self writeBytes:flac name:[name stringByAppendingString:@".flac"]] decoder:@"dr_flac"];
        XCTAssertEqualObjects([self readToEnd:file], reference, @"%@", name);
        [self assertSeeksOf:file match:reference block:16 name:name];
    }
}
// Exercise empty residual partitions, large Rice orders and 33-bit side
// channels. Unknown-length variants must find the last valid frame.
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
        XCTAssertEqualObjects(decoded, VibeFloat32PCM([self wideSourcePCM:[self fixture:sources[name]]]), @"%@", name);
        [self assertSeeksOf:file match:decoded block:4096 name:name];
    }
    NSMutableData *unknown = [NSMutableData dataWithContentsOfURL:[self fixture:@"flac-zero-residual.flac"]];
    [self clearLengthOfFLAC:unknown];
    NSData *source = VibeFloat32PCM([self wideSourcePCM:[self fixture:@"noise-48000-24-2.wav"]]);
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
    AudioFileHandle *interleaved = [[AudioFileHandle alloc] initForReading:url interleaved:YES error:NULL];
    XCTAssertEqualObjects([self readToEnd:interleaved], reference, @"interleaved, as the waveform reads");

    AudioFileHandle *(^open)(NSData *, NSString *) = ^AudioFileHandle *(NSData *stream, NSString *name) {
        return [self open:[self writeBytes:stream name:name] decoder:@"dr_flac"];
    };

    // An ID3v2 tag in front, and two.
    static const uint8_t tag[] = {'I','D','3',4,0,0, 0,0,0,16, 'T','I','T','2', 0,0,0,6, 0,0, 3,'t','i','t','l','e'};
    AudioFileHandle *file = nil;
    for (NSUInteger tags = 1; tags <= 2; tags++) {
        NSMutableData *tagged = [NSMutableData data];
        for (NSUInteger i = 0; i < tags; i++) [tagged appendBytes:tag length:sizeof(tag)];
        [tagged appendData:bytes];
        NSString *name = [NSString stringWithFormat:@"%lu ID3v2 tags in front", (unsigned long)tags];
        file = open(tagged, [name stringByAppendingString:@".flac"]);
        XCTAssertEqualObjects([self readToEnd:file], reference, @"%@", name);
        [self assertSeeksOf:file match:reference block:block name:name];
    }

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
    return VibePCM(whole);
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
        @"aifc-BEF32.aif", @"aifc-BEF64.aif", @"aifc-ulaw.aif", @"aifc-alaw.aif", @"aifc-ima4.aif", @"aifc-ima4-mono.aif", @"aifc-UI8.aif",
        @"wave64-LEI24.w64", @"rf64-LEI24.wav",
        @"wav-ima-adpcm.wav", @"wav-ms-adpcm.wav"];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *name in names) {
        NSURL *url = [self fixture:name];
        // The ADPCM WAVs need ffmpeg; one missing skips the test only once the rest has run.
        if ([name containsString:@"adpcm"] && ![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
            [missing addObject:name];
            continue;
        }
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
    // Samples narrower than their bytes, 12 bits in 2 and 20 in 3, their pad
    // bits zero as a writer leaves them.
    for (NSArray *narrowed in @[@[@"noise-44100-16-1.wav", @12], @[@"noise-48000-24-2.wav", @20]]) {
        NSMutableData *wave = [[NSData dataWithContentsOfURL:[self fixture:narrowed[0]]] mutableCopy];
        NSRange fmt = [self chunk:"fmt " of:wave bigEndian:NO], data = [self chunk:"data" of:wave bigEndian:NO];
        uint8_t *b = wave.mutableBytes, bits = [narrowed[1] unsignedCharValue], width = (bits + 7) / 8;
        b[fmt.location + 14] = bits; // wBitsPerSample
        for (NSUInteger at = data.location; at + width <= NSMaxRange(data); at += width) {
            b[at] &= (uint8_t)(0xFF << (8 * width - bits)); // the low byte holds the pad
        }
        NSURL *url = [self writeBytes:wave name:[NSString stringWithFormat:@"pcm-%u.wav", bits]];
        XCTAssertEqualObjects([self readToEnd:[self open:url decoder:@"dr_wav"]], [self appleDecodeOf:url], @"%u bits in %u bytes", bits, width);
    }
    AudioFileHandle *interleaved = [[AudioFileHandle alloc] initForReading:[self fixture:@"lossless.aiff"] interleaved:YES error:NULL];
    XCTAssertEqualObjects([self readToEnd:interleaved], [self appleDecodeOf:[self fixture:@"lossless.aiff"]], @"interleaved, as the waveform reads");
    NSURL *mpeg = [self optionalFixture:@"mp3-in.wav"];
    [self open:mpeg decoder:@"dr_mp3"];
    AudioFileHandle.appleMPEGDecoder = YES;
    [self open:mpeg decoder:@"apple"];
    XCTSkipIf(missing.count, @"Optional encoder fixtures %@ unavailable; install ffmpeg and regenerate", missing);
}
// The body of a RIFF or IFF file's first chunk of that ID.
- (NSRange)chunk:(const char *)name of:(NSData *)file bigEndian:(BOOL)bigEndian {
    const uint8_t *b = file.bytes;
    for (NSUInteger at = 12; at + 8 <= file.length;) {
        uint32_t size;
        memcpy(&size, b + at + 4, sizeof(size));
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
// Trailing AIFF chunks must not shift seeks into SSND's offset fields.
// Malformed sizes and ADPCM blocks must preserve the remaining valid audio.
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
    NSRange imaData = [self chunk:"data" of:ima bigEndian:NO];
    // CoreAudio's parser serves an ADPCM block as a packet.
    const AudioStreamBasicDescription *packet = imaClean.fileFormat.streamDescription;
    NSUInteger blockAlign = packet->mBytesPerPacket, blockFrames = packet->mFramesPerPacket;
    NSUInteger channels = imaClean.processingFormat.channelCount, damagedBlock = 3;
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

    NSURL *msURL = [self optionalFixture:@"wav-ms-adpcm.wav"];
    NSData *ms = [NSData dataWithContentsOfURL:msURL];
    AudioFileHandle *msClean = [self open:msURL decoder:@"dr_wav"];
    NSData *msReference = [self readToEnd:msClean];
    NSRange msData = [self chunk:"data" of:ms bigEndian:NO], msFmt = [self chunk:"fmt " of:ms bigEndian:NO];
    packet = msClean.fileFormat.streamDescription;
    blockAlign = packet->mBytesPerPacket;
    blockFrames = packet->mFramesPerPacket;
    channels = msClean.processingFormat.channelCount;
    NSUInteger header = 7 * channels;
    // A block's header holds two frames once all of it is there, and each byte after it two samples.
    for (NSNumber *into in @[@1, @(header), @(header + 6 * channels)]) {
        NSUInteger bytes = into.unsignedIntegerValue, held = blockFrames + (bytes < header ? 0 : 2 + (bytes - header) * 2 / channels);
        NSString *name = [NSString stringWithFormat:@"MS ADPCM cut %lu bytes into its second block", (unsigned long)bytes];
        file = open([ms subdataWithRange:NSMakeRange(0, msData.location + blockAlign + bytes)], [NSString stringWithFormat:@"ms-cut-%lu.wav", (unsigned long)bytes]);
        XCTAssertEqual(file.length, (AVAudioFramePosition)held, @"%@", name);
        XCTAssertEqualObjects([self readToEnd:file], [msReference subdataWithRange:NSMakeRange(0, held * channels * sizeof(float))], @"%@", name);
    }
    // An eighth coefficient pair, which the first block's predictors name.
    NSMutableData *eighth = [ms mutableCopy];
    static const uint8_t pair[] = {0x00, 0x01, 0x00, 0x00};
    [eighth replaceBytesInRange:NSMakeRange(NSMaxRange(msFmt), 0) withBytes:pair length:sizeof(pair)];
    uint8_t *e = eighth.mutableBytes;
    e[msFmt.location - 4] += sizeof(pair); // the chunk's size
    e[msFmt.location + 16] += sizeof(pair); // cbSize
    e[msFmt.location + 20] = 8; // wNumCoef
    memset(e + msData.location + sizeof(pair), 7, channels);
    [self setContainerSizeOf:eighth bigEndian:NO];
    NSURL *eighthURL = [self writeBytes:eighth name:@"ms-eighth-coefficient.wav"];
    AudioFileHandle *eighthFile = [self open:eighthURL decoder:@"dr_wav"];
    NSData *eighthDecoded = [self readToEnd:eighthFile], *eighthApple = [self appleDecodeOf:eighthURL];
    XCTAssertEqual(eighthDecoded.length, msReference.length, @"an eighth coefficient pair: the same frames");
    XCTAssertLessThan(eighthDecoded.length, eighthApple.length, @"an eighth coefficient pair: it ends at its fact count");
    XCTAssertEqualObjects(eighthDecoded, [eighthApple subdataWithRange:NSMakeRange(0, MIN(eighthDecoded.length, eighthApple.length))],
                          @"an eighth coefficient pair decodes as Apple's decoder does");
}
// A little-endian (sowt) AIFF-C of 24 or 32 bits, which CoreAudio's parser
// describes as 16-bit, made from a big-endian one by swapping each sample:
// dr_wav decodes the same samples, and the file's description carries their
// width. The depth report and bit-perfect output's depth check honor all of it.
// 20 bits in 3 bytes, a WAV's and an AIFF's, are described as the parser
// describes them: 20 bits, high-aligned. dr_wav rounds an AIFF's COMM width up
// to whole bytes, which would report 24. An extensible WAV's 24 valid bits in
// 32-bit containers are 24 bits, where the parser states 32, so a 24-bit
// device format carries them.
- (void)testDrWAVDescribesEachSampleAtItsWidth {
    self.continueAfterFailure = YES;
    for (NSString *name in @[@"aifc-BEI24.aif", @"aifc-BEI32.aif"]) {
        NSURL *url = [self fixture:name];
        AudioFileHandle *big = [self open:url decoder:@"dr_wav"];
        UInt32 bits = big.fileFormat.streamDescription->mBitsPerChannel, width = bits / 8;
        NSMutableData *aiff = [[NSData dataWithContentsOfURL:url] mutableCopy];
        NSRange comm = [self chunk:"COMM" of:aiff bigEndian:YES], ssnd = [self chunk:"SSND" of:aiff bigEndian:YES];
        [aiff replaceBytesInRange:NSMakeRange(comm.location + 18, 4) withBytes:"sowt"];
        uint8_t *samples = (uint8_t *)aiff.mutableBytes + ssnd.location + 8; // past SSND's offset and block size
        for (NSUInteger at = 0; at + width <= ssnd.length - 8; at += width) {
            for (UInt32 i = 0; i < width / 2; i++) {
                uint8_t byte = samples[at + i];
                samples[at + i] = samples[at + width - 1 - i];
                samples[at + width - 1 - i] = byte;
            }
        }

        AudioFileHandle *sowt = [self open:[self writeBytes:aiff name:[@"sowt-" stringByAppendingString:name]] decoder:@"dr_wav"];
        XCTAssertEqualObjects([self readToEnd:sowt], [self readToEnd:big], @"%@ as sowt", name);
        AudioStreamBasicDescription source = *sowt.fileFormat.streamDescription;
        XCTAssertEqual(VibeSourceBitDepth(source), bits, @"%@ as sowt: the depth reported", name);
        AudioStreamRangedDescription offered[2] = {VibeRangedPCMFormat(source.mSampleRate, 16, NO), VibeRangedPCMFormat(source.mSampleRate, bits, NO)};
        XCTAssertFalse(VibePhysicalFormatSatisfies(offered[0].mFormat, source, *sowt.processingFormat.streamDescription), @"%@ as sowt: 16 bits do not carry it", name);
    }

    NSURL *wavURL = [self fixture:@"noise-48000-24-2.wav"];
    NSData *wav24 = [NSData dataWithContentsOfURL:wavURL];
    NSMutableData *wav = [wav24 mutableCopy];
    ((uint8_t *)wav.mutableBytes)[[self chunk:"fmt " of:wav bigEndian:NO].location + 14] = 20; // wBitsPerSample
    NSMutableData *aiff = [[NSData dataWithContentsOfURL:[self fixture:@"lossless.aiff"]] mutableCopy];
    NSMutableData *aifc = [[NSData dataWithContentsOfURL:[self fixture:@"aifc-BEI24.aif"]] mutableCopy];
    [aifc replaceBytesInRange:NSMakeRange([self chunk:"COMM" of:aifc bigEndian:YES].location + 18, 4) withBytes:"NONE"];
    for (NSMutableData *form in @[aiff, aifc]) {
        [form replaceBytesInRange:NSMakeRange([self chunk:"COMM" of:form bigEndian:YES].location + 6, 2) withBytes:"\x00\x14"]; // sampleSize
    }
    NSDictionary<NSString *, NSData *> *twenty = @{@"pcm-20.wav": wav, @"pcm-20.aif": aiff, @"aifc-NONE-20.aif": aifc};
    for (NSString *name in twenty) {
        NSURL *url = [self writeBytes:twenty[name] name:name];
        AudioFileHandle *file = [self open:url decoder:@"dr_wav"];
        XCTAssertEqual(VibeSourceBitDepth(*file.fileFormat.streamDescription), 20u, @"%@: the depth reported", name);
        BOOL folds = NO;
        XCTAssertTrue([self assertFactsOf:file matchCoreAudioOf:url folds:&folds], @"%@", name);
    }

    // The 24-bit WAV's samples, each high-aligned in 4 bytes with its low byte zero.
    NSRange data24 = [self chunk:"data" of:wav24 bigEndian:NO];
    NSUInteger samples24 = data24.length / 3;
    NSMutableData *extensible = [NSMutableData data];
    void (^put)(uint32_t, int) = ^(uint32_t value, int bytes) { [extensible appendBytes:&value length:bytes]; }; // little-endian, as the host
    [extensible appendBytes:"RIFF" length:4];
    put(0, 4); // the container's size, set once the samples are in
    [extensible appendBytes:"WAVEfmt " length:8];
    put(40, 4);
    put(0xFFFE, 2); put(2, 2); put(48000, 4); put(48000 * 8, 4); put(8, 2); put(32, 2); // tag, channels, rate, bytes a second, frame, container
    put(22, 2); put(24, 2); put(3, 4); // cbSize, valid bits, channel mask
    [extensible appendBytes:"\x01\x00\x00\x00\x00\x00\x10\x00\x80\x00\x00\xAA\x00\x38\x9B\x71" length:16]; // KSDATAFORMAT_SUBTYPE_PCM
    [extensible appendBytes:"data" length:4];
    put((uint32_t)(samples24 * 4), 4);
    const uint8_t *in = (const uint8_t *)wav24.bytes + data24.location;
    for (NSUInteger i = 0; i < samples24; i++) {
        uint8_t sample[4] = {0, in[3 * i], in[3 * i + 1], in[3 * i + 2]};
        [extensible appendBytes:sample length:4];
    }
    [self setContainerSizeOf:extensible bigEndian:NO];
    AudioFileHandle *valid = [self open:[self writeBytes:extensible name:@"extensible-24-in-32.wav"] decoder:@"dr_wav"];
    XCTAssertEqualObjects([self readToEnd:valid], [self readToEnd:[self open:wavURL decoder:@"dr_wav"]],
                          @"24 in 32: the same samples");
    AudioStreamBasicDescription source = *valid.fileFormat.streamDescription;
    XCTAssertEqual(source.mBitsPerChannel, 24u, @"24 in 32: the valid bits");
    XCTAssertEqual(source.mBytesPerFrame, 8u, @"24 in 32: the container's bytes");
    XCTAssertEqual(source.mFormatFlags, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh);
    AudioStreamRangedDescription offered[2] = {VibeRangedPCMFormat(48000, 16, NO), VibeRangedPCMFormat(48000, 24, NO)};
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(source, 48000, offered, 2, &chosen), @"24 in 32: a 24-bit device format qualifies");
    XCTAssertEqual(chosen.mBitsPerChannel, 24u);
    XCTAssertTrue(VibePhysicalFormatSatisfies(offered[1].mFormat, source, *valid.processingFormat.streamDescription),
                  @"24 in 32: 24 bits and float32 carry every bit");
}
- (void)testQuickTimeAudio { [self checkLossy:@"lossy.qta" tolerance:kVibeAACDecodeTolerance]; }
- (void)testFloatLimitsAndSilence {
    for (NSString *name in @[@"limits.wav",@"silence.wav"]) {
        [self startPlayerAt:48000 channels:2 fx:NO bitPerfect:YES automatic:NO];
        AVAudioPCMBuffer *source=[self read:[self fixture:name]];
        [self play:[self fixture:name] paused:NO position:0];
        NSData *capture=[self renderSeconds:source.frameLength/_rate+0.1];
        if ([name isEqual:@"silence.wav"]) XCTAssertEqual(VibeRMS(capture,2,0,NSMakeRange(0,capture.length/8)),0);
        else [self assertReference:VibePCM(source) capture:capture skip:[self startupSkip] tolerance:0];
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
        NSData *wide=[self wideSourcePCM:url], *rounded=VibeFloat32PCM(wide);
        [self play:url paused:NO position:0];
        NSData *capture=[self renderSeconds:wide.length/sizeof(double)/2/_rate+0.1];
        [self assertReference:rounded capture:capture skip:[self startupSkip] tolerance:0];
        NSUInteger aligned=[VibeComparePCM(rounded,capture,2,[self startupSkip],0)[@"aligned"] unsignedIntegerValue];
        NSDictionary *full=VibeCompareWidePCM(wide,capture,2,aligned,[self startupSkip]);
        NSUInteger mismatched=[full[@"mismatchedSamples"] unsignedIntegerValue], compared=[full[@"comparedSamples"] unsignedIntegerValue];
        if ([name isEqual:@"integer32.wav"]) XCTAssertEqual(mismatched,0u,@"%@",full);
        else XCTAssertGreaterThan(mismatched,compared/2,@"%@: %@",name,full);
    }
}

@end
