//
//  PlaybackController+Debug.h
//  Vibe (iOS)
//
//  What the debug command channel needs from the model that the shipping
//  header has no reason to expose: the engine handle the shared consistency
//  checks read, the caches the cache verbs clear, and the two display-state
//  flags dump_state reports. It lives here, with its implementation beside it,
//  so no production file carries a declaration for a tool that does not ship;
//  the implementation reaches the state through PlaybackControllerInternal.h,
//  the same private surface the controller's own categories share.
//
//  Debug builds only.
//

#if DEBUG

#import "PlaybackController.h"

@class AudioPlayer;
@class AudioTrackMetadataCache;

@interface PlaybackController (Debug)

@property (nonatomic, readonly) AudioPlayer *debugPlayer;
@property (nonatomic, readonly) AudioTrackMetadataCache *debugMetadataCache;
@property (nonatomic, readonly) BOOL debugParked;
@property (nonatomic, readonly) BOOL debugTrackStartPending;

- (void)debugOpenPath:(NSString *)path;

@end

#endif
