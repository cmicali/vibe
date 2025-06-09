//
// Created by Christopher Micali on 1/8/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioWaveform.h"

#define NUM_CHUNKS     4096*2

#define min(a, b) (b < a ? b : a)
#define max(a, b) (a < b ? b : a)

AudioWaveform::AudioWaveform() {
    numChunks = NUM_CHUNKS;
    this->chunks = static_cast<AudioWaveformCacheChunk*>(calloc(this->numChunks, sizeof(AudioWaveformCacheChunk)));
}

AudioWaveform::AudioWaveform(NSUInteger numChunks, const void* chunks) {
    this->numChunks = numChunks;
    this->chunks = static_cast<AudioWaveformCacheChunk*>(calloc(this->numChunks, sizeof(AudioWaveformCacheChunk)));
    memcpy(this->chunks, chunks, this->getNumBytes());
    
}

AudioWaveform::~AudioWaveform() {
    free(this->chunks);
}

AudioWaveformCacheChunk AudioWaveform::getChunkAtIndex(NSUInteger index, NSUInteger size)  {
    AudioWaveformCacheChunk result;
    if (index >= size) return result;
    if (size == numChunks) { return chunks[index]; }
    NSUInteger startIndex = numChunks * index / size;
    NSUInteger numChunksToCombine = static_cast<NSUInteger>(max((float) numChunks / (float) size, 1.0f));
    if (numChunksToCombine == 1) {
        return chunks[startIndex];
    }
    for (NSUInteger i = 0; i < numChunksToCombine; ++i) {
        result.merge(&chunks[startIndex + i]);
    }
    return result;
}

void AudioWaveform::normalize() {
    AudioWaveformCacheChunk total;
    for (NSUInteger i = 0; i < numChunks; i++) {
        AudioWaveformCacheChunk* m = &chunks[i];
        if (m->getMin() < total.getMin()) total.setMin(m);
        if (m->getMax() > total.getMax()) total.setMax(m);
    }
    float factor = fabsf(total.getMin());
    if (fabsf(total.getMin()) > fabsf(total.getMax())) {
        factor = fabsf(total.getMin());
    }
    factor = 1/factor;
    for (NSUInteger i = 0; i < numChunks; i++) {
        AudioWaveformCacheChunk* m = &chunks[i];
        m->setMin(m->getMin() * factor);
        m->setMax(m->getMax() * factor);
    }
}

@implementation CodableAudioWaveform

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:@(self.waveform->getNumChunks()) forKey:@"numChunks"];
    [coder encodeBytes:(const uint8_t*)self.waveform->getBytes() length:self.waveform->getNumBytes() forKey:@"chunks"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        NSUInteger numChunks = [[coder decodeObjectForKey:@"numChunks"] unsignedIntegerValue];
        NSUInteger length;
        const void* data = [coder decodeBytesForKey:@"chunks" returnedLength:&length];
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

@end
