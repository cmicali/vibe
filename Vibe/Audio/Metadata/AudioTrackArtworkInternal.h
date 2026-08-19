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

@property (readonly) BOOL hasEmbeddedArt;
- (nullable VibeImage *)embeddedThumbnail;

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

// Metadata construction/cache storage only. Parsed art is reduced to its row
// thumbnail before publication, then its original compressed bytes are freed.
- (void)prewarmEmbeddedThumbnail;
- (void)discardArtData;

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
