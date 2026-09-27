//
//  AudioTrackMetadataCacheInternal.h
//  Vibe
//
//  What AudioTrackMetadataLoader needs from the cache that owns it.
//

#import "AudioTrackMetadataCache.h"
// Imported: a generic argument needs the real @interface.
#import "MetadataParseCoordinator.h"

@class PINCache;
@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataCache ()
// Atomic: set asynchronously after init, read per track from the loader's
// workers.
@property (atomic, strong, nullable) PINCache *metadataCache;
// Bumped by invalidation. A parse captures it at start, skips its write if it
// moved and rechecks after, or a parse in flight during Clear Cache would
// repopulate the emptied cache.
- (uint64_t)cacheGeneration;
// One parse per standardized path, shared by every loader: duplicate rows and
// the scan and priority slots would otherwise each parse the same file.
@property (nonatomic, readonly) MetadataParseCoordinator<AudioTrack *> *parseCoordinator;
@end

NS_ASSUME_NONNULL_END
