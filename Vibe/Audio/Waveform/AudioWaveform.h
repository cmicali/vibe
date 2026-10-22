//
//  AudioWaveform.h
//  Vibe
//

#import <Foundation/Foundation.h>
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

// Vibe's waveform is the summary of vibe-libs' waveform/Waveform: peaks
// and energy in bins of fixed time, read through its pyramid.
typedef wavecore::Summary AudioWaveform;

// The entry-format version. It is encoded in every archive and embedded in the
// disk cache's name, since AudioWaveformCache derives
// "audio_waveform_cache_v<N>" from it, so both invalidation mechanisms move
// together. Bump it to invalidate every cached entry, as after a format
// change. A changed observer needs no bump: it takes a new identifier
// (AudioWaveformObserver.h). Mismatched entries simply regenerate.
extern const int kCodableAudioWaveformVersion;

@interface CodableAudioWaveform : NSObject <NSCoding>

// Owned: freed with the wrapper.
@property (nonatomic, readonly) AudioWaveform *waveform;

// Each observer's result, a property-list object, by its identifier
// (AudioWaveformObserver.h). They share the summary's decode, key and
// lifecycle. An observer the decode did not run has no result, so a request
// that lists it misses and decodes again.
@property (nonatomic, copy) NSDictionary<NSString *, id> *results;

// Takes ownership.
- (instancetype)initWithWaveform:(std::unique_ptr<AudioWaveform>)waveform;

@end
