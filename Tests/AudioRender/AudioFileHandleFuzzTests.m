//
//  AudioFileHandleFuzzTests.m
//
//  Malformed files through AudioFileHandle: open, read the facts, decode to the
//  end, seek and decode again, close. Every decoder the handle chooses is fed:
//  dr_wav, dr_flac, dr_mp3, libvorbis and Apple's (AAC, ALAC, Opus, CAF, and
//  MPEG when it is chosen). The sources are the generated fixtures, sliced to a few
//  hundred KB, plus a few written here that no encoder on the machine makes.
//
//  Seeded. The seed, the source and the mutator are in every failure message,
//  and the failing mutant is attached to the result bundle.
//  TEST_RUNNER_VIBE_FUZZ_SEED re-runs one base seed, and
//  TEST_RUNNER_VIBE_FUZZ_ITERATIONS multiplies every random mutator's count.
//  TEST_RUNNER_VIBE_FUZZ_EXPORT names a folder each mutant is also written to,
//  so another build can decode the same files
//  (the vibe-audio-quality skill's comparison with a release).
//
//  Budgets at the default count. Each family is a subclass, so the parallel
//  runner gives each its own process. Each must stay under 30 seconds in CI.
//  One source's mutants decode across the cores. Seconds are measured on an
//  M-series Mac with the four classes running at once.
//
//  | Class                             | Formats                                                   | Sources | Iterations | Seconds |
//  | --------------------------------- | --------------------------------------------------------- | ------- | ---------- | ------- |
//  | AudioFileHandleFuzzDrWAVTests     | WAV, RF64, W64, AIFF, AIFF-C: every PCM width, float,      | 26      | 8          | 2.7     |
//  |                                   | G.711, unsigned 8-bit, IMA and MS ADPCM, ima4              |         |            |         |
//  | AudioFileHandleFuzzDrFLACTests    | every FLAC fixture: 16 to 32 bits, 1 to 8 channels,        | 11      | 8          | 2.1     |
//  |                                   | block sizes 16 to 65535, 705.6 kHz, 33-bit side channels   |         |            |         |
//  | AudioFileHandleFuzzMPEGTests      | MP3, MP2, MPEG in WAV, each through dr_mp3 and Apple's,    | 14      | 4          | 2.8     |
//  |                                   | and the MPEG open's framing: ID3v2 tags, Xing, VBRI, LAME  |         |            |         |
//  |                                   | and iTunes gapless, free format, mode changes, junk, tags  |         |            |         |
//  | AudioFileHandleFuzzCoreAudioTests | AAC, ADTS, QuickTime, ALAC in MP4 and CAF, LPCM in CAF,    | 10      | 8          | 2.4     |
//  |                                   | Ogg Vorbis (libvorbis), Opus, a WAV past dr_wav's 384 kHz  |         |            |         |
//
//  Iterations is how often each random mutator runs per source. A named shape
//  runs once per source it applies to, whatever the count.
//

#import <XCTest/XCTest.h>
#include <float.h>
#include <time.h>

#import "AudioFixtures.h"
#import "AudioFileHandle.h"

typedef NS_ENUM(NSUInteger, FuzzFamily) { FuzzFamilyWAV, FuzzFamilyFLAC, FuzzFamilyMPEG, FuzzFamilyApple };

static const uint32_t kFuzzIterations[] = {
    [FuzzFamilyWAV] = 8, [FuzzFamilyFLAC] = 8, [FuzzFamilyMPEG] = 4, [FuzzFamilyApple] = 8,
};

// A source larger than this is sliced to kFuzzSliceBytes of audio, so a mutant decodes in milliseconds.
static const NSUInteger kFuzzSourceByteCap = 600 * 1024, kFuzzSliceBytes = 256 * 1024;
// TRAP: a fixture's size says nothing about its length (flac-long.flac is 4.3 billion frames).
// A source declaring more is skipped before anything decodes it.
static const AVAudioFramePosition kFuzzMaxSourceFrames = 1 << 19;
// The CPU time one open, read or seek may take on its own thread. Thread CPU time
// counts only the time the call ran, so a descheduled worker cannot inflate it.
// Generous enough for a sanitizer build.
static const double kFuzzCallCPUSeconds = 2.0;
static const AVAudioFrameCount kFuzzChunkFrames = 4096;

#pragma mark - Random

static NSUInteger FuzzIn(VibeFuzzRandom *random, NSRange range) {
    return range.location + VibeFuzzBelow(random, range.length);
}

#pragma mark - Containers

typedef NS_ENUM(NSUInteger, FuzzContainer) {
    FuzzRIFF, FuzzRF64, FuzzW64, FuzzFORM, FuzzCAF, FuzzFLAC, FuzzMP4, FuzzOgg, FuzzMPEG, FuzzADTS,
};

// One chunk, box, metadata block or page: where its size field is, and its body.
typedef struct {
    NSUInteger at, sizeAt, body, end;
    uint64_t length;
    uint8_t sizeWidth, depth;
    BOOL bigEndian;
    char tag[5];
} FuzzChunk;

static uint64_t FuzzGet(NSData *data, NSUInteger at, uint8_t width, BOOL bigEndian) {
    if (at + width > data.length) return 0;
    const uint8_t *b = (const uint8_t *)data.bytes + at;
    uint64_t value = 0;
    for (uint8_t i = 0; i < width; i++) {
        value |= (uint64_t)b[bigEndian ? width - 1 - i : i] << (8 * i);
    }
    return value;
}

static void FuzzPut(NSMutableData *data, NSUInteger at, uint8_t width, BOOL bigEndian, uint64_t value) {
    if (at + width > data.length) return;
    uint8_t *b = (uint8_t *)data.mutableBytes + at;
    for (uint8_t i = 0; i < width; i++) {
        b[bigEndian ? width - 1 - i : i] = (uint8_t)(value >> (8 * i));
    }
}

static BOOL FuzzTagIs(const FuzzChunk *chunk, const char *tag) {
    return strncmp(chunk->tag, tag, 4) == 0;
}

static void FuzzAddChunk(NSMutableData *chunks, NSData *data, NSUInteger at, NSUInteger sizeAt, uint8_t width, BOOL bigEndian,
                         NSUInteger body, uint64_t length, NSUInteger end, uint8_t depth, const char *tag) {
    FuzzChunk chunk = {0};
    chunk.at = at; chunk.sizeAt = sizeAt; chunk.sizeWidth = width; chunk.bigEndian = bigEndian;
    chunk.body = MIN(body, data.length);
    chunk.length = MIN(length, (uint64_t)(data.length - chunk.body));
    chunk.end = MIN(end, data.length);
    chunk.depth = depth;
    memcpy(chunk.tag, tag, 4);
    [chunks appendBytes:&chunk length:sizeof(chunk)];
}

// A Xing tag within `range`, else an Info tag. location NSNotFound for neither.
static NSRange FuzzXingRange(NSData *bytes, NSRange range) {
    range.length = MIN(range.length, bytes.length - MIN(range.location, bytes.length));
    NSRange xing = [bytes rangeOfData:[@"Xing" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:range];
    return xing.location != NSNotFound ? xing : [bytes rangeOfData:[@"Info" dataUsingEncoding:NSASCIIStringEncoding] options:0 range:range];
}

// An MPEG audio frame's bytes from its header, 0 for no valid header.
static NSUInteger FuzzMPEGFrameBytes(const uint8_t *h) {
    if (h[0] != 0xFF || (h[1] & 0xE0) != 0xE0) return 0;
    int version = (h[1] >> 3) & 3, layer = (h[1] >> 1) & 3, bitrateIndex = h[2] >> 4, rateIndex = (h[2] >> 2) & 3, padding = (h[2] >> 1) & 1;
    if (version == 1 || layer == 0 || bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) return 0;
    static const int rates[4][3] = {{11025, 12000, 8000}, {0, 0, 0}, {22050, 24000, 16000}, {44100, 48000, 32000}};
    static const int kbps[2][3][15] = {
        {{0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256}, {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160},
         {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160}},
        {{0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448}, {0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384},
         {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320}}};
    BOOL mpeg1 = version == 3;
    int l = 3 - layer, rate = rates[version][rateIndex], bitrate = kbps[mpeg1][l][bitrateIndex] * 1000;
    if (l == 0) return (NSUInteger)(12 * bitrate / rate + padding) * 4;
    return (NSUInteger)((l == 2 && !mpeg1 ? 72 : 144) * bitrate / rate + padding);
}

static FuzzContainer FuzzContainerOf(NSData *data) {
    const uint8_t *b = data.bytes;
    if (data.length < 12) return FuzzMPEG;
    if (memcmp(b, "RIFF", 4) == 0) return FuzzRIFF;
    if (memcmp(b, "RF64", 4) == 0) return FuzzRF64;
    if (memcmp(b, "riff", 4) == 0) return FuzzW64;
    if (memcmp(b, "FORM", 4) == 0) return FuzzFORM;
    if (memcmp(b, "caff", 4) == 0) return FuzzCAF;
    if (memcmp(b, "fLaC", 4) == 0) return FuzzFLAC;
    if (memcmp(b, "OggS", 4) == 0) return FuzzOgg;
    if (memcmp(b + 4, "ftyp", 4) == 0 || memcmp(b + 4, "moov", 4) == 0 || memcmp(b + 4, "wide", 4) == 0) return FuzzMP4;
    if (b[0] == 0xFF && (b[1] & 0xF6) == 0xF0) return FuzzADTS;
    return FuzzMPEG;
}

static void FuzzWalkMP4(NSData *data, NSUInteger from, NSUInteger to, uint8_t depth, NSMutableData *chunks) {
    static const char *containers[] = {"moov", "trak", "mdia", "minf", "stbl", "edts", "udta"};
    for (NSUInteger at = from; at + 8 <= to && chunks.length < 256 * sizeof(FuzzChunk);) {
        uint64_t size = FuzzGet(data, at, 4, YES);
        NSUInteger header = 8, sizeAt = at;
        uint8_t width = 4;
        if (size == 1) { size = FuzzGet(data, at + 8, 8, YES); header = 16; sizeAt = at + 8; width = 8; }
        if (size == 0) size = to - at;
        if (size < header) break;
        char tag[5] = {0};
        memcpy(tag, (const char *)data.bytes + at + 4, 4);
        FuzzAddChunk(chunks, data, at, sizeAt, width, YES, at + header, size - header, at + size, depth, tag);
        for (size_t i = 0; i < sizeof(containers) / sizeof(*containers); i++) {
            if (memcmp(tag, containers[i], 4) == 0) FuzzWalkMP4(data, at + header, MIN(at + size, to), depth + 1, chunks);
        }
        if (size > to - at) break;
        at += size;
    }
}

// Every size-bearing structure of the file, and the range its audio frames occupy.
static NSData *FuzzWalk(NSData *data, FuzzContainer container, NSRange *audio) {
    NSMutableData *chunks = [NSMutableData data];
    const uint8_t *b = data.bytes;
    NSUInteger length = data.length;
    *audio = NSMakeRange(length / 4, length - length / 4);
    switch (container) {
        case FuzzRIFF: case FuzzRF64: case FuzzFORM: case FuzzW64: case FuzzCAF: {
            BOOL big = container == FuzzFORM || container == FuzzCAF, w64 = container == FuzzW64, caf = container == FuzzCAF;
            if (!caf) FuzzAddChunk(chunks, data, 0, w64 ? 16 : 4, w64 ? 8 : 4, big, 0, 0, length, 0, "<all");
            NSUInteger header = w64 ? 24 : caf ? 12 : 8, at = w64 ? 40 : caf ? 8 : 12;
            uint8_t width = w64 || caf ? 8 : 4;
            while (at + header <= length && chunks.length < 64 * sizeof(FuzzChunk)) {
                uint64_t size = FuzzGet(data, at + (w64 ? 16 : 4), width, big);
                if (w64) size = size >= 24 ? size - 24 : 0;
                if (caf && size == UINT64_MAX) size = length - at - header;
                char tag[5] = {0};
                memcpy(tag, b + at, 4);
                uint64_t padded = w64 ? (size + 7) & ~7ULL : caf ? size : size + (size & 1);
                NSUInteger end = padded > length - at - header ? length : at + header + (NSUInteger)padded;
                FuzzAddChunk(chunks, data, at, at + (w64 ? 16 : 4), width, big, at + header, size, end, 0, tag);
                NSUInteger body = at + header;
                if (memcmp(tag, "data", 4) == 0) {
                    uint64_t bytes = container == FuzzRF64 ? length - body : size;
                    NSUInteger start = body + (caf ? 4 : 0);
                    *audio = NSMakeRange(start, (NSUInteger)MIN(bytes, (uint64_t)(length - MIN(start, length))));
                } else if (memcmp(tag, "SSND", 4) == 0) {
                    *audio = NSMakeRange(body + 8, (NSUInteger)MIN(size >= 8 ? size - 8 : 0, (uint64_t)(length - MIN(body + 8, length))));
                }
                if (end <= at) break;
                at = end;
            }
            break;
        }
        case FuzzFLAC: {
            NSUInteger at = 4;
            while (at + 4 <= length) {
                uint32_t size = (uint32_t)FuzzGet(data, at + 1, 3, YES);
                char tag[5] = {'B', 'L', 'K', (char)('0' + (b[at] & 0x7F) % 10), 0};
                FuzzAddChunk(chunks, data, at, at + 1, 3, YES, at + 4, size, at + 4 + size, 0, tag);
                BOOL last = b[at] & 0x80;
                at += 4 + size;
                if (last) break;
            }
            if (at < length) *audio = NSMakeRange(at, length - at);
            break;
        }
        case FuzzMP4: {
            FuzzWalkMP4(data, 0, length, 0, chunks);
            for (NSUInteger i = 0; i < chunks.length / sizeof(FuzzChunk); i++) {
                const FuzzChunk *chunk = (const FuzzChunk *)chunks.bytes + i;
                if (FuzzTagIs(chunk, "mdat") && chunk->length > 0) *audio = NSMakeRange(chunk->body, (NSUInteger)chunk->length);
            }
            break;
        }
        case FuzzOgg: {
            NSUInteger pages = 0;
            for (NSUInteger at = 0; at + 27 <= length && memcmp(b + at, "OggS", 4) == 0;) {
                NSUInteger segments = b[at + 26], body = at + 27 + segments, size = 0;
                if (body > length) break;
                for (NSUInteger s = 0; s < segments; s++) size += b[at + 27 + s];
                // TRAP: a changed page segment count can make Apple's Ogg parser spin forever inside
                // ExtAudioFileRead (OggAudioFile::ReadPacketData over CompressedPacketTable). It reads memory
                // it never wrote, so it hangs only when the allocator leaves garbage there (ASan, MallocScribble).
                // So the page registers no size field, and no size mutator writes the count.
                // lossy.ogg at seed 0x73262c100d5d02fa reproduced it, before VibeFuzzBelow drew from the high bits.
                FuzzAddChunk(chunks, data, at, at + 26, 0, NO, body, size, body + size, 0, "OggS");
                if (++pages == 3) *audio = NSMakeRange(at, length - at);
                at = body + size;
            }
            break;
        }
        case FuzzMPEG: {
            NSUInteger tag = VibeID3v2Length(data, 0);
            if (tag) FuzzAddChunk(chunks, data, 0, 6, 4, YES, 10, tag - 10, tag, 0, "ID3 ");
            NSUInteger first = tag + 4 <= length ? FuzzMPEGFrameBytes(b + tag) : 0;
            if (tag + first < length) *audio = NSMakeRange(tag + first, length - tag - first);
            break;
        }
        case FuzzADTS:
            *audio = NSMakeRange(7, length - 7);
            break;
    }
    return chunks;
}

#pragma mark - Sources

@interface FuzzSource : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *extension;
@property (nonatomic, strong) NSData *bytes;
@property (nonatomic) FuzzContainer container;
@property (nonatomic) NSRange audio;
@property (nonatomic, strong) NSData *chunks;
@property (nonatomic) FuzzFamily family;
@property (nonatomic) AVAudioFramePosition length;
// The frames the audio bytes hold, past a count that ends short of them (MS ADPCM's fact count).
@property (nonatomic) AVAudioFramePosition heldFrames;
@end
@implementation FuzzSource
- (NSUInteger)chunkCount { return self.chunks.length / sizeof(FuzzChunk); }
- (const FuzzChunk *)chunkAt:(NSUInteger)i { return (const FuzzChunk *)self.chunks.bytes + i; }
- (const FuzzChunk *)chunkTagged:(const char *)tag {
    for (NSUInteger i = 0; i < self.chunkCount; i++) if (FuzzTagIs([self chunkAt:i], tag)) return [self chunkAt:i];
    return NULL;
}
@end

static void FuzzReadWalk(FuzzSource *source) {
    NSRange audio;
    source.container = FuzzContainerOf(source.bytes);
    source.chunks = FuzzWalk(source.bytes, source.container, &audio);
    source.audio = audio;
}

// A RIFF WAV whose 28-byte JUNK chunk is the room afconvert leaves for ds64, made RF64.
static NSData *FuzzAsRF64(NSData *wav, uint64_t sampleCount) {
    NSRange audio;
    NSData *chunks = FuzzWalk(wav, FuzzRIFF, &audio);
    NSMutableData *rf64 = [wav mutableCopy];
    const FuzzChunk *junk = NULL, *data = NULL;
    for (NSUInteger i = 0; i < chunks.length / sizeof(FuzzChunk); i++) {
        const FuzzChunk *chunk = (const FuzzChunk *)chunks.bytes + i;
        if (FuzzTagIs(chunk, "JUNK") && chunk->length == 28) junk = chunk;
        if (FuzzTagIs(chunk, "data")) data = chunk;
    }
    if (!junk || !data) return nil;
    [rf64 replaceBytesInRange:NSMakeRange(0, 4) withBytes:"RF64"];
    FuzzPut(rf64, 4, 4, NO, 0xFFFFFFFF);
    [rf64 replaceBytesInRange:NSMakeRange(junk->at, 4) withBytes:"ds64"];
    FuzzPut(rf64, junk->body, 8, NO, wav.length - 8);
    FuzzPut(rf64, junk->body + 8, 8, NO, data->length);
    FuzzPut(rf64, junk->body + 16, 8, NO, sampleCount);
    FuzzPut(rf64, junk->body + 24, 4, NO, 0);
    FuzzPut(rf64, data->sizeAt, 4, NO, 0xFFFFFFFF);
    return rf64;
}

// The containers FuzzSlice cuts. A larger source of any other is never read.
static BOOL FuzzSliceable(FuzzContainer container) {
    return container == FuzzFLAC || container == FuzzRIFF || container == FuzzRF64 || container == FuzzW64
        || container == FuzzFORM || container == FuzzCAF;
}

// The source cut to about kFuzzSliceBytes of audio and still well formed: a FLAC
// cut anywhere with its length cleared, as a streamed encode leaves it; fixed-size
// frames with every count that names them rewritten. nil when neither applies.
static NSData *FuzzSlice(FuzzSource *source, AudioFileHandle *handle) {
    NSMutableData *bytes = [source.bytes mutableCopy];
    if (source.container == FuzzFLAC) {
        if (bytes.length < 42) return nil;
        uint8_t *info = (uint8_t *)bytes.mutableBytes + 8;
        info[13] &= 0xF0;
        memset(info + 14, 0, 4);
        bytes.length = source.audio.location + kFuzzSliceBytes;
        return bytes;
    }
    const AudioStreamBasicDescription *file = handle.fileFormat.streamDescription;
    NSUInteger packet = file->mBytesPerPacket, frames = MAX(file->mFramesPerPacket, 1u);
    if (!FuzzSliceable(source.container) || packet == 0 || source.audio.length <= kFuzzSliceBytes) return nil;
    NSUInteger keep = kFuzzSliceBytes / (packet * 2) * packet * 2, cut = source.audio.length - keep;
    [bytes replaceBytesInRange:NSMakeRange(NSMaxRange(source.audio) - cut, cut) withBytes:NULL length:0];
    uint64_t frameCount = keep / packet * frames;
    for (NSUInteger i = 0; i < source.chunkCount; i++) {
        const FuzzChunk *chunk = [source chunkAt:i];
        if (chunk->at > source.audio.location) continue;
        if (FuzzTagIs(chunk, "<all")) {
            uint64_t all = FuzzGet(bytes, chunk->sizeAt, chunk->sizeWidth, chunk->bigEndian);
            if (all != 0xFFFFFFFF) FuzzPut(bytes, chunk->sizeAt, chunk->sizeWidth, chunk->bigEndian, all - cut);
        } else if (FuzzTagIs(chunk, "data") || FuzzTagIs(chunk, "SSND")) {
            uint64_t size = FuzzGet(bytes, chunk->sizeAt, chunk->sizeWidth, chunk->bigEndian);
            if (size != 0xFFFFFFFF && size != UINT64_MAX) FuzzPut(bytes, chunk->sizeAt, chunk->sizeWidth, chunk->bigEndian, size - cut);
        } else if (FuzzTagIs(chunk, "COMM")) {
            FuzzPut(bytes, chunk->body + 2, 4, YES, frameCount);
        } else if (FuzzTagIs(chunk, "ds64")) {
            FuzzPut(bytes, chunk->body, 8, NO, FuzzGet(bytes, chunk->body, 8, NO) - cut);
            FuzzPut(bytes, chunk->body + 8, 8, NO, keep);
            FuzzPut(bytes, chunk->body + 16, 8, NO, frameCount);
        } else if (FuzzTagIs(chunk, "fact")) {
            FuzzPut(bytes, chunk->body, 4, NO, frameCount);
        }
    }
    return bytes;
}

static NSURL *FuzzScratch(void) {
    static NSURL *scratch;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        scratch = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                          [@"AudioFileHandleFuzz-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:nil error:NULL];
    });
    return scratch;
}

static AudioFileHandle *FuzzOpenBytes(NSData *bytes, NSString *name) {
    NSURL *url = [FuzzScratch() URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingFormat:@"-%@", name]];
    [bytes writeToURL:url atomically:NO];
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url error:NULL];
    [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    return handle;
}

// Fixtures no encoder here supplies: integer LPCM and a 5.1 layout in CAF, a 5.1
// extensible WAV, and float W64. A quarter second of noise each, written into `dir`.
static NSArray<NSString *> *FuzzWrittenSources(NSURL *dir) {
    NSMutableArray<NSString *> *written = [NSMutableArray array];
    AVAudioChannelLayout *surround = [AVAudioChannelLayout layoutWithLayoutTag:kAudioChannelLayoutTag_MPEG_5_1_A];
    NSArray *specs = @[@[@"written-int16.caf", @(AVAudioPCMFormatInt16), @2], @[@"written-float32-5.1.caf", @(AVAudioPCMFormatFloat32), @6],
                       @[@"written-int16-5.1.wav", @(AVAudioPCMFormatInt16), @6], @[@"written-float32.w64", @(AVAudioPCMFormatFloat32), @2]];
    for (NSArray *spec in specs) {
        AVAudioChannelCount channels = [spec[2] unsignedIntValue];
        AVAudioFormat *format = channels == 6
                ? [[AVAudioFormat alloc] initWithCommonFormat:[spec[1] integerValue] sampleRate:48000 interleaved:NO channelLayout:surround]
                : [[AVAudioFormat alloc] initWithCommonFormat:[spec[1] integerValue] sampleRate:48000 channels:channels interleaved:NO];
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:12000];
        buffer.frameLength = 12000;
        VibeFuzzRandom random = {0x12345678};
        for (AVAudioChannelCount c = 0; c < channels; c++) {
            for (AVAudioFrameCount f = 0; f < buffer.frameLength; f++) {
                float value = ((float)(VibeFuzzNext(&random) >> 40) / 8388608.0f - 1.0f) * 0.25f;
                if (buffer.int16ChannelData) buffer.int16ChannelData[c][f] = (int16_t)(value * 32767);
                else buffer.floatChannelData[c][f] = value;
            }
        }
        NSURL *url = [dir URLByAppendingPathComponent:spec[0]];
        if (VibeWriteFixture(url, buffer, NULL)) [written addObject:url.path];
    }
    return written;
}

static FuzzFamily FuzzFamilyOf(NSString *decoder) {
    return [decoder isEqualToString:@"dr_wav"] ? FuzzFamilyWAV : [decoder isEqualToString:@"dr_flac"] ? FuzzFamilyFLAC
         : [decoder isEqualToString:@"dr_mp3"] ? FuzzFamilyMPEG : FuzzFamilyApple;
}

// Every fixture of `family` the generator wrote, one per coding for dr_wav's and every one for
// the rest. Each is probed at its own path to learn its family. Only the
// family's own are read, and a source over the cap only when FuzzSlice can cut it.
static NSArray<FuzzSource *> *FuzzCorpus(FuzzFamily family, NSURL *scratch, NSMutableArray<NSString *> *notes) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *root = NSProcessInfo.processInfo.environment[@"VIBE_AUDIO_FIXTURES"];
    for (NSString *name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:NULL] sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name hasPrefix:@"alias."] || [@[@"f32", @"json"] containsObject:name.pathExtension]) continue;
        [paths addObject:[root stringByAppendingPathComponent:name]];
    }
    [paths addObjectsFromArray:FuzzWrittenSources(scratch)];
    NSMutableDictionary<NSString *, FuzzSource *> *byKey = [NSMutableDictionary dictionary];
    for (NSString *path in paths) {
        FuzzSource *source = [FuzzSource new];
        source.name = path.lastPathComponent;
        source.extension = source.name.pathExtension;
        AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:[NSURL fileURLWithPath:path] error:NULL];
        if (!handle) { [notes addObject:[source.name stringByAppendingString:@": refused"]]; continue; }
        if (handle.length > kFuzzMaxSourceFrames) {
            [notes addObject:[NSString stringWithFormat:@"%@: declares %lld frames", source.name, handle.length]];
            continue;
        }
        if (FuzzFamilyOf(handle.decoderName) != family) continue;
        unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL].fileSize;
        if (size > kFuzzSourceByteCap) {
            NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
            NSData *head = [file readDataUpToLength:12 error:NULL];
            [file closeAndReturnError:NULL];
            if (!FuzzSliceable(FuzzContainerOf(head))) {
                [notes addObject:[NSString stringWithFormat:@"%@: %llu bytes, not sliceable", source.name, size]];
                continue;
            }
        }
        source.bytes = [NSData dataWithContentsOfFile:path];
        FuzzReadWalk(source);
        if (size > kFuzzSourceByteCap) {
            NSData *sliced = FuzzSlice(source, handle);
            handle = sliced ? FuzzOpenBytes(sliced, source.name) : nil;
            if (!handle || handle.length > kFuzzMaxSourceFrames) {
                [notes addObject:[NSString stringWithFormat:@"%@: %llu bytes, not sliceable", source.name, size]];
                continue;
            }
            source.bytes = sliced;
            FuzzReadWalk(source);
        }
        source.family = family;
        source.length = handle.length;
        const AudioStreamBasicDescription *file = handle.fileFormat.streamDescription;
        source.heldFrames = MAX(source.length, file->mBytesPerPacket
                ? (AVAudioFramePosition)(source.audio.length / file->mBytesPerPacket * MAX(file->mFramesPerPacket, 1u)) : 0);
        NSString *key = source.name;
        if (family == FuzzFamilyWAV && ![source.name hasPrefix:@"written-"]) {
            // The form type (WAVE, AIFF or AIFC) is in the key, since AIFF's COMM is not AIFF-C's.
            NSString *form = [[NSString alloc] initWithData:[source.bytes subdataWithRange:NSMakeRange(8, 4)] encoding:NSISOLatin1StringEncoding];
            key = [NSString stringWithFormat:@"%lu-%@-%u-%u-%u-%u", (unsigned long)source.container, form, (unsigned)file->mFormatID,
                   (unsigned)file->mBitsPerChannel, (unsigned)(file->mFormatFlags & kAudioFormatFlagIsFloat), (unsigned)(file->mChannelsPerFrame > 2)];
        }
        FuzzSource *held = byKey[key];
        if (!held || held.bytes.length > source.bytes.length) byKey[key] = source;
        // A true RF64, with its ds64, made from afconvert's RIFF.
        if (source.container == FuzzRIFF && [source.name hasPrefix:@"rf64-"]) {
            FuzzSource *rf64 = [FuzzSource new];
            rf64.name = [source.name.stringByDeletingPathExtension stringByAppendingString:@"-as-rf64.wav"];
            rf64.extension = @"wav";
            rf64.bytes = FuzzAsRF64(source.bytes, (uint64_t)source.length);
            rf64.family = FuzzFamilyWAV;
            rf64.length = source.length;
            rf64.heldFrames = source.heldFrames;
            if (rf64.bytes && FuzzOpenBytes(rf64.bytes, rf64.name)) {
                FuzzReadWalk(rf64);
                byKey[rf64.name] = rf64;
            }
        }
    }
    return [byKey.allValues sortedArrayUsingComparator:^NSComparisonResult(FuzzSource *a, FuzzSource *b) { return [a.name compare:b.name]; }];
}

#pragma mark - Mutators

// `arg` is the table's, for a mutator that runs in more than one shape.
typedef BOOL (*FuzzMutate)(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg);

static const FuzzChunk *FuzzAnyChunk(FuzzSource *source, VibeFuzzRandom *random) {
    return source.chunkCount ? [source chunkAt:VibeFuzzBelow(random, source.chunkCount)] : NULL;
}

// A chunk with a size field. An Ogg page has none (FuzzWalk).
static const FuzzChunk *FuzzSizedChunk(FuzzSource *source, VibeFuzzRandom *random) {
    NSUInteger sized = 0;
    for (NSUInteger i = 0; i < source.chunkCount; i++) sized += [source chunkAt:i]->sizeWidth > 0;
    for (NSUInteger i = 0, k = VibeFuzzBelow(random, sized); sized && i < source.chunkCount; i++) {
        if ([source chunkAt:i]->sizeWidth > 0 && k-- == 0) return [source chunkAt:i];
    }
    return NULL;
}

static BOOL FuzzTruncateHeader(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    if (source.audio.location < 2) return NO;
    bytes.length = 1 + VibeFuzzBelow(random, source.audio.location - 1);
    return YES;
}

static BOOL FuzzTruncateFrames(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    if (source.audio.length < 2) return NO;
    bytes.length = FuzzIn(random, NSMakeRange(source.audio.location + 1, source.audio.length - 1));
    return YES;
}

static BOOL FuzzFlipHeader(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    if (source.audio.location == 0) return NO;
    for (NSUInteger i = 0, n = 1 + VibeFuzzBelow(random, 4); i < n; i++) {
        ((uint8_t *)bytes.mutableBytes)[VibeFuzzBelow(random, source.audio.location)] ^= (uint8_t)(1 << VibeFuzzBelow(random, 8));
    }
    return YES;
}

static BOOL FuzzFlipSizeField(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    const FuzzChunk *chunk = FuzzSizedChunk(source, random);
    if (!chunk) return NO;
    ((uint8_t *)bytes.mutableBytes)[chunk->sizeAt + VibeFuzzBelow(random, chunk->sizeWidth)] ^= (uint8_t)(1 << VibeFuzzBelow(random, 8));
    return YES;
}

static BOOL FuzzFlipFrames(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    if (source.audio.length == 0) return NO;
    for (NSUInteger i = 0, n = 1 + VibeFuzzBelow(random, 16); i < n; i++) {
        ((uint8_t *)bytes.mutableBytes)[FuzzIn(random, source.audio)] = (uint8_t)VibeFuzzNext(random);
    }
    return YES;
}

typedef NS_ENUM(NSUInteger, FuzzSize) { FuzzSizeZero, FuzzSizeMax, FuzzSizePastEnd, FuzzSizeOdd };

static BOOL FuzzSetSize(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    const FuzzChunk *chunk = FuzzSizedChunk(source, random);
    if (!chunk) return NO;
    uint64_t max = chunk->sizeWidth == 8 ? UINT64_MAX : (1ULL << (8 * chunk->sizeWidth)) - 1;
    uint64_t now = FuzzGet(bytes, chunk->sizeAt, chunk->sizeWidth, chunk->bigEndian);
    uint64_t value = arg == FuzzSizeZero ? 0 : arg == FuzzSizeMax ? max
                   : arg == FuzzSizePastEnd ? MIN(max, (uint64_t)bytes.length + 1 + VibeFuzzBelow(random, 1 << 20)) : now | 1;
    FuzzPut(bytes, chunk->sizeAt, chunk->sizeWidth, chunk->bigEndian, value);
    return YES;
}

// Chunks a container lets stand in any order: never the outer size, and in an MP4 only the top level.
static const FuzzChunk *FuzzMovableChunk(FuzzSource *source, VibeFuzzRandom *random) {
    if (source.container == FuzzOgg || source.container == FuzzMPEG || source.container == FuzzADTS) return NULL;
    for (int attempt = 0; attempt < 8; attempt++) {
        const FuzzChunk *chunk = FuzzAnyChunk(source, random);
        if (chunk && !FuzzTagIs(chunk, "<all") && chunk->depth == 0 && chunk->end > chunk->at && chunk->end - chunk->at <= 1 << 20) return chunk;
    }
    return NULL;
}

static BOOL FuzzDuplicateChunk(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    const FuzzChunk *chunk = FuzzMovableChunk(source, random);
    if (!chunk) return NO;
    NSData *copy = [bytes subdataWithRange:NSMakeRange(chunk->at, chunk->end - chunk->at)];
    [bytes replaceBytesInRange:NSMakeRange(chunk->end, 0) withBytes:copy.bytes length:copy.length];
    return YES;
}

static BOOL FuzzReorderChunks(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    const FuzzChunk *a = FuzzMovableChunk(source, random), *b = FuzzMovableChunk(source, random);
    if (!a || !b || a == b) return NO;
    if (a->at > b->at) { const FuzzChunk *t = a; a = b; b = t; }
    if (a->end > b->at) return NO;
    NSData *first = [bytes subdataWithRange:NSMakeRange(a->at, a->end - a->at)];
    NSData *second = [bytes subdataWithRange:NSMakeRange(b->at, b->end - b->at)];
    [bytes replaceBytesInRange:NSMakeRange(b->at, second.length) withBytes:first.bytes length:first.length];
    [bytes replaceBytesInRange:NSMakeRange(a->at, first.length) withBytes:second.bytes length:second.length];
    return YES;
}

// One fact field the container states: a sample rate (rate YES) or a frame or sample count.
typedef struct { NSUInteger at; uint8_t width; BOOL bigEndian; } FuzzField;

static NSUInteger FuzzFactFields(FuzzSource *source, BOOL rate, FuzzField *fields) {
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < source.chunkCount; i++) {
        const FuzzChunk *c = [source chunkAt:i];
        NSUInteger at = c->body;
        #define FIELD(offset, w, big) fields[n++] = (FuzzField){at + (offset), (w), (big)}
        if (FuzzTagIs(c, "fmt ") && c->length >= 16) { if (rate) { FIELD(4, 4, NO); FIELD(8, 4, NO); } else { FIELD(2, 2, NO); FIELD(12, 2, NO); FIELD(14, 2, NO); } }
        else if (FuzzTagIs(c, "fact") && !rate) FIELD(0, 4, NO);
        else if (FuzzTagIs(c, "ds64") && !rate) { FIELD(8, 8, NO); FIELD(16, 8, NO); }
        else if (FuzzTagIs(c, "COMM") && c->length >= 18) { if (rate) { FIELD(8, 2, YES); FIELD(10, 8, YES); } else { FIELD(0, 2, YES); FIELD(2, 4, YES); FIELD(6, 2, YES); } }
        else if (FuzzTagIs(c, "desc") && c->length >= 32) { if (rate) FIELD(0, 8, YES); else { FIELD(16, 4, YES); FIELD(20, 4, YES); FIELD(24, 4, YES); } }
        else if (FuzzTagIs(c, "pakt") && c->length >= 24 && !rate) { FIELD(0, 8, YES); FIELD(8, 8, YES); FIELD(16, 4, YES); FIELD(20, 4, YES); }
        else if (FuzzTagIs(c, "BLK0") && c->length >= 18) { if (rate) FIELD(10, 3, YES); else { FIELD(0, 2, YES); FIELD(2, 2, YES); FIELD(13, 5, YES); } }
        else if ((FuzzTagIs(c, "mdhd") || FuzzTagIs(c, "mvhd")) && c->length >= 20) {
            BOOL v1 = ((const uint8_t *)source.bytes.bytes)[at] == 1;
            if (rate) FIELD(v1 ? 20 : 12, 4, YES); else FIELD(v1 ? 24 : 16, v1 ? 8 : 4, YES);
        }
        else if ((FuzzTagIs(c, "stts") || FuzzTagIs(c, "stsz")) && c->length >= 16 && !rate) { FIELD(4, 4, YES); FIELD(8, 4, YES); FIELD(12, 4, YES); }
        else if (FuzzTagIs(c, "stsd") && c->length >= 44 && rate) FIELD(8 + 32, 4, YES);
        else if (FuzzTagIs(c, "OggS")) {
            if (!rate) fields[n++] = (FuzzField){c->at + 6, 8, NO};
            else if (c->at == 0 && c->length >= 16) FIELD(12, 4, NO); // vorbis and OpusHead both hold the rate at 12
        }
        #undef FIELD
        if (n > 24) break;
    }
    if (source.container == FuzzMPEG && source.audio.location >= 4) {
        NSRange xing = FuzzXingRange(source.bytes, NSMakeRange(0, source.audio.location));
        if (xing.location != NSNotFound && !rate) fields[n++] = (FuzzField){xing.location + 8, 4, YES};
    }
    return n;
}

// `arg` YES for a rate, NO for a count.
static BOOL FuzzExtremeFact(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    BOOL rate = arg != 0;
    FuzzField fields[32];
    NSUInteger n = FuzzFactFields(source, rate, fields);
    // MPEG and ADTS state theirs in every frame header: a reserved rate index, or a frame length of 0 or 8191.
    if (source.container == FuzzMPEG || source.container == FuzzADTS) {
        const uint8_t *b = bytes.bytes;
        NSUInteger at = FuzzIn(random, source.audio);
        for (; at + 7 < bytes.length; at++) {
            BOOL adts = source.container == FuzzADTS;
            if (b[at] == 0xFF && (adts ? (b[at + 1] & 0xF6) == 0xF0 : (b[at + 1] & 0xE0) == 0xE0)) break;
        }
        if (at + 7 < bytes.length && (n == 0 || VibeFuzzBelow(random, 2))) {
            uint8_t *h = (uint8_t *)bytes.mutableBytes + at;
            if (source.container == FuzzMPEG) h[2] = rate ? (h[2] | 0x0C) : (h[2] | 0xF0);
            else if (rate) h[2] = (uint8_t)((h[2] & ~0x3C) | (VibeFuzzBelow(random, 2) ? 0x3C : 0x34));
            else { uint16_t frame = VibeFuzzBelow(random, 2) ? 0 : 0x1FFF; h[3] = (uint8_t)((h[3] & 0xFC) | (frame >> 11)); h[4] = (uint8_t)(frame >> 3); h[5] = (uint8_t)((h[5] & 0x1F) | (frame & 7) << 5); }
            return YES;
        }
    }
    if (n == 0) return NO;
    FuzzField field = fields[VibeFuzzBelow(random, n)];
    uint64_t max = field.width == 8 ? UINT64_MAX : (1ULL << (8 * field.width)) - 1;
    uint64_t choices[] = {0, 1, max, max >> 1, 384001, 0x7FFFFFFF, VibeFuzzNext(random) & max};
    if (field.width == 8 && field.bigEndian && rate) {
        // CAF's rate is a float64.
        double doubles[] = {0, -1, NAN, INFINITY, 1e300, 5e-324, 384001};
        double value = doubles[VibeFuzzBelow(random, 7)];
        uint64_t bits;
        memcpy(&bits, &value, sizeof(bits));
        FuzzPut(bytes, field.at, 8, YES, bits);
        return YES;
    }
    FuzzPut(bytes, field.at, field.width, field.bigEndian, choices[VibeFuzzBelow(random, 7)] & max);
    return YES;
}

static BOOL FuzzSyncMidFrame(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    static const uint8_t mpeg[] = {0xFF, 0xFB, 0x90, 0x64}, adts[] = {0xFF, 0xF1, 0x50, 0x80, 0x02, 0x1F, 0xFC},
                         flac[] = {0xFF, 0xF8, 0xC9, 0x18, 0x00}, ogg[] = {'O', 'g', 'g', 'S', 0}, riff[] = {'d', 'a', 't', 'a', 0xF0, 0xFF, 0xFF, 0xFF},
                         form[] = {'S', 'S', 'N', 'D', 0x7F, 0xFF, 0xFF, 0xF0};
    const uint8_t *sync = riff;
    NSUInteger length = sizeof(riff);
    switch (source.container) {
        case FuzzMPEG: sync = mpeg; length = sizeof(mpeg); break;
        case FuzzADTS: case FuzzMP4: sync = adts; length = sizeof(adts); break;
        case FuzzFLAC: sync = flac; length = sizeof(flac); break;
        case FuzzOgg: sync = ogg; length = sizeof(ogg); break;
        case FuzzFORM: case FuzzCAF: sync = form; length = sizeof(form); break;
        default: break;
    }
    if (source.audio.length <= length) return NO;
    [bytes replaceBytesInRange:NSMakeRange(FuzzIn(random, NSMakeRange(source.audio.location, source.audio.length - length)), length) withBytes:sync];
    return YES;
}

static BOOL FuzzSeekTablePastEnd(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    uint64_t past = bytes.length + 1 + VibeFuzzBelow(random, 1 << 24);
    if (source.container == FuzzFLAC && source.chunkCount) {
        const FuzzChunk *table = [source chunkTagged:"BLK3"];
        if (table) {
            for (NSUInteger at = table->body; at + 18 <= table->body + table->length; at += 18) FuzzPut(bytes, at + 8, 8, YES, past + at);
            return YES;
        }
        // A table after STREAMINFO, eight points across the stream, each past the file's end.
        const FuzzChunk *info = [source chunkAt:0];
        NSMutableData *block = [NSMutableData data];
        uint8_t header[4] = {(uint8_t)(3 | (((const uint8_t *)bytes.bytes)[info->at] & 0x80)), 0, 0, 8 * 18};
        [block appendBytes:header length:4];
        for (uint64_t k = 0; k < 8; k++) {
            NSMutableData *point = [NSMutableData dataWithLength:18];
            FuzzPut(point, 0, 8, YES, k * (uint64_t)MAX(source.length, 8) / 8);
            FuzzPut(point, 8, 8, YES, past * (k + 1));
            FuzzPut(point, 16, 2, YES, 4096);
            [block appendData:point];
        }
        ((uint8_t *)bytes.mutableBytes)[info->at] &= 0x7F;
        [bytes replaceBytesInRange:NSMakeRange(info->end, 0) withBytes:block.bytes length:block.length];
        return YES;
    }
    if (source.container == FuzzMPEG && source.audio.location > 8) {
        NSRange xing = FuzzXingRange(bytes, NSMakeRange(0, source.audio.location));
        if (xing.location == NSNotFound) return NO;
        uint32_t flags = (uint32_t)FuzzGet(bytes, xing.location + 4, 4, YES);
        NSUInteger at = xing.location + 8 + (flags & 1 ? 4 : 0);
        if (flags & 2) { FuzzPut(bytes, at, 4, YES, 0xFFFFFFFF); at += 4; }
        if (flags & 4) memset((uint8_t *)bytes.mutableBytes + MIN(at, bytes.length), 0xFF, MIN(100, bytes.length - MIN(at, bytes.length)));
        return (flags & 6) != 0;
    }
    if (source.container == FuzzMP4) {
        const FuzzChunk *stco = [source chunkTagged:"stco"] ?: [source chunkTagged:"co64"];
        if (!stco) return NO;
        uint8_t width = FuzzTagIs(stco, "co64") ? 8 : 4;
        uint64_t count = FuzzGet(bytes, stco->body + 4, 4, YES);
        for (uint64_t i = 0; i < count && stco->body + 8 + (i + 1) * width <= stco->body + stco->length; i++) {
            if (VibeFuzzBelow(random, 4) == 0) FuzzPut(bytes, stco->body + 8 + (NSUInteger)i * width, width, YES, past + i);
        }
        return YES;
    }
    return NO;
}

#pragma mark Named shapes: the dr_wav fixes (vibe-libs/third_party/dr_wav/AGENTS.md)

typedef NS_ENUM(NSUInteger, FuzzCOMM) { FuzzCOMM23, FuzzCOMMOdd, FuzzCOMMLong };

// Grows COMM to 23 bytes, an odd size or 8 bytes more, padded to even. The dr_wav fix reads COMM
// chunks of 23, odd or more than 18 bytes.
static BOOL FuzzCOMMSize(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    const FuzzChunk *comm = [source chunkTagged:"COMM"];
    if (source.container != FuzzFORM || !comm) return NO;
    uint32_t size = arg == FuzzCOMM23 ? 23 : arg == FuzzCOMMOdd ? (uint32_t)(comm->length | 1) + 2 : (uint32_t)comm->length + 8;
    if (comm->length > size) return NO;
    NSUInteger held = comm->body + (NSUInteger)comm->length, padded = comm->body + (NSUInteger)(comm->length + (comm->length & 1));
    NSUInteger grown = size + (size & 1) - (NSUInteger)comm->length;
    [bytes replaceBytesInRange:NSMakeRange(held, MIN(padded, bytes.length) - held) withBytes:[NSMutableData dataWithLength:grown].bytes length:grown];
    FuzzPut(bytes, comm->sizeAt, 4, YES, size);
    FuzzPut(bytes, 4, 4, YES, bytes.length - 8);
    return YES;
}

static BOOL FuzzCOMMCountPastData(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    const FuzzChunk *comm = [source chunkTagged:"COMM"];
    if (!comm) return NO;
    FuzzPut(bytes, comm->body + 2, 4, YES, (uint64_t)source.length * 2 + 1);
    return YES;
}

static BOOL FuzzDS64CountPastData(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    const FuzzChunk *ds64 = [source chunkTagged:"ds64"];
    if (!ds64) return NO;
    FuzzPut(bytes, ds64->body + 16, 8, NO, (uint64_t)source.length * 3 + 7);
    return YES;
}

static BOOL FuzzFactCountPastData(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    if (source.container != FuzzRIFF && source.container != FuzzRF64) return NO;
    const FuzzChunk *fact = [source chunkTagged:"fact"], *data = [source chunkTagged:"data"];
    uint64_t count = (uint64_t)source.length * 2 + 1;
    if (fact) {
        FuzzPut(bytes, fact->body, 4, NO, count);
        return YES;
    }
    if (!data) return NO;
    uint8_t chunk[12] = {'f', 'a', 'c', 't', 4, 0, 0, 0};
    memcpy(chunk + 8, &(uint32_t){CFSwapInt32HostToLittle((uint32_t)count)}, 4);
    [bytes replaceBytesInRange:NSMakeRange(data->at, 0) withBytes:chunk length:sizeof(chunk)];
    if (source.container == FuzzRIFF) FuzzPut(bytes, 4, 4, NO, bytes.length - 8);
    return YES;
}

// MS ADPCM's coefficient table: wNumCoef (`arg`) past the pairs the chunk holds, or none.
static BOOL FuzzMSADPCMTable(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    const FuzzChunk *fmt = [source chunkTagged:"fmt "];
    if (!fmt || fmt->length < 22 || FuzzGet(bytes, fmt->body, 2, NO) != 2) return NO;
    FuzzPut(bytes, fmt->body + 20, 2, NO, arg);
    return YES;
}

// The WAV data chunk's size set to `arg`.
static BOOL FuzzDataSize(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    const FuzzChunk *data = [source chunkTagged:"data"];
    if (source.container != FuzzRIFF || !data) return NO;
    FuzzPut(bytes, data->sizeAt, 4, NO, arg);
    return YES;
}

#pragma mark Named shapes: the MPEG open's own framing (AudioFileHandle+MPEG.m)

// The offsets of an MPEG file's frames that chain from past its ID3v2 tag, up to `capacity`. A
// free format or damaged header ends the chain. 0 for another container.
static NSUInteger FuzzMPEGFrameOffsets(NSData *bytes, FuzzSource *source, NSUInteger *offsets, NSUInteger capacity) {
    const uint8_t *b = bytes.bytes;
    NSUInteger n = 0;
    if (source.container != FuzzMPEG) return 0;
    for (NSUInteger at = VibeID3v2Length(bytes, 0), size; n < capacity && at + 4 <= bytes.length && (size = FuzzMPEGFrameBytes(b + at)); at += size) {
        offsets[n++] = at;
    }
    return n;
}

// The ID3v2 frame headers in the tag at the file's start, and its version.
static NSUInteger FuzzID3v2Frames(NSData *bytes, NSUInteger *offsets, NSUInteger capacity, uint8_t *version) {
    const uint8_t *b = bytes.bytes;
    NSUInteger end = MIN(VibeID3v2Length(bytes, 0), bytes.length), n = 0;
    if (end < 10) return 0;
    *version = b[3];
    NSUInteger header = *version == 2 ? 6 : 10;
    for (NSUInteger at = 10; n < capacity && at + header <= end && b[at];) {
        uint64_t size = *version == 2 ? FuzzGet(bytes, at + 3, 3, YES) : *version == 4
                ? (uint64_t)(b[at + 4] & 0x7F) << 21 | (b[at + 5] & 0x7F) << 14 | (b[at + 6] & 0x7F) << 7 | (b[at + 7] & 0x7F)
                : FuzzGet(bytes, at + 4, 4, YES);
        offsets[n++] = at;
        if (size > end - at - header) break;
        at += header + (NSUInteger)size;
    }
    return n;
}

// An ID3v2 frame's size set to a value that wraps, overruns the tag, or is random, in 32 bits as
// ID3v2.3 states it or syncsafe as ID3v2.4 does. With `arg`, the named shape: the first frame's
// size is 0xFFFFFFF6 in an ID3v2.3 tag, which with its 10-byte header wrapped a 32-bit cursor to
// where it stood.
static BOOL FuzzID3FrameSize(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    NSUInteger frames[64];
    uint8_t version = 0;
    NSUInteger n = source.container == FuzzMPEG ? FuzzID3v2Frames(bytes, frames, 64, &version) : 0;
    if (n == 0 || version == 2) return NO;
    if (arg) {
        ((uint8_t *)bytes.mutableBytes)[3] = 3;
        FuzzPut(bytes, frames[0] + 4, 4, YES, 0xFFFFFFF6);
        return YES;
    }
    // Weighted to sizes that wrap a 32-bit cursor, read as ID3v2.3 states them.
    uint32_t choices[] = {0xFFFFFFF6, 0xFFFFFFFF, 0xFFFFFFF6, 0, 1, 0x7FFFFFFF, (uint32_t)bytes.length, (uint32_t)VibeFuzzNext(random)};
    uint32_t size = choices[VibeFuzzBelow(random, 8)];
    ((uint8_t *)bytes.mutableBytes)[3] = VibeFuzzBelow(random, 4) ? 3 : 4;
    FuzzPut(bytes, frames[VibeFuzzBelow(random, n)] + 4, 4, YES, size);
    return YES;
}

// The tag's flags (unsynchronised, an extended header, a footer) and a frame's, and its version.
static BOOL FuzzID3Flags(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    NSUInteger frames[64];
    uint8_t version = 0;
    NSUInteger n = source.container == FuzzMPEG ? FuzzID3v2Frames(bytes, frames, 64, &version) : 0;
    if (n == 0) return NO;
    uint8_t *b = bytes.mutableBytes;
    static const uint8_t tagFlags[] = {0x80, 0x40, 0x10, 0xC0, 0xF0};
    b[5] ^= tagFlags[VibeFuzzBelow(random, 5)];
    if (VibeFuzzBelow(random, 2)) b[3] = (uint8_t)(2 + VibeFuzzBelow(random, 4));
    if (version >= 3) b[frames[VibeFuzzBelow(random, n)] + 9] ^= (uint8_t)(1 << VibeFuzzBelow(random, 8));
    return YES;
}

// An ID3v2.3 or 2.4 tag with an iTunSMPB comment put first: words extreme, random, missing or not
// hex, Latin-1 or UTF-16, the tag sometimes unsynchronised with an escaped 0xFF in a frame first.
static BOOL FuzzITunesComment(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    if (source.container != FuzzMPEG) return NO;
    static const char *words[] = {"00000000", "00000240", "FFFFFFFF", "7FFFFFFF", "0000000000017700", "FFFFFFFFFFFFFFFF", "zz", ""};
    NSMutableString *text = [NSMutableString string];
    for (NSUInteger i = 0, count = VibeFuzzBelow(random, 7); i < count; i++) {
        [text appendFormat:@" %s", VibeFuzzBelow(random, 3) ? words[VibeFuzzBelow(random, 8)] : [NSString stringWithFormat:@"%llX", VibeFuzzNext(random)].UTF8String];
    }
    BOOL wide = VibeFuzzBelow(random, 3) == 0;
    NSMutableData *body = [NSMutableData dataWithBytes:(uint8_t[]){wide ? 1 : 0, 'e', 'n', 'g'} length:4];
    NSStringEncoding encoding = wide ? NSUTF16StringEncoding : NSISOLatin1StringEncoding;
    [body appendData:[@"iTunSMPB" dataUsingEncoding:encoding]];
    [body appendBytes:"\0\0" length:wide ? 2 : 1];
    [body appendData:[text dataUsingEncoding:encoding] ?: NSData.data];
    if (VibeFuzzBelow(random, 4) == 0) body.length = VibeFuzzBelow(random, body.length + 1);
    uint8_t version = VibeFuzzBelow(random, 2) ? 3 : 4;
    BOOL unsynchronised = VibeFuzzBelow(random, 3) == 0;
    NSMutableData *frames = [NSMutableData data];
    if (unsynchronised && version == 3) {
        // 0xFF 0xE0 in a frame before the comment, written escaped: 0xFF 0x00 0xE0.
        [frames appendData:VibeID3v2Frame("PRIV", 3, 4, 0, [NSData dataWithBytes:"\xFF\x00\xE0\x01\x02" length:5])];
    }
    [frames appendData:VibeID3v2Frame("COMM", version, (uint32_t)body.length, 0, body)];
    NSData *prefix = VibeID3v2Tag(version, unsynchronised ? 0x80 : 0, frames);
    NSUInteger existing = VibeFuzzBelow(random, 2) ? VibeID3v2Length(bytes, 0) : 0;
    [bytes replaceBytesInRange:NSMakeRange(0, existing) withBytes:prefix.bytes length:prefix.length];
    return YES;
}

// The Xing or Info frame's fields: the count, the bytes, the flags, and the LAME tag's priming and
// remainder, each zero, at its maximum or random. Or its tag made a VBRI header with random counts.
static BOOL FuzzXingFields(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    if (source.container != FuzzMPEG) return NO;
    NSUInteger start = VibeID3v2Length(bytes, 0);
    NSRange xing = FuzzXingRange(bytes, NSMakeRange(start, 64));
    if (xing.location == NSNotFound || xing.location + 156 > bytes.length) return NO;
    uint32_t extremes[] = {0, 1, 2, 0x7FFFFFFF, 0xFFFFFFFF, (uint32_t)VibeFuzzNext(random)};
    if (arg) {
        // A VBRI header at 36 bytes into the frame, its byte and frame counts random.
        NSUInteger vbri = start + 36;
        uint8_t *b = bytes.mutableBytes;
        memcpy(b + vbri, "VBRI", 4);
        FuzzPut(bytes, vbri + 10, 4, YES, extremes[VibeFuzzBelow(random, 6)]);
        FuzzPut(bytes, vbri + 14, 4, YES, extremes[VibeFuzzBelow(random, 6)]);
        if (vbri != xing.location) memset(b + xing.location, 0, 4);
        return YES;
    }
    uint32_t flags = (uint32_t)FuzzGet(bytes, xing.location + 4, 4, YES);
    switch (VibeFuzzBelow(random, 4)) {
        case 0: FuzzPut(bytes, xing.location + 4, 4, YES, VibeFuzzBelow(random, 16)); break;
        case 1: if (flags & 1) FuzzPut(bytes, xing.location + 8, 4, YES, extremes[VibeFuzzBelow(random, 6)]); break;
        case 2: if (flags & 2) FuzzPut(bytes, xing.location + 8 + (flags & 1 ? 4 : 0), 4, YES, extremes[VibeFuzzBelow(random, 6)]); break;
        default: {
            NSUInteger lame = xing.location + 8 + (flags & 1 ? 4 : 0) + (flags & 2 ? 4 : 0) + (flags & 4 ? 100 : 0) + (flags & 8 ? 4 : 0);
            uint32_t delay = VibeFuzzBelow(random, 2) ? 0xFFF : (uint32_t)VibeFuzzBelow(random, 0x1000);
            uint32_t padding = VibeFuzzBelow(random, 2) ? 0xFFF : (uint32_t)VibeFuzzBelow(random, 0x1000);
            FuzzPut(bytes, lame + 21, 3, YES, delay << 12 | padding);
        }
    }
    return YES;
}

// Frame headers made free format (bit rate index 0), every one or some, or a frame's mode changed:
// mono, dual channel, stereo or joint stereo.
static BOOL FuzzFrameHeaders(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    NSUInteger offsets[4096];
    NSUInteger n = FuzzMPEGFrameOffsets(bytes, source, offsets, 4096);
    if (n < 2) return NO;
    uint8_t *b = bytes.mutableBytes;
    BOOL every = VibeFuzzBelow(random, 2);
    for (NSUInteger i = 0; i < n; i++) {
        if (!every && VibeFuzzBelow(random, 8)) continue;
        if (arg) b[offsets[i] + 3] = (uint8_t)((b[offsets[i] + 3] & 0x3F) | (VibeFuzzBelow(random, 4) << 6));
        else b[offsets[i] + 2] &= 0x0F;
    }
    return YES;
}

// Junk between two frames: random bytes, a false sync, or a run of zeros.
static BOOL FuzzJunkBetweenFrames(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    NSUInteger offsets[4096];
    NSUInteger n = FuzzMPEGFrameOffsets(bytes, source, offsets, 4096);
    if (n < 2) return NO;
    NSMutableData *junk = [NSMutableData dataWithLength:1 + VibeFuzzBelow(random, 2048)];
    uint8_t *j = junk.mutableBytes;
    switch (VibeFuzzBelow(random, 3)) {
        case 0: for (NSUInteger i = 0; i < junk.length; i++) j[i] = (uint8_t)VibeFuzzNext(random); break;
        case 1: for (NSUInteger i = 0; i + 4 <= junk.length; i += 4) memcpy(j + i, (uint8_t[]){0xFF, 0xFB, 0x90, 0x64}, 4); break;
        default: break;
    }
    [bytes replaceBytesInRange:NSMakeRange(offsets[1 + VibeFuzzBelow(random, n - 1)], 0) withBytes:j length:junk.length];
    return YES;
}

// A tag that ends a file, ID3v1, APE, Lyrics3 or ID3v2, at the end, between two of the last frames,
// or over the last frame's end, with a damaged frame before it or not.
static BOOL FuzzTrailingTag(NSMutableData *bytes, FuzzSource *source, VibeFuzzRandom *random, NSUInteger arg) {
    NSUInteger offsets[4096];
    NSUInteger n = FuzzMPEGFrameOffsets(bytes, source, offsets, 4096);
    if (n < 4) return NO;
    static const char *tags[] = {"TAG", "APETAGEX", "LYRICSBEGIN", "ID3\x04"};
    const char *name = tags[VibeFuzzBelow(random, 4)];
    NSMutableData *tag = [NSMutableData dataWithBytes:name length:strlen(name)];
    tag.length = MAX(tag.length, (NSUInteger)128);
    NSUInteger at = bytes.length;
    switch (VibeFuzzBelow(random, 3)) {
        case 0: at = offsets[n - 1 - VibeFuzzBelow(random, 3)]; break;
        case 1: at = offsets[n - 1] + VibeFuzzBelow(random, bytes.length - offsets[n - 1]); break;
        default: break;
    }
    if (VibeFuzzBelow(random, 2)) ((uint8_t *)bytes.mutableBytes)[offsets[n - 4 + VibeFuzzBelow(random, 3)]] = 0;
    [bytes replaceBytesInRange:NSMakeRange(at, 0) withBytes:tag.bytes length:tag.length];
    return YES;
}

// What a named shape must deliver besides what every mutant must.
typedef NS_ENUM(NSUInteger, FuzzExpect) {
    FuzzExpectNothingMore,
    FuzzExpectNoLongerThanSource,     // a count past the data is never trusted
    FuzzExpectSourceDecode,           // a legal shape: dr_wav opens it and decodes what the source holds
    FuzzExpectNotDrWAV,               // dr_wav refuses it, so Apple's decoder or nothing has it
    FuzzExpectDrMP3,                  // still a stream dr_mp3 opens, under its choice
};

typedef struct {
    const char *name;
    FuzzMutate mutate;
    NSUInteger arg;
    BOOL named;
    FuzzExpect expect;
} FuzzMutator;

static const FuzzMutator kFuzzMutators[] = {
    {"truncate-header", FuzzTruncateHeader, 0, NO, FuzzExpectNothingMore},
    {"truncate-frames", FuzzTruncateFrames, 0, NO, FuzzExpectNothingMore},
    {"flip-header", FuzzFlipHeader, 0, NO, FuzzExpectNothingMore},
    {"flip-size-field", FuzzFlipSizeField, 0, NO, FuzzExpectNothingMore},
    {"flip-frames", FuzzFlipFrames, 0, NO, FuzzExpectNothingMore},
    {"size-zero", FuzzSetSize, FuzzSizeZero, NO, FuzzExpectNothingMore},
    {"size-max", FuzzSetSize, FuzzSizeMax, NO, FuzzExpectNothingMore},
    {"size-past-end", FuzzSetSize, FuzzSizePastEnd, NO, FuzzExpectNothingMore},
    {"size-odd", FuzzSetSize, FuzzSizeOdd, NO, FuzzExpectNothingMore},
    {"duplicate-chunk", FuzzDuplicateChunk, 0, NO, FuzzExpectNothingMore},
    {"reorder-chunks", FuzzReorderChunks, 0, NO, FuzzExpectNothingMore},
    {"extreme-rate", FuzzExtremeFact, YES, NO, FuzzExpectNothingMore},
    {"extreme-count", FuzzExtremeFact, NO, NO, FuzzExpectNothingMore},
    {"sync-mid-frame", FuzzSyncMidFrame, 0, NO, FuzzExpectNothingMore},
    {"seek-table-past-end", FuzzSeekTablePastEnd, 0, NO, FuzzExpectNothingMore},
    {"aiff-comm-23-bytes", FuzzCOMMSize, FuzzCOMM23, YES, FuzzExpectSourceDecode},
    {"aiff-comm-odd-size", FuzzCOMMSize, FuzzCOMMOdd, YES, FuzzExpectSourceDecode},
    {"aiff-comm-longer-than-18", FuzzCOMMSize, FuzzCOMMLong, YES, FuzzExpectSourceDecode},
    {"aiff-comm-count-past-data", FuzzCOMMCountPastData, 0, YES, FuzzExpectNoLongerThanSource},
    {"rf64-ds64-count-past-data", FuzzDS64CountPastData, 0, YES, FuzzExpectNoLongerThanSource},
    {"wav-fact-count-past-data", FuzzFactCountPastData, 0, YES, FuzzExpectNoLongerThanSource},
    {"ms-adpcm-table-cut-short", FuzzMSADPCMTable, 200, YES, FuzzExpectNotDrWAV},
    {"ms-adpcm-table-of-no-pairs", FuzzMSADPCMTable, 0, YES, FuzzExpectNotDrWAV},
    {"wav-data-size-zero", FuzzDataSize, 0, YES, FuzzExpectNothingMore},
    {"wav-data-size-0xffffffff", FuzzDataSize, 0xFFFFFFFF, YES, FuzzExpectSourceDecode},
    {"id3-frame-size", FuzzID3FrameSize, 0, NO, FuzzExpectNothingMore},
    {"id3-frame-size-wraps", FuzzID3FrameSize, 1, YES, FuzzExpectNothingMore},
    {"id3-flags", FuzzID3Flags, 0, NO, FuzzExpectNothingMore},
    {"itunes-comment", FuzzITunesComment, 0, NO, FuzzExpectDrMP3},
    {"xing-fields", FuzzXingFields, 0, NO, FuzzExpectDrMP3},
    {"vbri-header", FuzzXingFields, 1, NO, FuzzExpectNothingMore},
    {"free-format", FuzzFrameHeaders, 0, NO, FuzzExpectNothingMore},
    {"mode-change", FuzzFrameHeaders, 1, NO, FuzzExpectDrMP3},
    {"junk-between-frames", FuzzJunkBetweenFrames, 0, NO, FuzzExpectDrMP3},
    {"trailing-tag", FuzzTrailingTag, 0, NO, FuzzExpectDrMP3},
};

#pragma mark - Decoding

// One file and what it delivered. Problems are collected, never asserted, so a decode can run off
// the test thread. A mutant also carries its bytes, its mutator and its seed.
@interface FuzzDecode : NSObject
@property (nonatomic, strong) NSData *bytes;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSUInteger mutator;
@property (nonatomic) uint64_t seed;
@property (atomic) BOOL finished;
@property (nonatomic) BOOL opened;
@property (nonatomic, copy) NSString *decoder;
@property (nonatomic) AVAudioFramePosition length;
@property (nonatomic) BOOL estimated;
@property (nonatomic, strong) NSMutableData *pcm;        // every frame read to the end, interleaved, when captured
@property (nonatomic, strong) NSMutableData *seekReads;  // what each seek's read delivered, in order, when captured
@property (nonatomic, strong) NSMutableArray<NSString *> *problems;
@end
@implementation FuzzDecode
@end

static double FuzzThreadCPU(void) {
    return (double)clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) / 1e9;
}

// Integer codings decode to [-1, 1). Float PCM may hold anything, NaN included.
static BOOL FuzzIntegerCoding(const AudioStreamBasicDescription *file, NSString *decoder) {
    if (file->mFormatID == kAudioFormatLinearPCM) return !(file->mFormatFlags & kAudioFormatFlagIsFloat);
    if ([decoder isEqualToString:@"apple"] && (file->mFormatID == kAudioFormatMPEGLayer1 || file->mFormatID == kAudioFormatMPEGLayer2
                                               || file->mFormatID == kAudioFormatMPEGLayer3)) return YES; // Apple's clips at full scale
    UInt32 integer[] = {kAudioFormatFLAC, kAudioFormatAppleLossless, kAudioFormatULaw, kAudioFormatALaw, kAudioFormatAppleIMA4, 0x6D730002, 0x6D730011};
    for (size_t i = 0; i < sizeof(integer) / sizeof(*integer); i++) if (file->mFormatID == integer[i]) return YES;
    return NO;
}

static void FuzzCheckSamples(AVAudioPCMBuffer *buffer, AudioFileHandle *handle, NSString *what, NSMutableArray<NSString *> *problems) {
    const AudioStreamBasicDescription *file = handle.fileFormat.streamDescription;
    BOOL floatPCM = file->mFormatID == kAudioFormatLinearPCM && (file->mFormatFlags & kAudioFormatFlagIsFloat);
    if (floatPCM || buffer.frameLength == 0) return;
    float bound = FuzzIntegerCoding(file, handle.decoderName) ? 1.0f + FLT_EPSILON
                : [handle.decoderName isEqualToString:@"dr_mp3"] ? 4.0f : INFINITY; // kVibeDecodeSampleBound
    NSUInteger channels = buffer.format.channelCount, planes = buffer.format.isInterleaved ? 1 : channels;
    NSUInteger perPlane = buffer.format.isInterleaved ? buffer.frameLength * channels : buffer.frameLength;
    for (NSUInteger p = 0; p < planes; p++) {
        const float *x = buffer.floatChannelData[p];
        for (NSUInteger i = 0; i < perPlane; i++) {
            if (!isfinite(x[i]) || fabsf(x[i]) > bound) {
                [problems addObject:[NSString stringWithFormat:@"%@: sample %g at %lu outside %g", what, x[i], (unsigned long)i, bound]];
                return;
            }
        }
    }
}

// One timed read; NO when it failed or reached the end.
static BOOL FuzzRead(AudioFileHandle *handle, AVAudioPCMBuffer *buffer, AVAudioFrameCount frames, NSString *what, NSMutableArray<NSString *> *problems) {
    NSError *error = nil;
    double started = FuzzThreadCPU();
    BOOL read = [handle readIntoBuffer:buffer frameCount:frames error:&error];
    double cpu = FuzzThreadCPU() - started;
    if (cpu > kFuzzCallCPUSeconds) [problems addObject:[NSString stringWithFormat:@"%@: a read took %.2f s of CPU", what, cpu]];
    if (!read && !error) [problems addObject:[NSString stringWithFormat:@"%@: a failed read set no error", what]];
    if (!read) buffer.frameLength = 0;
    FuzzCheckSamples(buffer, handle, what, problems);
    return read && buffer.frameLength > 0;
}

// Open, facts, decode to the end within `budget` frames, then seeks across the file, each read back.
// The samples are kept when `capture` asks for them. dr_wav and dr_flac keep them for the seek checks
// and drop them after unless asked.
static void FuzzDecodeURL(FuzzDecode *result, NSURL *url, AVAudioFramePosition budget, BOOL capture) {
    result.pcm = [NSMutableData data];
    result.seekReads = [NSMutableData data];
    result.problems = [NSMutableArray array];
    NSMutableArray<NSString *> *problems = result.problems;
    @try {
        NSError *error = nil;
        double started = FuzzThreadCPU();
        AudioFileHandle *handle = [[AudioFileHandle alloc] initForReading:url error:&error];
        double cpu = FuzzThreadCPU() - started;
        if (cpu > kFuzzCallCPUSeconds) [problems addObject:[NSString stringWithFormat:@"the open took %.2f s of CPU", cpu]];
        if (!handle) {
            if (!error) [problems addObject:@"a refused open set no error"];
            return;
        }
        result.opened = YES;
        result.decoder = handle.decoderName;
        // Apple's decoders read every packet their parser serves, past a damaged count, and can deliver
        // more after an end or a seek than a decode from the start did. A length of 0 is refused before
        // anything plays, and the bus stops at the length, so those are checked only of Vibe's decoders.
        BOOL ours = ![result.decoder isEqualToString:@"apple"];
        // dr_wav's and dr_flac's seeks land on the samples a decode from the start holds there, damaged or not.
        BOOL exact = [result.decoder isEqualToString:@"dr_wav"] || [result.decoder isEqualToString:@"dr_flac"];
        BOOL keep = capture || exact;
        BOOL estimated = NO;
        result.length = [handle lengthEstimated:&estimated];
        result.estimated = estimated;
        if (result.length < 0) [problems addObject:[NSString stringWithFormat:@"length %lld", result.length]];
        AVAudioFormat *format = handle.processingFormat;
        NSUInteger channels = format.channelCount;
        if (channels == 0 || !(format.sampleRate > 0) || !isfinite(format.sampleRate)) {
            [problems addObject:[NSString stringWithFormat:@"processing format %@", format]];
            return;
        }
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:kFuzzChunkFrames];
        AVAudioFramePosition delivered = 0;
        while (delivered < budget && FuzzRead(handle, buffer, kFuzzChunkFrames, @"decode", problems)) {
            if (keep) VibeAppendPCM(result.pcm, buffer);
            delivered += buffer.frameLength;
        }
        if (ours && delivered < budget && [handle readIntoBuffer:buffer error:NULL] && buffer.frameLength > 0) {
            [problems addObject:[NSString stringWithFormat:@"%u frames read past the end at %lld", buffer.frameLength, delivered]];
        }
        AVAudioFramePosition length = [handle lengthEstimated:&estimated];
        if (ours && !estimated && length > 0 && delivered > length) {
            [problems addObject:[NSString stringWithFormat:@"delivered %lld frames past its length of %lld", delivered, length]];
        }
        AVAudioFramePosition reach = MAX(length, delivered);
        // A damaged count can make a length near INT64_MAX, so the target past it saturates.
        AVAudioFramePosition targets[] = {0, 1, delivered / 3, delivered / 2, delivered - 1, delivered, delivered + 4096,
                                          length < INT64_MAX ? length + 1 : length, delivered * 7 / 11};
        for (size_t i = 0; i < sizeof(targets) / sizeof(*targets); i++) {
            AVAudioFramePosition target = MAX(0, targets[i]);
            NSString *what = [NSString stringWithFormat:@"seek to %lld", target];
            error = nil;
            started = FuzzThreadCPU();
            BOOL landed = [handle seekToFrame:target error:&error];
            cpu = FuzzThreadCPU() - started;
            if (cpu > kFuzzCallCPUSeconds) [problems addObject:[NSString stringWithFormat:@"%@ took %.2f s of CPU", what, cpu]];
            if (!landed) {
                if (!error) [problems addObject:[what stringByAppendingString:@": refused with no error"]];
                continue;
            }
            AVAudioFramePosition at = handle.framePosition;
            if (target <= delivered && at != target) {
                [problems addObject:[NSString stringWithFormat:@"%@ landed at %lld", what, at]];
                continue;
            }
            AVAudioFramePosition read = 0;
            NSMutableData *slice = [NSMutableData data];
            while (read < 2 * kFuzzChunkFrames && FuzzRead(handle, buffer, kFuzzChunkFrames, what, problems)) {
                if (keep) VibeAppendPCM(slice, buffer);
                read += buffer.frameLength;
            }
            if (ours && read > 0 && (at > reach || read > reach - at)) [problems addObject:[NSString stringWithFormat:@"%@: read %lld frames from %lld, past %lld", what, read, at, reach]];
            if (exact && at < delivered) {
                NSUInteger frames = (NSUInteger)MIN(read, delivered - at), bytes = frames * channels * sizeof(float);
                if (![[slice subdataWithRange:NSMakeRange(0, bytes)] isEqualToData:
                       [result.pcm subdataWithRange:NSMakeRange((NSUInteger)at * channels * sizeof(float), bytes)]]) {
                    [problems addObject:[what stringByAppendingString:@": reads other samples than the decode from the start"]];
                }
            }
            if (capture) [result.seekReads appendData:slice];
        }
        if (!capture) result.pcm = nil;
    } @catch (NSException *exception) {
        [problems addObject:[NSString stringWithFormat:@"exception %@: %@", exception.name, exception.reason]];
    }
}

#pragma mark - Tests

// The fuzz of one decoder family. It runs no tests itself. Each family is a subclass below, so the
// parallel runner spreads them across processes.
@interface AudioFileHandleFuzzTestCase : XCTestCase
@end

@implementation AudioFileHandleFuzzTestCase {
    NSURL *_root;
    uint64_t _baseSeed;
    NSUInteger _multiplier;
    NSUInteger _attachments;
    NSString *_export;
}

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = YES;
    _baseSeed = VibeFuzzBaseSeed(0xF022DEC0DE5EED01ULL);
    _multiplier = MAX(1, NSProcessInfo.processInfo.environment[@"VIBE_FUZZ_ITERATIONS"].integerValue);
    _export = NSProcessInfo.processInfo.environment[@"VIBE_FUZZ_EXPORT"];
    _root = [FuzzScratch() URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_root withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:_root error:NULL];
    [super tearDown];
}

// The decode on a worker, under the hang guard. nil when it never returned.
- (FuzzDecode *)decode:(NSURL *)url budget:(AVAudioFramePosition)budget {
    FuzzDecode *result = [FuzzDecode new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FuzzDecodeURL(result, url, budget, YES);
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) != 0) {
        return nil;
    }
    return result;
}

// Every mutant across the cores, each from its own file. NO when none finished within the hang
// guard. The ones still unfinished then are the hung ones.
- (BOOL)decodeMutants:(NSArray<FuzzDecode *> *)mutants budget:(AVAudioFramePosition)budget {
    NSURL *root = _root;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        dispatch_apply(mutants.count, DISPATCH_APPLY_AUTO, ^(size_t k) {
            FuzzDecode *mutant = mutants[k];
            NSURL *url = [root URLByAppendingPathComponent:mutant.name];
            [mutant.bytes writeToURL:url atomically:NO];
            FuzzDecodeURL(mutant, url, budget, kFuzzMutators[mutant.mutator].expect == FuzzExpectSourceDecode);
            [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
            mutant.finished = YES;
            dispatch_semaphore_signal(finished);
        });
    });
    for (NSUInteger k = 0; k < mutants.count; k++) {
        if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))) != 0) {
            return NO;
        }
    }
    return YES;
}

- (void)attach:(NSData *)bytes name:(NSString *)name {
    if (_attachments++ >= 24) return;
    XCTAttachment *attachment = [XCTAttachment attachmentWithData:bytes];
    attachment.name = name;
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
}

- (void)fuzzSource:(FuzzSource *)source {
    NSString *label = source.name;
    NSURL *originalURL = [_root URLByAppendingPathComponent:[@"original." stringByAppendingString:source.extension]];
    XCTAssertTrue([source.bytes writeToURL:originalURL atomically:NO]);
    FuzzDecode *reference = [self decode:originalURL budget:kFuzzMaxSourceFrames];
    XCTAssertNotNil(reference, @"%@: the source hung", label);
    XCTAssertTrue(reference.opened, @"%@: the source does not open", label);
    XCTAssertEqual(reference.problems.count, 0u, @"%@: the source: %@", label, reference.problems);
    if (!reference.opened) return;
    // Twice the source's samples, which bounds its frames from above.
    AVAudioFramePosition budget = MAX(2 * (AVAudioFramePosition)(reference.pcm.length / sizeof(float)), 1 << 16);
    uint64_t sourceHash = 0;
    for (const char *c = source.name.UTF8String; *c; c++) sourceHash = sourceHash * 131 + (uint8_t)*c;

    // Every mutant is made here, in order, and decoded after.
    NSMutableArray<FuzzDecode *> *mutants = [NSMutableArray array];
    for (NSUInteger m = 0; m < sizeof(kFuzzMutators) / sizeof(*kFuzzMutators); m++) {
        FuzzMutator mutator = kFuzzMutators[m];
        NSUInteger iterations = mutator.named ? 1 : kFuzzIterations[source.family] * _multiplier;
        for (NSUInteger i = 0; i < iterations; i++) {
            uint64_t seed = _baseSeed ^ sourceHash ^ ((uint64_t)m << 40) ^ ((uint64_t)i << 20);
            VibeFuzzRandom random = {seed | 1};
            NSMutableData *bytes = [source.bytes mutableCopy];
            // NO: the shape does not apply to this container.
            if (!mutator.mutate(bytes, source, &random, mutator.arg)) break;
            if ([bytes isEqualToData:source.bytes]) continue;
            if (_export) {
                NSString *name = [NSString stringWithFormat:@"%@-%s-%016llx.%@", source.name.stringByDeletingPathExtension, mutator.name, seed, source.extension];
                [bytes writeToFile:[_export stringByAppendingPathComponent:name] atomically:NO];
            }
            FuzzDecode *mutant = [FuzzDecode new];
            mutant.bytes = bytes;
            mutant.name = [NSString stringWithFormat:@"%s-%lu.%@", mutator.name, (unsigned long)i, source.extension];
            mutant.mutator = m;
            mutant.seed = seed;
            [mutants addObject:mutant];
        }
    }
    BOOL returned = [self decodeMutants:mutants budget:budget];
    for (FuzzDecode *mutant in mutants) {
        FuzzMutator mutator = kFuzzMutators[mutant.mutator];
        NSString *context = [NSString stringWithFormat:@"%@, %s, seed 0x%016llx", label, mutator.name, mutant.seed];
        NSString *attachment = [source.name stringByAppendingFormat:@"-%@", mutant.name];
        if (!mutant.finished) {
            XCTFail(@"%@: hung past %d s", context, VIBE_TEST_HANG_TIMEOUT);
            [self attach:mutant.bytes name:attachment];
            continue;
        }
        NSMutableArray<NSString *> *problems = mutant.problems;
        if (mutant.opened && mutator.expect == FuzzExpectNoLongerThanSource && !mutant.estimated && mutant.length > source.heldFrames) {
            [problems addObject:[NSString stringWithFormat:@"length %lld past the %lld frames the data holds", mutant.length, source.heldFrames]];
        }
        if (mutator.expect == FuzzExpectSourceDecode && [reference.decoder isEqualToString:@"dr_wav"]) {
            // The claim is dr_wav's. A refusal or a handoff is the fix regressing, not a clean answer.
            if (!mutant.opened) {
                [problems addObject:@"dr_wav refused a legal shape"];
            }
            else if (![mutant.decoder isEqualToString:@"dr_wav"]) {
                [problems addObject:[NSString stringWithFormat:@"dr_wav handed a legal shape to %@", mutant.decoder]];
            }
            else if (![mutant.pcm isEqualToData:reference.pcm]) {
                [problems addObject:@"decodes other samples than the source"];
            }
        }
        if (mutant.opened && mutator.expect == FuzzExpectNotDrWAV && [mutant.decoder isEqualToString:@"dr_wav"]) {
            [problems addObject:@"dr_wav accepted it"];
        }
        if (mutator.expect == FuzzExpectDrMP3 && [reference.decoder isEqualToString:@"dr_mp3"]
                && ![mutant.decoder isEqualToString:@"dr_mp3"]) {
            [problems addObject:[NSString stringWithFormat:@"dr_mp3 handed a playable stream to %@", mutant.decoder ?: @"nothing"]];
        }
        if (problems.count) {
            XCTFail(@"%@ (%@): %@", context, mutant.decoder ?: @"refused", problems);
            [self attach:mutant.bytes name:attachment];
        }
    }
    if (!returned) return; // a worker still holds its file; nothing after it can be trusted
    FuzzDecode *again = [self decode:originalURL budget:kFuzzMaxSourceFrames];
    XCTAssertNotNil(again, @"%@: the source hung after its mutants", label);
    XCTAssertEqualObjects(again.pcm, reference.pcm, @"%@: the source decodes differently after its mutants", label);
    XCTAssertEqualObjects(again.seekReads, reference.seekReads, @"%@: the source seeks differently after its mutants", label);
}

- (void)fuzzFamily:(FuzzFamily)family {
    NSMutableArray<NSString *> *skipped = [NSMutableArray array];
    NSArray<FuzzSource *> *sources = FuzzCorpus(family, _root, skipped);
    XCTSkipIf(sources.count == 0, @"No fixtures of this family; run make test-audio (skipped: %@)", skipped);
    for (FuzzSource *source in sources) {
        [self fuzzSource:source];
    }
}

@end

@interface AudioFileHandleFuzzDrWAVTests : AudioFileHandleFuzzTestCase
@end
@implementation AudioFileHandleFuzzDrWAVTests
- (void)testMutants { [self fuzzFamily:FuzzFamilyWAV]; }
@end

@interface AudioFileHandleFuzzDrFLACTests : AudioFileHandleFuzzTestCase
@end
@implementation AudioFileHandleFuzzDrFLACTests
- (void)testMutants { [self fuzzFamily:FuzzFamilyFLAC]; }
@end

@interface AudioFileHandleFuzzMPEGTests : AudioFileHandleFuzzTestCase
@end
@implementation AudioFileHandleFuzzMPEGTests
- (void)testMutants { [self fuzzFamily:FuzzFamilyMPEG]; }
@end

@interface AudioFileHandleFuzzCoreAudioTests : AudioFileHandleFuzzTestCase
@end
@implementation AudioFileHandleFuzzCoreAudioTests
- (void)testMutants { [self fuzzFamily:FuzzFamilyApple]; }
@end
