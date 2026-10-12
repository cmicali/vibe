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

// The bus's decode chunk: the most one input call answers.
static const int kVibeMaxInput = 4096;
// The 24-bit preset (180 dB stopband) with a 1% transition band, half
// upstream's default: −0.1 dB at 21.72 kHz from 44.1, for about 20% more cost
// (docs/audio-quality.md).
static const double kVibeR8TransitionBand = 1.0;

struct VibeResampler {
    // One per channel, identically configured, so every channel produces the
    // same count per call.
    std::vector<CR8BResampler> channels;
    std::vector<const float *> input; // where the input proc points each channel
    std::vector<double> widened;      // one channel's input
    // Each channel's last output, r8brain's own buffer: valid until that
    // channel's next process call, so it is handed out before the next pull.
    std::vector<double *> produced;
    size_t producedStart = 0;
    size_t producedCount = 0;

    ~VibeResampler() {
        for (CR8BResampler channel : channels) {
            r8b_delete(channel);
        }
    }
};

VibeResampler *VibeResamplerCreate(double fromRate, double toRate, uint32_t channels) {
    if (channels == 0 || fromRate <= 0 || toRate <= 0) {
        return NULL;
    }
    VibeResampler *resampler = new (std::nothrow) VibeResampler();
    if (!resampler) {
        return NULL;
    }
    try {
        for (uint32_t c = 0; c < channels; c++) {
            resampler->channels.push_back(r8b_create(fromRate, toRate, kVibeMaxInput, kVibeR8TransitionBand, r8brr24));
        }
        resampler->input.assign(channels, nullptr);
        resampler->widened.resize(kVibeMaxInput);
        resampler->produced.assign(channels, nullptr);
    }
    catch (const std::bad_alloc &) {
        delete resampler;
        return NULL;
    }
    return resampler;
}

void VibeResamplerDispose(VibeResampler *resampler) {
    delete resampler;
}

uint32_t VibeResamplerFill(VibeResampler *resampler, VibeResamplerInputProc input, void *userData, uint32_t frames,
                           float *const *output) {
    uint32_t filled = 0, channels = (uint32_t)resampler->channels.size();
    for (;;) {
        size_t take = MIN(resampler->producedCount, (size_t)(frames - filled));
        for (uint32_t c = 0; c < channels; c++) {
            vDSP_vdpsp(resampler->produced[c] + resampler->producedStart, 1, output[c] + filled, 1, take);
        }
        filled += (uint32_t)take;
        resampler->producedStart += take;
        resampler->producedCount -= take;
        if (filled == frames) {
            break;
        }
        // TRAP: MIN here can be <sys/param.h>'s, which evaluates its
        // arguments twice: wrapped around the input call, a pull that
        // answered under the maximum (a file's last read) read again and
        // lost it, breaking every gapless boundary (measured).
        uint32_t fed = input(userData, kVibeMaxInput, resampler->input.data());
        fed = MIN(fed, (uint32_t)kVibeMaxInput);
        if (fed == 0) {
            break;
        }
        int count = 0;
        for (uint32_t c = 0; c < channels; c++) {
            vDSP_vspdp(resampler->input[c], 1, resampler->widened.data(), 1, fed);
            count = r8b_process(resampler->channels[c], resampler->widened.data(), (int)fed, resampler->produced[c]);
        }
        resampler->producedStart = 0;
        resampler->producedCount = (size_t)count;
    }
    return filled;
}
