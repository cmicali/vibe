//
//  AudioTrackMetadataLoader.m
//  Vibe
//

#import "AudioTrackMetadataLoader.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "PINCache.h"
#import "AudioFileOpenCoordinator.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "CloudMetadataRetryRules.h"
#import "CloudParseOrderRules.h"
#import "MetadataParseCoordinator.h"
#import "CloudFileMaterializer.h"
#import "NSURLUtil.h"

#include <os/lock.h>

// One pending cloud parse: a plain record, never a pre-built NSOperation. The
// lane dispatches at most one at a time and picks the next from these under
// the lock, so everything still pending is re-rankable by construction.
@interface VibeCloudParseEntry : NSObject
@property (nonatomic, strong) AudioTrack *track;
@property (nonatomic, copy) NSURL *url;
// The playlist row this sweep queued the track from, the comparator's
// equal-rank tie-break: without it the tail of the lane downloads in
// stage-1 completion order, which reads as random.
@property (nonatomic) NSUInteger playlistIndex;
// A retry after a failed materialization. It stays at the bottom of the lane
// however the neighborhood moves, so re-ranking cannot promote a known-bad
// file back in front of tracks that have not been tried at all.
@property (nonatomic) BOOL deferred;
@end

@implementation VibeCloudParseEntry
@end

// How long a lane parked on nothing-but-blocked entries waits before asking
// again. The picker skips an entry whose path the player or its prefetch is
// already materializing; when every pending entry is blocked and the lane has
// gone idle, this bounded re-check is what picks the survivor up after the
// player's transfer settles, since nothing else would kick the lane.
static const NSTimeInterval kCloudParseBlockedRecheckSeconds = 1.0;

// How many of the best pending entries the picker carries out of the lock.
//
// TRAP: it must stay comfortably above the number of paths the player can be
// materializing at once, because that is the only thing that can make the
// picker skip an entry — a playback open and its prefetch, so two. If every
// candidate in the window were ever blocked the lane would park with work it
// could have done. Eight is four times the reachable maximum.
//
// The window exists because the pending list is the whole playlist's misses:
// measured against a real provider, a Dropbox tree opened as one playlist left
// 104,000 entries pending, and the picker runs on the MAIN thread at every
// track change (setNeighborhoodURLs:). Selecting the best few in one pass is
// what keeps that off the main thread's critical path; fully ordering the list
// there cost ~300ms per track change.
static const NSUInteger kCloudParsePickWindow = 8;

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
    // The lane's authoritative pending queue. Because the lane is serial, this
    // list's ORDER is the whole of what decides which file downloads next —
    // so entries stay here, app-owned and never pre-submitted, until
    // dispatchNextCloudParse picks exactly one by (deferred, rank, index).
    // Touched from the four stage-1 workers and from main, hence the lock.
    NSMutableArray<VibeCloudParseEntry *>* _cloudParses;
    // The one dispatched parse. The dispatch gate: nothing new is submitted
    // to _cloudQueue while it is set, which is what makes every pending entry
    // re-rankable and the pick order authoritative.
    BOOL _cloudParseInFlight;
    // One armed blocked-lane re-check at a time; see the constant above.
    BOOL _cloudParseRecheckArmed;
    // Stage-1 checks the sweep has queued but not finished. The picker waits
    // for zero: the sweep's misses trickle in over the first few milliseconds
    // in stage-1 COMPLETION order, and a pick taken mid-burst — which the
    // hold's release inside didStartPlaying: makes the common case — chooses
    // from a half-populated list, sending a tail row's download out ahead of
    // the neighborhood's. The last check to finish kicks the lane.
    NSUInteger _stageOneOutstanding;
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
        for (NSUInteger index = 0; index < tracks.count; index++) {
            if (setupSelf.isCancelled) break;
            AudioTrack *track = tracks[index];
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
            // as stage-2 work; the playlist index rides along because the
            // cloud lane's tie-break is the row order this loop walks in. See
            // cacheCheckOneTrack:index:deferred:.
            if (setupSelf->_cloudQueue) {
                os_unfair_lock_lock(&setupSelf->_cloudParsesLock);
                setupSelf->_stageOneOutstanding++;
                os_unfair_lock_unlock(&setupSelf->_cloudParsesLock);
            }
            NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
                __typeof(self) strongSelf = weakSelf;
                if (strongSelf && !strongSelf.isCancelled) {
                    [strongSelf cacheCheckOneTrack:track index:index deferred:NO];
                }
                [strongSelf noteStageOneCheckFinished];
            }];
            op.queuePriority = NSOperationQueuePriorityHigh;
            [setupSelf->_queue addOperation:op];
        }
    }];
    setup.queuePriority = NSOperationQueuePriorityHigh;
    [_queue addOperation:setup];
    LogInfo(@"Metadata sweep: %lu tracks", (unsigned long)tracks.count);
}

// The stage-1 worker: publish from the disk cache, or hand off to stage 2.
// Which lane that lands on is the whole point: a placeholder read blocks until
// the provider materializes the file, so dataless files become pending entries
// on the serial, holdable cloud lane and local ones parse on the wide queue,
// rather than a cloud-heavy folder pinning all four workers for a download's
// duration while fast local parses sit queued behind them.
//
// deferred marks a re-queue after a failed cloud materialization; see
// CloudMetadataRetryRules.h. It only reaches the cloud lane's ordering.
- (void)cacheCheckOneTrack:(AudioTrack *)track index:(NSUInteger)playlistIndex deferred:(BOOL)deferred {
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
    if (_cloudQueue && [NSURLUtil isDatalessFile:track.url]) {
        VibeCloudParseEntry *entry = [[VibeCloudParseEntry alloc] init];
        entry.track = track;
        entry.url = track.url;
        entry.playlistIndex = playlistIndex;
        entry.deferred = deferred;
        [self enqueueCloudParseEntry:entry];
        return;
    }
    __weak __typeof(self) weakSelf = self;
    [_queue addOperationWithBlock:^{
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) return;
        [strongSelf parseOneTrack:track];
    }];
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
- (void)runCloudParseEntry:(VibeCloudParseEntry *)entry {
    AudioTrack *track = entry.track;
    // The stand-aside, asked again here because the picker's answer can go
    // stale between choosing and running: the player or its prefetch is
    // already materializing this exact path, and a second transfer of the
    // same file would spend the provider's scarce slot on bytes already
    // moving. Reinsert at current rank with no attempt spent — nothing about
    // the file failed — and the picker skips it while the claim lives; once
    // the player's transfer settles, the file is local and the parse costs a
    // read. It cannot spin: reinsertion is a pending-list append, and the
    // picker, not this method, decides what runs next.
    if ([[AudioFileOpenCoordinator sharedCoordinator] isMaterializingURL:entry.url]) {
        LogInfo(@"Cloud parse: %@ standing aside for the player's own transfer",
                entry.url.lastPathComponent);
        [self enqueueCloudParseEntry:entry];
        return;
    }
    // Register the call under the same gate setCloudParsesHeld: closes before
    // it cancels. Either this preparation wins and the following cancel can
    // reach it before materializeURL: enters, or the hold wins and this
    // parse re-queues behind the closed dispatch gate.
    os_unfair_lock_lock(&_cloudParsesLock);
    NSUInteger preparedHoldGeneration = _cloudHoldGeneration;
    CloudFileMaterializationToken *token = (!self.isCancelled && !_cloudParsesHeld)
            ? [_materializer prepareMaterialization]
            : nil;
    os_unfair_lock_unlock(&_cloudParsesLock);
    if (!token) {
        if (!self.isCancelled) {
            [self cacheCheckOneTrack:track index:entry.playlistIndex deferred:entry.deferred];
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
                [self cacheCheckOneTrack:track index:entry.playlistIndex deferred:NO];
                break;
            case VibeCloudMetadataRetryDeferred:
                LogWarn(@"Cloud parse: %@ failed after %.1fs (attempt %lu of %lu); re-queued last (%@)",
                        track.url.lastPathComponent, CFAbsoluteTimeGetCurrent() - startedAt,
                        (unsigned long)(priorAttempts + 1),
                        (unsigned long)kVibeCloudMetadataMaxAttempts,
                        error.localizedDescription);
                [self cacheCheckOneTrack:track index:entry.playlistIndex deferred:YES];
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

- (void)enqueueCloudParseEntry:(VibeCloudParseEntry *)entry {
    os_unfair_lock_lock(&_cloudParsesLock);
    [_cloudParses addObject:entry];
    os_unfair_lock_unlock(&_cloudParsesLock);
    [self dispatchNextCloudParse];
}

// The stage-1 drain edge. Not gated on isCancelled: a cancelled loader's
// counter still settles, and the kick no-ops against its emptied list.
- (void)noteStageOneCheckFinished {
    if (!_cloudQueue) {
        return;
    }
    BOOL drained = NO;
    os_unfair_lock_lock(&_cloudParsesLock);
    if (_stageOneOutstanding > 0) {
        _stageOneOutstanding--;
        drained = (_stageOneOutstanding == 0);
    }
    os_unfair_lock_unlock(&_cloudParsesLock);
    if (drained) {
        [self dispatchNextCloudParse];
    }
}

// The lane's picker: with the lane idle and the gate open, choose exactly one
// pending entry by (deferred, rank, index) and dispatch it. The blocked check
// runs OUTSIDE the lock — it hops to the open coordinator's state queue — so
// the pick is snapshot, ask, then re-take the lock and verify the chosen
// entry is still pending before removing it.
// The best kCloudParsePickWindow entries by (deferred, rank, index), in one
// pass over the pending list. Called with _cloudParsesLock held.
//
// One pass rather than a sort, and a rank looked up once per entry rather than
// inside a comparator, because both costs are paid on the main thread at every
// track change and both scale with the playlist: sorting is O(n log n)
// comparisons, and -[NSArray indexOfObject:] inside the comparator made each
// one a linear walk of NSURL equality tests on top. Against a real cloud tree
// with 104,000 entries pending that measured ~300ms per track change; a track
// change on a 14-row playlist costs 49ms.
- (NSArray<VibeCloudParseEntry *> *)bestCloudParseCandidatesLocked {
    NSMutableDictionary<NSURL *, NSNumber *> *rankByURL =
            [NSMutableDictionary dictionaryWithCapacity:_neighborhood.count];
    [_neighborhood enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger rank, BOOL *stop) {
        // First spelling wins: a URL listed twice keeps its better rank.
        if (rankByURL[url] == nil) {
            rankByURL[url] = @(rank);
        }
    }];

    NSMutableArray<VibeCloudParseEntry *> *best =
            [NSMutableArray arrayWithCapacity:kCloudParsePickWindow];
    NSMutableArray<NSNumber *> *bestRanks =
            [NSMutableArray arrayWithCapacity:kCloudParsePickWindow];
    for (VibeCloudParseEntry *entry in _cloudParses) {
        NSNumber *found = rankByURL[entry.url];
        NSUInteger rank = found != nil ? found.unsignedIntegerValue : NSNotFound;
        // Insertion sort into a window this small is cheaper than any
        // alternative, and it is the same total order the seam defines.
        NSUInteger at = best.count;
        while (at > 0) {
            VibeCloudParseEntry *above = best[at - 1];
            if (VibeCloudParseOrderedBefore(above.deferred,
                                            bestRanks[at - 1].unsignedIntegerValue,
                                            above.playlistIndex,
                                            entry.deferred, rank, entry.playlistIndex)) {
                break;
            }
            at--;
        }
        if (at >= kCloudParsePickWindow) {
            continue;
        }
        [best insertObject:entry atIndex:at];
        [bestRanks insertObject:@(rank) atIndex:at];
        if (best.count > kCloudParsePickWindow) {
            [best removeLastObject];
            [bestRanks removeLastObject];
        }
    }
    return best;
}

- (void)dispatchNextCloudParse {
    NSArray<VibeCloudParseEntry *> *ordered = nil;
    os_unfair_lock_lock(&_cloudParsesLock);
    if (!_cloudParseInFlight && !_cloudParsesHeld && !self.isCancelled
            && _stageOneOutstanding == 0 && _cloudParses.count) {
        ordered = [self bestCloudParseCandidatesLocked];
    }
    os_unfair_lock_unlock(&_cloudParsesLock);
    if (!ordered.count) {
        return;
    }
    VibeCloudParseEntry *chosen = nil;
    BOOL anyBlocked = NO;
    for (VibeCloudParseEntry *candidate in ordered) {
        // The player or its prefetch already owns a transfer of this path;
        // skip it at its rank rather than downloading the same bytes twice.
        if ([[AudioFileOpenCoordinator sharedCoordinator] isMaterializingURL:candidate.url]) {
            anyBlocked = YES;
            continue;
        }
        chosen = candidate;
        break;
    }
    BOOL armRecheck = NO;
    os_unfair_lock_lock(&_cloudParsesLock);
    if (_cloudParseInFlight || _cloudParsesHeld || self.isCancelled) {
        chosen = nil;
    }
    else if (chosen) {
        if ([_cloudParses containsObject:chosen]) {
            [_cloudParses removeObjectIdenticalTo:chosen];
            _cloudParseInFlight = YES;
        }
        else {
            chosen = nil; // a cancel emptied the list between snapshot and now
        }
    }
    else if (anyBlocked && _cloudParses.count && !_cloudParseRecheckArmed) {
        // Everything pending is blocked behind the player's transfers and the
        // lane is idle: park, and re-ask on a bounded clock, because nothing
        // else kicks the lane when a claim it is waiting out settles.
        _cloudParseRecheckArmed = YES;
        armRecheck = YES;
    }
    os_unfair_lock_unlock(&_cloudParsesLock);
    __weak __typeof(self) weakSelf = self;
    if (armRecheck) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(kCloudParseBlockedRecheckSeconds * NSEC_PER_SEC)),
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            os_unfair_lock_lock(&strongSelf->_cloudParsesLock);
            strongSelf->_cloudParseRecheckArmed = NO;
            os_unfair_lock_unlock(&strongSelf->_cloudParsesLock);
            [strongSelf dispatchNextCloudParse];
        });
        return;
    }
    if (!chosen) {
        return;
    }
    [_cloudQueue addOperationWithBlock:^{
        __typeof(self) runSelf = weakSelf;
        if (runSelf && !runSelf.isCancelled) {
            [runSelf runCloudParseEntry:chosen];
        }
        // Re-taken, so a parse that outlived the loader's last outside owner
        // still settles the flag on whatever remains.
        __typeof(self) finishSelf = weakSelf;
        if (!finishSelf) return;
        os_unfair_lock_lock(&finishSelf->_cloudParsesLock);
        finishSelf->_cloudParseInFlight = NO;
        os_unfair_lock_unlock(&finishSelf->_cloudParsesLock);
        [finishSelf dispatchNextCloudParse];
    }];
}

- (void)setNeighborhoodURLs:(NSArray<NSURL *> *)urls {
    if (!_cloudQueue) {
        return;
    }
    os_unfair_lock_lock(&_cloudParsesLock);
    _neighborhood = [urls copy] ?: @[];
    os_unfair_lock_unlock(&_cloudParsesLock);
    // Pending entries carry no rank of their own — the picker reads the live
    // neighborhood — so a move re-ranks by construction. The kick covers a
    // lane parked on blocked entries: a track change can unblock the pick.
    [self dispatchNextCloudParse];
}

#if DEBUG
// Declared in Debug/AudioTrackMetadataCache+Debug.h; implemented here because
// the list it counts is this file's.
- (NSUInteger)debugPendingCloudParseCount {
    if (!_cloudQueue) {
        return 0;
    }
    os_unfair_lock_lock(&_cloudParsesLock);
    NSUInteger count = _cloudParses.count + (_cloudParseInFlight ? 1 : 0);
    os_unfair_lock_unlock(&_cloudParsesLock);
    return count;
}
#endif

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
    // Close the gate BEFORE cancelling, never after: the cancelled parse
    // re-queues itself, and with the gate open its replacement would dispatch
    // and start the same download again immediately — a cancel loop rather
    // than a hold. The one flag closes both doors under the one lock: the
    // picker stops dispatching, and a parse already running fails the token
    // preparation and re-queues behind it.
    if (held) {
        os_unfair_lock_lock(&_cloudParsesLock);
        _cloudParsesHeld = YES;
        _cloudHoldGeneration++;
        os_unfair_lock_unlock(&_cloudParsesLock);
        [_materializer cancel];
        return;
    }
    os_unfair_lock_lock(&_cloudParsesLock);
    _cloudParsesHeld = NO;
    os_unfair_lock_unlock(&_cloudParsesLock);
    [self dispatchNextCloudParse];
}

- (void)cancel {
    self.isCancelled = YES;
    [_queue cancelAllOperations];
    // Close the token-registration gate before cancelling the current token.
    // A parse which already passed the gate is in the materializer's slot and
    // is reached by cancel; one arriving later sees the closed gate. The
    // pending entries are plain records, dropped here directly — nothing is
    // pre-submitted, so there is no suspended queue pinning the discarded
    // playlist, and the one dispatched block still runs its own cancellation
    // checks and settles the in-flight flag on a loader that is already gone.
    if (_cloudQueue) {
        os_unfair_lock_lock(&_cloudParsesLock);
        _cloudParsesHeld = YES;
        [_cloudParses removeAllObjects];
        [_cloudAttemptsByPath removeAllObjects];
        os_unfair_lock_unlock(&_cloudParsesLock);
    }
    // The download in flight belongs to a playlist that is gone. Its parse
    // checks isCancelled and re-queues nothing.
    [_materializer cancel];
}

@end
