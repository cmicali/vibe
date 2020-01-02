//
// Created by Christopher Micali on 12/23/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AudioWaveformCache.h"
#import "BassWrapper.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "NSURL+Hash.h"
#import "BASSAudioWaveformLoader.h"

#pragma mark - Waveform Loader

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

- (AudioWaveform *)load:(NSString *)filename {
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
    if (isnan(result.min)) {
        LogError(@"min is nan");
    }
    if (isnan(result.max)) {
        LogError(@"max is nan");
    }
    return result;
}

@end

#pragma mark - Waveform Cache

@interface AudioWaveformCache () <AudioWaveformLoaderDelegate>
@end

@implementation AudioWaveformCache {
    dispatch_queue_t                _loaderQueue;
    PINCache*                       _waveformCache;
    __weak AudioWaveformLoader*     _currentLoader;
}

- (id)init {
    self = [super init];
    if (self) {
        dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_BACKGROUND, 0);
        _loaderQueue = dispatch_queue_create("AudioWaveformCache", queueAttributes);
        _waveformCache = [[PINCache alloc] initWithName:@"audio_waveform_cache"];
        _waveformCache.diskCache.byteLimit = 64 * 1024 * 1024; // 64mb disk cache limit
        _waveformCache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
        _currentLoader = nil;
        [_waveformCache removeAllObjects];
    }
    return self;
}

- (void)loadWaveformForTrack:(AudioTrack *)track {
    [_currentLoader cancel];
    AudioWaveformLoader *loader = [[BASSAudioWaveformLoader alloc] initWithDelegate:self];
     _currentLoader = loader;
    dispatch_async(_loaderQueue, ^{
        [self load:track withLoader:loader];
    });
}

- (void)load:(AudioTrack *)track withLoader:(AudioWaveformLoader *)loader {
    NSString *cacheKey = track.calculateFileHash;
    AudioWaveform *waveform = [self->_waveformCache objectForKey:cacheKey];
    if (!waveform) {
        waveform = [loader load:track.url.path];
    }
    if (!loader.isCancelled) {
        [self->_waveformCache setObject:waveform forKey:cacheKey];
        run_on_main_thread({
            if (!loader.isCancelled) {
                [self.delegate audioWaveform:waveform didLoadData:1];
            }
        });
    }
}

- (void)audioWaveformLoader:(AudioWaveformLoader*)loader waveform:(AudioWaveform *)waveform didLoadData:(float)percentLoaded {
    [self.delegate audioWaveform:waveform didLoadData:percentLoaded];
}

@end

