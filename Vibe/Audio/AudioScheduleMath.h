//
//  AudioScheduleMath.h
//  Vibe
//

#import <AVFoundation/AVFoundation.h>
#include <stdint.h>

// TRAP: AVAudioPlayerNode's segment count is uint32_t while file positions
// are int64_t. These helpers keep the narrowing explicit and testable rather
// than letting each scheduleSegment site cast for itself.
static inline uint64_t VibeAudioFramesToSchedule(AVAudioFramePosition fileLength,
                                                 AVAudioFramePosition startFrame) {
    return fileLength > startFrame ? (uint64_t)(fileLength - startFrame) : 1;
}

static inline AVAudioFrameCount VibeAudioScheduleChunkFrames(uint64_t remainingFrames) {
    return (AVAudioFrameCount)MIN(remainingFrames, (uint64_t)UINT32_MAX);
}
