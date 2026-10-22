//
//  AudioFileFixtures.h
//  Vibe
//
//  The audio files the file handle's tests write, shared with an app's tests.
//  VibeWriteWAV and VibeWriteSowtAIFF write the bytes themselves, so reading a
//  fixture back through AudioFileHandle never makes the handle its own oracle.
//  VibeWriteFixture uses the handle's writer for what a bare RIFF cannot
//  carry: a channel layout, or a codec. The ID3v2 and MP3 writers shape the
//  MPEG open's inputs. VibeToneBuffer is the one test tone, and VibeAppendPCM
//  the one capture. VibeFuzzRandom and VibeFuzzBaseSeed are the fuzz classes'
//  generator and seed. VibeTestFileOpener is the player's open, for the file
//  loader's stage 2.
//

#import <AVFoundation/AVFoundation.h>

#import "AudioFileHandle.h"
#import "AudioFileMaterializationCoordinator.h"

// The player's open (VibePlayerFileOpener), for a coordinator test that opens
// real files.
static VibeAudioFileOpener const VibeTestFileOpener =
        ^AudioFileHandle *(NSURL *url, BOOL (^interrupted)(void), NSError **error) {
    return [[AudioFileHandle alloc] initForReading:url interleaved:NO interrupted:interrupted error:error];
};

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
