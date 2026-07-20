//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import "AudioTrackMetadataCache.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "NSURLUtil.h"

@interface AudioTrackMetadataCache ()
// Atomic: created asynchronously at utility QoS, read from the loader's
// worker threads (and re-read per track — see loadTrackFromDiskCache: /
// parseOneTrack:).
@property (atomic, strong) PINCache *metadataCache;
@end

@interface AudioTrackMetadataLoader : NSObject

@property (atomic) BOOL isCancelled;
@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;

- (id)initWithOwner:(AudioTrackMetadataCache *)owner
           delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
       priorityLane:(BOOL)priorityLane;
- (void)cancel;

@end

@implementation AudioTrackMetadataLoader {
    // Weak (the owner strongly holds its current loader) and re-read at use
    // time rather than snapshotted: the owner constructs its PINCache
    // asynchronously, and a snapshot taken too early would freeze a nil cache
    // for this loader's lifetime — zero reads and writes, silently.
    __weak AudioTrackMetadataCache* _owner;
    NSOperationQueue* _queue;
    // Tracks this loader has queued (identity set). Deliberately its own
    // per-loader marker rather than inferring queued-ness from non-nil
    // track.metadata: a failed parse (parsedOK == NO) must stay eligible for
    // a re-parse by a later loader — the file may have downloaded since.
    // Main thread only (load: and loadSingleTrack: run on the caller's
    // thread — always main — and the priority lane's completion removal is
    // dispatched to main), so no locking is needed.
    NSMutableSet<AudioTrack *>* _queuedTracks;
}

- (id)initWithOwner:(AudioTrackMetadataCache *)owner
           delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
       priorityLane:(BOOL)priorityLane {
    self = [super init];
    if (self) {
        _isCancelled = NO;
        _owner = owner;
        _queuedTracks = [NSMutableSet set];
        _delegate = delegate;
        _queue = [[NSOperationQueue alloc] init];
        if (priorityLane) {
            // The current-track lane (loadSingleTrack:): only the newest
            // request is user-visible, so the width exists purely to absorb
            // blocked predecessors. Dataless placeholders never parse inline,
            // but a slow-but-materialized file (network mount, sleeping disk)
            // can block a worker for minutes — width 4 means it takes four
            // consecutive wedged opens before the header's load queues behind
            // one, at the cost of one stranded thread each. User-initiated:
            // the user is looking at a header that's waiting on this exact
            // load.
            _queue.name = @"AudioTrackMetadataLoader.priority";
            _queue.maxConcurrentOperationCount = 4;
            _queue.qualityOfService = NSQualityOfServiceUserInitiated;
        }
        else {
            // Concurrency 4 lets a single slow file (network mount, sleeping disk)
            // stall only its own worker rather than the whole playlist. Utility QoS
            // is the right band: user-visible (we drive the playlist UI) but not
            // user-initiated.
            _queue.name = @"AudioTrackMetadataLoader";
            _queue.maxConcurrentOperationCount = 4;
            _queue.qualityOfService = NSQualityOfServiceUtility;
        }
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
        // Stage 1 of the two-stage scan: the cache check (a stat + small
        // disk read — never the audio data, so a dataless cloud placeholder
        // can't block it on a download). High priority makes the whole cache
        // sweep drain before ANY parse gets a worker: every previously-seen
        // track's row populates at disk speed even when the playlist is
        // mostly slow cloud files. Misses re-enqueue as stage-2 parse ops at
        // Normal/Low — see cacheCheckOneTrack:.
        NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.isCancelled) return;
            [strongSelf cacheCheckOneTrack:track];
        }];
        op.queuePriority = NSOperationQueuePriorityHigh;
        [_queue addOperation:op];
    }
}

// Stage-1 worker: publish from the disk cache, or hand off to a stage-2
// parse op. Local files parse ahead of dataless placeholders: a placeholder
// read blocks until the provider materializes the file, and a cloud-heavy
// folder would otherwise pin all four workers for a download's duration
// while fast local parses sit queued behind them.
- (void)cacheCheckOneTrack:(AudioTrack *)track {
    // A track can be re-queued by a second drop before its first op runs;
    // if the earlier loader already produced real metadata, skip the
    // redundant work. Failed (parsedOK == NO) metadata does NOT count as
    // done — re-parsing it is the whole point of the re-queue.
    if (track.metadata.parsedOK) {
        return;
    }
    if ([self loadTrackFromDiskCache:track]) {
        return;
    }
    if (self.isCancelled) {
        return;
    }
    __weak __typeof(self) weakSelf = self;
    NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) return;
        [strongSelf parseOneTrack:track];
    }];
    op.queuePriority = [NSURLUtil isDatalessFile:track.url]
            ? NSOperationQueuePriorityLow : NSOperationQueuePriorityNormal;
    [_queue addOperation:op];
}

// The current-track jump-the-queue lane (priority loaders only — see
// -[AudioTrackMetadataCache loadMetadataNow:]). A cache hit publishes
// immediately; a miss parses inline UNLESS the file is still a dataless
// placeholder — the player's own open is already materializing that same
// file, so blocking a lane worker on the download buys nothing, and the
// didStartPlaying-driven call retries once it's local. Unlike the scan
// loader's keep-forever set, _queuedTracks here marks only in-flight tracks
// (removed on completion, on main) so a later re-click can retry a failed
// parse.
- (void)loadSingleTrack:(AudioTrack *)track {
    if (track.metadata.parsedOK) {
        return;
    }
    if ([_queuedTracks containsObject:track]) {
        return;
    }
    [_queuedTracks addObject:track];
    __weak __typeof(self) weakSelf = self;
    [_queue addOperationWithBlock:^{
        __typeof(self) strongSelf = weakSelf;
        if (strongSelf && !strongSelf.isCancelled
                && ![strongSelf loadTrackFromDiskCache:track]
                && ![NSURLUtil isDatalessFile:track.url]) {
            [strongSelf parseOneTrack:track];
        }
        run_on_main_thread({
            [weakSelf clearInFlightTrack:track];
        });
    }];
}

- (void)clearInFlightTrack:(AudioTrack *)track {
    [_queuedTracks removeObject:track];
}

// Disk-cache attempt: returns YES on a hit, with the metadata set on the
// track and published. Deliberately touches only file attributes and the
// cache store, never the audio data — both lanes rely on this staying fast
// for dataless cloud files.
- (BOOL)loadTrackFromDiskCache:(AudioTrack *)track {
    // nil when the file can't be statted (see NSURL+Hash): no stable
    // identity, so no cache read. The stage-2 parse still runs; an unreadable
    // file degrades to the filename-only fallback (parsedOK == NO).
    NSString *cacheKey = track.cacheKey;
    if (!cacheKey) {
        LogWarn(@"No cache key for %@ — loading metadata uncached", track.url.path);
        return NO;
    }
    // Re-read at use time (see _owner): nil just means not constructed yet —
    // the earliest tracks parse uncached instead of the whole playlist.
    PINCache *metadataCache = _owner.metadataCache;
    if (!metadataCache) {
        LogWarn(@"Metadata cache not yet available — loading %@ uncached", track.url.path);
        return NO;
    }
    // Read through the disk cache directly, bypassing PINMemoryCache: on
    // macOS the memory cache never evicts (its pressure hooks are iOS-only
    // and disk hits repopulate it at cost 0), so every track ever loaded —
    // decoded thumbnail included — would stay pinned for the age limit even
    // after its playlist is gone. The playlist's AudioTrack objects retain
    // the live metadata; a re-drop pays a ~10KB unarchive per track.
    AudioTrackMetadata *cachedMetaData = (AudioTrackMetadata *)[metadataCache.diskCache objectForKey:cacheKey];
    // PINCache unarchives without secure coding, so a tampered entry with a
    // different root class decodes cleanly and bypasses initWithCoder:'s
    // field validation entirely. A wrong-class object would crash on first
    // use (unrecognized selector) on every launch — evict it instead.
    if (cachedMetaData && ![cachedMetaData isKindOfClass:[AudioTrackMetadata class]]) {
        [metadataCache.diskCache removeObjectForKey:cacheKey];
        cachedMetaData = nil;
    }
    if (!cachedMetaData) {
        return NO;
    }
    // Pre-warm the playlist-cell thumbnail BEFORE publishing the metadata:
    // the table delegate (main thread) reads thumbnailAlbumArt as soon as
    // the metadata is visible, and publishing first would open a window
    // where a redraw pays the ImageIO decode on main. The getter is the whole
    // warm-up: it decodes eagerly (VibeDecodeImageData passes
    // kCGImageSourceShouldCacheImmediately), so the bitmap is ready the
    // moment the image object exists.
    (void)cachedMetaData.thumbnailAlbumArt;
    // Pairs with parseOneTrack's guarded store: this unconditional store
    // (cached entries are always parsedOK) must not interleave inside that
    // check-then-act.
    @synchronized (track) {
        track.metadata = cachedMetaData;
    }
    [self publishTrack:track];
    return YES;
}

// Stage-2 worker: the TagLib parse (opens the audio file — this is the call
// that can block for a download's duration on a cloud placeholder).
- (void)parseOneTrack:(AudioTrack *)track {
    // Re-checked at parse time: the priority lane (or an earlier loader) may
    // have produced real metadata while this op sat queued.
    if (track.metadata.parsedOK) {
        return;
    }
    // A stale loader (cancelled when a new playlist replaced this one)
    // must not keep parsing discarded tracks and issuing synchronous cache
    // writes that the live loader's objectForKey: reads then queue behind.
    if (self.isCancelled) {
        return;
    }
    AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:track.url];
    // Decode the thumbnail before the metadata becomes visible to the
    // main thread (see loadTrackFromDiskCache: — the getter itself is the
    // warm-up).
    (void)metadata.thumbnailAlbumArt;
    // Never clobber real metadata with a failed parse: a cancelled loader's
    // op can still be mid-parse when this loader re-parses successfully, and
    // last-writer-wins would reinstate the filename-only fallback. The
    // monitor spans the check AND the store — unguarded, it's the same race
    // one interleave later.
    @synchronized (track) {
        if (metadata.parsedOK || !track.metadata.parsedOK) {
            track.metadata = metadata;
        }
    }
    // cacheKey re-read here (memoized on the track): a transient stat
    // failure at cache-check time may have healed by end of parse.
    NSString *cacheKey = track.cacheKey;
    if (metadata.parsedOK && cacheKey && !self.isCancelled) {
        // Skip failed parses (dataless cloud file, transient I/O error):
        // caching the filename-only fallback would shadow the real tags
        // until the size+mtime cache key changes (up to the 6-month limit).
        // Synchronous on purpose: the write is small (~10KB) and the
        // back-pressure paces the workers. Async writes pile up on
        // PINDiskCache's serial queue and stall the workers' next
        // objectForKey: behind the backlog.
        // Fresh re-read: the cache may have finished constructing during
        // the parse above (nil no-ops harmlessly if not).
        [_owner.metadataCache.diskCache setObject:metadata forKey:cacheKey];
    }
    [self publishTrack:track];
}

- (void)publishTrack:(AudioTrack *)track {
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

@implementation AudioTrackMetadataCache {
    AudioTrackMetadataLoader*   _currentLoader;
    // The current-track lane (loadMetadataNow:). Lives for the cache's
    // lifetime and is never cancelled — unlike the scan loaders, its work is
    // per-track and a stale publish is harmless (the delegate's
    // reloadTrack:/currentTrack checks drop deliveries for departed tracks).
    AudioTrackMetadataLoader*   _priorityLoader;
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
        // Metadata loading usually starts well after init (deferred until
        // playback begins), but a launch-by-double-click can beat this block;
        // the loader re-reads the property at each use.
        dispatch_async(_cacheQueue, ^{
            // The name embeds the archive-format version — bump it whenever
            // the archived fields or their meaning change (e.g. fileType
            // labeling), since stale entries otherwise persist until the
            // size+mtime cache key changes (up to the age limit).
            PINCache *cache = [[PINCache alloc] initWithName:@"Audio Track Metadata v4"];
            cache.diskCache.byteLimit = 64 * 1024 * 1024;
            cache.diskCache.ageLimit = 6 * (30 * (24 * 60 * 60)); // 6 months
            // The memory cache is deliberately unused (the loaders read and
            // write diskCache directly): on macOS PINMemoryCache never evicts
            // — costLimit needs per-entry costs (and disk hits repopulate at
            // cost 0) and its memory-pressure hooks are iOS-only — so it would
            // pin every loaded track's metadata + thumbnail indefinitely.
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
    AudioTrackMetadataLoader* loader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                              delegate:self.delegate
                                                                          priorityLane:NO];
    _currentLoader = loader;
    [loader load:tracks];
}

- (void)loadMetadataNow:(AudioTrack *)track {
    if (!track || track.metadata.parsedOK) {
        return;
    }
    if (!_priorityLoader) {
        _priorityLoader = [[AudioTrackMetadataLoader alloc] initWithOwner:self
                                                                 delegate:self.delegate
                                                             priorityLane:YES];
    }
    // The scan loaders snapshot the delegate per loadMetadata:; the long-lived
    // priority loader refreshes it per call instead.
    _priorityLoader.delegate = self.delegate;
    [_priorityLoader loadSingleTrack:track];
}


@end
