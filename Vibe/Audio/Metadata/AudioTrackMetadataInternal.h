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
// for caching and its original art bytes have already been released.
+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url;

// The per-row art state, for the loader's storage round-trips: the archived
// display-art stash it writes and the provider it stamps. Display callers use
// the facade's cachedArt/loadArt methods, never this. A method, not a property
// redeclaration — the class extension owns the property.
- (nullable AudioTrackArtwork *)artwork;

@end

NS_ASSUME_NONNULL_END
