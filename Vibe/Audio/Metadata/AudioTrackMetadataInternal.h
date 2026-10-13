//
//  AudioTrackMetadataInternal.h
//  Vibe
//
//  Metadata-loader-only construction surface.
//

#import "AudioTrackMetadata.h"

@class AudioTrackArtwork;

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadata (Internal)

// Encodes the row thumbnail before publication. Original art bytes are
// released when that succeeds. The display-art rendition comes back through
// displayArtData for the cache write; the row never retains that rendition.
+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url
                         displayArtData:(NSData *_Nullable __autoreleasing *_Nullable)displayArtData;

// The per-row art state, for the loader's storage round-trips: the archived
// display-art provider it stamps. Display callers use
// the facade's cachedArt/loadArt methods, never this. A method, not a property
// redeclaration — the class extension owns the property.
- (nullable AudioTrackArtwork *)artwork;

@end

NS_ASSUME_NONNULL_END
