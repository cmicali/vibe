//
//  AudioTrackMetadataInternal.h
//  Vibe
//
//  Metadata-loader-only construction surface.
//

#import "AudioTrackMetadata.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadata (Internal)

// Parsed metadata is compact by construction: its embedded thumbnail is ready
// for caching and its original art bytes have already been released.
+ (AudioTrackMetadata *)metadataWithURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
