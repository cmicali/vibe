//
// AudioTrackArtwork.m
// Vibe
//
// One row's embedded-art state. Every transition takes the artwork monitor;
// no monitor spans I/O or a decode.
//

#import "AudioTrackArtwork.h"
#import "ArtworkLoadRegistry.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioWorkScheduler.h"
#import "EmbeddedThumbnailCache.h"
#import "FolderArtResolver.h"
#import "PlatformImage.h"

static const NSUInteger kEmbeddedThumbnailDecodeRunningCount = 2;
// Parked blocks for visible rows, unrelated to the pixel cache's count.
static const NSUInteger kEmbeddedThumbnailDecodePendingCount = 126;

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

static ArtworkLoadRegistry *sArtworkLoadRegistry;

ArtworkLoadRegistry *VibeSharedArtworkLoadRegistry(void) {
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

@implementation AudioTrackArtwork

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
    VibeEmbeddedThumbnailCacheLimitOverride = limit;
}

+ (void)clearDecodedThumbnailCacheForTesting {
    [VibeEmbeddedThumbnailCache() removeAllImages];
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

- (BOOL)isArtLoadPending {
    @synchronized (self) {
        return _artLoadPending;
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
