//
// Created by Christopher Micali on 1/8/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

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

    inline void mergeFromAudioBuffer(float* buffer, NSUInteger length, NSUInteger channels) {
        for (NSUInteger i = 0; i < length; ++i) {
            float value = 0;
            for (NSUInteger j = 0; j < channels; j++) {
                value += buffer[i];
                i++;
            }
            value /= channels;
//            if (value > 2 || value < -2) {
//            LogDebug(@"Value out of range: %.4f i: %d", value, i);
//            }
            merge(value);
        }
    }

private:
    float values[2];
};

class AudioWaveform {
public:
    AudioWaveform();
    AudioWaveform(NSUInteger numChunks, const void* chunks);
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

@end
