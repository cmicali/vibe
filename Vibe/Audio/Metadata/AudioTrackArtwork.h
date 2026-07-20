//
// AudioTrackArtwork.h
// Vibe
//
// The album-art state machine for one track: the decoded full-res image, the
// playlist thumbnail, the raw compressed art bytes, and the flags/generation
// counter that keep them coherent across background loads and track changes.
// AudioTrackMetadata delegates its art API here 1:1; caller-facing contracts
// (threading, blocking behavior) are documented in AudioTrackMetadata.h.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Blocking art extraction (file read + tag parse), supplied by the owner —
// TagLib is C++ and stays out of this class so it compiles as plain ObjC.
// Never invoked with the monitor held (the read can block for minutes on a
// cloud placeholder). nil means no art or an unreadable file.
typedef NSData * _Nullable (^AudioTrackArtworkExtractor)(NSString *path);

@interface AudioTrackArtwork : NSObject

// sourceFilePath is the audio file art can be (re-)extracted from; nil
// disables on-demand extraction. Immutable.
- (instancetype)initWithSourceFilePath:(nullable NSString *)sourceFilePath
                             extractor:(nullable AudioTrackArtworkExtractor)extractor;

// Archived by AudioTrackMetadata's encodeWithCoder:.
@property (nullable, readonly, copy) NSString *sourceFilePath;

// Fresh parse: the raw art bytes TagLib found (nil for an artless file).
// Marks extraction attempted either way, so an artless file never pays a
// second parse just to rediscover there is no art.
- (void)adoptParsedArtData:(nullable NSData *)artData;

// Cache hit (initWithCoder:): the archived thumbnail JPEG, nil for an artless
// entry. Decodes at a bounded pixel size (a tampered cache entry could carry
// a huge image) and derives the extraction-attempted flag — see the
// implementation.
- (void)adoptArchivedThumbnailJPEG:(nullable NSData *)jpegData;

// The AudioTrackMetadata art API, delegated here verbatim; contracts are on
// the matching AudioTrackMetadata.h declarations.
- (nullable NSImage *)albumArt;
- (nullable NSImage *)albumArtIfLoaded;
- (BOOL)albumArtNeedsLoad;
- (void)discardAlbumArtData;
// Does NOT touch albumArtLoadDispatched — that UI-side flag stays with the
// metadata object.
- (void)discardDecodedAlbumArt;
- (nullable NSImage *)thumbnailAlbumArt;

@end

NS_ASSUME_NONNULL_END
