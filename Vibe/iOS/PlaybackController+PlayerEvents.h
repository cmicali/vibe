//
//  PlaybackController+PlayerEvents.h
//  Vibe (iOS)
//
//  Every AudioPlayerDelegate callback. Two rules govern the whole file and are
//  stated at its top: every callback can be stale and must match the delivered
//  track against the playlist's current one, and stop fires no callback, so
//  nothing here drives auto-advance.
//

#import "PlaybackController.h"
#import "AudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackController (PlayerEvents) <AudioPlayerDelegate>
@end

NS_ASSUME_NONNULL_END
