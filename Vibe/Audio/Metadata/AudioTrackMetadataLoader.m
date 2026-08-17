//
//  AudioTrackMetadataLoader.m
//  Vibe
//

#import "AudioTrackMetadataLoader.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "CloudMetadataRetryRules.h"
#import "MetadataParseCoordinator.h"
#import "CloudFileMaterializer.h"
#import "NSURLUtil.h"

#include <os/lock.h>

// One pending cloud parse. The URL is kept beside the operation because the
// rank is decided by URL and an NSOperation cannot be asked what it captured.
@interface VibeCloudParseEntry : NSObject
@property (nonatomic, strong) NSOperation *operation;
@property (nonatomic, copy) NSURL *url;
// A retry after a failed materialization. It stays at the bottom of the lane
// however the neighborhood moves, so re-ranking cannot promote a known-bad
// file back in front of tracks that have not been tried at all.
@property (nonatomic) BOOL deferred;
@end

@implementation VibeCloudParseEntry
@end

// The neighborhood's own order IS the rank: first named is next up. Past it
// the sweep is one undifferentiated tier — once the tracks the listener is
// about to reach are out of the way, a folder's worth of downloads has no
// meaningful order left. A deferred retry sits below even that: it has already
// failed once, so every track that has not tried yet goes first.
static NSOperationQueuePriority VibeCloudParsePriority(NSUInteger rank, BOOL deferred) {
    if (deferred) {
        return NSOperationQueuePriorityVeryLow;
    }
    switch (rank) {
        case 0:  return NSOperationQueuePriorityVeryHigh;
        case 1:  return NSOperationQueuePriorityHigh;
        case 2:  return NSOperationQueuePriorityNormal;
        default: return NSOperationQueuePriorityLow;
    }
}

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
    // The scan lane's cloud queue: stage-2 parses of files whose data is not on
    // disk yet. Nil in the current-track lane, which never parses one. See
    // initWithOwner:delegate:lane: for why it is separate and serial.
    NSOperationQueue* _cloudQueue;
    // Because that queue is serial, the pending operations' ORDER is the whole
    // of what decides which file downloads next — so every one of them is kept
    // here and re-ranked in place when the neighborhood moves. NSOperationQueue
    // honors a queuePriority written any time before the operation starts.
    // Touched from the four stage-1 workers and from main, hence the lock.
    NSMutableArray<VibeCloudParseEntry *>* _cloudParses;
    NSArray<NSURL *>* _neighborhood;   // rank order; empty until a screen names one
    // The suspension verdict shares _cloudParsesLock with the preparation of
    // the active materialization token. That closes the race where a hold
    // cancelled an empty slot just before an already-started operation filled
    // it and began downloading anyway.
    BOOL _cloudParsesHeld;
    // Incremented whenever a foreground-open hold closes the materialization
    // gate. A worker snapshots it beside its token, so it can still identify
    // that cancellation after a short hold has already lifted.
    NSUInteger _cloudHoldGeneration;
    // Materialization failures per file path, hold cancellations excluded. The
    // budget is what keeps a transient provider error from costing the row its
    // tags for the rest of the sweep without letting a dead file retry forever.
    // Guarded by _cloudParsesLock; bounded by the playlist's failing tracks.
    NSMutableDictionary<NSString *, NSNumber *> *_cloudAttemptsByPath;
    os_unfair_lock _cloudParsesLock;
    // Makes the download in front of a cloud parse abortable, which a plain
    // read is not; the hold cancels it. See CloudFileMaterializer.
    CloudFileMaterializer* _materializer;
    // The parse ordering, over the owner's shared coordinator. Held strongly,
    // and it holds this loader weakly back.
    MetadataParseRunner* _parseRunner;
}

- (instancetype)initWithOwner:(AudioTrackMetadataCache *)owner
                     delegate:(id <AudioTrackMetadataCacheDelegate>)delegate
                         lane:(VibeMetadataLane)lane {
    self = [super init];
    if (self) {
        _isCancelled = NO;
        _owner = owner;
        _queuedTracks = [NSMutableSet set];
        _parseRunner = [[MetadataParseRunner alloc] initWithCoordinator:owner.parseCoordinator
                                                           delegate:self];
        _delegate = delegate;
        _queue = [[NSOperationQueue alloc] init];
        if (lane == VibeMetadataLaneCurrentTrack) {
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
            // The cloud lane, and the reason it is not just a low queue
            // priority on the queue above. Parsing a dataless file downloads
            // the WHOLE file through the file provider, so the unit of
            // contention is the provider's transfer, not a worker thread:
            // four of those at once is what turns opening a Dropbox folder
            // into minutes of thrash, and it starves the one open the user is
            // actually waiting on. Serial, therefore, and suspended outright
            // while a foreground open is materializing (setCloudParsesHeld:).
            // Local parses and every stage-1 cache check stay on the wide
            // queue above, which touches nothing but a stat and a small read.
            _cloudQueue = [[NSOperationQueue alloc] init];
            _cloudQueue.name = @"AudioTrackMetadataLoader.cloud";
            _cloudQueue.maxConcurrentOperationCount = 1;
            _cloudQueue.qualityOfService = NSQualityOfServiceUtility;
            _cloudParses = [NSMutableArray array];
            _neighborhood = @[];
            _cloudAttemptsByPath = [NSMutableDictionary dictionary];
            _cloudParsesLock = OS_UNFAIR_LOCK_INIT;
            _materializer = [[CloudFileMaterializer alloc] init];
            _materializer.label = @"metadata";
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
    LogInfo(@"Metadata sweep: %lu tracks", (unsigned long)tracks.count);
}

// The stage-1 worker: publish from the disk cache, or hand off to a stage-2
// parse op. Which queue that op lands on is the whole point: a placeholder
// read blocks until the provider materializes the file, so dataless files go
// to the serial, holdable cloud lane and local ones to the wide queue, rather
// than a cloud-heavy folder pinning all four workers for a download's duration
// while fast local parses sit queued behind them.
- (void)cacheCheckOneTrack:(AudioTrack *)track {
    [self cacheCheckOneTrack:track deferred:NO];
}

// deferred marks a re-queue after a failed cloud materialization; see
// CloudMetadataRetryRules.h. It only reaches the cloud lane's ranking.
- (void)cacheCheckOneTrack:(AudioTrack *)track deferred:(BOOL)deferred {
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
    BOOL cloud = _cloudQueue && [NSURLUtil isDatalessFile:track.url];
    NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) return;
        if (cloud) {
            [strongSelf runCloudParse:track];
        }
        else {
            [strongSelf parseOneTrack:track];
        }
    }];
    if (cloud) {
        [self enqueueCloudParse:op forURL:track.url deferred:deferred];
        return;
    }
    [_queue addOperation:op];
}

#pragma mark - The cloud lane's order

// The cloud lane's stage 2, in two halves, because on this lane the download
// is the expensive part and the parse is an afterthought. Materializing first
// is what makes the download abortable — a hold cancels it mid-transfer, where
// letting TagLib's own read do the downloading would own the lane until the
// provider finished — and it leaves the parse itself reading a local file.
//
// A download cancelled by the foreground-open hold re-queues the track at its
// current rank rather than dropping it: the sweep has no second pass, so the
// row would otherwise keep its filename fallback until the whole playlist was
// re-queued. It cannot spin, because the hold suspends the queue BEFORE it
// cancels, and it spends no attempt budget — nothing about the file failed.
//
// Any other failure re-queues at the BOTTOM of the lane instead, with a small
// per-path attempt budget (CloudMetadataRetryRules.h). Retrying at rank would
// let one terminal provider error monopolize this serial lane forever;
// abandoning the track outright would cost a row its tags for the rest of the
// sweep over a transient blip, since the only later retry is a whole new scan.
- (void)runCloudParse:(AudioTrack *)track {
    // Register the call under the same gate setCloudParsesHeld: closes before
    // it cancels. Either this preparation wins and the following cancel can
    // reach it before materializeURL: enters, or the hold wins and this
    // operation re-queues behind the suspended lane.
    os_unfair_lock_lock(&_cloudParsesLock);
    NSUInteger preparedHoldGeneration = _cloudHoldGeneration;
    CloudFileMaterializationToken *token = (!self.isCancelled && !_cloudParsesHeld)
            ? [_materializer prepareMaterialization]
            : nil;
    os_unfair_lock_unlock(&_cloudParsesLock);
    if (!token) {
        if (!self.isCancelled) {
            [self cacheCheckOneTrack:track];
        }
        return;
    }

    CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
    NSError *error = nil;
    if (![_materializer materializeURL:track.url token:token error:&error]) {
        NSString *attemptKey = track.url.path ?: track.url.absoluteString;
        os_unfair_lock_lock(&_cloudParsesLock);
        NSUInteger currentHoldGeneration = _cloudHoldGeneration;
        NSUInteger priorAttempts = attemptKey ? _cloudAttemptsByPath[attemptKey].unsignedIntegerValue : 0;
        VibeCloudMetadataRetry verdict = VibeCloudMetadataRetryForMaterializationFailure(
                error, preparedHoldGeneration, currentHoldGeneration,
                priorAttempts, kVibeCloudMetadataMaxAttempts);
        // Charged under the same lock that read it, so two workers can never
        // both see the last attempt as available. Only a real failure charges:
        // a hold cancellation is the app's own doing.
        if (attemptKey && verdict != VibeCloudMetadataRetryAtCurrentRank) {
            _cloudAttemptsByPath[attemptKey] = @(priorAttempts + 1);
        }
        os_unfair_lock_unlock(&_cloudParsesLock);
        if (self.isCancelled) {
            return;
        }
        switch (verdict) {
            case VibeCloudMetadataRetryAtCurrentRank:
                LogInfo(@"Cloud parse: %@ yielded to foreground open after %.1fs",
                        track.url.lastPathComponent, CFAbsoluteTimeGetCurrent() - startedAt);
                [self cacheCheckOneTrack:track deferred:NO];
                break;
            case VibeCloudMetadataRetryDeferred:
                LogWarn(@"Cloud parse: %@ failed after %.1fs (attempt %lu of %lu); re-queued last (%@)",
                        track.url.lastPathComponent, CFAbsoluteTimeGetCurrent() - startedAt,
                        (unsigned long)(priorAttempts + 1),
                        (unsigned long)kVibeCloudMetadataMaxAttempts,
                        error.localizedDescription);
                [self cacheCheckOneTrack:track deferred:YES];
                break;
            case VibeCloudMetadataRetryNone:
                LogWarn(@"Cloud parse: %@ failed after %.1fs and is out of attempts; "
                        @"waiting for a later scan (%@)",
                        track.url.lastPathComponent, CFAbsoluteTimeGetCurrent() - startedAt,
                        error.localizedDescription);
                break;
        }
        return;
    }
    [self parseOneTrack:track];
    LogInfo(@"Cloud parse: %@ in %.1fs", track.url.lastPathComponent,
            CFAbsoluteTimeGetCurrent() - startedAt);
}

- (void)enqueueCloudParse:(NSOperation *)op forURL:(NSURL *)url deferred:(BOOL)deferred {
    VibeCloudParseEntry *entry = [[VibeCloudParseEntry alloc] init];
    entry.operation = op;
    entry.url = url;
    entry.deferred = deferred;
    os_unfair_lock_lock(&_cloudParsesLock);
    [self pruneStartedCloudParsesLocked];
    op.queuePriority = VibeCloudParsePriority([_neighborhood indexOfObject:url], deferred);
    [_cloudParses addObject:entry];
    os_unfair_lock_unlock(&_cloudParsesLock);
    [_cloudQueue addOperation:op];
}

- (void)setNeighborhoodURLs:(NSArray<NSURL *> *)urls {
    if (!_cloudQueue) {
        return;
    }
    os_unfair_lock_lock(&_cloudParsesLock);
    _neighborhood = [urls copy] ?: @[];
    [self pruneStartedCloudParsesLocked];
    for (VibeCloudParseEntry *entry in _cloudParses) {
        entry.operation.queuePriority =
                VibeCloudParsePriority([_neighborhood indexOfObject:entry.url], entry.deferred);
    }
    os_unfair_lock_unlock(&_cloudParsesLock);
}

#if DEBUG
// Declared in Debug/AudioTrackMetadataCache+Debug.h; implemented here because
// the list it counts is this file's.
- (NSUInteger)debugPendingCloudParseCount {
    if (!_cloudQueue) {
        return 0;
    }
    os_unfair_lock_lock(&_cloudParsesLock);
    [self pruneStartedCloudParsesLocked];
    NSUInteger count = _cloudParses.count;
    os_unfair_lock_unlock(&_cloudParsesLock);
    return count;
}
#endif

// An operation that has started can no longer be re-ranked, so it is only
// weight here. Pruning on each write keeps the list to what is still pending
// without a completion block per operation — which would retain the loader
// from the queue and outlive a cancel.
- (void)pruneStartedCloudParsesLocked {
    [_cloudParses filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(VibeCloudParseEntry *entry, NSDictionary *bindings) {
        return !entry.operation.isExecuting && !entry.operation.isFinished;
    }]];
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
    // parseOneTrack:. On macOS the unarchive above already decoded it, because
    // initWithCoder: hands the archived JPEG straight to the artwork, so the
    // main thread's first cachedThumbnail read after publish is a plain ivar
    // hit; on iOS there is no thumbnail to warm at all.
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
// MetadataParseRunner's; the four steps below are what it calls back into.
- (void)parseOneTrack:(AudioTrack *)track {
    // A stale loader, cancelled when a new playlist replaced this one, must
    // not keep parsing discarded tracks and issuing synchronous cache writes
    // that the live loader's objectForKey: reads then queue behind. The runner's
    // own entry check covers a track an earlier loader or the priority lane
    // resolved while this op sat queued.
    if (self.isCancelled) {
        return;
    }
    // Keyed on the file URL, not the track: the same file can occupy several
    // playlist rows as distinct AudioTracks, and one parse must answer them
    // all. When the holder is a DIFFERENT track for the same file, skipping
    // outright would leave this row bare, since the winner's result lands on
    // its own track — so the runner registers it as a waiter and the winner fans
    // its result out once, avoiding one polling chain per duplicate row while
    // a cloud parse is wedged.
    [_parseRunner runForParticipant:track key:track.url];
}

#pragma mark - MetadataParseRunnerDelegate

- (BOOL)parseRunnerIsResolved:(AudioTrack *)track {
    return track.metadata.parsedOK;
}

// Also how a duplicate row is served once the holder's parse lands: from the
// disk entry it just wrote, NOT by handing over the holder's own object. Two
// rows for the same file must own SEPARATE AudioTrackMetadata, because the art
// state on it is mutable and per-row — the current row decodes
// full-resolution art into it, and a track change discards that art again.
- (BOOL)parseRunnerServeFromCache:(AudioTrack *)track {
    return [self loadTrackFromDiskCache:track];
}

- (void)parseRunnerPublish:(AudioTrack *)track {
    [self publishTrack:track];
}

- (void)parseRunnerReadAndCache:(AudioTrack *)track {
    AudioTrackMetadataCache *owner = _owner;
    // Captured before the parse, which can block for minutes on a cloud file:
    // an invalidate arriving mid-parse makes this result stale for the cache.
    uint64_t generation = owner.cacheGeneration;
    AudioTrackMetadata *metadata = [AudioTrackMetadata metadataWithURL:track.url];
    // Decode the row thumbnail before publication so the main thread never
    // pays ImageIO work. Folder fallback remains lazy and visibility-driven.
    // Both platforms want it — the mac playlist's art cells, the iOS library
    // rows and mini strip — while the iOS pager deliberately draws none of it
    // and decodes full size for the few pages in its window.
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
        // The strong local throughout, never the weak _owner: it is pinned at
        // the top precisely so the cache cannot deallocate across the parse
        // above, and reaching back through the ivar here would put a nil hole
        // in the middle of the write-then-recheck pair.
        if (generation == owner.cacheGeneration) {
            [owner.metadataCache.diskCache setObject:metadata forKey:cacheKey];
            if (generation != owner.cacheGeneration) {
                [owner.metadataCache.diskCache removeObjectForKey:cacheKey];
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
        // Drop the full-size art bytes, or a large first import pins hundreds
        // of MB. Cache-hit instances never carried them, and freshly parsed
        // ones now match: whatever each platform wanted decoding — the mac's
        // thumbnail, above — is decoded by now, and the full-resolution image
        // is re-read on demand for the few tracks actually shown at that size.
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

- (void)setCloudParsesHeld:(BOOL)held {
    if (!_cloudQueue) {
        return;
    }
    // Suspend BEFORE cancelling, never after: the cancelled parse re-queues
    // itself, and on a queue still running that replacement would start the
    // same download again immediately — a cancel loop rather than a hold.
    if (held) {
        _cloudQueue.suspended = YES;
        os_unfair_lock_lock(&_cloudParsesLock);
        _cloudParsesHeld = YES;
        _cloudHoldGeneration++;
        os_unfair_lock_unlock(&_cloudParsesLock);
        [_materializer cancel];
        return;
    }
    // Open the registration gate before resuming the queue, so its first
    // operation can prepare a fresh, unpoisoned token immediately.
    os_unfair_lock_lock(&_cloudParsesLock);
    _cloudParsesHeld = NO;
    os_unfair_lock_unlock(&_cloudParsesLock);
    _cloudQueue.suspended = NO;
}

- (void)cancel {
    self.isCancelled = YES;
    [_queue cancelAllOperations];
    [_cloudQueue cancelAllOperations];
    // Close the token-registration gate before cancelling the current token.
    // An operation which already passed the gate is in the materializer's slot
    // and is reached by cancel; one arriving later sees the closed gate.
    if (_cloudQueue) {
        os_unfair_lock_lock(&_cloudParsesLock);
        _cloudParsesHeld = YES;
        os_unfair_lock_unlock(&_cloudParsesLock);
    }
    // The download in flight belongs to a playlist that is gone. Its op checks
    // isCancelled above and re-queues nothing.
    [_materializer cancel];
    // TRAP: a suspended queue never starts its cancelled operations, and an
    // operation that never runs never releases the track it captured. Lifting
    // the hold lets them drain — each returns immediately on isCancelled —
    // rather than pinning the discarded playlist for the loader's lifetime.
    _cloudQueue.suspended = NO;
    os_unfair_lock_lock(&_cloudParsesLock);
    [_cloudParses removeAllObjects];
    [_cloudAttemptsByPath removeAllObjects];
    os_unfair_lock_unlock(&_cloudParsesLock);
}

@end
