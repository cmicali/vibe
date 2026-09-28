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

struct VibeConverter {
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

    ~VibeConverter() {
        for (CR8BResampler channel : channels) {
            r8b_delete(channel);
        }
    }
};

VibeConverter *VibeConverterCreate(double fromRate, double toRate, uint32_t channels) {
    if (channels == 0 || fromRate <= 0 || toRate <= 0) {
        return NULL;
    }
    VibeConverter *converter = new (std::nothrow) VibeConverter();
    if (!converter) {
        return NULL;
    }
    try {
        for (uint32_t c = 0; c < channels; c++) {
            converter->channels.push_back(r8b_create(fromRate, toRate, kVibeMaxInput, kVibeR8TransitionBand, r8brr24));
        }
        converter->input.assign(channels, nullptr);
        converter->widened.resize(kVibeMaxInput);
        converter->produced.assign(channels, nullptr);
    }
    catch (const std::bad_alloc &) {
        delete converter;
        return NULL;
    }
    return converter;
}

void VibeConverterDispose(VibeConverter *converter) {
    delete converter;
}

uint32_t VibeConverterFill(VibeConverter *converter, VibeConverterInputProc input, void *userData, uint32_t frames,
                           float *const *output) {
    uint32_t filled = 0, channels = (uint32_t)converter->channels.size();
    for (;;) {
        size_t take = MIN(converter->producedCount, (size_t)(frames - filled));
        for (uint32_t c = 0; c < channels; c++) {
            vDSP_vdpsp(converter->produced[c] + converter->producedStart, 1, output[c] + filled, 1, take);
        }
        filled += (uint32_t)take;
        converter->producedStart += take;
        converter->producedCount -= take;
        if (filled == frames) {
            break;
        }
        // TRAP: MIN here can be <sys/param.h>'s, which evaluates its
        // arguments twice: wrapped around the input call, a pull that
        // answered under the maximum (a file's last read) read again and
        // lost it, breaking every gapless boundary (measured).
        uint32_t fed = input(userData, kVibeMaxInput, converter->input.data());
        fed = MIN(fed, (uint32_t)kVibeMaxInput);
        if (fed == 0) {
            break;
        }
        int count = 0;
        for (uint32_t c = 0; c < channels; c++) {
            vDSP_vspdp(converter->input[c], 1, converter->widened.data(), 1, fed);
            count = r8b_process(converter->channels[c], converter->widened.data(), (int)fed, converter->produced[c]);
        }
        converter->producedStart = 0;
        converter->producedCount = (size_t)count;
    }
    return filled;
}
