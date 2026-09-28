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

// Parsed metadata is compact by construction: its embedded thumbnail is ready
// for caching and its original art bytes have already been released. The
// display-art rendition for the cache write comes back through displayArtData
// and never lands on the row.
+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url
                         displayArtData:(NSData *_Nullable __autoreleasing *_Nullable)displayArtData;

// The per-row art state, for the loader's storage round-trips: the archived
// display-art provider it stamps. Display callers use
// the facade's cachedArt/loadArt methods, never this. A method, not a property
// redeclaration — the class extension owns the property.
- (nullable AudioTrackArtwork *)artwork;

@end

NS_ASSUME_NONNULL_END
