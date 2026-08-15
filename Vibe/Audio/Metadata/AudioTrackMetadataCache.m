//
// Created by Christopher Micali on 1/1/20.
// Copyright (c) 2020 Christopher Micali. All rights reserved.
//

#import <stdatomic.h>

#import "AudioTrackMetadataCache.h"
#import "PINCache.h"
#import "PINCache+VibeAudioCache.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "MetadataParseCoordinator.h"
#import "MetadataParseFlow.h"
#import "NSURLUtil.h"

@interface AudioTrackMetadataCache ()
// Atomic, because it is created asynchronously at utility QoS and read from
// the loader's worker threads, and re-read per track; see
// loadTrackFromDiskCache: and parseOneTrack:.
@property (atomic, strong) PINCache *metadataCache;
// The invalidation generation; see the waveform cache's _cacheGeneration for
// the full contract. A parse captures it when it starts, skips its disk write
// if it has moved, and re-checks after the write lands — otherwise a parse in
// flight during Settings > Clear Cache would repopulate the emptied cache.
- (uint64_t)cacheGeneration;
// The cross-lane parse claims, keyed on the file URL rather than the track
// object, because the same file can occupy several playlist rows as distinct
// AudioTracks. The scan's stage-2 op and the priority lane can both pass their
// parsedOK entry checks before either finishes, as on a folder drop with
// auto-play, paying for the full TagLib parse, thumbnail decode and disk write
// twice for the same file. One holder and its weak duplicate-row waiters per
// URL; every loader shares this one, through its own MetadataParseFlow.
@property (nonatomic, readonly) MetadataParseCoordinator<AudioTrack *> *parseCoordinator;
@end

@interface AudioTrackMetadataLoader : NSObject <MetadataParseFlowDelegate>

@property (atomic) BOOL isCancelled;
@property (nullable, weak) id <AudioTrackMetadataCacheDelegate> delegate;

- (id)initWithOwner:(AudioTrackMetadataCache *)owner
           delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
       priorityLane:(BOOL)priorityLane;
- (void)cancel;

@end

@implementation AudioTrackMetadataLoader {
    // Weak, since the owner strongly holds its current loader, and re-read at
    // use time rather than snapshotted. The owner constructs its PINCache
    // asynchronously, and a snapshot taken too early would freeze a nil cache
    // for this loader's lifetime: zero reads and writes, silently.
    __weak AudioTrackMetadataCache* _owner;
    NSOperationQueue* _queue;
    // An identity set of the tracks this loader has queued. It is deliberately
    // its own per-loader marker rather than an inference from non-nil
    // track.metadata, because a failed parse, with parsedOK == NO, must stay
    // eligible for a re-parse by a later loader: the file may have downloaded
    // since. Either way it lives in a single context and needs no locking.
    // Scan loaders touch it only inside load:'s one setup op, and the priority
    // lane touches it only on main, since loadSingleTrack: runs on the caller's
    // thread, always main, and the completion removal is dispatched to main.
    NSMutableSet<AudioTrack *>* _queuedTracks;
    // The parse ordering, over the owner's shared coordinator. Held strongly,
    // and it holds this loader weakly back.
    MetadataParseFlow* _parseFlow;
}

- (id)initWithOwner:(AudioTrackMetadataCache *)owner
           delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
       priorityLane:(BOOL)priorityLane {
    self = [super init];
    if (self) {
        _isCancelled = NO;
        _owner = owner;
        _queuedTracks = [NSMutableSet set];
        _parseFlow = [[MetadataParseFlow alloc] initWithCoordinator:owner.parseCoordinator
                                                           delegate:self];
        _delegate = delegate;
        _queue = [[NSOperationQueue alloc] init];
        if (priorityLane) {
            // The current-track lane, loadSingleTrack:. Only the newest
            // request is user-visible, so the width exists purely to absorb
            // blocked predecessors. Dataless placeholders never parse inline,
            // but a slow yet materialized file, on a network mount or a
            // sleeping disk, can block a worker for minutes. A width of 4
            // means it takes four consecutive wedged opens before the header's
            // load queues behind one, at the cost of one stranded thread each.
            // The QoS is user-initiated because the user is looking at a
            // header waiting on this exact load.
            _queue.name = @"AudioTrackMetadataLoader.priority";
            _queue.maxConcurrentOperationCount = 4;
            _queue.qualityOfService = NSQualityOfServiceUserInitiated;
        }
        else {
            // A concurrency of 4 lets a single slow file, on a network mount
            // or a sleeping disk, stall only its own worker rather than the
            // whole playlist. Utility is the right QoS band: the work is
            // user-visible, since it drives the playlist UI, but not
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
    // One setup op, rather than a per-track loop on the caller's main thread.
    // A drop of several thousand tracks would otherwise pay for thousands of
    // NSBlockOperation allocations and addOperation: locks in one main-thread
    // burst. It runs at high priority so that the sweep still starts ahead of
    // any queued stage-2 parses.
    NSOperation *setup = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) setupSelf = weakSelf;
        if (!setupSelf) return;
        for (AudioTrack *track in tracks) {
            if (setupSelf.isCancelled) break;
            // Skip only tracks with real metadata. A failed parse, where
            // parsedOK is NO because of a dataless cloud placeholder or a
            // transient I/O error, stays eligible: the file may be readable by
            // the time the playlist is re-queued, and the filename-only
            // fallback would otherwise stick until the app restarts. Messaging
            // nil metadata returns NO, so never-parsed tracks pass through too.
            if (track.metadata.parsedOK) continue;
            // A track appearing twice in the array must not parse twice.
            if ([setupSelf->_queuedTracks containsObject:track]) continue;
            [setupSelf->_queuedTracks addObject:track];
            // Stage 1 of the two-stage scan: the cache check, a stat and a
            // small disk read, never the audio data, so a dataless cloud
            // placeholder cannot block it on a download. High priority makes
            // the whole cache sweep drain before any parse gets a worker, so
            // every previously seen track's row populates at disk speed even
            // when the playlist is mostly slow cloud files. Misses re-enqueue
            // as stage-2 parse ops at normal or low priority; see
            // cacheCheckOneTrack:.
            NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
                __typeof(self) strongSelf = weakSelf;
                if (!strongSelf || strongSelf.isCancelled) return;
                [strongSelf cacheCheckOneTrack:track];
            }];
            op.queuePriority = NSOperationQueuePriorityHigh;
            [setupSelf->_queue addOperation:op];
        }
    }];
    setup.queuePriority = NSOperationQueuePriorityHigh;
    [_queue addOperation:setup];
}

// The stage-1 worker: publish from the disk cache, or hand off to a stage-2
// parse op. Local files parse ahead of dataless placeholders, because a
// placeholder read blocks until the provider materializes the file, and a
// cloud-heavy folder would otherwise pin all four workers for a download's
// duration while fast local parses sat queued behind them.
- (void)cacheCheckOneTrack:(AudioTrack *)track {
    // A second drop can re-queue a track before its first op runs, so skip the
    // redundant work if the earlier loader already produced real metadata.
    // Failed metadata, with parsedOK == NO, does not count as done: re-parsing
    // it is the whole point of the re-queue.
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

// The current-track jump-the-queue lane, for priority loaders only; see
// -[AudioTrackMetadataCache loadMetadataNow:]. A cache hit publishes
// immediately. A miss parses inline unless the file is still a dataless
// placeholder: the player's own open is already materializing that same file,
// so blocking a lane worker on the download buys nothing, and the
// didStartPlaying-driven call retries once it is local. Unlike the scan
// loader's keep-forever set, _queuedTracks here marks only in-flight tracks,
// removed on completion on main, so a later re-click can retry a failed parse.
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

// A disk-cache attempt. It returns YES on a hit, with the metadata set on the
// track and published. It deliberately touches only file attributes and the
// cache store, never the audio data, because both lanes rely on it staying
// fast for dataless cloud files.
- (BOOL)loadTrackFromDiskCache:(AudioTrack *)track {
    // nil when the file cannot be statted; see NSURL+Hash. Without a stable
    // identity there is no cache read. The stage-2 parse still runs, and an
    // unreadable file degrades to the filename-only fallback, parsedOK == NO.
    NSString *cacheKey = track.cacheKey;
    if (!cacheKey) {
        LogWarn(@"No cache key for %@ — loading metadata uncached", track.url.path);
        return NO;
    }
    // Re-read at use time; see _owner. nil merely means not yet constructed,
    // so the earliest tracks parse uncached rather than the whole playlist.
    PINCache *metadataCache = _owner.metadataCache;
    if (!metadataCache) {
        LogWarn(@"Metadata cache not yet available — loading %@ uncached", track.url.path);
        return NO;
    }
    // Read the disk cache directly, bypassing PINMemoryCache. On macOS the
    // memory cache never evicts, since its pressure hooks are iOS-only and
    // disk hits repopulate it at cost 0, so every track ever loaded — decoded
    // thumbnail included — would stay pinned for the age limit even after its
    // playlist was gone. The playlist's AudioTrack objects retain the live
    // metadata, and a re-drop pays about a 10KB unarchive per track.
    AudioTrackMetadata *cachedMetaData = (AudioTrackMetadata *)[metadataCache.diskCache objectForKey:cacheKey];
    // PINCache unarchives without secure coding, so a tampered entry with a
    // different root class decodes cleanly and bypasses initWithCoder:'s field
    // validation entirely. A wrong-class object would crash on first use, with
    // an unrecognized selector, on every launch. Evict it instead.
    if (cachedMetaData && ![cachedMetaData isKindOfClass:[AudioTrackMetadata class]]) {
        [metadataCache.diskCache removeObjectForKey:cacheKey];
        cachedMetaData = nil;
    }
    if (!cachedMetaData) {
        return NO;
    }
    // No thumbnail warm-up is needed before publishing, unlike in
    // parseOneTrack:. The unarchive above already decoded it, because
    // initWithCoder: calls adoptArchivedThumbnailJPEG:, which decodes eagerly,
    // so the main thread's first cachedThumbnail read after publish is a
    // plain ivar hit.
    //
    // This pairs with parseOneTrack's guarded store. The unconditional store
    // here is safe because cached entries are always parsedOK, but it must not
    // interleave inside that check-then-act.
    @synchronized (track) {
        track.metadata = cachedMetaData;
    }
    [self publishTrack:track];
    return YES;
}

// The stage-2 worker: the TagLib parse. It opens the audio file, and this is
// the call that can block for a download's duration on a cloud placeholder.
// The claim, the recheck under it and the duplicate-row fan-out are
// MetadataParseFlow's; the four steps below are what it calls back into.
- (void)parseOneTrack:(AudioTrack *)track {
    // A stale loader, cancelled when a new playlist replaced this one, must
    // not keep parsing discarded tracks and issuing synchronous cache writes
    // that the live loader's objectForKey: reads then queue behind. The flow's
    // own entry check covers a track an earlier loader or the priority lane
    // resolved while this op sat queued.
    if (self.isCancelled) {
        return;
    }
    // Keyed on the file URL, not the track: the same file can occupy several
    // playlist rows as distinct AudioTracks, and one parse must answer them
    // all. When the holder is a DIFFERENT track for the same file, skipping
    // outright would leave this row bare, since the winner's result lands on
    // its own track — so the flow registers it as a waiter and the winner fans
    // its result out once, avoiding one polling chain per duplicate row while
    // a cloud parse is wedged.
    [_parseFlow runForParticipant:track key:track.url];
}

#pragma mark - MetadataParseFlowDelegate

- (BOOL)parseFlowParticipantIsResolved:(AudioTrack *)track {
    return track.metadata.parsedOK;
}

// Also how a duplicate row is served once the holder's parse lands: from the
// disk entry it just wrote, NOT by handing over the holder's own object. Two
// rows for the same file must own SEPARATE AudioTrackMetadata, because the art
// state on it is mutable and per-row — the current row decodes
// full-resolution art into it, and a track change discards that art again.
- (BOOL)parseFlowServeFromCache:(AudioTrack *)track {
    return [self loadTrackFromDiskCache:track];
}

- (void)parseFlowPublishParsed:(AudioTrack *)track {
    [self publishTrack:track];
}

- (void)parseFlowParse:(AudioTrack *)track {
    AudioTrackMetadataCache *owner = _owner;
    // Captured before the parse, which can block for minutes on a cloud file:
    // an invalidate arriving mid-parse makes this result stale for the cache.
    uint64_t generation = owner.cacheGeneration;
    AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:track.url];
    // Decode embedded art before publication so the table never pays ImageIO
    // work on main. Folder fallback remains lazy and visibility-driven.
    [metadata prewarmEmbeddedThumbnail];
    // Never clobber real metadata with a failed parse. A cancelled loader's op
    // can still be mid-parse when this loader re-parses successfully, and
    // last-writer-wins would reinstate the filename-only fallback. The monitor
    // spans both the check and the store: unguarded, it is the same race one
    // interleave later.
    @synchronized (track) {
        if (metadata.parsedOK || !track.metadata.parsedOK) {
            track.metadata = metadata;
        }
    }
    // cacheKey is re-read here, memoized on the track, because a transient
    // stat failure at cache-check time may have healed by the end of the parse.
    NSString *cacheKey = track.cacheKey;
    if (metadata.parsedOK && cacheKey) {
        // Skip failed parses, whether from a dataless cloud file or a
        // transient I/O error: caching the filename-only fallback would shadow
        // the real tags until the size-and-mtime cache key changed, which can
        // take up to the six-month limit. The write is synchronous on purpose,
        // because it is small, about 10KB, and the back-pressure paces the
        // workers; async writes pile up on PINDiskCache's serial queue and
        // stall the workers' next objectForKey: behind the backlog. The cache
        // is re-read fresh here, since it may have finished constructing
        // during the parse above, and nil no-ops harmlessly if it has not.
        // The generation guard mirrors the waveform cache's: skip the write
        // after an invalidate, and re-check after it lands, because
        // removeAllObjects takes PINDiskCache's lock directly and can slip
        // between the check and the write. The compensating remove is what
        // keeps Settings > Clear Cache genuinely empty.
        if (generation == owner.cacheGeneration) {
            [_owner.metadataCache.diskCache setObject:metadata forKey:cacheKey];
            if (generation != owner.cacheGeneration) {
                [_owner.metadataCache.diskCache removeObjectForKey:cacheKey];
            }
        }
    }
}

// Deliberately not gated on isCancelled: once a parse has landed on the track,
// every later loader's parsedOK checks skip it, so this publish is the only one
// the delegate will ever get — the cross-lane claim's "the winner's publish
// reaches the delegate either way". The art-byte discard must run for the same
// reason, and a departed track is dropped by the delegate's own checks.
- (void)publishTrack:(AudioTrack *)track {
    if (track.metadata) {
        // The thumbnail was pre-warmed before publish, so drop the full-size
        // art bytes and a large first import will not pin hundreds of MB.
        // Cache-hit instances never carried them, and freshly parsed ones now
        // match, since the art is re-read on demand for the one track shown
        // at full resolution.
        [track.metadata discardArtData];
        // The folder-artwork fallback is deliberately NOT resolved here: this
        // is the scan's path, including the cache-check lane whose whole point
        // is that it blocks on nothing but a stat and a small read, and a cover
        // on a network folder would. The accessors resolve it lazily instead,
        // for the tracks actually on screen.
        run_on_main_thread({
            [self.delegate didLoadMetadata:track];
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
    // The current-track lane, loadMetadataNow:. It lives for the cache's
    // lifetime and is never cancelled. Unlike the scan loaders, its work is
    // per-track and a stale publish is harmless, because the delegate's
    // reloadTrack: and currentTrack checks drop deliveries for departed tracks.
    AudioTrackMetadataLoader*   _priorityLoader;
    // Exists only to construct the cache off the main thread at utility QoS;
    // see init.
    dispatch_queue_t            _cacheQueue;
    // Bumped by invalidateWithCompletion:; see the class-extension comment.
    atomic_uint_fast64_t        _cacheGeneration;
}

- (uint64_t)cacheGeneration {
    return atomic_load_explicit(&_cacheGeneration, memory_order_relaxed);
}

+ (NSString *)cacheName {
    // The name embeds the archive-format version. Bump it whenever the
    // archived fields or their meaning change, as fileType labeling did, since
    // stale entries otherwise persist until the size-and-mtime cache key
    // changes, which can take up to the age limit.
    // v5: the tagged musical key joined the archive; older entries would
    // otherwise show no key until their cache key changed.
    return @"Audio Track Metadata v5";
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentLoader = nil;
        _parseCoordinator = [[MetadataParseCoordinator alloc] init];
        _cacheQueue = dispatch_queue_create("com.vibe.metadatacache",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        // Create the cache at utility QoS. Constructing it on the main thread
        // boosts PINCache's internal init-time disk scan to user-initiated,
        // which then priority-inverts against the utility worker ops, and the
        // Thread Performance Checker warns about it on the first drop.
        // Metadata loading usually starts well after init, since it is
        // deferred until playback begins, but a launch by double-click can
        // beat this block. The loader re-reads the property at each use.
        dispatch_async(_cacheQueue, ^{
            // Why the memory cache goes unused is with the shared policy.
            self.metadataCache = [PINCache audioCacheWithName:AudioTrackMetadataCache.cacheName];
        });
    }
    return self;
}

- (void)invalidateWithCompletion:(dispatch_block_t)completion {
    // The queue is serial, so this runs after the deferred cache construction
    // in init and self.metadataCache is always set when this block executes.
    dispatch_async(_cacheQueue, ^{
        atomic_fetch_add_explicit(&self->_cacheGeneration, 1, memory_order_relaxed);
        [self.metadataCache removeAllObjects];
        if (completion) {
            completion();
        }
    });
}

- (void)diskUsageWithCompletion:(void (^)(NSUInteger fileCount, unsigned long long totalBytes))completion {
    // The serial queue guarantees the cache exists and keeps the blocking
    // enumeration off the caller's thread.
    dispatch_async(_cacheQueue, ^{
        [self.metadataCache audioDiskUsageWithCompletion:completion];
    });
}

- (void)cancelAll {
    // Release it, rather than merely cancelling. _queuedTracks strongly holds
    // every queued track, pinning the old playlist until a next loadMetadata:
    // that may never come. Duplicate parse waiters are weak, and the priority
    // lane holds only in-flight tracks, so leave both alone.
    [_currentLoader cancel];
    _currentLoader = nil;
}

-(void)loadMetadata:(NSArray<AudioTrack*>*)tracks {
    [self cancelAll];
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
    // The scan loaders snapshot the delegate once per loadMetadata:, whereas
    // the long-lived priority loader refreshes it on every call.
    _priorityLoader.delegate = self.delegate;
    [_priorityLoader loadSingleTrack:track];
}

#if DEBUG
- (NSDictionary<NSString *, NSNumber *> *)debugPendingCounts {
    return [self.parseCoordinator debugPendingCounts];
}
#endif

@end
