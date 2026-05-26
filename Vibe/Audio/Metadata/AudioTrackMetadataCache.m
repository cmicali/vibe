//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadataCache.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"

#define METADATA_CACHE_ENABLED 1

@interface AudioTrackMetadataLoader : NSObject

@property (atomic) BOOL isFinished;
@property (atomic) BOOL isCancelled;
@property (nullable, weak) id <AudioTrackMetadataManagerDelegate> delegate;

- (id)initWithCache:(PINCache *)cache delegate:(id <AudioTrackMetadataManagerDelegate>)delegate;
- (void)cancel;

@end

@implementation AudioTrackMetadataLoader {
    PINCache* _metadataCache;
    NSOperationQueue* _queue;
}

- (id)initWithCache:(PINCache *)cache delegate:(id <AudioTrackMetadataManagerDelegate>)delegate {
    self = [super init];
    if (self) {
        _isCancelled = NO;
        _isFinished = NO;
        _metadataCache = cache;
        _delegate = delegate;
        // Concurrency 4 lets a single slow file (network mount, sleeping disk)
        // stall only its own worker rather than the whole playlist. Utility QoS
        // is the right band: user-visible (we drive the playlist UI) but not
        // user-initiated.
        _queue = [[NSOperationQueue alloc] init];
        _queue.name = @"AudioTrackMetadataLoader";
        _queue.maxConcurrentOperationCount = 4;
        _queue.qualityOfService = NSQualityOfServiceUtility;
    }
    return self;
}

- (void)load:(NSArray<AudioTrack*>*)tracks {
    __weak __typeof(self) weakSelf = self;
    for (AudioTrack *track in tracks) {
        if (self.isCancelled) break;
        if (track.metadata) continue;  // already loaded earlier
        [_queue addOperationWithBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.isCancelled) return;
            [strongSelf loadOneTrack:track];
        }];
    }
}

- (void)loadOneTrack:(AudioTrack *)track {
    NSString *cacheKey = track.cacheKey;
    AudioTrackMetadata *cachedMetaData = nil;
    if (METADATA_CACHE_ENABLED) {
        cachedMetaData = [_metadataCache objectForKey:cacheKey];
    }
    if (cachedMetaData) {
        track.metadata = cachedMetaData;
    } else {
        track.metadata = [AudioTrackMetadata metadataWithURL:track.url];
        if (METADATA_CACHE_ENABLED && track.metadata) {
            [_metadataCache setObject:track.metadata forKey:cacheKey];
        }
    }
    if (track.metadata && !self.isCancelled) {
        // Pre-warm the playlist-cell thumbnail on the worker so the table
        // delegate (main thread) never has to do the resize itself.
        (void)track.metadata.thumbnailAlbumArt;
        run_on_main_thread({
            if (!self.isCancelled) {
                [self.delegate didLoadMetadata:track];
            }
        });
    }
}

- (void)cancel {
    self.isCancelled = YES;
    [_queue cancelAllOperations];
}

@end

@implementation AudioTrackMetadataCache {
    PINCache*                   _metadataCache;
    AudioTrackMetadataLoader*   _currentLoader;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentLoader = nil;
        _metadataCache = [[PINCache alloc] initWithName:@"Audio Track Metadata"];
        _metadataCache.diskCache.byteLimit = 64 * 1024 * 1024;
        _metadataCache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
        if (!METADATA_CACHE_ENABLED) {
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
    [loader load:tracks];
}


@end
