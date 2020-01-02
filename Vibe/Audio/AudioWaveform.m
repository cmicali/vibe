//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioWaveform.h"

#define NUM_WAVEFORM_CHUNKS     512

@interface AudioWaveform ()

@property (strong) NSMutableData* chunks;

@end

@implementation AudioWaveform {
    AudioWaveformCacheChunk zeroedChunk;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.count = NUM_WAVEFORM_CHUNKS;
        ZeroAudioWaveformCacheChunk(zeroedChunk);
        [self setup];
    }
    return self;
}

- (void)setup {
    if (self.chunks) {
        [self.chunks setLength:self.count * sizeof(AudioWaveformCacheChunk)];
    }
    else {
        self.chunks = [NSMutableData dataWithLength:self.count * sizeof(AudioWaveformCacheChunk)];
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        self.count = [[coder decodeObjectForKey:@"numChunks"] unsignedIntegerValue];
        self.chunks = [coder decodeObjectForKey:@"chunks"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:@(self.count) forKey:@"numChunks"];
    [coder encodeObject:self.chunks forKey:@"chunks"];
}

- (AudioWaveformCacheChunk *)chunkAtIndex:(NSUInteger)index {
    if (index >= self.count) {
        return &zeroedChunk;
    }
    AudioWaveformCacheChunk* chunks = [self.chunks mutableBytes];
    return &chunks[index];
}

- (void)setChunk:(AudioWaveformCacheChunk)chunk atIndex:(NSInteger)idx {
    if (idx >= 0 && idx < self.count) {
        AudioWaveformCacheChunk *chunks = [self.chunks mutableBytes];
        chunks[idx] = chunk;
    }
}

- (void)normalize {
    AudioWaveformCacheChunk total;
    total.min = 0;
    total.max = 0;
    AudioWaveformCacheChunk *chunks = [self.chunks mutableBytes];
    for (NSUInteger i = 0; i < self.count; i++) {
        AudioWaveformCacheChunk* m = &chunks[i];
        if (m->min < total.min) total.min = m->min;
        if (m->max > total.max) total.max = m->max;
    }
    float factor = fabsf(total.min);
    if (fabsf(total.min) > fabsf(total.max)) {
        factor = fabsf(total.min);
    }
    factor = 1/factor;
    LogDebug(@"normalize: min: %.4f max: %.4f - adjustment factor: %.4f", total.min, total.max, factor);
    for (NSUInteger i = 0; i < self.count; i++) {
        AudioWaveformCacheChunk* m = &chunks[i];
        m->min = m->min * factor;
        m->max = m->max * factor;
    }
}

@end
