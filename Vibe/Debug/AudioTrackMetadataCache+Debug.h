//
//  AudioTrackMetadataCache+Debug.h
//  Vibe
//
//  What the health oracle reads from the metadata cache's cloud lane. Both of
//  these belong at rest — a sweep that has settled holds no pending cloud
//  parse and is not suspended — so the stress driver scores them as pending
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
#import "AudioTrackMetadataLoader.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadataLoader (Debug)
// Cloud-lane operations queued and not yet started. Zero in the current-track
// lane, which has no cloud queue.
- (NSUInteger)debugPendingCloudParseCount;
@end

@interface AudioTrackMetadataCache (Debug)

// Stage-2 parses queued on the scan's cloud lane and not yet started. Main
// thread only, like the rest of the cache's surface.
- (NSUInteger)debugPendingCloudParseCount;

// Whether the cloud lane is currently suspended by the foreground-download
// hold.
- (BOOL)debugCloudParsesHeld;

@end

NS_ASSUME_NONNULL_END

#endif
