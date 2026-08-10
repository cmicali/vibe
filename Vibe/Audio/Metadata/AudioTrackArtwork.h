//
// AudioTrackArtwork.h
// Vibe
//
// The album-art state machine for one track: the decoded full-resolution
// image, the playlist thumbnail, the raw compressed art bytes, and the flags
// and generation counter that keep them coherent across background loads and
// track changes. AudioTrackMetadata delegates its art API here one for one,
// and AudioTrackMetadata.h documents the caller-facing contracts on threading
// and blocking.
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

@interface AudioTrackArtwork : NSObject

// sourceFilePath is the audio file the art can be extracted, or re-extracted,
// from. nil disables on-demand extraction. Immutable.
- (instancetype)initWithSourceFilePath:(nullable NSString *)sourceFilePath
                             extractor:(nullable AudioTrackArtworkExtractor)extractor;

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

// The AudioTrackMetadata art API, delegated here verbatim. The contracts sit
// on the matching AudioTrackMetadata.h declarations.
- (nullable VibeImage *)albumArt;
- (nullable VibeImage *)albumArtIfLoaded;
- (BOOL)albumArtNeedsLoad;
- (void)discardAlbumArtData;
// This does not touch albumArtLoadDispatched. That UI-side flag stays with the
// metadata object.
- (void)discardDecodedAlbumArt;
- (nullable VibeImage *)thumbnailAlbumArt;

@end

NS_ASSUME_NONNULL_END
