//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

struct AudioWaveformCacheChunk {
    float min;
    float max;
};
typedef struct CG_BOXABLE AudioWaveformCacheChunk AudioWaveformCacheChunk;


#define ZeroAudioWaveformCacheChunk(chunk) chunk.min = 0; chunk.max = 0;
#define ZeroedAudioWaveformCacheChunk(chunk) AudioWaveformCacheChunk chunk; chunk.min = 0; chunk.max = 0;

@interface AudioWaveform : NSObject <NSCoding>

@property (assign) NSUInteger count;

- (AudioWaveformCacheChunk *)chunkAtIndex:(NSUInteger)index;

- (AudioWaveformCacheChunk)chunksAtIndex:(NSUInteger)index numChunks:(NSUInteger)size;

- (void)setChunk:(AudioWaveformCacheChunk)chunk atIndex:(NSInteger)idx;

+ (AudioWaveformCacheChunk *)emptyChunk;

@end
