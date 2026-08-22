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
//
// TRAP: 0 < hopSize <= frameSize is a real precondition of the arithmetic, not
// a stylistic one. `base` below is bounded by hopSize, and the final assign
// needs it bounded by frameCount; only hopSize <= frameSize makes the second
// follow from the first, and with a larger hop a short buffer produces
// base > frameCount — a reversed iterator range, which is an overread rather
// than an empty one. hopSize == 0 never advances and spins forever. Both
// analyzers satisfy this (hop is half the frame, or 256 against 1024), so the
// guard below costs one comparison per decode buffer and has never fired; it
// is here so that a future caller gets nothing rather than undefined behavior.
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
