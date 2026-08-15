//
// AudioTrackArtwork.h
// Vibe
//
// One track's EMBEDDED art — the art inside the audio file. The folder's cover
// is never state here; the accessors just fall back to the shared resolver.
// AudioTrackMetadata delegates its art API here one for one.
//
// Five states, and which one holds is decided entirely by these fields:
//
//   State         art  data  attempted  undecodable   folder fallback
//   ───────────────────────────────────────────────────────────────────
//   Unknown        —    —       NO          NO           REFUSED
//   BytesHeld      —    ✓       ✓           NO           refused
//   Decoded        ✓    ·       ✓           NO           refused
//   Artless        —    —       YES         NO           allowed
//   Undecodable    —    —       ·           YES          allowed
//
// **Unknown refuses the fallback**, which is the whole precedence rule: while
// the file's own art is merely unresolved, a folder cover must not stand in
// front of it. Only a settled "this file has none" opens that gate, and
// knownToCarryNoArtLocked (FolderArtRules.h) is its single home.
//
// Transitions. Only these five move the state:
//
//   adoptParsedArtData:        → BytesHeld, or Artless for nil bytes
//   adoptArchivedThumbnailJPEG:→ Artless for a nil archive, else the file has
//                                art that is not loaded (a cache hit carries no
//                                bytes; loadArtBlocking re-reads the file)
//   loadArtBlocking            → Unknown → BytesHeld → Decoded, or Undecodable
//   discardArtData             → drops bytes; re-arms to Unknown if nothing was
//                                decoded, so the file can be read again
//   discardDecodedArt          → drops everything, re-arms to Unknown, and is
//                                the ONLY thing that bumps the generation
//
// The generation fences a load in flight: discardDecodedArt runs on a track
// change, and a load that started before it must not store its result back, or
// a skip during a load re-pins the demoted track's art for the playlist's
// lifetime. Undecodable is permanent for the file's bytes and no discard
// clears it — otherwise every updateUI pass re-dispatches the same doomed
// decode.
//
// Locking: the monitor is never held across file I/O or a decode. Both can
// block for minutes on a cloud placeholder, and the main thread takes this
// monitor on every updateUI pass through cachedArt. Loads therefore run
// outside it, and at worst two callers do the same work and the first store
// wins.
//

#import <Foundation/Foundation.h>
#import "PlatformTypes.h"

NS_ASSUME_NONNULL_BEGIN

// Blocking art extraction — a file read and a tag parse — supplied by the
// owner. TagLib is C++ and stays out of this class so that it compiles as
// plain ObjC. It is never invoked with the monitor held, because the read can
// block for minutes on a cloud placeholder. nil means no art, or an unreadable
// file.
typedef NSData * _Nullable (^AudioTrackArtworkExtractor)(NSString *path);

@class FolderArtResolver;

@interface AudioTrackArtwork : NSObject

// sourceFilePath is the audio file the art can be extracted, or re-extracted,
// from. nil disables on-demand extraction. Immutable.
- (instancetype)initWithSourceFilePath:(nullable NSString *)sourceFilePath
                             extractor:(nullable AudioTrackArtworkExtractor)extractor;

// The resolver the folder fallback asks. Production leaves it at the shared one
// set in init; tests inject their own to drive the precedence rules against a
// known folder. Set it before the instance is shared across threads.
@property (nonatomic, strong) FolderArtResolver *folderArt;

// Archived by AudioTrackMetadata's encodeWithCoder:.
@property (nullable, readonly, copy) NSString *sourceFilePath;

// For a fresh parse: the raw art bytes TagLib found, or nil for an artless
// file. It marks extraction as attempted either way, so an artless file never
// pays for a second parse merely to rediscover that there is no art.
- (void)adoptParsedArtData:(nullable NSData *)artData;

// For a cache hit, through initWithCoder:: the archived thumbnail JPEG, or nil
// for an artless entry. It decodes at a bounded pixel size, since a tampered
// cache entry could carry a huge image, and derives the extraction-attempted
// flag; see the implementation.
- (void)adoptArchivedThumbnailJPEG:(nullable NSData *)jpegData;

// The thumbnail for the disk cache: the file's own art, never the folder's
// cover. The cache is keyed by the audio file's size and mtime, which a sidecar
// image cannot change, so an archived cover would outlive its file by up to the
// cache's age limit.
- (nullable VibeImage *)embeddedThumbnail;

// Decodes embedded art only. Metadata scanning uses this before publication so
// it cannot schedule folder-art resolution for every artless playlist row.
- (void)prewarmEmbeddedThumbnail;

// The AudioTrackMetadata art API, delegated here verbatim. The contracts sit
// on the matching AudioTrackMetadata.h declarations.
- (nullable VibeImage *)loadArtBlocking;
- (nullable VibeImage *)cachedArt;
- (BOOL)artNeedsLoad;
- (void)discardArtData;
// This does not touch artLoadDispatched. That UI-side flag stays with the
// metadata object.
- (void)discardDecodedArt;
- (nullable VibeImage *)cachedThumbnail;

@end

NS_ASSUME_NONNULL_END
