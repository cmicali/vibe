//
//  AudioWaveform.h
//  Vibe
//

#include <Accelerate/Accelerate.h>
#include <memory>

#include "WaveformSummary.hpp"

// The waveform summary, BPM and key analyzers share one mono mix per buffer.
// For mono input it returns the buffer itself, with no copy. Otherwise it
// averages the channels, which are interleaved as L0 R0 L1 R1 and so on, into
// scratch, and returns scratch. scratch must hold numFrames floats.
static inline const float* AudioWaveformMonoMix(const float* buffer, float* scratch,
                                                NSUInteger numFrames, NSUInteger channels) {
    if (channels <= 1) {
        return buffer;
    }
    // vDSP_vasm rounds the sum before scaling it.
    float scale = 1.0f / (float)channels;
    if (channels == 2) {
        vDSP_vasm(buffer, 2, buffer + 1, 2, &scale, scratch, 1, numFrames);
        return scratch;
    }
    vDSP_vadd(buffer, (vDSP_Stride)channels, buffer + 1, (vDSP_Stride)channels, scratch, 1, numFrames);
    for (NSUInteger ch = 2; ch + 1 < channels; ch++) {
        vDSP_vadd(scratch, 1, buffer + ch, (vDSP_Stride)channels, scratch, 1, numFrames);
    }
    vDSP_vasm(scratch, 1, buffer + channels - 1, (vDSP_Stride)channels, &scale, scratch, 1, numFrames);
    return scratch;
}

// Vibe's waveform is WaveformCore's summary (Packages/WaveformCore): peaks
// and energy in bins of fixed time, read through its pyramid.
typedef wavecore::Summary AudioWaveform;

// Vibe draws one mono lane, so a summary keeps the mix's peaks.
static const uint32_t kAudioWaveformStoredChannels = 1;

// The entry-format version. It is encoded in every archive and embedded in the
// disk cache's name, since AudioWaveformCache derives
// "audio_waveform_cache_v<N>" from it, so both invalidation mechanisms move
// together. Bump it to invalidate every cached entry, as after a format change
// or a BPM-analyzer change that should re-detect. Mismatched entries simply
// regenerate.
extern const int kCodableAudioWaveformVersion;

@interface CodableAudioWaveform : NSObject <NSCoding>

// Owned: freed with the wrapper.
@property (nonatomic, readonly) AudioWaveform *waveform;

// The detected tempo; 0 means unknown or undetectable. It is not conceptually
// waveform data, but it is the product of the same track-window decode pass and
// shares the waveform's cache key and lifecycle, so it rides along in this
// archive rather than paying for a second decode into a cache of its own.
@property (nonatomic) float bpm;

// The detected musical key (VibeMusicalKey, not imported to keep this C++
// header out of MusicalKey.h's reverse closure); -1, VibeMusicalKeyNone, means
// unknown. Same ride-along rationale as bpm. A fresh object must set -1: the
// zero-filled default is C major.
@property (nonatomic) NSInteger key;

// Whether the decode ran each analyzer, so a request asking for one this
// entry skipped misses and decodes again: turning detection on reaches files
// first decoded with detection off. An absent archived flag reads YES.
@property (nonatomic) BOOL bpmAnalyzed;
@property (nonatomic) BOOL keyAnalyzed;

// Takes ownership.
- (instancetype)initWithWaveform:(std::unique_ptr<AudioWaveform>)waveform;

@end
