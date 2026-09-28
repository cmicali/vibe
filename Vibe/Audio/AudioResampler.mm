//
//  AudioResampler.mm
//  Vibe
//

#import "AudioResampler.h"
// r8brain's own C entry points, compiled optimized in every configuration
// (project.yml): its filters are header templates, and at -O0 they cost many
// times Apple's converter, which is always optimized.
#define R8BSRC_DECL
#include "r8brain/DLL/r8bsrc.h"
#import <Accelerate/Accelerate.h>
#include <cmath>
#include <memory>
#include <new>
#include <vector>

// The bus's decode chunk: the most one proc call answers.
static const int kVibeR8MaxInput = 4096;
// The 24-bit preset (180 dB stopband) with a 1% transition band, half
// upstream's default: −0.1 dB at 21.72 kHz from 44.1, level with Apple's
// Mastering filter, for about 20% more of a cost that is a twentieth of
// Apple's (docs/future/resampler.md).
static const double kVibeR8TransitionBand = 1.0;

struct VibeR8ChannelDeleter {
    void operator()(void *resampler) const { r8b_delete(resampler); }
};

struct VibeR8Resampler {
    UInt32 channels;
    std::vector<std::unique_ptr<void, VibeR8ChannelDeleter>> resamplers; // one per channel, identically configured
    std::vector<double> widened;                                  // one channel's input
    std::vector<std::vector<float>> produced;                     // per channel; every channel holds the same count
    size_t producedStart = 0;
    size_t producedCount = 0;
    std::vector<uint8_t> inputList;                               // the AudioBufferList the proc points at its data
};

VibeR8Resampler *VibeR8ResamplerCreate(double fromRate, double toRate, UInt32 channels) {
    if (channels == 0 || fromRate <= 0 || toRate <= 0) {
        return NULL;
    }
    try {
        std::unique_ptr<VibeR8Resampler> resampler(new VibeR8Resampler());
        resampler->channels = channels;
        for (UInt32 c = 0; c < channels; c++) {
            resampler->resamplers.emplace_back(r8b_create(fromRate, toRate, kVibeR8MaxInput, kVibeR8TransitionBand, r8brr24));
        }
        resampler->widened.resize(kVibeR8MaxInput);
        // A fill keeps at most one proc's output beyond what it hands back;
        // a larger one grows it (the decode queue may allocate).
        size_t capacity = (size_t)ceil(kVibeR8MaxInput * toRate / fromRate) * 2 + kVibeR8MaxInput;
        resampler->produced.assign(channels, std::vector<float>(capacity));
        resampler->inputList.assign(offsetof(AudioBufferList, mBuffers) + channels * sizeof(AudioBuffer), 0);
        return resampler.release();
    }
    catch (const std::bad_alloc &) {
        return NULL;
    }
}

void VibeR8ResamplerDispose(VibeR8Resampler *resampler) {
    delete resampler;
}

OSStatus VibeR8ResamplerFill(VibeR8Resampler *resampler, AudioConverterComplexInputDataProc proc, void *userData,
                             UInt32 *ioFrames, AudioBufferList *output) {
    UInt32 wanted = *ioFrames, filled = 0;
    UInt32 channels = MIN(resampler->channels, output->mNumberBuffers);
    OSStatus status = noErr;
    for (;;) {
        size_t take = MIN(resampler->producedCount, (size_t)(wanted - filled));
        for (UInt32 c = 0; c < channels; c++) {
            memcpy((float *)output->mBuffers[c].mData + filled, resampler->produced[c].data() + resampler->producedStart,
                   take * sizeof(float));
        }
        filled += (UInt32)take;
        resampler->producedStart += take;
        resampler->producedCount -= take;
        if (filled == wanted) {
            break;
        }
        AudioBufferList *input = (AudioBufferList *)resampler->inputList.data();
        input->mNumberBuffers = resampler->channels;
        for (UInt32 c = 0; c < resampler->channels; c++) {
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
        // Everything left over was handed out above, so the kept output
        // starts over at the front.
        resampler->producedStart = 0;
        int count = 0;
        for (UInt32 c = 0; c < resampler->channels; c++) {
            vDSP_vspdp((const float *)input->mBuffers[c].mData, 1, resampler->widened.data(), 1, packets);
            double *out = NULL;
            count = r8b_process(resampler->resamplers[c].get(), resampler->widened.data(), (int)packets, out);
            std::vector<float> &into = resampler->produced[c];
            if (into.size() < (size_t)count) {
                into.resize((size_t)count);
            }
            vDSP_vdpsp(out, 1, into.data(), 1, (vDSP_Length)count);
        }
        resampler->producedCount = (size_t)count;
    }
    for (UInt32 c = 0; c < output->mNumberBuffers; c++) {
        output->mBuffers[c].mDataByteSize = filled * sizeof(float);
    }
    *ioFrames = filled;
    return status;
}
