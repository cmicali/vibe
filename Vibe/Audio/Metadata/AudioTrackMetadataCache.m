//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadataCache.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"

#define METADATA_CACHE_ENABELD 1

@interface AudioTrackMetadataLoader : NSObject

@property (atomic) BOOL isFinished;
@property (atomic) BOOL isCancelled;
@property (nullable, weak) id <AudioTrackMetadataManagerDelegate> delegate;

- (id)initWithCache:(PINCache *)cache delegate:(id <AudioTrackMetadataManagerDelegate>)delegate;
- (void)cancel;

@end

@implementation AudioTrackMetadataLoader {
    PINCache* _metadataCache;
}

- (id)initWithCache:(PINCache *)cache delegate:(id <AudioTrackMetadataManagerDelegate>)delegate {
    self = [super init];
    if (self) {
        _isCancelled = NO;
        _isFinished = NO;
        _metadataCache = cache;
        _delegate = delegate;
    }
    return self;
}

- (void)load:(NSArray<AudioTrack*>*)tracks {
    for (NSUInteger i = 0; i < tracks.count && !self.isCancelled; ++i) {
        AudioTrack *track = tracks[i];
        if (!track.metadata) {
            NSString *cacheKey = track.calculateFileHash; // track.url.path;
            AudioTrackMetadata *cachedMetaData;
            if (METADATA_CACHE_ENABELD) {
                cachedMetaData = [_metadataCache objectForKey:cacheKey];
            }
            if (cachedMetaData) {
                track.metadata = cachedMetaData;
            }
            else {
                track.metadata = [AudioTrackMetadata metadataWithURL:track.url];
                if (METADATA_CACHE_ENABELD) {
                    [_metadataCache setObject:track.metadata forKey:cacheKey];
                }
            }
        }
        if (track.metadata && !self.isCancelled) {
            run_on_main_thread({
                [self.delegate didLoadMetadata:track];
            });
        }
    }
    self.isFinished = YES;
}

- (void)cancel {
    self.isCancelled = YES;
}

@end

@implementation AudioTrackMetadataCache {
    dispatch_queue_t            _loaderQueue;
    PINCache*                   _metadataCache;
    AudioTrackMetadataLoader*   _currentLoader;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentLoader  =nil;
        dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_BACKGROUND, 0);
        _loaderQueue = dispatch_queue_create("AudioTrackMetadataCache", queueAttributes);
        _metadataCache = [[PINCache alloc] initWithName:@"Audio Track Metadata"];
        _metadataCache.diskCache.byteLimit = 64 * 1024 * 1024;
        _metadataCache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
        if (!METADATA_CACHE_ENABELD) {
            [self invalidate];
        }
    }
    return self;
}

-(void) invalidate {
    [_metadataCache removeAllObjects];
}

-(void)loadMetadata:(NSArray<AudioTrack*>*)tracks {
    [_currentLoader cancel];
    if (!tracks.count) {
        return;
    }
    AudioTrackMetadataLoader* loader = [[AudioTrackMetadataLoader alloc] initWithCache:_metadataCache delegate:self.delegate];
    _currentLoader = loader;
    dispatch_async(_loaderQueue, ^{
        [loader load:tracks];
    });
}


@end
