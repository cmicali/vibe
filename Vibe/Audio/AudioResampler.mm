//
//  AudioResampler.mm
//  Vibe
//

#import "AudioResampler.h"
#define R8BSRC_DECL
#include "r8brain/DLL/r8bsrc.h"
#import <Accelerate/Accelerate.h>
#include <new>
#include <vector>

// The bus's decode chunk: the most one proc call answers.
static const int kVibeMaxInput = 4096;
// The 24-bit preset (180 dB stopband) with a 1% transition band, half
// upstream's default: −0.1 dB at 21.72 kHz from 44.1, level with Apple's
// Mastering filter, for about 20% more of a cost that is a twentieth of
// Apple's (docs/future/resampler.md).
static const double kVibeR8TransitionBand = 1.0;

struct VibeConverter {
    VibeResampler resampler;
    AudioConverterRef apple = NULL;
    // r8brain: one per channel, identically configured, so every channel
    // produces the same count per call.
    std::vector<CR8BResampler> channels;
    std::vector<double> widened;   // one channel's input
    // Each channel's last output, r8brain's own buffer: valid until that
    // channel's next process call, so it is handed out before the next pull.
    std::vector<double *> produced;
    size_t producedStart = 0;
    size_t producedCount = 0;
    std::vector<uint8_t> inputList; // the AudioBufferList the proc points at its data

    ~VibeConverter() {
        if (apple) {
            AudioConverterDispose(apple);
        }
        for (CR8BResampler channel : channels) {
            r8b_delete(channel);
        }
    }
};

// The resampler complexity as read back; nil where the read fails (iOS).
static NSString *VibeAppleAlgorithm(AudioConverterRef converter) {
    UInt32 complexity = 0, size = sizeof(complexity);
    if (AudioConverterGetProperty(converter, kAudioConverterSampleRateConverterComplexity, &size, &complexity) != noErr) {
        return nil;
    }
    switch (complexity) {
        case kAudioConverterSampleRateConverterComplexity_Mastering: return @"Mastering";
        case kAudioConverterSampleRateConverterComplexity_Normal: return @"Normal";
        case kAudioConverterSampleRateConverterComplexity_MinimumPhase: return @"Minimum Phase";
        case kAudioConverterSampleRateConverterComplexity_Linear: return @"Linear";
    }
    return [NSString stringWithFormat:@"%08x", (unsigned)complexity];
}

static UInt32 VibeAppleQuality(AudioConverterRef converter) {
    UInt32 quality = 0, size = sizeof(quality);
    return AudioConverterGetProperty(converter, kAudioConverterSampleRateConverterQuality, &size, &quality) == noErr ? quality : 0;
}

// Mastering complexity at maximum quality. The read-back is the check: macOS
// reports the complexity it took, iOS reports none (its resampler has no
// selectable complexity) and runs at the quality alone.
static BOOL VibeMakeApple(VibeConverter *converter, const AudioStreamBasicDescription *from,
                          const AudioStreamBasicDescription *to) {
    if (AudioConverterNew(from, to, &converter->apple) != noErr || !converter->apple) {
        converter->apple = NULL;
        return NO;
    }
    UInt32 quality = kAudioConverterQuality_Max, complexity = kAudioConverterSampleRateConverterComplexity_Mastering;
    AudioConverterSetProperty(converter->apple, kAudioConverterSampleRateConverterQuality, sizeof(quality), &quality);
    AudioConverterSetProperty(converter->apple, kAudioConverterSampleRateConverterComplexity, sizeof(complexity), &complexity);
    NSString *algorithm = VibeAppleAlgorithm(converter->apple);
    UInt32 took = VibeAppleQuality(converter->apple);
    if ((algorithm && ![algorithm isEqualToString:@"Mastering"]) || took != quality) {
        LogWarn(@"AudioResampler: Apple's converter runs %@ at quality %u, not mastering at quality %u",
                algorithm, (unsigned)took, (unsigned)quality);
    }
    return YES;
}

static BOOL VibeMakeR8brain(VibeConverter *converter, const AudioStreamBasicDescription *from,
                            const AudioStreamBasicDescription *to) {
    UInt32 channels = to->mChannelsPerFrame;
    try {
        for (UInt32 c = 0; c < channels; c++) {
            converter->channels.push_back(r8b_create(from->mSampleRate, to->mSampleRate, kVibeMaxInput,
                                                     kVibeR8TransitionBand, r8brr24));
        }
        converter->widened.resize(kVibeMaxInput);
        converter->produced.assign(channels, nullptr);
        converter->inputList.assign(offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer), 0);
        return YES;
    }
    catch (const std::bad_alloc &) {
        return NO;
    }
}

VibeConverter *VibeConverterCreate(VibeResampler resampler, const AudioStreamBasicDescription *from,
                                   const AudioStreamBasicDescription *to) {
    if (from->mChannelsPerFrame == 0 || from->mChannelsPerFrame != to->mChannelsPerFrame
            || from->mSampleRate <= 0 || to->mSampleRate <= 0) {
        return NULL;
    }
    VibeConverter *converter = new (std::nothrow) VibeConverter();
    if (!converter) {
        return NULL;
    }
    converter->resampler = resampler;
    BOOL made = resampler == VibeResamplerR8brain ? VibeMakeR8brain(converter, from, to) : VibeMakeApple(converter, from, to);
    if (!made) {
        delete converter;
        return NULL;
    }
    return converter;
}

void VibeConverterDispose(VibeConverter *converter) {
    delete converter;
}

VibeResampler VibeConverterResampler(const VibeConverter *converter) {
    return converter->resampler;
}

NSDictionary<NSString *, id> *VibeConverterReport(const VibeConverter *converter) {
    if (converter->apple) {
        NSMutableDictionary *report = [@{ @"resampler": VibeResamplerName(VibeResamplerApple),
                                          @"quality": @(VibeAppleQuality(converter->apple)) } mutableCopy];
        report[@"algorithm"] = VibeAppleAlgorithm(converter->apple); // nil sets nothing
        return report;
    }
    return @{ @"resampler": VibeResamplerName(VibeResamplerR8brain), @"algorithm": @"r8brain-free-src" };
}

static OSStatus VibeR8brainFill(VibeConverter *converter, AudioConverterComplexInputDataProc proc, void *userData,
                                UInt32 *ioFrames, AudioBufferList *output) {
    UInt32 wanted = *ioFrames, filled = 0, channels = (UInt32)converter->channels.size();
    OSStatus status = noErr;
    for (;;) {
        size_t take = MIN(converter->producedCount, (size_t)(wanted - filled));
        for (UInt32 c = 0; c < channels; c++) {
            vDSP_vdpsp(converter->produced[c] + converter->producedStart, 1,
                       (float *)output->mBuffers[c].mData + filled, 1, take);
        }
        filled += (UInt32)take;
        converter->producedStart += take;
        converter->producedCount -= take;
        if (filled == wanted) {
            break;
        }
        AudioBufferList *input = (AudioBufferList *)converter->inputList.data();
        input->mNumberBuffers = channels;
        for (UInt32 c = 0; c < channels; c++) {
            input->mBuffers[c] = (AudioBuffer){ 1, 0, NULL };
        }
        UInt32 packets = kVibeMaxInput;
        // The proc's converter argument is nonnull and the bus's proc never
        // reads it; this handle stands in.
        status = proc((AudioConverterRef)(void *)converter, &packets, input, NULL, userData);
        if (status != noErr || packets == 0) {
            break;
        }
        packets = MIN(packets, (UInt32)kVibeMaxInput);
        int count = 0;
        for (UInt32 c = 0; c < channels; c++) {
            vDSP_vspdp((const float *)input->mBuffers[c].mData, 1, converter->widened.data(), 1, packets);
            count = r8b_process(converter->channels[c], converter->widened.data(), (int)packets, converter->produced[c]);
        }
        converter->producedStart = 0;
        converter->producedCount = (size_t)count;
    }
    for (UInt32 c = 0; c < output->mNumberBuffers; c++) {
        output->mBuffers[c].mDataByteSize = filled * sizeof(float);
    }
    *ioFrames = filled;
    return status;
}

OSStatus VibeConverterFill(VibeConverter *converter, AudioConverterComplexInputDataProc proc, void *userData,
                           UInt32 *ioFrames, AudioBufferList *output) {
    if (converter->apple) {
        return AudioConverterFillComplexBuffer(converter->apple, proc, userData, ioFrames, output, NULL);
    }
    return VibeR8brainFill(converter, proc, userData, ioFrames, output);
}
