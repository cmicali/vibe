//
//  AudioTrackArtworkInternal.h
//  Vibe
//
//  AudioTrackArtwork's ivars and the helpers its two files share. Only
//  AudioTrackArtwork.m and AudioTrackArtwork+Loading.m import it; the test
//  seam is the (Internal) category in AudioTrackArtwork.h.
//

#import "AudioTrackArtwork.h"
#import "EmbeddedThumbnailCache.h"

NS_ASSUME_NONNULL_BEGIN

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

NS_ASSUME_NONNULL_END
