//
//  AudioTrackMetadata+ArtLoad.h
//  Vibe
//
//  The one background art load both screens use. It sits here, beside the
//  flags and loadArtBlocking it drives, because the mechanism — dispatch once,
//  clear the marker, demote the decode if the user has moved on — is the same
//  on both platforms while what each screen then DOES with the art is not.
//

#import "AudioTrackMetadata.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioTrackMetadata (ArtLoad)

// Main thread only, matching artLoadDispatched. Does nothing unless a load is
// worth dispatching (artNeedsLoad) and none is already in flight.
//
// stillWanted runs on the main thread once the load lands and answers whether
// the caller still shows this track. NO discards the decode — a track the user
// skipped past never becomes anything's displayed art, so nothing else would
// demote the full-resolution bytes this load just pinned — and completion never
// runs. YES calls completion on the main thread with whatever loadArtBlocking
// returned, nil included: nil is not proof of artlessness while a folder-art
// resolve is still in flight, and what to show in that gap is the caller's
// policy, not this one's.
//
// The marker is cleared before either block runs, so a caller torn down
// mid-load leaves the metadata re-armed rather than permanently in flight.
- (void)dispatchArtLoadIfNeededStillWanted:(BOOL (^)(void))stillWanted
                                completion:(void (^)(VibeImage *_Nullable art))completion;

@end

NS_ASSUME_NONNULL_END
