//
//  AudioTrackArtworkInternal.h
//  Vibe
//
//  One metadata row's art state behind the AudioTrackMetadata facade; only
//  the metadata implementation and tests import this.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

@class AudioFileMaterializationCoordinator;
@class AudioWorkScheduler;
@class FolderArtResolver;

typedef NSTimeInterval (^AudioTrackArtworkClock)(void);
typedef VibeImage *_Nullable (^AudioTrackThumbnailDecoder)(NSData *_Nonnull data);

NS_ASSUME_NONNULL_BEGIN

// The TagLib read AudioTrackMetadata.mm supplies; blocking, never called
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
- (BOOL)artNeedsLoad;
- (void)discardDecodedArt;
- (nullable VibeImage *)cachedThumbnail;

@property (nonatomic, readonly, getter=isArtLoadPending) BOOL artLoadPending;

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

NS_ASSUME_NONNULL_END
