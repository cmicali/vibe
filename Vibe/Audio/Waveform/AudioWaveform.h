//
// Created by Christopher Micali on 1/8/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#include <Accelerate/Accelerate.h>
#include <cmath>

struct AudioWaveformCacheChunk {

    inline AudioWaveformCacheChunk() noexcept { set(0, 0); }
    inline AudioWaveformCacheChunk(float min, float max) noexcept { set(min, max); }
    inline AudioWaveformCacheChunk(float* buffer, NSUInteger length, NSUInteger channels) noexcept {
        set(0, 0);
        mergeFromAudioBuffer(buffer, length, channels);
    }

    inline float getMin() const noexcept { return values[0]; }
    inline float getMax() const noexcept { return values[1]; }
    inline void set(float min, float max) noexcept { values[0] = min; values[1] = max; }
    inline void setMin(float min) noexcept { values[0] = min; }
    inline void setMin(AudioWaveformCacheChunk chunk) noexcept { values[0] = chunk.values[0]; }
    inline void setMin(AudioWaveformCacheChunk* chunk) noexcept { values[0] = chunk->values[0]; }
    inline void setMax(float max) noexcept { values[1] = max; }
    inline void setMax(AudioWaveformCacheChunk chunk) noexcept { values[1] = chunk.values[1]; }
    inline void setMax(AudioWaveformCacheChunk* chunk) noexcept { values[1] = chunk->values[1]; }
    inline void merge(float value) {
        if (value < values[0]) values[0] = value;
        if (value > values[1]) values[1] = value;
    }
    inline void merge(AudioWaveformCacheChunk chunk) noexcept { merge(&chunk); }
    inline void merge(AudioWaveformCacheChunk* chunk) noexcept {
        if (chunk->values[0] < values[0]) values[0] = chunk->values[0];
        if (chunk->values[1] > values[1]) values[1] = chunk->values[1];
    }

    inline void mergeFromAudioBuffer(float* buffer, NSUInteger numSamples, NSUInteger channels) {
        if (numSamples == 0) return;
        NSUInteger numFrames = numSamples / channels;
        if (numFrames == 0) return;

        float minVal, maxVal;

        if (channels == 1) {
            // Mono: min/max directly on the buffer via vDSP
            vDSP_minv(buffer, 1, &minVal, numFrames);
            vDSP_maxv(buffer, 1, &maxVal, numFrames);
        } else if (channels == 2) {
            // Stereo: average L+R using vDSP, then find min/max
            // Use a stack buffer for small sizes, heap for large
            constexpr NSUInteger kStackLimit = 8192;
            float stackBuf[kStackLimit];
            float *mono = (numFrames <= kStackLimit) ? stackBuf : (float*)malloc(numFrames * sizeof(float));
            if (!mono) return; // OOM on a large chunk — leave this chunk at 0,0

            // Add left + right channels (interleaved: L0 R0 L1 R1 ...)
            vDSP_vadd(buffer, 2, buffer + 1, 2, mono, 1, numFrames);
            // Scale by 0.5 to average
            float half = 0.5f;
            vDSP_vsmul(mono, 1, &half, mono, 1, numFrames);

            vDSP_minv(mono, 1, &minVal, numFrames);
            vDSP_maxv(mono, 1, &maxVal, numFrames);

            if (mono != stackBuf) free(mono);
        } else {
            // N-channel: sum all channels, divide by N, then find min/max
            NSUInteger monoLen = numFrames;
            float *mono = (float*)calloc(monoLen, sizeof(float));
            if (!mono) return; // OOM — leave this chunk at 0,0

            for (NSUInteger ch = 0; ch < channels; ch++) {
                vDSP_vadd(mono, 1, buffer + ch, channels, mono, 1, monoLen);
            }
            float scale = 1.0f / (float)channels;
            vDSP_vsmul(mono, 1, &scale, mono, 1, monoLen);

            vDSP_minv(mono, 1, &minVal, monoLen);
            vDSP_maxv(mono, 1, &maxVal, monoLen);

            free(mono);
        }

        // A corrupt file can decode NaN/Inf floats, which vDSP propagates into
        // min/max. Left unsanitized they produce NaN CGRects in the renderers
        // (CoreGraphics error spam, blank bars), can wipe the whole waveform in
        // normalize(), and — because isComplete stays YES — get persisted under
        // the file hash, breaking that track forever. Clamp to 0 here.
        if (!std::isfinite(minVal)) minVal = 0.0f;
        if (!std::isfinite(maxVal)) maxVal = 0.0f;

        if (minVal < values[0]) values[0] = minVal;
        if (maxVal > values[1]) values[1] = maxVal;
    }

private:
    float values[2];
};

class AudioWaveform {
public:
    AudioWaveform();
    AudioWaveform(NSUInteger numChunks, const void* chunks);
    AudioWaveform(const AudioWaveform& other);
    // Copy-assignment would shallow-copy the raw chunks pointer → double-free.
    // It's never used (waveforms are always heap-allocated and passed by
    // pointer); delete it to complete the rule-of-three and keep it that way.
    AudioWaveform& operator=(const AudioWaveform&) = delete;
    ~AudioWaveform();

    AudioWaveformCacheChunk getChunkAtIndex(NSUInteger index, NSUInteger size);
    inline void setChunkAtIndex(AudioWaveformCacheChunk chunk, NSUInteger index) {
        if (index < numChunks) { chunks[index] = chunk; }
    }

    void normalize();

    inline NSUInteger getNumChunks() { return this->numChunks; }
    inline const void* getBytes() { return (const void *)&chunks[0]; }
    inline NSUInteger getNumBytes() { return this->numChunks * sizeof(AudioWaveformCacheChunk); }

private:
    NSUInteger numChunks;
    AudioWaveformCacheChunk* chunks;
};

@interface CodableAudioWaveform : NSObject <NSCoding>

@property (nonatomic) AudioWaveform *waveform;

- (id)initWithWaveform:(AudioWaveform *)waveform;

// Deep copy of the current chunk buffer, wrapped in a new object that owns it.
// Handed to the main thread on progress ticks so it renders an immutable copy
// while the loader keeps writing the live buffer (otherwise a data race).
- (CodableAudioWaveform *)snapshot;

@end
