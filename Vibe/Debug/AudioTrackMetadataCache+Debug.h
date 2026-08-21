//
//  AudioTrackMetadataCache+Debug.h
//  Vibe
//
//  What the health oracle reads from background metadata materialization. Both
//  values belong at rest — a settled sweep has no pending file acquisition
//  and is not held — so the stress driver scores them as pending
//  counters rather than as information.
//
//  A held lane at rest is the failure this exists for: the hold is set when a
//  slow open starts and cleared when it settles, so a teardown that loses the
//  clearing edge leaves the whole sweep suspended, and the symptom is metadata
//  that simply never arrives for anything.
//
//  Declaration-only, like AudioPlayer+Debug.h: both implementations stay in the
//  classes' own .m files, where the ivars are, and re-declaring here is what
//  keeps the shipping headers free of #if DEBUG.
//
//  Debug builds only, like everything in this directory.
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

// Stage-2 file acquisitions queued by the scan and not yet settled. Main
// thread only, like the rest of the cache's surface.
- (NSUInteger)debugPendingBackgroundMaterializationCount;

// Whether background materialization is suspended by the foreground-download
// hold.
- (BOOL)debugBackgroundMaterializationHeld;

// The priority lane's request bookkeeping by track name: queued, parked, the
// later-load markers, and the live materialization token count. Main thread.
- (NSDictionary *)debugPriorityLaneState;

@end

NS_ASSUME_NONNULL_END

#endif
