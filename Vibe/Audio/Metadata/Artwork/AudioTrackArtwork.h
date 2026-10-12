//
//  AudioTrackArtwork.h
//  Vibe
//
//  One metadata row's art state behind the AudioTrackMetadata facade; only
//  the metadata implementation and tests import this. Its last section is
//  the state AudioTrackArtwork.m and its +Loading category share.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

@class ArtworkLoadRegistry;
@class AudioFileMaterializationCoordinator;
@class AudioWorkScheduler;
@class EmbeddedThumbnailKey;
@class FolderArtResolver;

typedef NSTimeInterval (^AudioTrackArtworkClock)(void);
typedef VibeImage *_Nullable (^AudioTrackThumbnailDecoder)(NSData *_Nonnull data);

NS_ASSUME_NONNULL_BEGIN

// The TagLib read TagLibAudioFile.mm supplies; blocking, never called
// with the monitor held.
typedef NS_ENUM(NSUInteger, VibeEmbeddedArtExtractionResult) {
    VibeEmbeddedArtExtractionReadFailed,
    VibeEmbeddedArtExtractionNoArt,
    VibeEmbeddedArtExtractionFoundArt,
};

typedef VibeEmbeddedArtExtractionResult (^AudioTrackArtworkExtractor)(
        NSString *path,
        NSData * _Nullable __autoreleasing * _Nullable artData);

// A blocking read of the archived rendition, on a worker, never with the
// monitor held. nil means it is gone and the load falls back to extraction.
typedef NSData *_Nullable (^AudioTrackArchivedDisplayArtProvider)(void);

@interface AudioTrackArtwork : NSObject <NSCopying>

- (instancetype)initWithSourceFilePath:(nullable NSString *)sourceFilePath
                             extractor:(nullable AudioTrackArtworkExtractor)extractor;

- (void)adoptParsedArtData:(nullable NSData *)artData;
- (void)adoptArchivedThumbnailData:(nullable NSData *)encodedData
                    hasEmbeddedArt:(BOOL)hasEmbeddedArt;
- (nullable NSData *)encodedThumbnailDataForStorage;
- (void)storeEncodedThumbnailData:(nullable NSData *)encodedData;

// Read before file extraction. An empty or undecodable read drops it and
// takes the demotion fence: one extra pass, never a stall. adopt* clears it;
// the loader re-stamps.
@property (nonatomic, copy, nullable) AudioTrackArchivedDisplayArtProvider archivedDisplayArtProvider;

// The original bytes, for cutting the rendition; nil after discardArtData.
// Metadata workers only.
- (nullable NSData *)artDataForArchivedDisplayArt;

@property (readonly) BOOL hasEmbeddedArt;

// Never inserts into the display cache, so a scan cannot evict visible
// pixels. Metadata workers only.
- (nullable VibeImage *)decodeThumbnailForArchiving;

// The bounded off-main decode behind cachedThumbnail. YES admitted the row's
// one request; a duplicate returns NO. Completes once on main, nil on failure.
// A row with no thumbnail bytes decodes from the archived rendition.
- (BOOL)requestEmbeddedThumbnailDecodeWithCompletion:
        (void (^)(VibeImage *_Nullable image))completion;

// Non-blocking. NO means the request above has nothing to decode, so a
// drawing path (the mini player polls at display rate) skips it.
- (BOOL)embeddedThumbnailDecodeHasSource;

- (nullable VibeImage *)cachedArt;
- (void)discardDecodedArt;
- (nullable VibeImage *)cachedThumbnail;

@property (nonatomic, readonly, getter=isArtLoadPending) BOOL artLoadPending;

@end

// The full-art load, in AudioTrackArtwork+Loading.m.
@interface AudioTrackArtwork (Loading)

- (BOOL)artNeedsLoad;

- (void)loadArtIfNeededWithLabel:(nullable NSString *)label
                     stillWanted:(BOOL (^)(void))stillWanted
                       completion:(void (^)(VibeImage *_Nullable art))completion;

@end

@interface AudioTrackArtwork (Internal)

// Test seams; init installs the macOS resolver (nil on iOS) and uptime clock.
@property (nonatomic, strong, nullable) FolderArtResolver *folderArt;
@property (nonatomic, copy, nullable) AudioTrackArtworkClock clock;
@property (nullable, readonly, copy) NSString *sourceFilePath;

// After the thumbnail is encoded, before publication.
- (void)discardArtData;

// Test-only; install before requesting a decode.
@property (nonatomic, copy, nullable) AudioTrackThumbnailDecoder thumbnailDecoder;

- (BOOL)decodedThumbnailIsCachedForTesting;
- (void)evictDecodedThumbnailForTesting;
+ (NSUInteger)decodedThumbnailCacheCountForTesting;
+ (NSUInteger)decodedThumbnailCacheLimitForTesting;
// 0 restores the production bound.
+ (void)setDecodedThumbnailCacheLimitForTesting:(NSUInteger)limit;
+ (void)clearDecodedThumbnailCacheForTesting;

// Tests only.
- (nullable VibeImage *)loadArtBlocking;

// Tests only, while no request is live.
+ (void)installArtLoadServicesForTesting:
        (AudioFileMaterializationCoordinator *)materializationCoordinator
                              workScheduler:(AudioWorkScheduler *)workScheduler;

// Claims extraction only while generation is current; exposed so a test can
// prove the demotion fence without racing threads.
- (nullable VibeImage *)loadArtBlockingForExpectedGeneration:(NSUInteger)generation
                                       sourceFileReadAllowed:(BOOL)sourceFileReadAllowed;

@end

#pragma mark - Shared by AudioTrackArtwork.m and +Loading

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

@interface AudioTrackArtwork () {
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
    // sourceFilePath's storage, declared so +Loading can read it.
    NSString *_sourceFilePath;
}
@property (nonatomic, strong, nullable) FolderArtResolver *folderArt;
@property (nonatomic, copy, nullable) AudioTrackArtworkClock clock;
@property (nullable, readonly, copy) NSString *sourceFilePath;
- (void)discardDecodedArtStateLocked;
- (nullable VibeImage *)cachedEmbeddedThumbnail;
- (nullable NSString *)folderFallbackPathLocked;
@end

// The one registry, made on first use. Main thread only.
ArtworkLoadRegistry *VibeSharedArtworkLoadRegistry(void);

NS_ASSUME_NONNULL_END
