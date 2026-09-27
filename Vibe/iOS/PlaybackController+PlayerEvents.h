//
//  PlaybackController+PlayerEvents.h
//  Vibe (iOS)
//
//  Every AudioPlayerDelegate callback; the rules are at the top of the .m.
//

#import "PlaybackController.h"
#import "AudioPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackController (PlayerEvents) <AudioPlayerDelegate>
@end

NS_ASSUME_NONNULL_END
