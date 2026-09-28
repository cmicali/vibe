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
static const int kVibeR8MaxInput = 4096;
// The 24-bit preset (180 dB stopband) with a 1% transition band, half
// upstream's default: −0.1 dB at 21.72 kHz from 44.1, level with Apple's
// Mastering filter, for about 20% more of a cost that is a twentieth of
// Apple's (docs/future/resampler.md).
static const double kVibeR8TransitionBand = 1.0;

struct VibeR8Resampler {
    // One per channel, identically configured, so every channel produces the
    // same count per call.
    std::vector<CR8BResampler> channels;
    std::vector<double> widened;   // one channel's input
    // Each channel's last output, r8brain's own buffer: valid until that
    // channel's next process call, so it is handed out before the next pull.
    std::vector<double *> produced;
    size_t producedStart = 0;
    size_t producedCount = 0;
    std::vector<uint8_t> inputList; // the AudioBufferList the proc points at its data

    ~VibeR8Resampler() {
        for (CR8BResampler channel : channels) {
            r8b_delete(channel);
        }
    }
};

VibeR8Resampler *VibeR8ResamplerCreate(double fromRate, double toRate, UInt32 channels) {
    if (channels == 0 || fromRate <= 0 || toRate <= 0) {
        return NULL;
    }
    VibeR8Resampler *resampler = new (std::nothrow) VibeR8Resampler();
    if (!resampler) {
        return NULL;
    }
    try {
        for (UInt32 c = 0; c < channels; c++) {
            resampler->channels.push_back(r8b_create(fromRate, toRate, kVibeR8MaxInput, kVibeR8TransitionBand, r8brr24));
        }
        resampler->widened.resize(kVibeR8MaxInput);
        resampler->produced.assign(channels, nullptr);
        resampler->inputList.assign(offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer), 0);
        return resampler;
    }
    catch (const std::bad_alloc &) {
        delete resampler;
        return NULL;
    }
}

void VibeR8ResamplerDispose(VibeR8Resampler *resampler) {
    delete resampler;
}

OSStatus VibeR8ResamplerFill(VibeR8Resampler *resampler, AudioConverterComplexInputDataProc proc, void *userData,
                             UInt32 *ioFrames, AudioBufferList *output) {
    UInt32 wanted = *ioFrames, filled = 0, channels = (UInt32)resampler->channels.size();
    OSStatus status = noErr;
    for (;;) {
        size_t take = MIN(resampler->producedCount, (size_t)(wanted - filled));
        for (UInt32 c = 0; c < channels; c++) {
            vDSP_vdpsp(resampler->produced[c] + resampler->producedStart, 1,
                       (float *)output->mBuffers[c].mData + filled, 1, take);
        }
        filled += (UInt32)take;
        resampler->producedStart += take;
        resampler->producedCount -= take;
        if (filled == wanted) {
            break;
        }
        AudioBufferList *input = (AudioBufferList *)resampler->inputList.data();
        input->mNumberBuffers = channels;
        for (UInt32 c = 0; c < channels; c++) {
            input->mBuffers[c] = (AudioBuffer){ 1, 0, NULL };
        }
        UInt32 packets = kVibeR8MaxInput;
        // The proc's converter argument is nonnull and the bus's proc never
        // reads it; this handle stands in.
        status = proc((AudioConverterRef)(void *)resampler, &packets, input, NULL, userData);
        if (status != noErr || packets == 0) {
            break;
        }
        packets = MIN(packets, (UInt32)kVibeR8MaxInput);
        int count = 0;
        for (UInt32 c = 0; c < channels; c++) {
            vDSP_vspdp((const float *)input->mBuffers[c].mData, 1, resampler->widened.data(), 1, packets);
            count = r8b_process(resampler->channels[c], resampler->widened.data(), (int)packets, resampler->produced[c]);
        }
        resampler->producedStart = 0;
        resampler->producedCount = (size_t)count;
    }
    for (UInt32 c = 0; c < output->mNumberBuffers; c++) {
        output->mBuffers[c].mDataByteSize = filled * sizeof(float);
    }
    *ioFrames = filled;
    return status;
}
