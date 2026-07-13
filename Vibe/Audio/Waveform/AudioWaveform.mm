//
// Created by Christopher Micali on 1/8/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioWaveform.h"

#define NUM_CHUNKS     (4096*2)

AudioWaveform::AudioWaveform() {
    numChunks = NUM_CHUNKS;
    this->chunks = static_cast<AudioWaveformCacheChunk*>(calloc(this->numChunks, sizeof(AudioWaveformCacheChunk)));
    // A NULL alloc would make setChunkAtIndex dereference NULL; a zero count
    // turns every access into a safe no-op instead.
    if (!this->chunks) { this->numChunks = 0; }
}

AudioWaveform::AudioWaveform(NSUInteger numChunks, const void* chunks) {
    this->numChunks = numChunks;
    this->chunks = static_cast<AudioWaveformCacheChunk*>(calloc(this->numChunks, sizeof(AudioWaveformCacheChunk)));
    if (this->chunks && chunks) {
        memcpy(this->chunks, chunks, this->getNumBytes());
    } else {
        this->numChunks = 0;
    }
}

AudioWaveform::AudioWaveform(const AudioWaveform& other) {
    this->numChunks = other.numChunks;
    this->chunks = static_cast<AudioWaveformCacheChunk*>(calloc(this->numChunks, sizeof(AudioWaveformCacheChunk)));
    if (this->chunks && other.chunks) {
        memcpy(this->chunks, other.chunks, this->getNumBytes());
    } else {
        this->numChunks = 0;
    }
}

AudioWaveform::~AudioWaveform() {
    free(this->chunks);
}

AudioWaveformCacheChunk AudioWaveform::getChunkAtIndex(NSUInteger index, NSUInteger size)  {
    AudioWaveformCacheChunk result;
    // A failed calloc leaves chunks NULL / numChunks 0 (see the constructors);
    // guard here as normalize() already does, so a renderer read can't deref NULL.
    if (chunks == nullptr || numChunks == 0) return result;
    if (index >= size) return result;
    if (size == numChunks) { return chunks[index]; }
    NSUInteger startIndex = numChunks * index / size;
    NSUInteger numChunksToCombine = static_cast<NSUInteger>(MAX((float) numChunks / (float) size, 1.0f));
    if (numChunksToCombine == 1) {
        return chunks[startIndex];
    }
    // Clamp to avoid reading past the buffer
    if (startIndex + numChunksToCombine > numChunks) {
        numChunksToCombine = numChunks - startIndex;
    }
    if (numChunksToCombine < 16) {
        // vDSP setup overhead dominates for tiny strided ranges — plain loop
        result = chunks[startIndex];
        for (NSUInteger i = 1; i < numChunksToCombine; i++) {
            result.merge(&chunks[startIndex + i]);
        }
        return result;
    }
    // chunks[] is float[2] pairs: [min0, max0, min1, max1, ...]
    // Use stride-2 vDSP to find min of all mins and max of all maxes
    float *base = reinterpret_cast<float*>(&chunks[startIndex]);
    float minVal, maxVal;
    vDSP_minv(base,     2, &minVal, numChunksToCombine);  // stride 2, starting at values[0]
    vDSP_maxv(base + 1, 2, &maxVal, numChunksToCombine);  // stride 2, starting at values[1]
    result.set(minVal, maxVal);
    return result;
}

void AudioWaveform::normalize() {
    if (chunks == 0 || numChunks == 0) return;
    // chunks[] is a contiguous array of float[2] pairs: [min0, max0, min1, max1, ...]
    // We can treat it as a single float array of length numChunks * 2
    float *data = reinterpret_cast<float*>(chunks);
    vDSP_Length totalFloats = numChunks * 2;

    // Find global min and max across all values
    float globalMin, globalMax;
    vDSP_minv(data, 1, &globalMin, totalFloats);
    vDSP_maxv(data, 1, &globalMax, totalFloats);

    // Find the largest absolute value for normalization
    float absMin = fabsf(globalMin);
    float absMax = fabsf(globalMax);
    float peak = (absMin > absMax) ? absMin : absMax;

    if (peak != 0.0f) {
        float factor = 1.0f / peak;
        // Scale all values in one vectorized pass
        vDSP_vsmul(data, 1, &factor, data, 1, totalFloats);
    }
}

static const int kCodableAudioWaveformVersion = 2;

@implementation CodableAudioWaveform

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInt:kCodableAudioWaveformVersion forKey:@"version"];
    [coder encodeObject:@(self.waveform->getNumChunks()) forKey:@"numChunks"];
    [coder encodeBytes:(const uint8_t*)self.waveform->getBytes() length:self.waveform->getNumBytes() forKey:@"chunks"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        // Missing/mismatched version (old cache entries decode as 0) or
        // malformed payloads are rejected; the waveform just re-generates.
        if ([coder decodeIntForKey:@"version"] != kCodableAudioWaveformVersion) {
            return nil;
        }
        // Validate the class before messaging: a bit-rotted entry that decodes
        // numChunks as some other object would otherwise crash (unrecognized
        // selector) inside the decode, ahead of the payload checks below.
        NSNumber *numChunksValue = [coder decodeObjectForKey:@"numChunks"];
        if (![numChunksValue isKindOfClass:[NSNumber class]]) {
            return nil;
        }
        NSUInteger numChunks = [numChunksValue unsignedIntegerValue];
        NSUInteger length;
        const void* data = [coder decodeBytesForKey:@"chunks" returnedLength:&length];
        // The encoder only ever writes NUM_CHUNKS. Requiring exact equality
        // rejects corrupt/rot entries and removes the unchecked-multiply
        // overflow the length comparison would otherwise carry.
        if (!data || numChunks != NUM_CHUNKS || length != numChunks * sizeof(AudioWaveformCacheChunk)) {
            return nil;
        }
        self.waveform = new AudioWaveform(numChunks, data);
    }
    return self;
}

- (id)initWithWaveform:(AudioWaveform *)waveform {
    self = [super init];
    if (self) {
        self.waveform = waveform;
    }
    return self;
}

- (CodableAudioWaveform *)snapshot {
    if (!self.waveform) {
        return nil;
    }
    return [[CodableAudioWaveform alloc] initWithWaveform:new AudioWaveform(*self.waveform)];
}

- (void)dealloc {
    if (self.waveform) {
        delete self.waveform;
    }
}


@end
