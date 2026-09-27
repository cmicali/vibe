//
//  MainPlayerController+PlayerEvents.h
//  Vibe
//
//  Every AudioPlayerDelegate callback, and nothing else. Two rules:
//
//  1. **Every callback can be stale**, so each handler matches the delivered
//     track against the playlist's current one before acting.
//  2. **`stop` fires no callback**, so nothing here auto-advances from it.
//     Track end and skip-past-end both funnel through didFinishPlaying:.
//

#import "MainPlayerController.h"
#import "AudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (PlayerEvents) <AudioPlayerDelegate>
@end

NS_ASSUME_NONNULL_END
