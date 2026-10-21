//
//  AudioFixtures.h
//  VibeTests, VibeAudioTests
//
//  Fixture writers shared by both test targets. VibeWriteWAV writes the bytes
//  itself, so reading a fixture back through AudioFileHandle never makes the
//  handle its own oracle; VibeWriteFixture uses the handle's writer for what a
//  bare RIFF cannot carry — a channel layout, or a codec. VibeReferenceResample
//  is the one reference conversion. VibeFitTones is the one tone fit, with
//  VibeFitTone and VibeDB beside it, which both quality measurements share. VibeRangedPCMFormat is a device's offered
//  format, for the bit-perfect format rules. VibeToneBuffer is the one test tone, and VibeImageOfColor the one
//  solid-color image. VibeFuzzRandom and VibeFuzzBaseSeed are the fuzz classes' generator and seed.
//  VibeTestFileOpener is the player's open, for the coordinator's stage 2.
//

#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "AudioFileHandle.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioResampler.h"

// The player's open (VibePlayerFileOpener), for a coordinator test that opens
// real files.
static VibeAudioFileOpener const VibeTestFileOpener =
        ^AudioFileHandle *(NSURL *url, BOOL (^interrupted)(void), NSError **error) {
    return [[AudioFileHandle alloc] initForReading:url interleaved:NO interrupted:interrupted error:error];
};

// A format a device offers at exactly `rate`: stereo PCM of `bits`, integer
// or float.
static inline AudioStreamRangedDescription VibeRangedPCMFormat(double rate, UInt32 bits, BOOL isFloat) {
    AudioStreamRangedDescription r = {0};
    r.mFormat.mSampleRate = rate;
    r.mFormat.mFormatID = kAudioFormatLinearPCM;
    r.mFormat.mFormatFlags = isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger;
    r.mFormat.mBitsPerChannel = bits;
    r.mFormat.mChannelsPerFrame = 2;
    r.mSampleRateRange.mMinimum = rate;
    r.mSampleRateRange.mMaximum = rate;
    return r;
}

// xorshift64*, chosen for being four lines rather than for its statistics.
// A state of 0 stays 0, so a seed must be nonzero.
typedef struct { uint64_t state; } VibeFuzzRandom;

static inline uint64_t VibeFuzzNext(VibeFuzzRandom *random) {
    uint64_t x = random->state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    random->state = x;
    return x * 0x2545F4914F6CDD1DULL;
}

// From the high bits. TRAP: `% bound` kept only the low bits, and seeds that
// differ only in high bits drew the same small numbers first. Every iteration
// of a mutator then made the same mutant.
static inline NSUInteger VibeFuzzBelow(VibeFuzzRandom *random, NSUInteger bound) {
    return (NSUInteger)(((__uint128_t)VibeFuzzNext(random) * bound) >> 64);
}

// VIBE_FUZZ_SEED in decimal or 0x hex, else `fallback`. Fixed by default: a
// suite that explores new inputs on every run passes and fails at random.
static inline uint64_t VibeFuzzBaseSeed(uint64_t fallback) {
    NSString *seed = NSProcessInfo.processInfo.environment[@"VIBE_FUZZ_SEED"];
    return seed ? strtoull(seed.UTF8String, NULL, 0) : fallback;
}

// `frames` of a 440 Hz tone at about -12 dBFS, every channel alike, interleaved
// int16 or float32.
static inline AVAudioPCMBuffer *VibeToneBuffer(AVAudioFrameCount frames, double rate, AVAudioChannelCount channels,
                                               AVAudioCommonFormat format) {
    AVAudioFormat *pcm = [[AVAudioFormat alloc] initWithCommonFormat:format sampleRate:rate channels:channels
                                                         interleaved:YES];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:pcm frameCapacity:frames];
    buffer.frameLength = frames;
    for (AVAudioFrameCount i = 0; i < frames; i++) {
        int16_t sample = (int16_t)(8000 * sin(2 * M_PI * 440 * i / rate));
        for (AVAudioChannelCount c = 0; c < channels; c++) {
            if (format == AVAudioPCMFormatInt16) buffer.int16ChannelData[0][i * channels + c] = sample;
            else buffer.floatChannelData[0][i * channels + c] = sample / 32768.0f;
        }
    }
    return buffer;
}

// A side x side image of one opaque sRGB color, PNG or JPEG.
static inline NSData *VibeImageOfColor(size_t side, CGFloat red, CGFloat green, CGFloat blue, BOOL jpeg) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, side, side, 8, 0, space,
                                                 (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetRGBFillColor(context, red, green, blue, 1);
    CGContextFillRect(context, CGRectMake(0, 0, side, side));
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)data,
            (__bridge CFStringRef)(jpeg ? UTTypeJPEG : UTTypePNG).identifier, 1, NULL);
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return data;
}

// A canonical 44-byte-header WAV of `bits` per sample (16 or 24 integer, 32
// float), interleaved `samples` as the file stores them, little-endian.
// `declaredBytes` is what the data chunk claims; pass the samples' length,
// or more to shape a file that ends before its header says.
static inline NSURL *VibeWriteWAV(NSURL *url, NSData *samples, uint32_t rate, uint16_t channels, uint16_t bits,
                                  uint32_t declaredBytes) {
    NSMutableData *wav = [NSMutableData data];
    void (^append32)(uint32_t) = ^(uint32_t v) { [wav appendBytes:&v length:4]; };
    void (^append16)(uint16_t) = ^(uint16_t v) { [wav appendBytes:&v length:2]; };
    uint16_t width = bits / 8;
    [wav appendBytes:"RIFF" length:4];
    append32(36 + declaredBytes);
    [wav appendBytes:"WAVEfmt " length:8];
    append32(16);
    append16(bits == 32 ? 3 : 1);                   // IEEE float, or PCM
    append16(channels);
    append32(rate);
    append32(rate * channels * width);
    append16(channels * width);                     // block align
    append16(bits);
    [wav appendBytes:"data" length:4];
    append32(declaredBytes);
    [wav appendData:samples];
    return [wav writeToURL:url atomically:YES] ? url : nil;
}

static inline void VibeAppendBE64(NSMutableData *data, uint64_t value) {
    for (int shift = 56; shift >= 0; shift -= 8) {
        uint8_t byte = (uint8_t)(value >> shift);
        [data appendBytes:&byte length:1];
    }
}

// A binary CUESHEET block, CD-flagged. Each track is @[number, offset in
// samples, pregap, data]: a pregap > 0 writes INDEX 00 at the offset and
// INDEX 01 that many samples later, else INDEX 01 alone; data nonzero marks a
// non-audio track. The lead-out (170) follows at leadOut.
static inline NSData *VibeFLACCueSheetBlock(NSArray<NSArray<NSNumber *> *> *tracks, uint64_t leadOut) {
    NSMutableData *block = [NSMutableData dataWithLength:128];
    VibeAppendBE64(block, 88200);
    uint8_t flag = 0x80, count = (uint8_t)(tracks.count + 1), zero = 0;
    [block appendBytes:&flag length:1];
    [block increaseLengthBy:258];
    [block appendBytes:&count length:1];
    void (^track)(uint8_t, uint64_t, uint64_t, BOOL) = ^(uint8_t number, uint64_t offset, uint64_t pregap, BOOL data) {
        VibeAppendBE64(block, offset);
        [block appendBytes:&number length:1];
        [block increaseLengthBy:12];
        uint8_t type = data ? 0x80 : 0;
        [block appendBytes:&type length:1];
        [block increaseLengthBy:13];
        uint8_t indexes = number == 170 ? 0 : (pregap > 0 ? 2 : 1);
        [block appendBytes:&indexes length:1];
        for (uint8_t i = pregap > 0 ? 0 : 1; indexes > 0 && i <= 1; i++) {
            VibeAppendBE64(block, i == 0 ? 0 : pregap);
            [block appendBytes:&i length:1];
            [block appendBytes:&zero length:1];
            [block appendBytes:&zero length:1];
            [block appendBytes:&zero length:1];
        }
    };
    for (NSArray<NSNumber *> *t in tracks) {
        track(t[0].unsignedCharValue, t[1].unsignedLongLongValue, t[2].unsignedLongLongValue, t[3].boolValue);
    }
    track(170, leadOut, 0, NO);
    return block;
}

// A FLAC's metadata blocks and no playable audio: what the embedded-sheet
// reader reads. A picture comes first, so the reader must seek over it; the
// sheet rides as a CUESHEET Vorbis comment (cueText) and/or a binary block;
// id3 prefixes an ID3v2 tag; size > 0 extends the file sparse to that size.
static inline NSURL *VibeWriteFLACHeader(NSURL *url, uint32_t rate, NSString *cueText, NSData *cueBlock,
                                         BOOL id3, unsigned long long size) {
    NSMutableData *file = [NSMutableData data];
    if (id3) {
        const uint8_t tag[10] = {'I', 'D', '3', 4, 0, 0, 0, 0, 0, 20};
        [file appendBytes:tag length:sizeof tag];
        [file increaseLengthBy:20];
    }
    [file appendBytes:"fLaC" length:4];
    NSMutableArray<NSData *> *blocks = [NSMutableArray array];
    NSMutableArray<NSNumber *> *types = [NSMutableArray array];
    NSMutableData *info = [NSMutableData dataWithLength:34];
    uint8_t *bytes = (uint8_t *)info.mutableBytes;
    bytes[10] = (uint8_t)(rate >> 12);
    bytes[11] = (uint8_t)(rate >> 4);
    bytes[12] = (uint8_t)((rate & 0xf) << 4 | 0x02);
    [blocks addObject:info];
    [types addObject:@0];
    [blocks addObject:[NSMutableData dataWithLength:1000]];
    [types addObject:@6];
    if (cueText) {
        NSMutableData *comment = [NSMutableData data];
        NSArray<NSString *> *fields = @[@"TITLE=The Whole Album", [@"CUESHEET=" stringByAppendingString:cueText]];
        uint32_t vendor = 4, n = (uint32_t)fields.count;
        [comment appendBytes:&vendor length:4];
        [comment appendBytes:"vibe" length:4];
        [comment appendBytes:&n length:4];
        for (NSString *field in fields) {
            NSData *utf8 = [field dataUsingEncoding:NSUTF8StringEncoding];
            uint32_t length = (uint32_t)utf8.length;
            [comment appendBytes:&length length:4];
            [comment appendData:utf8];
        }
        [blocks addObject:comment];
        [types addObject:@4];
    }
    if (cueBlock) {
        [blocks addObject:cueBlock];
        [types addObject:@5];
    }
    for (NSUInteger i = 0; i < blocks.count; i++) {
        NSUInteger length = blocks[i].length;
        uint8_t header[4] = {(uint8_t)(types[i].unsignedCharValue | (i + 1 == blocks.count ? 0x80 : 0)),
                             (uint8_t)(length >> 16), (uint8_t)(length >> 8), (uint8_t)length};
        [file appendBytes:header length:4];
        [file appendData:blocks[i]];
    }
    const uint8_t frame[4] = {0xff, 0xf8, 0xc9, 0x18};
    [file appendBytes:frame length:sizeof frame];
    if (![file writeToURL:url atomically:YES]) {
        return nil;
    }
    if (size > file.length) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingToURL:url error:NULL];
        [handle truncateAtOffset:size error:NULL];
        [handle closeAndReturnError:NULL];
    }
    return url;
}

// A little-endian (sowt) AIFF-C of integer `samples` as a WAV stores them,
// `bits` per sample: the coding CoreAudio's parser describes as 16-bit
// whatever COMM says.
static inline NSURL *VibeWriteSowtAIFF(NSURL *url, NSData *samples, double rate, uint16_t channels, uint16_t bits) {
    int exponent = ilogb(rate);
    uint16_t rateExponent = CFSwapInt16HostToBig((uint16_t)(16383 + exponent));
    uint64_t rateMantissa = CFSwapInt64HostToBig((uint64_t)ldexp(rate, 63 - exponent));
    uint16_t channelsBE = CFSwapInt16HostToBig(channels), bitsBE = CFSwapInt16HostToBig(bits);
    uint32_t frames = CFSwapInt32HostToBig((uint32_t)(samples.length / (bits / 8 * channels)));
    NSMutableData *comm = [NSMutableData data];
    [comm appendBytes:&channelsBE length:2]; [comm appendBytes:&frames length:4]; [comm appendBytes:&bitsBE length:2];
    [comm appendBytes:&rateExponent length:2]; [comm appendBytes:&rateMantissa length:8];
    [comm appendBytes:"sowt\0\0" length:6]; // the compression type and an empty name, padded
    NSMutableData *aiff = [NSMutableData dataWithBytes:"FORM\0\0\0\0AIFCFVER\0\0\0\4\xA2\x80\x51\x40" length:24];
    uint32_t size = CFSwapInt32HostToBig((uint32_t)comm.length);
    [aiff appendBytes:"COMM" length:4]; [aiff appendBytes:&size length:4]; [aiff appendData:comm];
    size = CFSwapInt32HostToBig((uint32_t)samples.length + 8);
    [aiff appendBytes:"SSND" length:4]; [aiff appendBytes:&size length:4]; [aiff appendBytes:"\0\0\0\0\0\0\0\0" length:8];
    [aiff appendData:samples];
    size = CFSwapInt32HostToBig((uint32_t)aiff.length - 8);
    [aiff replaceBytesInRange:NSMakeRange(4, 4) withBytes:&size];
    return [aiff writeToURL:url atomically:YES] ? url : nil;
}

// An ID3v2 tag's whole length at `at`, its header, its size and any footer
// counted. 0 when no tag starts there.
static inline NSUInteger VibeID3v2Length(NSData *file, NSUInteger at) {
    const uint8_t *b = (const uint8_t *)file.bytes + at;
    if (at + 10 > file.length || memcmp(b, "ID3", 3) != 0) return 0;
    return 10 + (b[5] & 0x10 ? 10 : 0) + ((NSUInteger)(b[6] & 0x7F) << 21 | (b[7] & 0x7F) << 14 | (b[8] & 0x7F) << 7 | (b[9] & 0x7F));
}

// An ID3v2.3 or 2.4 frame: its header, its size field saying `size` as
// `version` writes it (syncsafe in 2.4), then `body` as stored. A size apart
// from the body's length lets a test write a damaged or escaped frame.
static inline NSData *VibeID3v2Frame(const char *name, uint8_t version, uint32_t size, uint8_t flags, NSData *body) {
    uint32_t field = version == 4 ? (size & 0x7F) | (size >> 7 & 0x7F) << 8 | (size >> 14 & 0x7F) << 16 | (size >> 21 & 0x7F) << 24 : size;
    uint8_t header[10] = {(uint8_t)name[0], (uint8_t)name[1], (uint8_t)name[2], (uint8_t)name[3],
                          (uint8_t)(field >> 24), (uint8_t)(field >> 16), (uint8_t)(field >> 8), (uint8_t)field, 0, flags};
    NSMutableData *frame = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [frame appendData:body];
    return frame;
}

// An ID3v2 tag of `frames` with these header flags, its size syncsafe.
static inline NSData *VibeID3v2Tag(uint8_t version, uint8_t flags, NSData *frames) {
    uint32_t size = (uint32_t)frames.length;
    uint8_t header[10] = {'I', 'D', '3', version, 0, flags,
                          (uint8_t)(size >> 21 & 0x7F), (uint8_t)(size >> 14 & 0x7F), (uint8_t)(size >> 7 & 0x7F), (uint8_t)(size & 0x7F)};
    NSMutableData *tag = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [tag appendData:frames];
    return tag;
}

// MPEG-1 Layer III, 320 kbps, 44.1 kHz, stereo: a LAME Info frame counting
// `frames` silent frames after it, which, as for every MP3 with one, makes
// CoreAudio's open read the file's head and then its last bytes; with an
// ID3v1 tag after them when asked.
static inline NSData *VibeMP3WithInfoFrame(uint32_t frames, BOOL id3v1) {
    const uint8_t header[4] = {0xFF, 0xFB, 0xE0, 0x00};
    NSMutableData *bytes = [NSMutableData data];
    for (uint32_t i = 0; i <= frames; i++) {
        NSMutableData *frame = [NSMutableData dataWithLength:1044];
        uint8_t *out = (uint8_t *)frame.mutableBytes;
        memcpy(out, header, sizeof(header));
        if (i == 0) {
            const uint32_t fields[3] = {CFSwapInt32HostToBig(3), CFSwapInt32HostToBig(frames),
                                        CFSwapInt32HostToBig((frames + 1) * 1044)};
            memcpy(out + 36, "Info", 4);
            memcpy(out + 40, fields, sizeof(fields));
        }
        [bytes appendData:frame];
    }
    if (id3v1) {
        NSMutableData *tag = [NSMutableData dataWithLength:128];
        memcpy(tag.mutableBytes, "TAGVibe", 7);
        ((uint8_t *)tag.mutableBytes)[127] = 255; // no genre
        [bytes appendData:tag];
    }
    return bytes;
}

// MPEG-1 Layer III, stereo, at 44.1 or 48 kHz: `frames` silent frames and no
// VBR header, frame i at the bit rate index `index(i)` names (1 is 32 kbps,
// 9 is 128, 14 is 320), so a stream whose length CoreAudio counts only by
// reading every frame header, and whose rate varies as `index` says.
static inline NSData *VibeMP3WithoutVBRHeader(uint32_t frames, uint32_t rate, uint8_t (^index)(uint32_t frame)) {
    static const uint32_t kbps[15] = {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320};
    NSMutableData *bytes = [NSMutableData data];
    for (uint32_t i = 0; i < frames; i++) {
        uint8_t bitrate = index(i);
        NSMutableData *frame = [NSMutableData dataWithLength:144 * kbps[bitrate] * 1000 / rate];
        uint8_t *out = (uint8_t *)frame.mutableBytes;
        out[0] = 0xFF;
        out[1] = 0xFB;
        out[2] = (uint8_t)(bitrate << 4 | (rate == 48000 ? 1 : 0) << 2);
        [bytes appendData:frame];
    }
    return bytes;
}

// VibeMP3WithoutVBRHeader's frames at 44.1 kHz behind a 128 kbps Xing frame.
// The Xing frame counts the frames and bytes and carries a 100-entry seek
// TOC. That is the VBR header LAME writes, without its LAME extension.
static inline NSData *VibeMP3WithXingFrame(uint32_t frames, uint8_t (^index)(uint32_t frame)) {
    static const uint32_t kbps[15] = {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320};
    NSData *body = VibeMP3WithoutVBRHeader(frames, 44100, index);
    NSMutableData *bytes = [NSMutableData dataWithLength:417];
    uint8_t *out = (uint8_t *)bytes.mutableBytes;
    const uint8_t header[4] = {0xFF, 0xFB, 0x90, 0x00};
    memcpy(out, header, sizeof(header));
    memcpy(out + 36, "Xing", 4);
    const uint32_t fields[3] = {CFSwapInt32HostToBig(7), CFSwapInt32HostToBig(frames),
                                CFSwapInt32HostToBig((uint32_t)(417 + body.length))};
    memcpy(out + 40, fields, sizeof(fields));
    // Entry i is where i percent of the frames starts, in 256ths of the audio.
    uint64_t offset = 0;
    uint32_t frame = 0;
    for (uint32_t i = 0; i < 100; i++) {
        for (; frame < (uint64_t)frames * i / 100; frame++) {
            offset += 144 * kbps[index(frame)] * 1000 / 44100;
        }
        out[52 + i] = (uint8_t)MIN((uint64_t)255, offset * 256 / body.length);
    }
    [bytes appendData:body];
    return bytes;
}

// Writes `buffer` as the container its name says — WAV, AIFC for .aif, W64
// for .w64, CAF for .caf — in the buffer's own sample format, interleaved,
// with its channel layout. A .flac is Apple's encode, as afconvert writes it,
// with no seek table: 16-bit from an int16 buffer, else 24-bit.
static inline NSURL *VibeWriteFixture(NSURL *url, AVAudioPCMBuffer *buffer, NSError **error) {
    AVAudioFormat *format = buffer.format;
    NSString *extension = url.pathExtension.lowercaseString;
    BOOL aiff = [extension hasPrefix:@"aif"];
    BOOL flac = [extension isEqualToString:@"flac"];
    AudioFileTypeID type = aiff ? kAudioFileAIFCType
            : flac ? kAudioFileFLACType
            : [extension isEqualToString:@"w64"] ? kAudioFileWave64Type
            : [extension isEqualToString:@"caf"] ? kAudioFileCAFType
            : kAudioFileWAVEType;
    AudioStreamBasicDescription file = *format.streamDescription;
    file.mFormatFlags = (file.mFormatFlags & ~(UInt32)kAudioFormatFlagIsNonInterleaved) | (aiff ? kAudioFormatFlagIsBigEndian : 0);
    file.mBytesPerFrame = file.mBitsPerChannel / 8 * file.mChannelsPerFrame;
    file.mBytesPerPacket = file.mBytesPerFrame;
    if (flac) {
        file = (AudioStreamBasicDescription){
            .mSampleRate = format.sampleRate, .mFormatID = kAudioFormatFLAC,
            .mFormatFlags = format.commonFormat == AVAudioPCMFormatInt16 ? kAppleLosslessFormatFlag_16BitSourceData
                                                                         : kAppleLosslessFormatFlag_24BitSourceData,
            .mChannelsPerFrame = format.channelCount};
    }
    AVAudioFormat *fileFormat = [[AVAudioFormat alloc] initWithStreamDescription:&file channelLayout:format.channelLayout];
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForWriting:url fileType:type
                                                           fileFormat:fileFormat processingFormat:format error:error];
    if (![handle writeFromBuffer:buffer error:error] || ![handle closeWithError:error]) {
        return nil;
    }
    return url;
}

// Decode through AVAudioFile without Vibe's handle wrapper. Both paths can
// use Apple's codecs. Returns nil on failure.
static inline AVAudioPCMBuffer *VibeReadWithAVAudioFile(NSURL *url, NSError **error) {
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:error];
    AVAudioPCMBuffer *whole = file ? [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                                 frameCapacity:(AVAudioFrameCount)file.length] : nil;
    return whole && [file readIntoBuffer:whole error:error] ? whole : nil;
}

// Appends whole interleaved frames; shares no production DSP, so a capture stays independent.
static inline void VibeAppendPCM(NSMutableData *capture, AVAudioPCMBuffer *buffer) {
    NSUInteger channels = buffer.format.channelCount;
    if (buffer.format.isInterleaved) {
        [capture appendBytes:buffer.floatChannelData[0] length:buffer.frameLength * channels * sizeof(float)];
        return;
    }
    NSUInteger start = capture.length;
    [capture increaseLengthBy:buffer.frameLength * channels * sizeof(float)];
    float *out = (float *)((uint8_t *)capture.mutableBytes + start);
    for (NSUInteger frame = 0; frame < buffer.frameLength; frame++)
        for (NSUInteger channel = 0; channel < channels; channel++)
            out[frame * channels + channel] = buffer.floatChannelData[channel][frame];
}

// The least-squares fit of c + Σ a_k·cos(ω_k t) + b_k·sin(ω_k t) over
// `count` samples, t = (index + n) / rate − origin: the tones at their exact
// frequencies, jointly, and the power of everything else. `a` and `b` receive
// each tone's cos and sin terms when given.
static inline double VibeFitTones(const double *x, NSUInteger count, const double *frequencies, int tones, double rate,
                                   double index, double origin, double *a, double *b) {
    int size = 2 * tones + 1;
    double *m = (double *)calloc((size_t)size * size, sizeof(double)), *v = (double *)calloc((size_t)size, sizeof(double));
    double *basis = (double *)malloc((size_t)size * sizeof(double));
    double *coefficients = (double *)calloc((size_t)size, sizeof(double));
    for (NSUInteger n = 0; n < count; n++) {
        double t = (index + n) / rate - origin;
        basis[0] = 1;
        for (int k = 0; k < tones; k++) {
            double phase = 2 * M_PI * frequencies[k] * t;
            basis[1 + 2 * k] = cos(phase);
            basis[2 + 2 * k] = sin(phase);
        }
        for (int i = 0; i < size; i++) {
            v[i] += basis[i] * x[n];
            for (int j = i; j < size; j++) {
                m[i * size + j] += basis[i] * basis[j];
            }
        }
    }
    for (int i = 0; i < size; i++) {
        for (int j = 0; j < i; j++) {
            m[i * size + j] = m[j * size + i];
        }
    }
    // Gaussian elimination with partial pivoting on the normal equations.
    for (int col = 0; col < size; col++) {
        int pivot = col;
        for (int row = col + 1; row < size; row++) {
            if (fabs(m[row * size + col]) > fabs(m[pivot * size + col])) pivot = row;
        }
        if (pivot != col) {
            for (int k = 0; k < size; k++) {
                double swap = m[col * size + k]; m[col * size + k] = m[pivot * size + k]; m[pivot * size + k] = swap;
            }
            double swap = v[col]; v[col] = v[pivot]; v[pivot] = swap;
        }
        for (int row = col + 1; row < size; row++) {
            double factor = m[row * size + col] / m[col * size + col];
            for (int k = col; k < size; k++) {
                m[row * size + k] -= factor * m[col * size + k];
            }
            v[row] -= factor * v[col];
        }
    }
    for (int row = size - 1; row >= 0; row--) {
        double sum = v[row];
        for (int k = row + 1; k < size; k++) {
            sum -= m[row * size + k] * coefficients[k];
        }
        coefficients[row] = sum / m[row * size + row];
    }
    double residual = 0;
    for (NSUInteger n = 0; n < count; n++) {
        double t = (index + n) / rate - origin, e = x[n] - coefficients[0];
        for (int k = 0; k < tones; k++) {
            double phase = 2 * M_PI * frequencies[k] * t;
            e -= coefficients[1 + 2 * k] * cos(phase) + coefficients[2 + 2 * k] * sin(phase);
        }
        residual += e * e;
    }
    for (int k = 0; k < tones; k++) {
        if (a) a[k] = coefficients[1 + 2 * k];
        if (b) b[k] = coefficients[2 + 2 * k];
    }
    free(m);
    free(v);
    free(basis);
    free(coefficients);
    return residual / count;
}

// One tone of VibeFitTones, with its amplitude.
typedef struct {
    double amplitude;   // hypot(a, b)
    double a, b;        // cos and sin terms
    double residualPower;
} VibeToneFit;

static inline VibeToneFit VibeFitTone(const double *x, NSUInteger count, double frequency, double rate, double index,
                                      double origin) {
    VibeToneFit fit;
    fit.residualPower = VibeFitTones(x, count, &frequency, 1, rate, index, origin, &fit.a, &fit.b);
    fit.amplitude = hypot(fit.a, fit.b);
    return fit;
}

// A power ratio in dB; -400 for none.
static inline double VibeDB(double ratio) {
    return ratio > 0 ? 10 * log10(ratio) : -400;
}

typedef struct {
    __unsafe_unretained AVAudioPCMBuffer *source;
    AVAudioFrameCount next;
} VibeReferenceFeed;

static inline uint32_t VibeReferenceSupply(void *userData, uint32_t maxFrames, const float **channels) {
    static float silence[4096];
    VibeReferenceFeed *feed = (VibeReferenceFeed *)userData;
    AVAudioFrameCount left = feed->source.frameLength - feed->next;
    uint32_t count = MIN(maxFrames, 4096u);
    if (left > 0) {
        count = MIN(count, left);
    }
    for (AVAudioChannelCount c = 0; c < feed->source.format.channelCount; c++) {
        channels[c] = left > 0 ? feed->source.floatChannelData[c] + feed->next : silence;
    }
    feed->next += left > 0 ? count : 0;
    return count;
}

// The whole float32 non-interleaved `source` at `rate`: the resampler itself,
// off the bus — no file handle, decoder, ring, render or stream-end logic —
// its tail pushed out with silence and cut at round(N × ratio), as the bus's
// flush does. nil when it cannot convert.
static inline AVAudioPCMBuffer *VibeReferenceResample(AVAudioPCMBuffer *source, double rate) {
    AVAudioChannelCount channels = source.format.channelCount;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
    AVAudioFrameCount length = (AVAudioFrameCount)llround((double)source.frameLength * rate / source.format.sampleRate);
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:MAX(length, 1u)];
    VibeResampler *resampler = VibeResamplerCreate(source.format.sampleRate, rate, channels);
    if (!out || !resampler) {
        return nil;
    }
    float **into = (float **)calloc(channels, sizeof(float *));
    VibeReferenceFeed feed = { source, 0 };
    AVAudioFrameCount made = 0;
    while (made < length) {
        for (AVAudioChannelCount c = 0; c < channels; c++) {
            into[c] = out.floatChannelData[c] + made;
        }
        uint32_t frames = VibeResamplerFill(resampler, VibeReferenceSupply, &feed, MIN(length - made, 4096u), into);
        if (frames == 0) {
            break;
        }
        made += frames;
    }
    free(into);
    VibeResamplerDispose(resampler);
    out.frameLength = made;
    return made == length ? out : nil;
}
