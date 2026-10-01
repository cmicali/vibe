//
//  AnalysisFramerMath.h
//  Vibe
//
//  The boundary-straddling stream framer both analyzers run their DSP behind:
//  the guarantee that the buffer sizes the decoder happens to hand an analyzer
//  never reach its result lives in this one function. C++ only — it is
//  included from the analyzers' .mm files and nowhere else.
//

#pragma once

#include <algorithm>
#include <cstring>
#include <vector>

// Frames a mono sample stream into fixed-size windows at a fixed hop, calling
// process(frame) once per complete frame. Only the frames straddling the
// buffer boundary are spliced into pending; every later frame is read in
// place out of the caller's buffer, so a decode buffer is never copied whole.
// pending carries fewer than frameSize floats between calls; the owner
// reserves it at twice frameSize so the splice never reallocates.
//
// TRAP: 0 < hopSize <= frameSize is a precondition of the arithmetic. `base`
// below is bounded by hopSize and the final tail copy needs it bounded by
// frameCount; only hopSize <= frameSize makes the second follow. A larger hop
// wraps a short buffer's frameCount - base — a huge resize and an overread,
// not an empty one — and a zero hop never advances. The guard returns
// nothing instead.
template <typename ProcessFrame>
static inline void VibeAnalysisFrameStream(std::vector<float> &pending,
                                           const float *samples, size_t frameCount,
                                           size_t frameSize, size_t hopSize,
                                           ProcessFrame process) {
    if (frameSize == 0 || hopSize == 0 || hopSize > frameSize) {
        return;
    }
    const size_t carried = pending.size();
    size_t offset = 0;
    if (carried > 0) {
        const size_t take = std::min(frameCount, frameSize);
        pending.resize(carried + take);
        memcpy(pending.data() + carried, samples, take * sizeof(float));
        while (offset < carried && offset + frameSize <= pending.size()) {
            process(pending.data() + offset);
            offset += hopSize;
        }
        if (offset < carried) { // not even the first straddling frame is whole yet
            pending.erase(pending.begin(), pending.begin() + (long)offset);
            return;
        }
    }
    size_t base = offset - carried;
    while (base + frameSize <= frameCount) {
        process(samples + base);
        base += hopSize;
    }
    pending.resize(frameCount - base);
    memcpy(pending.data(), samples + base, (frameCount - base) * sizeof(float));
}
