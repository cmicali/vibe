//
//  AudioTrackArtworkInternal.h
//  Vibe
//
//  One metadata row's embedded-art state and bounded asynchronous loader.
//  AudioTrackMetadata is the display-facing facade; only its implementation
//  and focused tests import this header.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

@class AudioFileMaterializationCoordinator;
@class AudioWorkScheduler;
@class FolderArtResolver;

typedef NSTimeInterval (^AudioTrackArtworkClock)(void);
typedef VibeImage *_Nullable (^AudioTrackThumbnailDecoder)(NSData *_Nonnull data);

NS_ASSUME_NONNULL_BEGIN

// TagLib stays in AudioTrackMetadata.mm. The plain-ObjC artwork state receives
// only this blocking extraction block and never invokes it while holding its
// monitor.
typedef NS_ENUM(NSUInteger, VibeEmbeddedArtExtractionResult) {
    VibeEmbeddedArtExtractionReadFailed,
    VibeEmbeddedArtExtractionNoArt,
    VibeEmbeddedArtExtractionFoundArt,
};

typedef VibeEmbeddedArtExtractionResult (^AudioTrackArtworkExtractor)(
        NSString *path,
        NSData * _Nullable __autoreleasing * _Nullable artData);

@interface AudioTrackArtwork : NSObject <NSCopying>

- (instancetype)initWithSourceFilePath:(nullable NSString *)sourceFilePath
                             extractor:(nullable AudioTrackArtworkExtractor)extractor;

- (void)adoptParsedArtData:(nullable NSData *)artData;
- (void)adoptArchivedThumbnailData:(nullable NSData *)encodedData
                    hasEmbeddedArt:(BOOL)hasEmbeddedArt;
- (nullable NSData *)encodedThumbnailDataForStorage;
- (void)storeEncodedThumbnailData:(nullable NSData *)encodedData;

@property (readonly) BOOL hasEmbeddedArt;

// The archive-encode path's one decode: cached pixels if present, otherwise a
// fresh decode that never inserts into the shared display cache, so a
// playlist-wide scan cannot evict visible rows' thumbnails. Metadata workers
// only; UI paths use cachedThumbnail plus the bounded request below.
- (nullable VibeImage *)decodeThumbnailForArchiving;

// cachedThumbnail never decodes. This is the bounded off-main counterpart for
// an embedded thumbnail whose compact bytes survived a pixel-cache eviction.
// YES means this call admitted the one request for the row; a duplicate while
// that request is live returns NO. A request that starts completes once on
// main, with nil when the bytes did not decode or admission failed.
- (BOOL)requestEmbeddedThumbnailDecodeWithCompletion:
        (void (^)(VibeImage *_Nullable image))completion;

- (nullable VibeImage *)cachedArt;
- (BOOL)artNeedsLoad;
- (void)discardDecodedArt;
- (nullable VibeImage *)cachedThumbnail;

@property (nonatomic, readonly, getter=isArtLoadPending) BOOL artLoadPending;

- (void)loadArtIfNeededWithLabel:(nullable NSString *)label
                     stillWanted:(BOOL (^)(void))stillWanted
                       completion:(void (^)(VibeImage *_Nullable art))completion;

@end

@interface AudioTrackArtwork (Internal)

// Construction/cache state and test seams. Production keeps the shared macOS
// resolver and monotonic clock installed by init; iOS leaves the resolver nil.
@property (nonatomic, strong, nullable) FolderArtResolver *folderArt;
@property (nonatomic, copy, nullable) AudioTrackArtworkClock clock;
@property (nullable, readonly, copy) NSString *sourceFilePath;

// Metadata construction/cache storage only. Parsed art is reduced to compact
// row-thumbnail bytes before publication, then its original bytes are freed.
- (void)discardArtData;

// Test-only decoder seam. Production leaves it nil and uses the bounded
// PlatformImage ImageIO decode. Install it before requesting a decode.
@property (nonatomic, copy, nullable) AudioTrackThumbnailDecoder thumbnailDecoder;

// Focused proof that archived rows decode lazily and can recover after the
// shared thumbnail cache evicts their pixels.
- (BOOL)decodedThumbnailIsCachedForTesting;
- (void)evictDecodedThumbnailForTesting;
+ (NSUInteger)decodedThumbnailCacheCountForTesting;
+ (NSUInteger)decodedThumbnailCacheLimitForTesting;
+ (void)clearDecodedThumbnailCacheForTesting;

// Synchronous seam for the state-machine tests. UI callers use the bounded
// asynchronous method above.
- (nullable VibeImage *)loadArtBlocking;

// Replaces the shared async services once no request is live. Production never
// calls this; focused tests install isolated coordinators and schedulers.
+ (void)installArtLoadServicesForTesting:
        (AudioFileMaterializationCoordinator *)materializationCoordinator
                              workScheduler:(AudioWorkScheduler *)workScheduler;

// A blocking request may claim extraction only while this exact generation is
// current. Kept internal so a test can prove the demotion fence without racing
// thread scheduling.
- (nullable VibeImage *)loadArtBlockingForExpectedGeneration:(NSUInteger)generation
                                       sourceFileReadAllowed:(BOOL)sourceFileReadAllowed;

@end

NS_ASSUME_NONNULL_END
