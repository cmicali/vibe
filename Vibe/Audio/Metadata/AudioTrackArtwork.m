//
// AudioTrackArtwork.m
// Vibe
//
// One row's embedded-art state. Every transition takes the artwork monitor;
// no monitor spans I/O or a decode.
//

#import "AudioTrackArtworkInternal.h"
#import "ArtworkLoadRegistry.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioWorkScheduler.h"
#import "FolderArtResolver.h"
#import "PlatformImage.h"

// Failed reads per display pass; discardDecodedArt re-arms them.
static const NSUInteger kMaxEmbeddedArtExtractionFailures = 3;

// The gap after a failed read: a track start runs updateUI several times in
// quick succession, which would spend every attempt back to back. Not a
// poll; it only gates the next pass that asks.
static const NSTimeInterval kEmbeddedArtExtractionRetryBackoff = 2.0;

// A session's scrolled rows stay decoded (spec H): <=128px RGBA, ~64 KiB each,
// ~1 GiB only at 16k distinct rows. iOS flushes it on a memory warning rather
// than carrying a byte cap.
static const NSUInteger kEmbeddedThumbnailCacheCount = 16384;
// Test-only; 0 is the production bound.
static NSUInteger sEmbeddedThumbnailCacheLimitOverride = 0;
static NSUInteger VibeEmbeddedThumbnailCacheLimit(void) {
    return sEmbeddedThumbnailCacheLimitOverride
            ?: kEmbeddedThumbnailCacheCount;
}
static const NSUInteger kEmbeddedThumbnailDecodeRunningCount = 2;
// Parked blocks for visible rows, unrelated to the pixel cache's count.
static const NSUInteger kEmbeddedThumbnailDecodePendingCount = 126;

// What is known about the file's own art; Unknown is the zero value. The
// HasArt states split on whether this display pass still needs a source read,
// and demotion moves Settled back to NeedsRead. Outside it:
// _embeddedExtractionInFlight (a claim that survives demotion) and
// _embeddedUndecodable (a verdict about bytes).
typedef NS_ENUM(NSUInteger, VibeEmbeddedArtFact) {
    VibeEmbeddedArtFactUnknown = 0,      // never conclusively determined
    VibeEmbeddedArtFactArtless,          // conclusively carries none
    VibeEmbeddedArtFactHasArtNeedsRead,  // carries art; full bytes need a read
    VibeEmbeddedArtFactHasArtSettled,    // carries art; this pass needs no read
};

static inline BOOL VibeEmbeddedArtFactHasArt(VibeEmbeddedArtFact fact) {
    return fact == VibeEmbeddedArtFactHasArtNeedsRead
            || fact == VibeEmbeddedArtFactHasArtSettled;
}

// No further source read wanted this pass.
static inline BOOL VibeEmbeddedArtFactIsSettled(VibeEmbeddedArtFact fact) {
    return fact == VibeEmbeddedArtFactArtless
            || fact == VibeEmbeddedArtFactHasArtSettled;
}

// An explicit LRU: NSCache treats its limits as suggestions, and this bound
// must hold.
@interface EmbeddedThumbnailKey : NSObject <NSCopying>
@end

@implementation EmbeddedThumbnailKey
- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}
@end

// TRAP: _images is the sole owner of every node; the links are unowned (strong
// ones would cycle along the chain). Safe only because every removal unlinks
// the node first, in the same critical section.
@interface EmbeddedThumbnailNode : NSObject
@property (nonatomic, strong) VibeImage *image;
@property (nonatomic, strong) EmbeddedThumbnailKey *key;
@property (nonatomic, unsafe_unretained, nullable) EmbeddedThumbnailNode *newer;
@property (nonatomic, unsafe_unretained, nullable) EmbeddedThumbnailNode *older;
@end

@implementation EmbeddedThumbnailNode
@end

@interface EmbeddedThumbnailCache : NSObject
- (nullable VibeImage *)imageForKey:(EmbeddedThumbnailKey *)key;
- (void)setImage:(VibeImage *)image forKey:(EmbeddedThumbnailKey *)key;
- (void)removeImageForKey:(EmbeddedThumbnailKey *)key;
- (void)removeAllImages;
@property (nonatomic, readonly) NSUInteger count;
@end

// O(1) per operation: every row draw hits it.
@implementation EmbeddedThumbnailCache {
    NSMutableDictionary<EmbeddedThumbnailKey *, EmbeddedThumbnailNode *> *_images;
    __unsafe_unretained EmbeddedThumbnailNode *_mostRecent;
    __unsafe_unretained EmbeddedThumbnailNode *_leastRecent;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _images = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Recency list. All four run with the monitor held.

- (void)unlinkNode:(EmbeddedThumbnailNode *)node {
    if (node.newer) {
        node.newer.older = node.older;
    }
    else if (_mostRecent == node) {
        _mostRecent = node.older;
    }
    if (node.older) {
        node.older.newer = node.newer;
    }
    else if (_leastRecent == node) {
        _leastRecent = node.newer;
    }
    node.newer = nil;
    node.older = nil;
}

- (void)linkNodeAtHead:(EmbeddedThumbnailNode *)node {
    node.older = _mostRecent;
    node.newer = nil;
    _mostRecent.newer = node;
    _mostRecent = node;
    if (!_leastRecent) {
        _leastRecent = node;
    }
}

- (void)touchNode:(EmbeddedThumbnailNode *)node {
    if (_mostRecent == node) {
        return;
    }
    [self unlinkNode:node];
    [self linkNodeAtHead:node];
}

// Unlink before the removal that frees, so a caller may pass the unowned
// _leastRecent.
// TRAP: the strong local is load-bearing. Once the row is gone the dictionary
// and the node hold the key's only references (copyWithZone: returns self),
// so the removal would otherwise hash a key its own value had just freed.
- (void)evictNode:(EmbeddedThumbnailNode *)node {
    EmbeddedThumbnailKey *key = node.key;
    [self unlinkNode:node];
    [_images removeObjectForKey:key];
}

#pragma mark -

- (VibeImage *)imageForKey:(EmbeddedThumbnailKey *)key {
    @synchronized (self) {
        EmbeddedThumbnailNode *node = _images[key];
        if (!node) {
            return nil;
        }
        [self touchNode:node];
        return node.image;
    }
}

- (void)setImage:(VibeImage *)image forKey:(EmbeddedThumbnailKey *)key {
    @synchronized (self) {
        EmbeddedThumbnailNode *node = _images[key];
        if (node) {
            node.image = image;
            [self touchNode:node];
        }
        else {
            node = [[EmbeddedThumbnailNode alloc] init];
            node.image = image;
            node.key = key;
            _images[key] = node;
            [self linkNodeAtHead:node];
        }
        while (_images.count > VibeEmbeddedThumbnailCacheLimit() && _leastRecent) {
            [self evictNode:_leastRecent];
        }
    }
}

- (void)removeImageForKey:(EmbeddedThumbnailKey *)key {
    @synchronized (self) {
        EmbeddedThumbnailNode *node = _images[key];
        if (node) {
            [self evictNode:node];
        }
    }
}

- (void)removeAllImages {
    @synchronized (self) {
        // The unowned ends must not outlive the nodes.
        _mostRecent = nil;
        _leastRecent = nil;
        [_images removeAllObjects];
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
#if !TARGET_OS_OSX
        // No pressure eviction of its own; visible rows re-request.
        [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification *note) {
            (void)note;
            [cache removeAllImages];
        }];
#endif
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
    // The one staleness fence for thumbnail pixels: every data transition
    // replaces it and clears the pending flag.
    EmbeddedThumbnailKey *_thumbnailCacheKey;
    NSData *_encodedThumbnailData;
    AudioTrackThumbnailDecoder _thumbnailDecoder;
    BOOL _thumbnailDecodePending;
    VibeImage *_embeddedArt;
    NSData *_embeddedArtData;
    AudioTrackArchivedDisplayArtProvider _archivedDisplayArtProvider;
    AudioTrackArtworkExtractor _extractor;
    // A read failure leaves Unknown, keeping the folder fallback closed.
    VibeEmbeddedArtFact _embeddedArtFact;
    BOOL _embeddedExtractionInFlight;
    NSUInteger _embeddedExtractionFailures;
    // Monotonic; 0 for none.
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
        // macOS-only: nil makes every folder-art accessor a no-op.
        _folderArt = nil;
#endif
    }
    return self;
}

// Keyed by this instance alone, so nothing else can remove the entry. A
// decode in flight retains self, so none lands after.
- (void)dealloc {
    [VibeEmbeddedThumbnailCache() removeImageForKey:_thumbnailCacheKey];
}

- (id)copyWithZone:(NSZone *)zone {
    AudioTrackArtwork *copy = [[[self class] allocWithZone:zone]
            initWithSourceFilePath:self.sourceFilePath extractor:_extractor];
    copy.folderArt = self.folderArt;
    copy.clock = self.clock;
    @synchronized (self) {
        // Like a cache hit: compact bytes only, full art re-read on demand.
        copy->_encodedThumbnailData = [_encodedThumbnailData copy];
        copy->_thumbnailDecoder = [_thumbnailDecoder copy];
        // Same disk entry.
        copy->_archivedDisplayArtProvider = _archivedDisplayArtProvider;
        copy->_embeddedUndecodable = _embeddedUndecodable;
        copy->_embeddedArtFact = VibeEmbeddedArtFactHasArt(_embeddedArtFact)
                ? (_embeddedUndecodable ? VibeEmbeddedArtFactHasArtSettled
                                        : VibeEmbeddedArtFactHasArtNeedsRead)
                : _embeddedArtFact;
    }
    // No display-LRU entry: copies are made on parse workers, and a scan's
    // duplicate rows must not evict visible pixels.
    return copy;
}

// Never under the monitor: the injected clock is arbitrary code.
- (NSTimeInterval)nowSeconds {
    AudioTrackArtworkClock clock = self.clock;
    return clock ? clock() : NSProcessInfo.processInfo.systemUptime;
}

- (BOOL)retryBackoffHasElapsedLocked:(NSTimeInterval)now {
    return now >= _embeddedExtractionRetryNotBefore;
}

- (BOOL)canStartEmbeddedExtractionLockedAt:(NSTimeInterval)now {
    return !VibeEmbeddedArtFactIsSettled(_embeddedArtFact)
            && !_embeddedExtractionInFlight &&
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
        // The loader re-stamps the provider once the fresh entry is written.
        _archivedDisplayArtProvider = nil;
        _embeddedArtFact = artData != nil ? VibeEmbeddedArtFactHasArtSettled
                                          : VibeEmbeddedArtFactArtless;
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
        _archivedDisplayArtProvider = nil;
        _embeddedArtFact = hasEmbeddedArt ? VibeEmbeddedArtFactHasArtNeedsRead
                                          : VibeEmbeddedArtFactArtless;
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

- (AudioTrackArchivedDisplayArtProvider)archivedDisplayArtProvider {
    @synchronized (self) {
        return _archivedDisplayArtProvider;
    }
}

- (void)setArchivedDisplayArtProvider:(AudioTrackArchivedDisplayArtProvider)provider {
    @synchronized (self) {
        _archivedDisplayArtProvider = [provider copy];
    }
}

- (NSData *)artDataForArchivedDisplayArt {
    @synchronized (self) {
        return _embeddedArtData;
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
        return VibeEmbeddedArtFactHasArt(_embeddedArtFact);
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
    return VibeEmbeddedThumbnailCacheLimit();
}

// Applies from the next setImage:; the caller clears the cache around it.
+ (void)setDecodedThumbnailCacheLimitForTesting:(NSUInteger)limit {
    sEmbeddedThumbnailCacheLimitOverride = limit;
}

+ (void)clearDecodedThumbnailCacheForTesting {
    [VibeEmbeddedThumbnailCache() removeAllImages];
}

// The file's own art, or the folder's cover when it has none. Blocking.
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

// Lazy: only displayed tracks pay the decode. Order: decoded art, in-memory
// bytes, archived rendition, source-file extraction.
- (VibeImage *)embeddedArtForExpectedGeneration:(NSUInteger)expectedGeneration
                           sourceFileReadAllowed:(BOOL)sourceFileReadAllowed {
    NSString *pathToExtract = nil;
    NSData *dataToDecode = nil;
    BOOL dataWasInMemory = NO;
    AudioTrackArchivedDisplayArtProvider providerToRead = nil;
    VibeEmbeddedArtExtractionResult extractionResult = VibeEmbeddedArtExtractionReadFailed;
    NSUInteger generation;
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        // One critical section with the extraction claim: a demotion lands
        // wholly before the read or wholly after its claim.
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
        else if (_archivedDisplayArtProvider) {
            // No extraction claim: a concurrent read is at worst redundant,
            // and the store is generation-fenced.
            providerToRead = _archivedDisplayArtProvider;
        }
        else if ([self canStartEmbeddedExtractionLockedAt:now]) {
            if (!sourceFileReadAllowed) {
                return nil;
            }
            _embeddedExtractionInFlight = YES;
            pathToExtract = _sourceFilePath;
        }
        else {
            return nil;
        }
    }
    // Outside the monitor: a provider read can block indefinitely.
    if (providerToRead) {
        dataToDecode = providerToRead();
        VibeImage *decodedProviderArt = dataToDecode
                ? VibeDecodedImageWithData(dataToDecode, kVibeDisplayArtDimension)
                : nil;
        if (!decodedProviderArt) {
            // Not undecodable: the file's own art may be fine. Drop the
            // provider and take the demotion fence, so finishRequest
            // re-requests a still-wanted row and the next pass extracts.
            @synchronized (self) {
                if (_archivedDisplayArtProvider == providerToRead) {
                    _archivedDisplayArtProvider = nil;
                }
                if (generation == _artGeneration) {
                    _artGeneration++;
                    _artLoadPending = NO;
                }
            }
            return nil;
        }
        @synchronized (self) {
            // Never re-pinned as _embeddedArtData; a re-read is cheap.
            if (generation == _artGeneration && !_embeddedArt) {
                _embeddedArt = decodedProviderArt;
            }
            return _embeddedArt ?: decodedProviderArt;
        }
    }
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
    // The backoff runs from completion: a read that blocked already waited.
    NSTimeInterval completedAt = [self nowSeconds];
    @synchronized (self) {
        if (pathToExtract) {
            _embeddedExtractionInFlight = NO;
            if (extractionResult == VibeEmbeddedArtExtractionReadFailed) {
                // A superseded read must not spend the new pass's budget.
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
                _embeddedArtFact = VibeEmbeddedArtFactArtless;
                return _embeddedArt;
            }
            _embeddedArtFact = VibeEmbeddedArtFactHasArtSettled;
        }
        if (dataToDecode && !decoded) {
            // Permanent for this file; drop the bytes.
            _embeddedUndecodable = YES;
            _embeddedArtData = nil;
            return _embeddedArt; // still nil unless a concurrent store won
        }
        // Store only if no demotion ran mid-load; otherwise return it
        // transiently.
        if (generation == _artGeneration) {
            // Only freshly read bytes: in-memory ones gone by now were dropped
            // by discardArtData, and restoring them would undo it.
            if (dataToDecode && !_embeddedArtData && !dataWasInMemory) {
                _embeddedArtData = dataToDecode;
            }
            if (!_embeddedArt && decoded) {
                _embeddedArt = decoded;
            }
        }
        else if (dataToDecode) {
            // Superseded: nothing stored, but the file has art, so the new
            // pass must read again.
            _embeddedArtFact = VibeEmbeddedArtFactHasArtNeedsRead;
        }
        return _embeddedArt ?: decoded;
    }
}

// The gate on every folder-art fallback below. Call with the monitor held.
- (BOOL)knownToCarryNoArtLocked {
    // The fact covers rows that have art but hold no bytes.
    BOOL hasArtOfItsOwn = VibeEmbeddedArtFactHasArt(_embeddedArtFact) ||
                          _embeddedArt != nil ||
                          _embeddedArtData != nil || _encodedThumbnailData != nil;
    if (_embeddedUndecodable) {
        return YES;
    }
    if (hasArtOfItsOwn) {
        return NO;
    }
    return _embeddedArtFact == VibeEmbeddedArtFactArtless;
}

// The one home of "embedded beats folder": the file to ask the folder about,
// or nil, which every FolderArtResolver accessor accepts. Monitor held.
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
    // No decode, no file access: the folder's cover only if already decoded.
    return [self.folderArt cachedDisplayImageForAudioFilePath:path];
}

- (BOOL)artNeedsLoad {
    NSString *path;
    NSTimeInterval now = [self nowSeconds];
    @synchronized (self) {
        if (_embeddedArt) {
            return NO;
        }
        // The backoff applies here too, so a pass inside the window answers
        // NO rather than dispatching a load that would no-op.
        BOOL canExtract = [self canStartEmbeddedExtractionLockedAt:now];
        if (!_embeddedUndecodable && (_embeddedArtData != nil ||
                _archivedDisplayArtProvider != nil || canExtract)) {
            return YES;
        }
        path = [self folderFallbackPathLocked];
    }
    // Cannot spin: the resolver answers NO for good once a folder has none.
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
        BOOL hasArchivedRendition = _archivedDisplayArtProvider != nil;
        BOOL needsEmbeddedWork = !_embeddedUndecodable &&
                (_embeddedArtData != nil || hasArchivedRendition || canExtract);
        // No source URL while a rendition stands in: it must not materialize
        // the song.
        *sourceURL = needsEmbeddedWork && canExtract && !_embeddedArtData &&
                !hasArchivedRendition
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

// Drops the original art bytes once the thumbnail exists; the row then
// behaves like a cache hit.
- (void)discardArtData {
    @synchronized (self) {
        // No generation bump: an in-flight decode of these bytes stays valid.
        if (!_embeddedArtData) {
            return;
        }
        // Without thumbnail bytes these are the row art's only source.
        if (VibeEmbeddedArtFactHasArt(_embeddedArtFact) && !_encodedThumbnailData) {
            return;
        }
        _embeddedArtData = nil;
        if (!_embeddedArt) {
            if (VibeEmbeddedArtFactHasArt(_embeddedArtFact)) {
                _embeddedArtFact = VibeEmbeddedArtFactHasArtNeedsRead;
            }
            _embeddedExtractionFailures = 0;
            _embeddedExtractionRetryNotBefore = 0;
        }
    }
}

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
    // Before any early exit: the store fence and the request identity.
    _artGeneration++;
    _artLoadPending = NO;
    if (!VibeEmbeddedArtFactIsSettled(_embeddedArtFact) && !_embeddedUndecodable) {
        _embeddedExtractionFailures = 0;
        _embeddedExtractionRetryNotBefore = 0;
    }
    // TRAP: _embeddedExtractionInFlight is not cleared: it claims a read still
    // running outside the monitor, and clearing it would let the next pass
    // start a second uncancellable read.
    if (!_embeddedArt && !_embeddedArtData) {
        return;
    }
    _embeddedArt = nil;
    _embeddedArtData = nil;
    // Held art or bytes imply HasArt: the bytes go, the fact stays.
    _embeddedArtFact = VibeEmbeddedArtFactHasArtNeedsRead;
}

- (BOOL)embeddedThumbnailDecodeHasSource {
    @synchronized (self) {
        return _encodedThumbnailData != nil || _embeddedArtData != nil
                || _archivedDisplayArtProvider != nil;
    }
}

- (VibeImage *)cachedThumbnail {
    VibeImage *embedded = [self cachedEmbeddedThumbnail];
    if (embedded) {
        return embedded;
    }
    NSString *path;
    @synchronized (self) {
        path = [self folderFallbackPathLocked];
    }
    // Non-blocking; an unresolved folder resolves in the background and its
    // notification redraws the row.
    return [self.folderArt cachedThumbnailForAudioFilePath:path];
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
        // adopt* may have rotated the key since the capture.
        return key == _thumbnailCacheKey ? cached : nil;
    }
}

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

// Monitor held. Drops bytes that failed to decode, so redraws stop retrying,
// and rotates the key so a concurrent decode of them reads as stale.
- (void)markThumbnailDecodeFailureLockedForData:(NSData *)dataToDecode
                        decodingStoredThumbnail:(BOOL)decodingStoredThumbnail {
    if (decodingStoredThumbnail && [_encodedThumbnailData isEqual:dataToDecode]) {
        // A corrupt compact copy says nothing about the source art.
        _encodedThumbnailData = nil;
        _thumbnailCacheKey = [[EmbeddedThumbnailKey alloc] init];
        _thumbnailDecodePending = NO;
    }
    else if (!decodingStoredThumbnail && [_embeddedArtData isEqual:dataToDecode]) {
        // As the full-resolution path marks it.
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
    __block AudioTrackArchivedDisplayArtProvider archivedProvider;
    __block BOOL decodingStoredThumbnail;
    __block EmbeddedThumbnailKey *cacheKey;
    __block AudioTrackThumbnailDecoder decoder;
    @synchronized (self) {
        if (_thumbnailDecodePending) {
            return NO;
        }
        dataToDecode = _encodedThumbnailData ?: _embeddedArtData;
        if (!dataToDecode) {
            // An art-bearing entry with no thumbnail bytes (the 128px
            // re-encode failed) recovers through the archived rendition.
            archivedProvider = _archivedDisplayArtProvider;
            if (!archivedProvider) {
                LogDebug(@"Thumb request %@: no bytes and no rendition — dead end",
                         _sourceFilePath.lastPathComponent);
                return NO;
            }
        }
        decodingStoredThumbnail = _encodedThumbnailData != nil;
        cacheKey = _thumbnailCacheKey;
        decoder = _thumbnailDecoder;
        _thumbnailDecodePending = YES;
    }

    [VibeEmbeddedThumbnailDecodeScheduler() submitWork:^{
        NSData *bytes = dataToDecode ?: archivedProvider();
        VibeImage *thumbnail = !bytes ? nil : (decoder
                ? decoder(bytes)
                : VibeDecodedImageWithData(bytes, kVibeThumbnailArtDimension));
        // Sync, keeping the slot until main consumes the pixels: async would
        // let a busy main queue pile up an unbounded tail of them.
        dispatch_sync(dispatch_get_main_queue(), ^{
            BOOL current = NO;
            @synchronized (self) {
                // Key identity is the staleness check, and a match proves the
                // pending flag is this request's. The insert stays under the
                // monitor so a rotation cannot strand pixels under a dead key.
                current = cacheKey == self->_thumbnailCacheKey;
                if (current) {
                    self->_thumbnailDecodePending = NO;
                    if (thumbnail) {
                        [VibeEmbeddedThumbnailCache() setImage:thumbnail
                                                        forKey:cacheKey];
                    }
                    else if (dataToDecode) {
                        [self markThumbnailDecodeFailureLockedForData:dataToDecode
                                              decodingStoredThumbnail:decodingStoredThumbnail];
                    }
                    // A failed rendition marks nothing about the file's art.
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
