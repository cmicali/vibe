//
//  AudioTrackMetadataCache+Debug.h
//  Vibe
//
//  What the health oracle reads from background metadata materialization.
//  Declaration-only, like AudioPlayer+Debug.h.
//

#if DEBUG

#import "AudioTrackMetadataCache.h"

@class AudioLoadingConfiguration;

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataCache (Debug)

@property (nonatomic, readonly) AudioLoadingConfiguration *loadingConfiguration;

// Applies only to loaders constructed after this call. Existing work keeps
// its configuration snapshot.
- (void)applyLoadingConfiguration:(AudioLoadingConfiguration *)loadingConfiguration;

// The versioned PINCache store name reported by clear_caches.
+ (NSString *)cacheName;

// Stage-2 file acquisitions queued, delayed or in flight. Zero at rest, so the
// stress driver scores it as a pending counter. Main thread, like the rest of
// the cache's surface.
- (NSUInteger)debugPendingBackgroundMaterializationCount;

// The coordinator's isForegroundTransferActive, which suspends background
// materialization. Stopped and settled must read NO.
- (BOOL)debugBackgroundMaterializationHeld;

// The priority lane's bookkeeping, rows by file name. Main thread.
- (NSDictionary *)debugPriorityLaneState;

// The scan lane apart from priority rows, so a scenario can prove stage-1
// completion and scan demand without subtracting aggregates.
- (NSDictionary *)debugScanLaneState;

@end

NS_ASSUME_NONNULL_END

#endif
