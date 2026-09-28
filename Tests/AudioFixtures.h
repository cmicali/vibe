//
//  AudioFixtures.h
//  VibeTests, VibeAudioTests
//
//  Fixture writers shared by both test targets. VibeWriteWAV writes the bytes
//  itself, so reading a fixture back through AudioFileHandle never makes the
//  handle its own oracle; VibeWriteFixture uses the handle's writer for what a
//  bare RIFF cannot carry — a channel layout, or a codec. VibeReferenceResample
//  is the one reference conversion.
//

#import <AVFoundation/AVFoundation.h>

#import "AudioFileHandle.h"
#import "AudioResampler.h"

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

// Writes `buffer` as the container its name says — WAV, or AIFC for .aif —
// in the buffer's own sample format, interleaved, with its channel layout.
static inline NSURL *VibeWriteFixture(NSURL *url, AVAudioPCMBuffer *buffer, NSError **error) {
    AVAudioFormat *format = buffer.format;
    BOOL aiff = [url.pathExtension.lowercaseString hasPrefix:@"aif"];
    AudioStreamBasicDescription file = *format.streamDescription;
    file.mFormatFlags = (file.mFormatFlags & ~(UInt32)kAudioFormatFlagIsNonInterleaved) | (aiff ? kAudioFormatFlagIsBigEndian : 0);
    file.mBytesPerFrame = file.mBitsPerChannel / 8 * file.mChannelsPerFrame;
    file.mBytesPerPacket = file.mBytesPerFrame;
    AVAudioFormat *fileFormat = [[AVAudioFormat alloc] initWithStreamDescription:&file channelLayout:format.channelLayout];
    AudioFileHandle *handle = [[AudioFileHandle alloc] initForWriting:url fileType:aiff ? kAudioFileAIFCType : kAudioFileWAVEType
                                                           fileFormat:fileFormat processingFormat:format error:error];
    if (![handle writeFromBuffer:buffer error:error] || ![handle closeWithError:error]) {
        return nil;
    }
    return url;
}

// Appends whole interleaved frames; shares no production DSP, so a capture stays independent.
static inline void VibeAppendPCM(NSMutableData *capture, AVAudioPCMBuffer *buffer) {
    NSUInteger channels = buffer.format.channelCount;
    NSUInteger start = capture.length;
    [capture increaseLengthBy:buffer.frameLength * channels * sizeof(float)];
    float *out = (float *)((uint8_t *)capture.mutableBytes + start);
    for (NSUInteger frame = 0; frame < buffer.frameLength; frame++)
        for (NSUInteger channel = 0; channel < channels; channel++)
            out[frame * channels + channel] = buffer.floatChannelData[channel][frame];
}

typedef struct {
    __unsafe_unretained AVAudioPCMBuffer *source;
    AVAudioFrameCount next;
} VibeReferenceFeed;

static inline OSStatus VibeReferenceSupply(AudioConverterRef converter, UInt32 *ioPackets, AudioBufferList *ioData,
                                           AudioStreamPacketDescription **descriptions, void *userData) {
    static float silence[4096];
    VibeReferenceFeed *feed = (VibeReferenceFeed *)userData;
    AVAudioFrameCount left = feed->source.frameLength - feed->next;
    UInt32 count = MIN(*ioPackets, 4096u);
    if (left > 0) {
        count = MIN(count, left);
    }
    for (UInt32 c = 0; c < ioData->mNumberBuffers; c++) {
        float *from = left > 0 ? feed->source.floatChannelData[c] + feed->next : silence;
        ioData->mBuffers[c] = (AudioBuffer){ 1, count * (UInt32)sizeof(float), from };
    }
    feed->next += left > 0 ? count : 0;
    *ioPackets = count;
    return noErr;
}

// The whole float32 non-interleaved `source` at `rate`: the resampler itself,
// off the bus — no file handle, decoder, ring, render or stream-end logic —
// fed 4096 frames at a time, its tail pushed out with silence and cut at
// round(N × ratio), as the bus's flush does. nil when it cannot convert.
static inline AVAudioPCMBuffer *VibeReferenceResample(AVAudioPCMBuffer *source, double rate) {
    AVAudioChannelCount channels = source.format.channelCount;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
    AVAudioFrameCount length = (AVAudioFrameCount)llround((double)source.frameLength * rate / source.format.sampleRate);
    AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:MAX(length, 1u)];
    VibeConverter *converter = VibeConverterCreate(source.format.streamDescription, format.streamDescription);
    if (!out || !converter) {
        return nil;
    }
    AudioBufferList *list = (AudioBufferList *)calloc(1, offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer));
    list->mNumberBuffers = channels;
    VibeReferenceFeed feed = { source, 0 };
    AVAudioFrameCount made = 0;
    while (made < length) {
        UInt32 frames = MIN(length - made, 4096u);
        for (AVAudioChannelCount c = 0; c < channels; c++) {
            list->mBuffers[c] = (AudioBuffer){ 1, frames * (UInt32)sizeof(float), out.floatChannelData[c] + made };
        }
        if (VibeConverterFill(converter, VibeReferenceSupply, &feed, &frames, list) != noErr || frames == 0) {
            break;
        }
        made += frames;
    }
    free(list);
    VibeConverterDispose(converter);
    out.frameLength = made;
    return made == length ? out : nil;
}
