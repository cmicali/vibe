//
//  PlaybackController+Debug.h
//  Vibe (iOS)
//
//  What the debug channel needs from the model that the shipping header has no
//  reason to expose. The implementation reaches the state through
//  PlaybackControllerInternal.h.
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
// WidgetPublisher.widgetPlaced: whether track changes reach the shared
// container at all.
@property (nonatomic, readonly) BOOL debugWidgetPlaced;

- (void)debugOpenPath:(NSString *)path;
- (void)debugAppendPath:(NSString *)path;

@end

#endif
