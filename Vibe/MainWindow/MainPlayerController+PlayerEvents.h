//
//  MainPlayerController+PlayerEvents.h
//  Vibe
//
//  The AudioPlayerDelegate half of the controller: every callback the player
//  sends, and nothing else. Loading, start, pause, resume, finish, the gapless
//  auto-advance, errors, the output-device change and the seek settle.
//
//  Two rules govern the whole file, and are the reason it is one file:
//
//  1. **Every callback can be stale.** A delivery can land after the playlist
//     has moved on — a re-drop, a double-click, a swap — so each handler
//     matches the delivered track against the playlist's current one before
//     acting. What "acting" would cost differs per callback and is commented
//     at each; that the check exists never varies.
//  2. **`stop` fires no callback.** It is not a track-end event, so nothing
//     here drives auto-advance from it; the caller owns that UI reset. Track
//     end and skip-past-end both funnel through didFinishPlaying:.
//

#import "MainPlayerController.h"
#import "AudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface MainPlayerController (PlayerEvents) <AudioPlayerDelegate>
@end

NS_ASSUME_NONNULL_END
