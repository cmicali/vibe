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
#include <vector>

// Frames a mono sample stream into fixed-size windows at a fixed hop, calling
// process(frame) once per complete frame. Only the frames straddling the
// buffer boundary are spliced into pending; every later frame is read in
// place out of the caller's buffer, so a decode buffer is never copied whole.
// pending carries fewer than frameSize floats between calls; the owner
// reserves it at twice frameSize so the splice never reallocates.
template <typename ProcessFrame>
static inline void VibeAnalysisFrameStream(std::vector<float> &pending,
                                           const float *samples, size_t frameCount,
                                           size_t frameSize, size_t hopSize,
                                           ProcessFrame process) {
    const size_t carried = pending.size();
    size_t offset = 0;
    if (carried > 0) {
        pending.insert(pending.end(), samples,
                       samples + std::min(frameCount, frameSize));
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
    pending.assign(samples + base, samples + frameCount);
}
