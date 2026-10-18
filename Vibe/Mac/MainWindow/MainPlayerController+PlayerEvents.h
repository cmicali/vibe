//
//  MainPlayerController+PlayerEvents.h
//  Vibe
//
//  Every AudioPlayerDelegate callback, and the registry's progress for the
//  open they report loading. Two rules:
//
//  1. Track callbacks match the playlist's current track. Device and output
//     activity callbacks reconcile from their own current state.
//  2. `stop` fires no transport callback. It never drives auto-advance.
//     Track end and skip-past-end both funnel through didFinishPlaying:.
//

#import "MainPlayerController.h"
#import "AudioPlayer.h"
#import "CloudTransferRegistry.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (PlayerEvents) <AudioPlayerDelegate, CloudTransferRegistryObserver>

// Reopens the current track where the intent left it, paused or playing,
// through the replay resume hint (the convert swap).
- (void)replayTrack:(AudioTrack *)track intent:(VibePendingPlaybackIntent)intent;

@end

NS_ASSUME_NONNULL_END
