//
//  AudioTrackMetadataCacheInternal.h
//  Vibe
//
//  What AudioTrackMetadataLoader needs from the cache that owns it, and nothing
//  else reaches. Same shape as AudioPlayerInternal.h.
//

#import "AudioTrackMetadataCache.h"
// Imported, not forward-declared: the property below is parameterized, and a
// generic argument needs the real @interface.
#import "MetadataParseCoordinator.h"

@class PINCache;
@class AudioTrack;

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataCache ()
// Atomic, because it is created asynchronously at utility QoS and read from
// the loader's worker threads, and re-read per track; see
// loadTrackFromDiskCache: and parseOneTrack:.
@property (atomic, strong) PINCache *metadataCache;
// The invalidation generation; see the waveform cache's _cacheGeneration for
// the full contract. A parse captures it when it starts, skips its disk write
// if it has moved, and re-checks after the write lands — otherwise a parse in
// flight during Settings > Clear Cache would repopulate the emptied cache.
- (uint64_t)cacheGeneration;
// The cross-lane parse claims, keyed on the file URL rather than the track
// object, because the same file can occupy several playlist rows as distinct
// AudioTracks. The scan's stage-2 op and the priority lane can both pass their
// parsedOK entry checks before either finishes, as on a folder drop with
// auto-play, paying for the full TagLib parse, thumbnail decode and disk write
// twice for the same file. One holder and its weak duplicate-row waiters per
// URL; every loader shares this one, through its own MetadataParseFlow.
@property (nonatomic, readonly) MetadataParseCoordinator<AudioTrack *> *parseCoordinator;
@end

NS_ASSUME_NONNULL_END
