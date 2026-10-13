//
//  AudioTrackMetadataLoader+Parse.m
//  Vibe
//
//  Stage 2 and the cache: the disk-cache read, the parse and its cache write,
//  installation, settlement and publication, and the display-art
//  rendition's sidecar.
//

#import "AudioTrackMetadataLoaderInternal.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "PINCache.h"
#import "AudioTrack.h"
#import "AudioTrackInternal.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataInternal.h"
#import "AudioTrackArtwork.h"
#import "MetadataScanEntry.h"
#import "MetadataParseCoordinator.h"

#import "AudioTrackMetadataLoader+Debug.h"

// NSURL+Hash cache keys never contain '#'.
static NSString *VibeArchivedDisplayArtKey(NSString *cacheKey) {
    return [cacheKey stringByAppendingString:@"#displayArt"];
}

// An art-bearing cache entry may have no thumbnail bytes. Its rendition
// supplies both thumbnail and display decodes. An absent rendition falls
// through to source extraction for full art.
static void VibeInstallArchivedDisplayArtProvider(AudioTrackMetadata *metadata,
                                                  PINCache *metadataCache,
                                                  NSString *cacheKey) {
    if (!metadata.artwork.hasEmbeddedArt) {
        return;
    }
    NSString *sidecarKey = VibeArchivedDisplayArtKey(cacheKey);
    __weak PINCache *weakCache = metadataCache;
    metadata.artwork.archivedDisplayArtProvider = ^NSData *{
        // Blocking read on a registry worker; a departed cache reads as absent.
        PINCache *cache = weakCache;
        NSData *data = (NSData *)[cache.diskCache objectForKey:sidecarKey];
        // PINCache unarchives without secure coding: a wrong class is absent.
        return [data isKindOfClass:[NSData class]] ? data : nil;
    };
}

@implementation AudioTrackMetadataLoader (Parse)

// Reads file attributes and the cache, never the audio bytes. A dataless
// file needs no download for this lookup.
- (AudioTrackMetadata *)readCachedMetadataForTrack:(AudioTrack *)track {
    if (_cacheReader) {
        return _cacheReader(track);
    }
    // nil when the stat fails (NSURL+Hash); the parse still runs.
    NSString *cacheKey = track.cacheKey;
    if (!cacheKey) {
        LogWarn(@"No cache key for %@ — loading metadata uncached", track.url.path);
        return nil;
    }
    // nil until constructed; only the earliest tracks parse uncached.
    PINCache *metadataCache = _owner.metadataCache;
    if (!metadataCache) {
        LogWarn(@"Metadata cache not yet available — loading %@ uncached", track.url.path);
        return nil;
    }
    // Bypasses PINMemoryCache: on macOS it never evicts (its pressure hooks
    // are iOS-only), so every track ever loaded would stay pinned.
    AudioTrackMetadata *cachedMetaData = (AudioTrackMetadata *)[metadataCache.diskCache objectForKey:cacheKey];
    // PINCache unarchives without secure coding: a wrong root class skips
    // initWithCoder:'s validation and would crash on first use every launch.
    if (cachedMetaData && ![cachedMetaData isKindOfClass:[AudioTrackMetadata class]]) {
        [metadataCache.diskCache removeObjectForKey:cacheKey];
        [metadataCache.diskCache removeObjectForKey:VibeArchivedDisplayArtKey(cacheKey)];
        cachedMetaData = nil;
    }
    if (!cachedMetaData) {
        return nil;
    }
    VibeInstallArchivedDisplayArtProvider(cachedMetaData, metadataCache, cacheKey);
    return cachedMetaData;
}

- (void)loadFromCacheOnly:(NSArray<AudioTrack *> *)tracks {
    __weak __typeof(self) weakSelf = self;
    for (AudioTrack *track in tracks) {
        NSOperation *op = [NSBlockOperation blockOperationWithBlock:^{
            __typeof(self) strongSelf = weakSelf;
            if (strongSelf && !track.metadata) {
                [strongSelf loadTrackFromDiskCache:track];
            }
        }];
        // Rows on screen.
        op.qualityOfService = NSQualityOfServiceUserInitiated;
        op.queuePriority = NSOperationQueuePriorityHigh;
        [_queue addOperation:op];
    }
}

- (BOOL)loadTrackFromDiskCache:(AudioTrack *)track {
    AudioTrackMetadata *cachedMetaData = [self readCachedMetadataForTrack:track];
    if (!cachedMetaData) {
        return NO;
    }
    // Only the winner publishes: another lane may have installed a parse
    // during the read.
    if ([track installMetadataIfUnresolved:cachedMetaData]) {
        [self publishTrack:track];
    }
    return YES;
}

// Stage 2's one parse operation for a Ready record, user-initiated for the
// current track. Answers whether it went user-initiated.
- (BOOL)scheduleParseForEntry:(MetadataScanEntry *)entry
                userInitiated:(BOOL)userInitiatedParse {
    __weak __typeof(self) weakSelf = self;
    __block __weak NSOperation *weakParse = nil;
    NSOperation *parse = [NSBlockOperation blockOperationWithBlock:^{
        __typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            if (!strongSelf.isCancelled) {
                [strongSelf parseOneEntry:entry];
            }
            [strongSelf finishParseOperation:weakParse forEntry:entry];
        }
    }];
    weakParse = parse;
    parse.qualityOfService = userInitiatedParse
            ? NSQualityOfServiceUserInitiated : NSQualityOfServiceUtility;
    if (userInitiatedParse) {
        parse.queuePriority = NSOperationQueuePriorityHigh;
    }
    os_unfair_lock_lock(&_materializationLock);
    // prioritizeTrack: may have marked it after the caller decided, and
    // before this operation existed.
    if ([self priorityMarkForEntryLocked:entry]) {
        userInitiatedParse = YES;
        parse.qualityOfService = NSQualityOfServiceUserInitiated;
        parse.queuePriority = NSOperationQueuePriorityHigh;
    }
    for (AudioTrack *track in entry.tracks) {
        [_parseOperationsByTrack setObject:parse forKey:track];
    }
#if DEBUG
    [self debugNoteScheduledParseQualityOfService:parse.qualityOfService];
#endif
    os_unfair_lock_unlock(&_materializationLock);
    [_queue addOperation:parse];
    return userInitiatedParse;
}

- (void)finishParseOperation:(NSOperation *)operation forEntry:(MetadataScanEntry *)entry {
    os_unfair_lock_lock(&_materializationLock);
    for (AudioTrack *track in entry.tracks) {
        if ([_parseOperationsByTrack objectForKey:track] == operation) {
            [_parseOperationsByTrack removeObjectForKey:track];
        }
    }
    os_unfair_lock_unlock(&_materializationLock);
}

// Stage 2: the TagLib parse, entered only after materialization was Ready.
- (void)parseOneEntry:(MetadataScanEntry *)entry {
    if (self.isCancelled) {
        return;
    }
    // A mark adopted since Ready leads too.
    os_unfair_lock_lock(&_materializationLock);
    [self leadEntryWithItsMarkedRowLocked:entry];
    os_unfair_lock_unlock(&_materializationLock);
    NSArray<AudioTrack *> *tracks = entry.tracks;
    if (tracks.firstObject.metadata.parsedOK) {
        [self settleTracks:tracks withMetadata:tracks.firstObject.metadata];
        return;
    }
    // A priority edge landing while the parse is queued has no record to
    // carry it, so entry and settlement both retire it.
    [self retirePriorityMarksSatisfiedByTracks:tracks];
    // Rows ahead of the owner joined another lane's holder, which serves them.
    MetadataParseClaim *claim = nil;
    NSUInteger ownerIndex = 0;
    for (; ownerIndex < tracks.count; ownerIndex++) {
        claim = [_parseCoordinator claimParseForKey:entry.standardizedPath
                                        participant:tracks[ownerIndex]];
        if (claim.isOwner) {
            break;
        }
    }
    if (!claim.isOwner) {
        [self finishTracks:tracks];
        return;
    }
    AudioTrack *track = tracks[ownerIndex];
    // Another lane or a prior holder may have resolved it before the claim.
    AudioTrackMetadata *result = (track.metadata.parsedOK || [self loadTrackFromDiskCache:track])
            ? track.metadata : [self parseAndCacheMetadataForTrack:track];
    if (result.parsedOK) {
        // NO for a resolved holder, already published.
        BOOL publishHolder = [track installMetadataIfUnresolved:result];
        NSMutableArray<AudioTrack *> *adopted = [NSMutableArray array];
        BOOL completed = NO;
        do {
            NSArray<AudioTrack *> *waiters =
                    [_parseCoordinator drainWaitersForSuccessfulClaim:claim
                                                              completed:&completed];
            [adopted addObjectsFromArray:
                    [self installCopiesOfMetadata:result onTracks:waiters]];
        } while (!completed);
        if (publishHolder) {
            [self publishTrack:track];
        }
        for (AudioTrack *waiter in adopted) {
            [self publishTrack:waiter];
        }
        [self settleTracks:tracks withMetadata:result];
        return;
    }

    BOOL publishFallback = [track installMetadataIfUnresolved:result];
    NSArray<AudioTrack *> *waiters = [_parseCoordinator completeClaim:claim];
    if (publishFallback) {
        [self publishTrack:track expectedMetadata:result];
    }
    for (AudioTrack *waiter in waiters) {
        AudioTrackMetadata *copy = [result copy];
        if ([waiter installMetadataIfUnresolved:copy]) {
            [self publishTrack:waiter expectedMetadata:copy];
        }
    }
    [self finishTracks:[tracks subarrayWithRange:NSMakeRange(0, ownerIndex + 1)]];
    // Only the row it read for takes a failure: the rows past it try the file
    // for themselves, as a record of their own.
    NSRange rest = NSMakeRange(ownerIndex + 1, tracks.count - ownerIndex - 1);
    if (rest.length > 0 && !self.isCancelled) {
        [self enqueueScanMaterialization:[[MetadataScanEntry alloc]
                initWithTracks:[tracks subarrayWithRange:rest]
              standardizedPath:entry.standardizedPath
                 playlistIndex:entry.playlistIndex]];
        [self dispatchNextScanMaterialization];
    }
}

- (NSArray<AudioTrack *> *)installCopiesOfMetadata:(AudioTrackMetadata *)metadata
                                           onTracks:(NSArray<AudioTrack *> *)tracks {
    NSMutableArray<AudioTrack *> *installed = [NSMutableArray array];
    for (AudioTrack *track in tracks) {
        if (track.metadata.parsedOK) {
            continue;
        }
        AudioTrackMetadata *copy = [metadata copy];
        if ([track installMetadataIfUnresolved:copy]) {
            [installed addObject:track];
        }
    }
    return installed;
}

// Ends each track's scan and retires the marks they satisfy.
- (void)finishTracks:(NSArray<AudioTrack *> *)tracks {
    os_unfair_lock_lock(&_materializationLock);
    for (AudioTrack *track in tracks) {
        [_tracksWithScanInFlight removeObject:track];
    }
    BOOL retired = [self retirePriorityMarksTargetingTracksLocked:tracks];
    os_unfair_lock_unlock(&_materializationLock);
    if (retired) {
        [self dispatchNextScanMaterialization];
    }
}

// Copies into every track still unresolved and publishes it, then finishes
// them all.
- (void)settleTracks:(NSArray<AudioTrack *> *)tracks withMetadata:(AudioTrackMetadata *)metadata {
    for (AudioTrack *adopted in [self installCopiesOfMetadata:metadata onTracks:tracks]) {
        [self publishTrack:adopted];
    }
    [self finishTracks:tracks];
}

- (AudioTrackMetadata *)parseAndCacheMetadataForTrack:(AudioTrack *)track {
    AudioTrackMetadataCache *owner = _owner;
    // Before the parse, which can block for minutes: an invalidate during it
    // makes the result stale for the cache.
    uint64_t generation = owner.cacheGeneration;
    // A local, so every skipped write below releases it with the frame.
    NSData *displayArt = nil;
    AudioTrackMetadata *metadata = _fileParser
            ? _fileParser(track.url)
            : [AudioTrackMetadata metadataWithURL:track.url displayArtData:&displayArt];
    // Re-read: a stat failure at cache-check time may have healed.
    NSString *cacheKey = track.cacheKey;
    if (metadata.parsedOK && cacheKey) {
        // A failed parse is never cached: its fallback would shadow the real
        // tags until the cache key changed. The write is synchronous so its
        // back-pressure paces the workers; async writes back up PINDiskCache's
        // queue. The generation is rechecked after the write because
        // removeAllObjects can slip between check and write, and the remove
        // keeps Clear Cache empty. Use the strong `owner`, never _owner, so
        // the pair cannot see the cache vanish midway.
        if (generation == owner.cacheGeneration) {
            [owner.metadataCache.diskCache setObject:metadata forKey:cacheKey];
            // Same write-then-recheck pair for the rendition.
            if (displayArt) {
                [owner.metadataCache.diskCache setObject:displayArt
                                                  forKey:VibeArchivedDisplayArtKey(cacheKey)];
            }
            if (generation != owner.cacheGeneration) {
                [owner.metadataCache.diskCache removeObjectForKey:cacheKey];
                [owner.metadataCache.diskCache
                        removeObjectForKey:VibeArchivedDisplayArtKey(cacheKey)];
            }
            VibeInstallArchivedDisplayArtProvider(metadata, owner.metadataCache, cacheKey);
        }
    }
    return metadata;
}

// Not gated on isCancelled: every caller won an install. The identity guard
// decides delivery, and the delegate drops a departed track.
- (void)publishTrack:(AudioTrack *)track {
    [self publishTrack:track expectedMetadata:track.metadata];
}

- (void)publishTrack:(AudioTrack *)track
    expectedMetadata:(AudioTrackMetadata *)expectedMetadata {
    if (!expectedMetadata) {
        return;
    }
    run_on_main_thread({
        // Holds the track monitor through the delegate, which may read
        // track.metadata but must never wait on a metadata worker.
        [track deliverIfMetadataStillInstalled:expectedMetadata usingBlock:^{
            [self.delegate didLoadMetadata:track];
        }];
    });
}

@end
