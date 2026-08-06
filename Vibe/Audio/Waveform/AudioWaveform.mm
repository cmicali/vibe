//
// Created by Christopher Micali on 1/8/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioWaveform.h"

#define NUM_CHUNKS     (4096*2)

AudioWaveform::AudioWaveform() {
    numChunks = NUM_CHUNKS;
    this->chunks = static_cast<AudioWaveformCacheChunk*>(calloc(this->numChunks, sizeof(AudioWaveformCacheChunk)));
    // A NULL allocation would make setChunkAtIndex dereference NULL, whereas a
    // zero count turns every access into a safe no-op.
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
    // A failed calloc leaves chunks NULL and numChunks 0; see the
    // constructors. Guard here so that a renderer read cannot dereference NULL.
    if (chunks == nullptr || numChunks == 0) return result;
    if (index >= size) return result;
    if (size == numChunks) { return chunks[index]; }
    // Column i combines [start(i), start(i+1)), so consecutive columns tile
    // the source exactly. A floored fixed width skips a source chunk on most
    // steps of a fractional ratio, which makes transient peaks vanish at some
    // view widths.
    NSUInteger startIndex = numChunks * index / size;
    NSUInteger endIndex = numChunks * (index + 1) / size;
    NSUInteger numChunksToCombine = endIndex > startIndex ? endIndex - startIndex : 1;
    if (numChunksToCombine == 1) {
        return chunks[startIndex];
    }
    // Clamp so we never read past the buffer.
    if (startIndex + numChunksToCombine > numChunks) {
        numChunksToCombine = numChunks - startIndex;
    }
    if (numChunksToCombine < 16) {
        // vDSP setup overhead dominates for tiny strided ranges, so use a
        // plain loop.
        result = chunks[startIndex];
        for (NSUInteger i = 1; i < numChunksToCombine; i++) {
            result.merge(&chunks[startIndex + i]);
        }
        return result;
    }
    // chunks[] holds float[2] pairs: min0, max0, min1, max1 and so on. Use
    // stride-2 vDSP to find the minimum of all the minima and the maximum of
    // all the maxima.
    float *base = reinterpret_cast<float*>(&chunks[startIndex]);
    float minVal, maxVal;
    vDSP_minv(base,     2, &minVal, numChunksToCombine);  // stride 2, starting at values[0]
    vDSP_maxv(base + 1, 2, &maxVal, numChunksToCombine);  // stride 2, starting at values[1]
    result.set(minVal, maxVal);
    return result;
}

// See the declaration in AudioWaveform.h. It also names the disk cache, so a
// bump invalidates by rename as well as by mismatch.
const int kCodableAudioWaveformVersion = 4;

@implementation CodableAudioWaveform

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeInt:kCodableAudioWaveformVersion forKey:@"version"];
    [coder encodeObject:@(self.waveform->getNumChunks()) forKey:@"numChunks"];
    [coder encodeBytes:(const uint8_t*)self.waveform->getBytes() length:self.waveform->getNumBytes() forKey:@"chunks"];
    [coder encodeFloat:self.bpm forKey:@"bpm"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        // A missing or mismatched version, since old cache entries decode as
        // 0, and a malformed payload are both rejected. The waveform simply
        // regenerates.
        if ([coder decodeIntForKey:@"version"] != kCodableAudioWaveformVersion) {
            return nil;
        }
        // Validate the class before messaging. A bit-rotted entry that decodes
        // numChunks as some other object would otherwise crash with an
        // unrecognized selector inside the decode, before the payload checks
        // below ever ran.
        NSNumber *numChunksValue = [coder decodeObjectForKey:@"numChunks"];
        if (![numChunksValue isKindOfClass:[NSNumber class]]) {
            return nil;
        }
        NSUInteger numChunks = [numChunksValue unsignedIntegerValue];
        NSUInteger length;
        const void* data = [coder decodeBytesForKey:@"chunks" returnedLength:&length];
        // The encoder only ever writes NUM_CHUNKS. Requiring exact equality
        // rejects corrupt and bit-rotted entries, and removes the unchecked
        // multiply overflow the length comparison would otherwise carry.
        if (!data || numChunks != NUM_CHUNKS || length != numChunks * sizeof(AudioWaveformCacheChunk)) {
            return nil;
        }
        // Generation clamps NaN before chunks are stored; see AudioWaveform.h.
        // But the archive has no checksum, so a bit-rotted entry can still
        // decode non-finite floats, which poison the renderers' geometry on
        // every play until the entry ages out. Reject it like any other
        // malformed payload.
        const float *values = (const float *)data;
        NSUInteger numValues = length / sizeof(float);
        for (NSUInteger i = 0; i < numValues; i++) {
            if (!std::isfinite(values[i])) {
                return nil;
            }
        }
        self.waveform = new AudioWaveform(numChunks, data);
        float bpm = [coder decodeFloatForKey:@"bpm"];
        self.bpm = std::isfinite(bpm) && bpm > 0 ? bpm : 0;
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
    CodableAudioWaveform *copy = [[CodableAudioWaveform alloc] initWithWaveform:new AudioWaveform(*self.waveform)];
    copy.bpm = self.bpm;
    return copy;
}

- (void)dealloc {
    if (self.waveform) {
        delete self.waveform;
    }
}


@end
