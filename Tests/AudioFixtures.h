//
//  AudioFixtures.h
//  VibeTests, VibeAudioTests
//
//  The two fixture writers every test file shares. VibeWriteWAV lays the
//  bytes down itself, so a fixture read back through AudioFileHandle is not
//  the handle's own work; VibeWriteFixture goes through the handle's writing
//  side for what a bare RIFF cannot carry — a channel layout, or a codec.
//  Header-only so both test targets pick it up by import.
//

#import <AVFoundation/AVFoundation.h>

#import "AudioFileHandle.h"

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

// Append complete channel frames without sharing any production DSP/oracle logic.
static inline void VibeAppendPCM(NSMutableData *capture, AVAudioPCMBuffer *buffer) {
    NSUInteger channels = buffer.format.channelCount;
    NSUInteger start = capture.length;
    [capture increaseLengthBy:buffer.frameLength * channels * sizeof(float)];
    float *out = (float *)((uint8_t *)capture.mutableBytes + start);
    for (NSUInteger frame = 0; frame < buffer.frameLength; frame++)
        for (NSUInteger channel = 0; channel < channels; channel++)
            out[frame * channels + channel] = buffer.floatChannelData[channel][frame];
}
