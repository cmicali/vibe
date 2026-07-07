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
            // Synchronous on purpose: the write is small (~10KB) and the
            // back-pressure paces the workers. Async writes pile up on
            // PINDiskCache's serial queue and stall the workers' next
            // objectForKey: behind the backlog.
            [_metadataCache setObject:track.metadata forKey:cacheKey];
        }
    }
    if (track.metadata && !self.isCancelled) {
        // Pre-warm the playlist-cell thumbnail on the worker so the table
        // delegate (main thread) never pays the resize or the JPEG decode.
        // CGImageForProposedRect forces the actual bitmap decode, which is
        // otherwise deferred until the cell first draws (on main).
        [track.metadata.thumbnailAlbumArt CGImageForProposedRect:NULL context:nil hints:nil];
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

@interface AudioTrackMetadataCache ()
// Atomic: created asynchronously at utility QoS, read from the main thread.
@property (atomic, strong) PINCache *metadataCache;
@end

@implementation AudioTrackMetadataCache {
    AudioTrackMetadataLoader*   _currentLoader;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentLoader = nil;
        // Create the cache at utility QoS: constructing it on the main
        // thread boosts PINCache's internal init-time disk scan to
        // user-initiated, which then priority-inverts against the utility
        // worker ops (Thread Performance Checker warning at first drop).
        // Metadata loading starts well after init (deferred until playback
        // begins), so the cache is always ready by first use; the loader
        // tolerates a nil cache regardless.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            // v3: archives only the JPEG thumbnail + scalar fields
            // (~10KB/track). Earlier formats stored art at original size,
            // which overflowed the byte limit and turned every launch into a
            // full library re-parse.
            PINCache *cache = [[PINCache alloc] initWithName:@"Audio Track Metadata v3"];
            cache.diskCache.byteLimit = 64 * 1024 * 1024;
            cache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
            // Objects are stored without cost tracking, so costLimit would be
            // a no-op; an age limit keeps idle entries from pinning memory.
            cache.memoryCache.ageLimit = 60 * 60; // 1 hour
            if (!METADATA_CACHE_ENABLED) {
                [cache removeAllObjects];
            }
            self.metadataCache = cache;
        });
    }
    return self;
}

-(void) invalidate {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self.metadataCache removeAllObjects];
    });
}

-(void)loadMetadata:(NSArray<AudioTrack*>*)tracks {
    [_currentLoader cancel];
    if (!tracks.count) {
        return;
    }
    AudioTrackMetadataLoader* loader = [[AudioTrackMetadataLoader alloc] initWithCache:self.metadataCache delegate:self.delegate];
    _currentLoader = loader;
    [loader load:tracks];
}


@end
