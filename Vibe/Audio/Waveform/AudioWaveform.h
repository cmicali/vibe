//
//  AudioWaveform.h
//  Vibe
//

#include <Accelerate/Accelerate.h>
#include <cmath>

// The interleaved-to-mono downmix shared by the waveform chunker and the BPM
// analyzer: one mix per decode buffer rather than one per consumer. For mono
// input it returns the buffer itself, with no copy. Otherwise it averages the
// channels, which are interleaved as L0 R0 L1 R1 and so on, into scratch, and
// returns scratch. scratch must hold numFrames floats.
static inline const float* AudioWaveformMonoMix(const float* buffer, float* scratch,
                                                NSUInteger numFrames, NSUInteger channels) {
    if (channels <= 1) {
        return buffer;
    }
    vDSP_vadd(buffer, (vDSP_Stride)channels, buffer + 1, (vDSP_Stride)channels, scratch, 1, numFrames);
    for (NSUInteger ch = 2; ch < channels; ch++) {
        vDSP_vadd(scratch, 1, buffer + ch, (vDSP_Stride)channels, scratch, 1, numFrames);
    }
    float scale = 1.0f / (float)channels;
    vDSP_vsmul(scratch, 1, &scale, scratch, 1, numFrames);
    return scratch;
}

struct AudioWaveformCacheChunk {

    inline AudioWaveformCacheChunk() noexcept { set(0, 0); }
    inline AudioWaveformCacheChunk(const float* mono, NSUInteger numFrames) noexcept {
        set(0, 0);
        mergeFromMonoBuffer(mono, numFrames);
    }

    inline float getMin() const noexcept { return values[0]; }
    inline float getMax() const noexcept { return values[1]; }
    // Mean of the squared samples across every frame merged in — sqrt of it is
    // the chunk's RMS. 0 for an empty chunk.
    inline float getMeanSquare() const noexcept { return values[3] > 0 ? values[2] / values[3] : 0; }
    inline void set(float min, float max) noexcept { set(min, max, 0, 0); }
    inline void set(float min, float max, float sumSquares, float frameCount) noexcept {
        values[0] = min; values[1] = max; values[2] = sumSquares; values[3] = frameCount;
    }
    inline void merge(AudioWaveformCacheChunk* chunk) noexcept {
        if (chunk->values[0] < values[0]) values[0] = chunk->values[0];
        if (chunk->values[1] > values[1]) values[1] = chunk->values[1];
        values[2] += chunk->values[2];
        values[3] += chunk->values[3];
    }

    inline void mergeFromMonoBuffer(const float* mono, NSUInteger numFrames) {
        if (numFrames == 0) return;

        float minVal, maxVal, meanSquare;
        vDSP_minv(mono, 1, &minVal, numFrames);
        vDSP_maxv(mono, 1, &maxVal, numFrames);
        vDSP_measqv(mono, 1, &meanSquare, numFrames);

        // A corrupt file can decode NaN or Inf, which vDSP propagates into all
        // three reductions: NaN geometry in the renderers, persisted under the
        // file's key because the decode still completes.
        if (!std::isfinite(minVal)) minVal = 0.0f;
        if (!std::isfinite(maxVal)) maxVal = 0.0f;
        if (!std::isfinite(meanSquare)) meanSquare = 0.0f;

        if (minVal < values[0]) values[0] = minVal;
        if (maxVal > values[1]) values[1] = maxVal;
        values[2] += meanSquare * (float)numFrames;
        values[3] += (float)numFrames;
    }

private:
    // min, max, sum of squared samples, frame count. Energy is a sum plus a
    // weight rather than a stored mean so that merging — partial decode
    // buffers into one chunk, chunks into one drawn column — stays exact and
    // order-independent whatever the pieces' frame counts.
    float values[4];
};

class AudioWaveform {
public:
    AudioWaveform();
    AudioWaveform(NSUInteger numChunks, const void* chunks);
    AudioWaveform(const AudioWaveform& other);
    // Deleted: it would shallow-copy the raw chunks pointer and double free.
    AudioWaveform& operator=(const AudioWaveform&) = delete;
    ~AudioWaveform();

    AudioWaveformCacheChunk getChunkAtIndex(NSUInteger index, NSUInteger size);
    // The loudest of the track's energy columns at this resolution — its mean
    // square, as getMeanSquare — which the renderers' Normalize draws at
    // full height. 0 for an empty or silent waveform.
    float getMaxMeanSquare(NSUInteger columns);
    // The loader's own verdict, carried on the data: a decode it accepts can
    // end a chunk or two short, so the chunks cannot answer this. A fresh
    // waveform is a load still streaming, and a snapshot copies the answer;
    // one built from bytes is an archive, which is only written complete.
    inline bool isComplete() const noexcept { return complete; }
    inline void markComplete() noexcept { complete = true; }
    inline void setChunkAtIndex(AudioWaveformCacheChunk chunk, NSUInteger index) {
        if (index < numChunks) { chunks[index] = chunk; }
    }

    inline NSUInteger getNumChunks() { return this->numChunks; }
    inline const void* getBytes() { return (const void *)&chunks[0]; }
    inline NSUInteger getNumBytes() { return this->numChunks * sizeof(AudioWaveformCacheChunk); }

private:
    NSUInteger numChunks;
    AudioWaveformCacheChunk* chunks;
    bool complete;
};

// The entry-format version. It is encoded in every archive and embedded in the
// disk cache's name, since AudioWaveformCache derives
// "audio_waveform_cache_v<N>" from it, so both invalidation mechanisms move
// together. Bump it to invalidate every cached entry, as after a chunk-format
// change or a BPM-analyzer change that should re-detect. Mismatched entries
// simply regenerate.
extern const int kCodableAudioWaveformVersion;

@interface CodableAudioWaveform : NSObject <NSCoding>

@property (nonatomic) AudioWaveform *waveform;

// The detected tempo; 0 means unknown or undetectable. It is not conceptually
// waveform data, but it is the product of the same full-file decode pass and
// shares the waveform's cache key and lifecycle, so it rides along in this
// archive rather than paying for a second decode into a cache of its own.
@property (nonatomic) float bpm;

// The detected musical key (VibeMusicalKey, not imported to keep this C++
// header out of MusicalKey.h's reverse closure); -1, VibeMusicalKeyNone, means
// unknown. Same ride-along rationale as bpm. A fresh object must set -1: the
// zero-filled default is C major.
@property (nonatomic) NSInteger key;

- (id)initWithWaveform:(AudioWaveform *)waveform;

// A deep copy of the current chunk buffer, wrapped in a new object that owns
// it. It is handed to the main thread on progress ticks, so that the main
// thread renders an immutable copy while the loader keeps writing the live
// buffer. Sharing the live buffer would be a data race.
- (CodableAudioWaveform *)snapshot;

@end
