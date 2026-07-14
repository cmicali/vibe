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

@property (atomic) BOOL isCancelled;
@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;

- (id)initWithCache:(PINCache *)cache delegate:(id <AudioTrackMetadataCacheDelegate>)delegate;
- (void)cancel;

@end

@implementation AudioTrackMetadataLoader {
    PINCache* _metadataCache;
    NSOperationQueue* _queue;
    // Tracks this loader has queued (identity set). track.metadata being
    // non-nil used to double as the "already queued" marker, but a failed
    // parse (parsedOK == NO) must stay eligible for a re-parse by a later
    // loader — the file may have downloaded since — so queued-ness gets its
    // own, per-loader marker. Only touched from load: (a single pass on the
    // caller's thread), so no locking is needed.
    NSMutableSet<AudioTrack *>* _queuedTracks;
}

- (id)initWithCache:(PINCache *)cache delegate:(id <AudioTrackMetadataCacheDelegate>)delegate {
    self = [super init];
    if (self) {
        _isCancelled = NO;
        _metadataCache = cache;
        _queuedTracks = [NSMutableSet set];
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
        // Skip only tracks with real metadata. A failed parse (parsedOK ==
        // NO: dataless cloud placeholder, transient I/O error) stays
        // eligible — the file may be readable by the time the playlist is
        // re-queued, and the filename-only fallback would otherwise stick
        // until app restart. (Messaging nil metadata returns NO, so
        // never-parsed tracks pass through too.)
        if (track.metadata.parsedOK) continue;
        // A track appearing twice in the array must not parse twice.
        if ([_queuedTracks containsObject:track]) continue;
        [_queuedTracks addObject:track];
        [_queue addOperationWithBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.isCancelled) return;
            [strongSelf loadOneTrack:track];
        }];
    }
}

- (void)loadOneTrack:(AudioTrack *)track {
    // A track can be re-queued by a second drop before its first op runs;
    // if the earlier loader already produced real metadata, skip the
    // redundant parse. Failed (parsedOK == NO) metadata does NOT count as
    // done — re-parsing it is the whole point of the re-queue.
    if (track.metadata.parsedOK) {
        return;
    }
    NSString *cacheKey = track.cacheKey;
    AudioTrackMetadata *cachedMetaData = nil;
    if (METADATA_CACHE_ENABLED) {
        // Read through the disk cache directly, bypassing PINMemoryCache: on
        // macOS the memory cache never evicts (its pressure hooks are iOS-only
        // and disk hits repopulate it at cost 0), so every track ever loaded —
        // decoded thumbnail included — would stay pinned for the age limit even
        // after its playlist is gone. The playlist's AudioTrack objects retain
        // the live metadata; a re-drop pays a ~10KB unarchive per track.
        cachedMetaData = (AudioTrackMetadata *)[_metadataCache.diskCache objectForKey:cacheKey];
        // PINCache unarchives without secure coding, so a tampered entry with a
        // different root class decodes cleanly and bypasses initWithCoder:'s
        // field validation entirely. A wrong-class object would crash on first
        // use (unrecognized selector) on every launch — evict it instead.
        if (cachedMetaData && ![cachedMetaData isKindOfClass:[AudioTrackMetadata class]]) {
            [_metadataCache.diskCache removeObjectForKey:cacheKey];
            cachedMetaData = nil;
        }
    }
    if (cachedMetaData) {
        // Pre-warm the playlist-cell thumbnail BEFORE publishing the metadata:
        // the table delegate (main thread) reads thumbnailAlbumArt as soon as
        // the metadata is visible, and publishing first opened a window where
        // a redraw paid the ImageIO decode on main. CGImageForProposedRect
        // forces the actual bitmap decode, which is otherwise deferred until
        // the cell first draws (on main).
        [cachedMetaData.thumbnailAlbumArt CGImageForProposedRect:NULL context:nil hints:nil];
        track.metadata = cachedMetaData;
    } else {
        // A stale loader (cancelled when a new playlist replaced this one)
        // must not keep parsing discarded tracks and issuing synchronous cache
        // writes that the live loader's objectForKey: reads then queue behind.
        if (self.isCancelled) {
            return;
        }
        AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:track.url];
        // Decode the thumbnail before the metadata becomes visible to the
        // main thread (see the cache-hit branch above).
        [metadata.thumbnailAlbumArt CGImageForProposedRect:NULL context:nil hints:nil];
        // Never clobber real metadata with a failed parse: a cancelled
        // loader's op can still be mid-parse (having opened the file while it
        // was dataless) when this loader re-parses it successfully; last-
        // writer-wins would reinstate the filename-only fallback.
        if (metadata.parsedOK || !track.metadata.parsedOK) {
            track.metadata = metadata;
        }
        if (METADATA_CACHE_ENABLED && metadata.parsedOK && !self.isCancelled) {
            // Skip failed parses (dataless cloud file, transient I/O error):
            // caching the filename-only fallback would shadow the real tags
            // until the size+mtime cache key changes (up to the 6-month limit).
            // Synchronous on purpose: the write is small (~10KB) and the
            // back-pressure paces the workers. Async writes pile up on
            // PINDiskCache's serial queue and stall the workers' next
            // objectForKey: behind the backlog.
            [_metadataCache.diskCache setObject:metadata forKey:cacheKey];
        }
    }
    if (track.metadata && !self.isCancelled) {
        // The thumbnail was pre-warmed before publish — drop the full-size art
        // bytes so a large first import doesn't pin hundreds of MB. Cache-hit
        // instances never carried them; freshly parsed ones now match that
        // (re-read on demand for the one track shown full-res).
        [track.metadata discardAlbumArtData];
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
    // Exists only to construct the cache off the main thread at utility QoS
    // (see init).
    dispatch_queue_t            _cacheQueue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentLoader = nil;
        _cacheQueue = dispatch_queue_create("com.vibe.metadatacache",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        // Create the cache at utility QoS: constructing it on the main
        // thread boosts PINCache's internal init-time disk scan to
        // user-initiated, which then priority-inverts against the utility
        // worker ops (Thread Performance Checker warning at first drop).
        // Metadata loading starts well after init (deferred until playback
        // begins), so the cache is always ready by first use; the loader
        // tolerates a nil cache regardless.
        dispatch_async(_cacheQueue, ^{
            // v3: archives only the JPEG thumbnail + scalar fields
            // (~10KB/track). Earlier formats stored art at original size,
            // which overflowed the byte limit and turned every launch into a
            // full library re-parse.
            PINCache *cache = [[PINCache alloc] initWithName:@"Audio Track Metadata v3"];
            cache.diskCache.byteLimit = 64 * 1024 * 1024;
            cache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
            // The memory cache is deliberately unused (loadOneTrack reads and
            // writes diskCache directly): on macOS PINMemoryCache never evicts
            // — costLimit needs per-entry costs (and disk hits repopulate at
            // cost 0) and its memory-pressure hooks are iOS-only — so it would
            // pin every loaded track's metadata + thumbnail indefinitely.
            if (!METADATA_CACHE_ENABLED) {
                [cache removeAllObjects];
            }
            self.metadataCache = cache;
        });
    }
    return self;
}

- (void)invalidateWithCompletion:(dispatch_block_t)completion {
    // Serial queue: runs after the deferred cache construction in init, so
    // self.metadataCache is always set by the time this block executes.
    dispatch_async(_cacheQueue, ^{
        [self.metadataCache removeAllObjects];
        if (completion) {
            completion();
        }
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
