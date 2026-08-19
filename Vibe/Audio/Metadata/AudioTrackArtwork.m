//
// AudioTrackArtwork.m
// Vibe
//
// One row's embedded-art state. The bounded async load registry it drives is
// ArtworkLoadRegistry. All per-row transitions use the artwork monitor; no
// monitor spans I/O or decode.
//

#import "AudioTrackArtworkInternal.h"
#import "ArtworkLoadRegistry.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioWorkScheduler.h"
#import "FolderArtResolver.h"
#import "PlatformImage.h"

// Three consecutive read failures end the current display attempt rather than
// letting updateUI dispatch forever. discardDecodedArt re-arms them when the
// track leaves the header, so a later visit can recover after the file or its
// provider becomes readable again.
static const NSUInteger kMaxEmbeddedArtExtractionFailures = 3;

// And how long after a failed read the next attempt may start. The count alone
// bounded how many reads a bad file cost but not how fast they were spent:
// updateUI runs several times in quick succession at a track start (begin
// loading, start playing, metadata, art), so all three attempts went back to
// back, each blocking a user-initiated worker for however long the failing read
// takes — and nothing about an unreachable provider changes between two calls
// milliseconds apart. The delay is what makes the second and third attempts
// worth making. It is not a poll: nothing schedules a retry, it only decides
// whether the next pass that asks is allowed to try.
static const NSTimeInterval kEmbeddedArtExtractionRetryBackoff = 2.0;

// The load-admission bounds live in ArtworkLoadRegistry.h, beside the
// registry that enforces them.
static const NSUInteger kEmbeddedThumbnailCacheCount = 128;
static const NSUInteger kEmbeddedThumbnailDecodeRunningCount = 2;
// Parked decode requests are visible rows awaiting pixels; the bound is app
// memory for parked blocks, unrelated to the pixel cache's own count.
static const NSUInteger kEmbeddedThumbnailDecodePendingCount = 126;

// NSCache treats its limits as eviction suggestions. The row-art guarantee is
// an actual bound, so keep the tiny LRU explicit: every image is decoded at no
// more than 128 x 128 pixels, and no more than 128 of them are retained here.
// In-flight decodes hold pixels outside the cache, bounded separately by the
// decode scheduler's running count plus the metadata worker pool.
@interface EmbeddedThumbnailKey : NSObject <NSCopying>
@end

@implementation EmbeddedThumbnailKey
- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}
@end

@interface EmbeddedThumbnailCache : NSObject
- (nullable VibeImage *)imageForKey:(EmbeddedThumbnailKey *)key;
- (void)setImage:(VibeImage *)image forKey:(EmbeddedThumbnailKey *)key;
- (void)removeImageForKey:(EmbeddedThumbnailKey *)key;
- (void)removeAllImages;
@property (nonatomic, readonly) NSUInteger count;
@end

@implementation EmbeddedThumbnailCache {
    NSMutableDictionary<EmbeddedThumbnailKey *, VibeImage *> *_images;
    NSMutableArray<EmbeddedThumbnailKey *> *_leastRecentlyUsedKeys;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _images = [NSMutableDictionary dictionary];
        _leastRecentlyUsedKeys = [NSMutableArray array];
    }
    return self;
}

- (VibeImage *)imageForKey:(EmbeddedThumbnailKey *)key {
    @synchronized (self) {
        VibeImage *image = _images[key];
        if (image) {
            [_leastRecentlyUsedKeys removeObjectIdenticalTo:key];
            [_leastRecentlyUsedKeys addObject:key];
        }
        return image;
    }
}

- (void)setImage:(VibeImage *)image forKey:(EmbeddedThumbnailKey *)key {
    @synchronized (self) {
        _images[key] = image;
        [_leastRecentlyUsedKeys removeObjectIdenticalTo:key];
        [_leastRecentlyUsedKeys addObject:key];
        while (_images.count > kEmbeddedThumbnailCacheCount) {
            EmbeddedThumbnailKey *evictedKey = _leastRecentlyUsedKeys.firstObject;
            [_leastRecentlyUsedKeys removeObjectAtIndex:0];
            [_images removeObjectForKey:evictedKey];
        }
    }
}

- (void)removeImageForKey:(EmbeddedThumbnailKey *)key {
    @synchronized (self) {
        [_images removeObjectForKey:key];
        [_leastRecentlyUsedKeys removeObjectIdenticalTo:key];
    }
}

- (void)removeAllImages {
    @synchronized (self) {
        [_images removeAllObjects];
        [_leastRecentlyUsedKeys removeAllObjects];
    }
}

- (NSUInteger)count {
    @synchronized (self) {
        return _images.count;
    }
}

@end


static EmbeddedThumbnailCache *VibeEmbeddedThumbnailCache(void) {
    static EmbeddedThumbnailCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[EmbeddedThumbnailCache alloc] init];
    });
    return cache;
}

static AudioWorkScheduler *VibeEmbeddedThumbnailDecodeScheduler(void) {
    static AudioWorkScheduler *scheduler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        scheduler = [[AudioWorkScheduler alloc]
                initWithLabel:@"com.vibe.embedded-thumbnail-decode"
                qualityOfService:QOS_CLASS_USER_INITIATED
                maximumRunningCount:kEmbeddedThumbnailDecodeRunningCount
                maximumPendingCount:kEmbeddedThumbnailDecodePendingCount
                pendingGrace:30];
    });
    return scheduler;
}

@interface AudioTrackArtwork ()
@property (nonatomic, strong, nullable) FolderArtResolver *folderArt;
@property (nonatomic, copy, nullable) AudioTrackArtworkClock clock;
@property (nullable, readonly, copy) NSString *sourceFilePath;
- (VibeImage *)embeddedArtForExpectedGeneration:(NSUInteger)expectedGeneration
                           sourceFileReadAllowed:(BOOL)sourceFileReadAllowed;
- (BOOL)prepareAsyncLoadReturningGeneration:(NSUInteger *)generation
                                  sourceURL:(NSURL * _Nullable * _Nonnull)sourceURL;
- (BOOL)isGenerationCurrent:(NSUInteger)generation;
- (void)clearLoadPendingForGeneration:(NSUInteger)generation;
- (void)invalidateDecodedArtForGeneration:(NSUInteger)generation;
- (void)discardDecodedArtStateLocked;
- (nullable VibeImage *)cachedEmbeddedThumbnail;
@end

static ArtworkLoadRegistry *sArtworkLoadRegistry;

static ArtworkLoadRegistry *VibeSharedArtworkLoadRegistry(void) {
    NSCAssert(NSThread.isMainThread, @"Artwork load admission is main-thread only");
    @synchronized ([AudioTrackArtwork class]) {
        if (!sArtworkLoadRegistry) {
            AudioWorkScheduler *scheduler = [[AudioWorkScheduler alloc]
                    initWithLabel:@"com.vibe.artwork"
                    qualityOfService:QOS_CLASS_USER_INITIATED
                    maximumRunningCount:kArtworkLoadMaximumRunningCount
                    maximumPendingCount:kArtworkLoadMaximumPendingCount
                    pendingGrace:kArtworkLoadPendingGrace];
            sArtworkLoadRegistry = [[ArtworkLoadRegistry alloc]
                    initWithMaterializationCoordinator:
                            AudioFileMaterializationCoordinator.sharedCoordinator
                    workScheduler:scheduler];
        }
        return sArtworkLoadRegistry;
    }
}

static ArtworkLoadRegistry *VibeExistingArtworkLoadRegistry(void) {
    @synchronized ([AudioTrackArtwork class]) {
        return sArtworkLoadRegistry;
    }
}

@implementation AudioTrackArtwork {
    // The key is the one staleness fence for thumbnail pixels: every data
    // transition replaces it (and clears the pending flag), so a decode is
    // current exactly when its captured key is still installed.
    EmbeddedThumbnailKey *_thumbnailCacheKey;
    NSData *_encodedThumbnailData;
    AudioTrackThumbnailDecoder _thumbnailDecoder;
    BOOL _thumbnailDecodePending;
    VibeImage *_embeddedArt;
    NSData *_embeddedArtData;
    AudioTrackArtworkExtractor _extractor;
    // The file carries art, in hand or not. Set by a parse that found bytes and
    // by an archive that recorded the fact, and never cleared by a discard —
    // the bytes go, the fact does not.
    BOOL _embeddedArtKnown;
    // YES only after extraction conclusively found art or found none. A read
    // failure leaves this NO, keeping the file unknown and the folder fallback
    // closed.
    BOOL _embeddedExtractionSettled;
    BOOL _embeddedExtractionInFlight;
    NSUInteger _embeddedExtractionFailures;
    // Monotonic seconds before which no further extraction may start, 0 for
    // none. Set by a failed read, cleared by anything that re-arms the budget.
    NSTimeInterval _embeddedExtractionRetryNotBefore;
    BOOL _embeddedUndecodable;
    NSUInteger _artGeneration;
    BOOL _artLoadPending;
}

+ (void)installArtLoadServicesForTesting:
        (AudioFileMaterializationCoordinator *)materializationCoordinator
                              workScheduler:(AudioWorkScheduler *)workScheduler {
    NSParameterAssert(NSThread.isMainThread);
    NSParameterAssert(materializationCoordinator);
    NSParameterAssert(workScheduler);
    @synchronized (self) {
        NSAssert(!sArtworkLoadRegistry || sArtworkLoadRegistry.registeredRequestCount == 0,
                 @"Cannot replace artwork load services while requests are live");
        sArtworkLoadRegistry = [[ArtworkLoadRegistry alloc]
                initWithMaterializationCoordinator:materializationCoordinator
                workScheduler:workScheduler];
    }
}

- (instancetype)initWithSourceFilePath:(NSString *)sourceFilePath
                             extractor:(AudioTrackArtworkExtractor)extractor {
    self = [super init];
    if (self) {
        _thumbnailCacheKey = [[EmbeddedThumbnailKey alloc] init];
        _sourceFilePath = [sourceFilePath copy];
        _extractor = [extractor copy];
#if TARGET_OS_OSX
        _folderArt = FolderArtResolver.sharedInstance;
#else
        // Folder art is a macOS feature. Left nil, every folder-art accessor
        // below is a message to nil: no cover image, and no background load
        // scheduled, so iOS shows a file's embedded art alone and the resolver
        // is never built.
        _folderArt = nil;
#endif
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    AudioTrackArtwork *copy = [[[self class] allocWithZone:zone]
            initWithSourceFilePath:self.sourceFilePath extractor:_extractor];
    copy.folderArt = self.folderArt;
    copy.clock = self.clock;
    @synchronized (self) {
        // Every transition field belongs to the new holder. A copied
        // art-bearing row carries only the thumbnail's compact bytes, matching
        // a disk-cache hit, and re-reads full-size bytes on demand.
        copy->_encodedThumbnailData = [_encodedThumbnailData copy];
        copy->_thumbnailDecoder = [_thumbnailDecoder copy];
        copy->_embeddedArtKnown = _embeddedArtKnown;
        copy->_embeddedUndecodable = _embeddedUndecodable;
        // Known-and-decodable re-arms extraction, since the copy carries no
        // full-size bytes; known-undecodable stays settled; unknown or artless
        // inherits.
        copy->_embeddedExtractionSettled = _embeddedArtKnown
                ? _embeddedUndecodable : _embeddedExtractionSettled;
    }
    // Deliberately no thumbnail transfer into the display LRU: only the
    // display request path populates it, and copies are made on parse workers
    // — a scan's duplicate rows must not evict visible rows' pixels. The
    // copy's thumbnail decodes on demand through the bounded display path.
    return copy;
}

// Read before taking the monitor, never under it — it is cheap and never
// blocks, but the injected form is arbitrary caller code.
- (NSTimeInterval)nowSeconds {
    AudioTrackArtworkClock clock = self.clock;
    return clock ? clock() : NSProcessInfo.processInfo.systemUptime;
}

// _embeddedExtractionRetryNotBefore is 0 whenever no read has failed, so this
// is also the answer for a track that has never been read at all.
- (BOOL)retryBackoffHasElapsedLocked:(NSTimeInterval)now {
    return now >= _embeddedExtractionRetryNotBefore;
}

- (BOOL)canStartEmbeddedExtractionLockedAt:(NSTimeInterval)now {
    return !_embeddedExtractionSettled && !_embeddedExtractionInFlight &&
            !_embeddedUndecodable &&
            _embeddedExtractionFailures < kMaxEmbeddedArtExtractionFailures &&
            [self retryBackoffHasElapsedLocked:now] &&
            _sourceFilePath != nil && _extractor != nil;
}

- (void)adoptParsedArtData:(NSData *)artData {
    EmbeddedThumbnailKey *departedCacheKey;
    @synchronized (self) {
        departedCacheKey = _thumbnailCacheKey;
        _thumbnailCacheKey = [[EmbeddedThumbnailKey alloc] init];
        _thumbnailDecodePending = NO;
        _embeddedArtData = artData;
        _encodedThumbnailData = nil;
        _embeddedArtKnown = (artData != nil);
        _embeddedExtractionSettled = YES;
        _embeddedExtractionInFlight = NO;
        _embeddedExtractionFailures = 0;
        _embeddedExtractionRetryNotBefore = 0;
    }
    [VibeEmbeddedThumbnailCache() removeImageForKey:departedCacheKey];
}

- (void)adoptArchivedThumbnailData:(NSData *)encodedData
                    hasEmbeddedArt:(BOOL)hasEmbeddedArt {
    EmbeddedThumbnailKey *departedCacheKey;
    @synchronized (self) {
        departedCacheKey = _thumbnailCacheKey;
        _thumbnailCacheKey = [[EmbeddedThumbnailKey alloc] init];
        _thumbnailDecodePending = NO;
        _encodedThumbnailData = [encodedData copy];
        _embeddedArtKnown = hasEmbeddedArt;
        // An entry that knows of no art is artless: mark it settled rather
        // than re-reading the file for art that is not there. An art-bearing
        // entry stays NO, so the full-resolution image is re-read on demand.
        _embeddedExtractionSettled = !hasEmbeddedArt;
        _embeddedExtractionInFlight = NO;
        _embeddedExtractionFailures = 0;
        _embeddedExtractionRetryNotBefore = 0;
    }
    [VibeEmbeddedThumbnailCache() removeImageForKey:departedCacheKey];
}

- (NSData *)encodedThumbnailDataForStorage {
    @synchronized (self) {
        return _encodedThumbnailData;
    }
}

- (void)storeEncodedThumbnailData:(NSData *)encodedData {
    if (!encodedData.length) {
        return;
    }
    @synchronized (self) {
        _encodedThumbnailData = [encodedData copy];
    }
}

- (AudioTrackThumbnailDecoder)thumbnailDecoder {
    @synchronized (self) {
        return _thumbnailDecoder;
    }
}

- (void)setThumbnailDecoder:(AudioTrackThumbnailDecoder)thumbnailDecoder {
    @synchronized (self) {
        _thumbnailDecoder = [thumbnailDecoder copy];
    }
}

- (BOOL)hasEmbeddedArt {
    @synchronized (self) {
        return _embeddedArtKnown;
    }
}

- (BOOL)decodedThumbnailIsCachedForTesting {
    EmbeddedThumbnailKey *key;
    @synchronized (self) {
        key = _thumbnailCacheKey;
    }
    return [VibeEmbeddedThumbnailCache() imageForKey:key] != nil;
}

- (void)evictDecodedThumbnailForTesting {
    EmbeddedThumbnailKey *key;
    @synchronized (self) {
        key = _thumbnailCacheKey;
    }
    [VibeEmbeddedThumbnailCache() removeImageForKey:key];
}

+ (NSUInteger)decodedThumbnailCacheCountForTesting {
    return VibeEmbeddedThumbnailCache().count;
}

+ (NSUInteger)decodedThumbnailCacheLimitForTesting {
    return kEmbeddedThumbnailCacheCount;
}

+ (void)clearDecodedThumbnailCacheForTesting {
    [VibeEmbeddedThumbnailCache() removeAllImages];
}

// The file's own art, or the folder's cover when it has none. Blocking on both
// paths; the folder side resolves its directory the first time any track in it
// asks — see FolderArtResolver, which owns the cost rules.
- (VibeImage *)loadArtBlocking {
    NSUInteger generation;
    @synchronized (self) {
        generation = _artGeneration;
    }
    return [self loadArtBlockingForExpectedGeneration:generation
                                sourceFileReadAllowed:YES];
}

- (VibeImage *)loadArtBlockingForExpectedGeneration:(NSUInteger)generation
                              sourceFileReadAllowed:(BOOL)sourceFileReadAllowed {
    VibeImage *embedded = [self embeddedArtForExpectedGeneration:generation
                                           sourceFileReadAllowed:sourceFileReadAllowed];
    if (embedded) {
        return embedded;
    }
    NSString *path;
    @synchronized (self) {
        if (generation != _artGeneration) {
            return nil;
        }
        path = [self folderFallbackPathLocked];
    }
    return [self.folderArt displayImageForAudioFilePath:path];
}

// Full-resolution art decodes lazily, so only the tracks actually displayed
// pay the decode and memory cost. Cache-hit instances carry no art bytes,
// which are not archived, and re-extract from the audio file on demand. Only
// the current track ever takes that path.
- (VibeImage *)embeddedArtForExpectedGeneration:(NSUInteger)expectedGeneration
                           sourceFileReadAllowed:(BOOL)sourceFileReadAllowed {
    NSString *pathToExtract = nil;
    NSData *dataToDecode = nil;
    BOOL dataWasInMemory = NO;
    VibeEmbeddedArtExtractionResult extractionResult = VibeEmbeddedArtExtractionReadFailed;
    NSUInteger generation;
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        // This check and the source-extraction claim are one critical section.
        // A demotion therefore lands wholly before the read (which never starts)
        // or wholly after its claim (when it is legitimately uncancellable).
        if (expectedGeneration != _artGeneration) {
            return nil;
        }
        generation = expectedGeneration;
        if (_embeddedArt) {
            return _embeddedArt;
        }
        if (_embeddedArtData) {
            dataToDecode = _embeddedArtData;
            dataWasInMemory = YES;
        }
        else if ([self canStartEmbeddedExtractionLockedAt:now]) {
            if (!sourceFileReadAllowed) {
                return nil;
            }
            _embeddedExtractionInFlight = YES;
            pathToExtract = _sourceFilePath;
        }
        // A conclusive artless result is never re-read, while a failed read gets
        // a small bounded retry budget, no faster than the backoff. Claim the
        // call under the lock so concurrent callers do not double-extract.
        else {
            return nil;
        }
    }
    // File I/O and the decode run outside the lock; see the discipline above.
    if (!dataToDecode && pathToExtract) {
        extractionResult = _extractor(pathToExtract, &dataToDecode);
        if (extractionResult == VibeEmbeddedArtExtractionFoundArt && !dataToDecode) {
            LogWarn(@"Embedded art extractor reported art without bytes for %@",
                    pathToExtract.lastPathComponent);
            extractionResult = VibeEmbeddedArtExtractionReadFailed;
        }
    }
    VibeImage *decoded = dataToDecode
            ? VibeDecodedImageWithData(dataToDecode, kVibeDisplayArtDimension)
            : nil;
    // The injected test clock is sampled after the read. Production starts its
    // relative timer here for the same reason: a blocked read has already given
    // the condition time to change; an immediate failure needs the full gate.
    NSTimeInterval completedAt = [self nowSeconds];
    @synchronized (self) {
        if (pathToExtract) {
            _embeddedExtractionInFlight = NO;
            if (extractionResult == VibeEmbeddedArtExtractionReadFailed) {
                // A demotion starts a fresh display pass. Its generation bump
                // re-armed the budget, so an older read must not spend one of
                // the new pass's attempts, or hold the new pass off behind a
                // backoff, when it finally settles.
                if (generation == _artGeneration) {
                    _embeddedExtractionFailures = MIN(kMaxEmbeddedArtExtractionFailures,
                                                       _embeddedExtractionFailures + 1);
                    _embeddedExtractionRetryNotBefore =
                            completedAt + kEmbeddedArtExtractionRetryBackoff;
                }
                return _embeddedArt; // a concurrent store, if one arrived
            }
            _embeddedExtractionFailures = 0;
            _embeddedExtractionRetryNotBefore = 0;
            if (extractionResult == VibeEmbeddedArtExtractionNoArt) {
                _embeddedArtKnown = NO;
                _embeddedExtractionSettled = YES;
                return _embeddedArt;
            }
            _embeddedArtKnown = YES;
            _embeddedExtractionSettled = YES;
        }
        if (dataToDecode && !decoded) {
            // The bytes exist but cannot be decoded, which is permanent for
            // this file. Mark it and drop the bytes rather than pinning them.
            _embeddedUndecodable = YES;
            _embeddedArtData = nil;
            return _embeddedArt; // still nil unless a concurrent store won
        }
        // Store back only if no track-change discard ran mid-load. Otherwise
        // return the result transiently, without re-pinning a demoted track's
        // art. A racing discardArtData is fine, since it only wants the
        // raw bytes gone.
        if (generation == _artGeneration) {
            // Cache the bytes only when they were freshly read from the file.
            // Bytes that have gone from _embeddedArtData by now were dropped by
            // discardArtData mid-decode, and restoring them would undo
            // its memory release.
            if (dataToDecode && !_embeddedArtData && !dataWasInMemory) {
                _embeddedArtData = dataToDecode;
            }
            if (!_embeddedArt && decoded) {
                _embeddedArt = decoded;
            }
        }
        else if (dataToDecode) {
            // Nothing is stored, but the file demonstrably has art, so re-arm
            // the on-demand re-read. This load claimed the attempt flag on
            // entry, and the discard's early return left that claim in place.
            _embeddedExtractionSettled = NO;
        }
        return _embeddedArt ?: decoded;
    }
}

// The gate on every folder-art fallback below. Call with the monitor held.
- (BOOL)knownToCarryNoArtLocked {
    // _embeddedArtKnown covers what the other three cannot: a cache hit whose
    // entry was written before the thumbnail was archived, and a parsed track
    // whose bytes have been discarded, both of which have art without holding
    // any of it.
    BOOL hasArtOfItsOwn = _embeddedArtKnown || _embeddedArt != nil ||
                          _embeddedArtData != nil || _encodedThumbnailData != nil;
    if (_embeddedUndecodable) {
        return YES;
    }
    if (hasArtOfItsOwn) {
        return NO;
    }
    return _embeddedExtractionSettled;
}

// The file to ask the folder about, or nil when the folder must not be asked.
// Every fallback below goes through this one line, so the guarantee that a
// cover can never stand in front of a track's own art has exactly one home.
// Call with the monitor held. nil is a contractual argument to every
// FolderArtResolver accessor, so callers pass the result straight on.
- (NSString *)folderFallbackPathLocked {
    return [self knownToCarryNoArtLocked] ? _sourceFilePath : nil;
}

- (VibeImage *)cachedArt {
    NSString *path;
    @synchronized (self) {
        if (_embeddedArt) {
            return _embeddedArt;
        }
        path = [self folderFallbackPathLocked];
    }
    // No decode and no file access: this is the main thread's updateUI
    // accessor, and both happen on the background loadArtBlocking path that
    // artNeedsLoad asks for. The folder's cover comes back only if it is
    // already decoded.
    return [self.folderArt cachedDisplayImageForAudioFilePath:path];
}

- (BOOL)artNeedsLoad {
    NSString *path;
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        if (_embeddedArt) {
            return NO;
        }
        // Either there are in-memory bytes still to decode, or the file has
        // not been read. Both are background work worth dispatching. The
        // backoff is applied here as well as in embeddedArt, so a pass inside
        // the window answers NO rather than dispatching a load that would take
        // the pending marker and immediately no-op.
        BOOL canExtract = [self canStartEmbeddedExtractionLockedAt:now];
        if (!_embeddedUndecodable && (_embeddedArtData != nil || canExtract)) {
            return YES;
        }
        path = [self folderFallbackPathLocked];
    }
    // The file has no art of its own, or none that decodes. A load is still
    // worth dispatching while the folder's cover is unsettled or undecoded, and
    // FolderArtResolver answers NO for good once a folder is known to have none, so
    // this cannot spin.
    return [self.folderArt needsBackgroundLoadForAudioFilePath:path];
}

- (BOOL)isArtLoadPending {
    @synchronized (self) {
        return _artLoadPending;
    }
}

- (BOOL)prepareAsyncLoadReturningGeneration:(NSUInteger *)generation
                                  sourceURL:(NSURL **)sourceURL {
    NSParameterAssert(generation);
    NSParameterAssert(sourceURL);
    if (![self artNeedsLoad]) {
        return NO;
    }
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        if (_artLoadPending || _embeddedArt) {
            return NO;
        }
        BOOL canExtract = [self canStartEmbeddedExtractionLockedAt:now];
        BOOL needsEmbeddedWork = !_embeddedUndecodable &&
                (_embeddedArtData != nil || canExtract);
        *sourceURL = needsEmbeddedWork && canExtract && !_embeddedArtData
                ? [NSURL fileURLWithPath:_sourceFilePath] : nil;
        *generation = _artGeneration;
        _artLoadPending = YES;
        return YES;
    }
}

- (void)loadArtIfNeededWithLabel:(NSString *)label
                     stillWanted:(BOOL (^)(void))stillWanted
                       completion:(void (^)(VibeImage *))completion {
    NSParameterAssert(NSThread.isMainThread);
    NSParameterAssert(stillWanted);
    NSParameterAssert(completion);
    [VibeSharedArtworkLoadRegistry() loadArtwork:self label:label
                                     stillWanted:stillWanted completion:completion];
}

- (BOOL)isGenerationCurrent:(NSUInteger)generation {
    @synchronized (self) {
        return _artGeneration == generation;
    }
}

- (void)clearLoadPendingForGeneration:(NSUInteger)generation {
    @synchronized (self) {
        if (_artGeneration == generation) {
            _artLoadPending = NO;
        }
    }
}

// Drops the full-size compressed art bytes once the thumbnail exists. Freshly
// parsed instances otherwise pin 0.5-5MB per track for the whole session.
// Afterwards the instance behaves like a cache hit: loadArtBlocking re-reads the
// audio file on demand for the one track shown at full resolution.
- (void)discardArtData {
    @synchronized (self) {
        // There is deliberately no generation bump. This only wants the raw
        // bytes released, not an in-flight decode of those same bytes thrown
        // away.
        if (!_embeddedArtData) {
            // There is nothing to drop. Keep the settled flag: an artless
            // track has it set to YES from the parse, and resetting it would
            // trigger a full TagLib re-parse merely to rediscover that there
            // is no art.
            return;
        }
        // If thumbnail encoding failed, keep the source bytes. Otherwise a
        // shared-cache eviction would make this row's list art unrecoverable.
        if (_embeddedArtKnown && !_encodedThumbnailData) {
            return;
        }
        _embeddedArtData = nil;
        if (!_embeddedArt) {
            // Art exists but is not yet decoded, so re-arm the on-demand
            // re-read.
            _embeddedExtractionSettled = NO;
            _embeddedExtractionFailures = 0;
            _embeddedExtractionRetryNotBefore = 0;
        }
    }
}

// Called by the UI, on the main thread, when this track stops being current.
- (void)discardDecodedArt {
    NSParameterAssert(NSThread.isMainThread);
    @synchronized (self) {
        [self discardDecodedArtStateLocked];
    }
    [VibeExistingArtworkLoadRegistry() cancelLoadsForArtwork:self];
}

- (void)invalidateDecodedArtForGeneration:(NSUInteger)generation {
    @synchronized (self) {
        if (_artGeneration == generation) {
            [self discardDecodedArtStateLocked];
        }
    }
}

// Call with the monitor held.
- (void)discardDecodedArtStateLocked {
    // Bump before every early exit. This is both the store fence and the request
    // identity presented under the extraction-claim lock.
    _artGeneration++;
    _artLoadPending = NO;
    if (!_embeddedExtractionSettled && !_embeddedUndecodable) {
        _embeddedExtractionFailures = 0;
        _embeddedExtractionRetryNotBefore = 0;
    }
    // TRAP: _embeddedExtractionInFlight is deliberately NOT cleared here. It is
    // the single-flight claim over a read already running outside the monitor.
    if (!_embeddedArt && !_embeddedArtData) {
        return;
    }
    _embeddedArt = nil;
    _embeddedArtData = nil;
    _embeddedExtractionSettled = NO;
}

- (VibeImage *)cachedThumbnail {
    VibeImage *embedded = [self cachedEmbeddedThumbnail];
    if (embedded) {
        return embedded;
    }
    NSString *path;
    @synchronized (self) {
        // A track with its own art never asks the folder anything, so a fully
        // tagged playlist never opens a cover file at all.
        path = [self folderFallbackPathLocked];
    }
    // Non-blocking, so a playlist cell may call this while drawing: an
    // unresolved folder resolves in the background, and the notification brings
    // the row back to be redrawn.
    return [self.folderArt cachedThumbnailForAudioFilePath:path resolveIfUnknown:YES];
}

- (VibeImage *)cachedEmbeddedThumbnail {
    EmbeddedThumbnailKey *key;
    @synchronized (self) {
        key = _thumbnailCacheKey;
    }
    VibeImage *cached = [VibeEmbeddedThumbnailCache() imageForKey:key];
    if (!cached) {
        return nil;
    }
    @synchronized (self) {
        // adopt* may have rotated the key between the capture and the lookup;
        // an identity mismatch means those pixels belong to departed data.
        return key == _thumbnailCacheKey ? cached : nil;
    }
}

// Metadata construction and archive encoding run on metadata workers and need
// pixels once, to produce compact bytes. This never inserts into the shared
// display cache, so a playlist-wide scan cannot evict visible rows' pixels.
// UI paths use cachedThumbnail plus the bounded request below instead.
- (VibeImage *)decodeThumbnailForArchiving {
    VibeImage *cached = [self cachedEmbeddedThumbnail];
    if (cached) {
        return cached;
    }
    NSData *dataToDecode = nil;
    BOOL decodingStoredThumbnail = NO;
    EmbeddedThumbnailKey *cacheKey;
    AudioTrackThumbnailDecoder decoder;
    @synchronized (self) {
        dataToDecode = _encodedThumbnailData ?: _embeddedArtData;
        decodingStoredThumbnail = _encodedThumbnailData != nil;
        if (!dataToDecode) {
            return nil;
        }
        cacheKey = _thumbnailCacheKey;
        decoder = _thumbnailDecoder;
    }
    VibeImage *thumbnail = decoder
            ? decoder(dataToDecode)
            : VibeDecodedImageWithData(dataToDecode, kVibeThumbnailArtDimension);
    if (thumbnail) {
        return thumbnail;
    }
    @synchronized (self) {
        if (cacheKey != _thumbnailCacheKey) {
            return nil;
        }
        [self markThumbnailDecodeFailureLockedForData:dataToDecode
                                decodingStoredThumbnail:decodingStoredThumbnail];
    }
    return nil;
}

// _thumbnailCacheKey's monitor held. The bytes conclusively failed to decode:
// drop them so redraws stop retrying, and rotate the key so any concurrent
// decode of the departed bytes reads as stale.
- (void)markThumbnailDecodeFailureLockedForData:(NSData *)dataToDecode
                        decodingStoredThumbnail:(BOOL)decodingStoredThumbnail {
    if (decodingStoredThumbnail && [_encodedThumbnailData isEqual:dataToDecode]) {
        // A corrupt archived thumbnail does not prove the source art is bad.
        // Drop only the compact copy; full art can re-extract.
        _encodedThumbnailData = nil;
        _thumbnailCacheKey = [[EmbeddedThumbnailKey alloc] init];
        _thumbnailDecodePending = NO;
    }
    else if (!decodingStoredThumbnail && [_embeddedArtData isEqual:dataToDecode]) {
        // The same undecodable marking as the full-resolution path.
        // Otherwise every playlist cell redraw retries doomed bytes.
        _embeddedUndecodable = YES;
        _embeddedArtData = nil;
        _thumbnailCacheKey = [[EmbeddedThumbnailKey alloc] init];
        _thumbnailDecodePending = NO;
    }
}

- (BOOL)requestEmbeddedThumbnailDecodeWithCompletion:
        (void (^)(VibeImage *_Nullable image))completion {
    NSParameterAssert(NSThread.isMainThread);
    NSParameterAssert(completion);
    if ([self cachedEmbeddedThumbnail]) {
        return NO;
    }

    __block NSData *dataToDecode;
    __block BOOL decodingStoredThumbnail;
    __block EmbeddedThumbnailKey *cacheKey;
    __block AudioTrackThumbnailDecoder decoder;
    @synchronized (self) {
        if (_thumbnailDecodePending) {
            return NO;
        }
        dataToDecode = _encodedThumbnailData ?: _embeddedArtData;
        if (!dataToDecode) {
            return NO;
        }
        decodingStoredThumbnail = _encodedThumbnailData != nil;
        cacheKey = _thumbnailCacheKey;
        decoder = _thumbnailDecoder;
        _thumbnailDecodePending = YES;
    }

    [VibeEmbeddedThumbnailDecodeScheduler() submitWork:^{
        VibeImage *thumbnail = decoder
                ? decoder(dataToDecode)
                : VibeDecodedImageWithData(dataToDecode, kVibeThumbnailArtDimension);
        // Keep the scheduler slot until main has consumed the decoded result.
        // Otherwise a busy main queue can accumulate a second, unbounded tail
        // of pixel objects after the bounded worker says those jobs finished.
        dispatch_sync(dispatch_get_main_queue(), ^{
            BOOL current = NO;
            @synchronized (self) {
                // Key identity is the whole staleness check. A match also
                // proves the pending flag is this request's: rotation clears
                // it, and only one request per key epoch can set it. The store
                // stays under this monitor so a rotation cannot land between
                // the check and the insert and strand pixels under a departed
                // key.
                current = cacheKey == self->_thumbnailCacheKey;
                if (current) {
                    self->_thumbnailDecodePending = NO;
                    if (thumbnail) {
                        [VibeEmbeddedThumbnailCache() setImage:thumbnail
                                                        forKey:cacheKey];
                    }
                    else {
                        [self markThumbnailDecodeFailureLockedForData:dataToDecode
                                              decodingStoredThumbnail:decodingStoredThumbnail];
                    }
                }
            }
            completion(current ? thumbnail : nil);
        });
    } failureQueue:dispatch_get_main_queue()
      admissionFailure:^(VibeAudioWorkAdmissionFailure failure) {
        (void)failure;
        @synchronized (self) {
            if (cacheKey == self->_thumbnailCacheKey) {
                self->_thumbnailDecodePending = NO;
            }
        }
        completion(nil);
    }];
    return YES;
}

@end
