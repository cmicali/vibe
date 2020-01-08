//
// Created by Christopher Micali on 1/2/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioWaveformLoader.h"
#import "AudioWaveformCache.h"


@implementation AudioWaveformLoader

- (instancetype)initWithDelegate:(id <AudioWaveformLoaderDelegate>)delegate {
    self = [super init];
    if (self) {
        self.isCancelled = NO;
        self.isFinished = NO;
        self.delegate = delegate;
    }
    return self;
}

- (BOOL)isDone {
    return self.isFinished || self.isCancelled;
}

- (BOOL)cancel {
    if (self.isDone) {
        return YES;
    }
    self.isCancelled = YES;
    return NO;
}

- (AudioWaveformOld *)load:(NSString *)filename {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:[NSString stringWithFormat:@"You must override %@ in a subclass", NSStringFromSelector(_cmd)]
                                 userInfo:nil];
}

- (AudioWaveformCacheChunk)getChunkForAudioBuffer:(float *)buffer
                                           length:(NSUInteger)length
                                      numChannels:(NSUInteger)channels {
    ZeroedAudioWaveformCacheChunk(result);
    NSUInteger i = 0;
    while (i < length && !self.isCancelled) {
        float value = 0;
        for (int j = 0; j < channels; j++) {
            value = value + buffer[i];
            i++;
        }
        value /= channels;
        if (value > 2 || value < -2) {
//            LogDebug(@"Value out of range: %.4f i: %d", value, i);
        }
        else {
            if (value < result.min) result.min = value;
            if (value > result.max) result.max = value;
        }
    }
    return result;
}
//
//- (AudioWaveformCacheChunk)getChunkForAudioBuffer:(float *)buffer
//                                           length:(NSUInteger)length
//                                      numChannels:(NSUInteger)channels {
//    ZeroedAudioWaveformCacheChunk(result);
//    NSUInteger i = 0;
//    double min = 0;
//    double max = 0;
//    while (i < length && !self.isCancelled) {
//        float value = 0;
//        for (int j = 0; j < channels; j++) {
//            value = value + buffer[i];
//            i++;
//        }
////        value /= channels;
//        if (value > 0) {
//            max += value;
//        }
//        else {
//            min += value;
//        }
//    }
//    result.min = 4 * (float) (min / (length/channels));
//    result.max = 4 * (float) (max / (length/channels));
//    return result;
//}

@end
