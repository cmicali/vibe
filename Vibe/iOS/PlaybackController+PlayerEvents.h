//
//  PlaybackController+PlayerEvents.h
//  Vibe (iOS)
//
//  Every AudioPlayerDelegate callback, and the registry's progress for the
//  open they report loading; the rules are at the top of the .m.
//

#import "PlaybackController.h"
#import "AudioPlayer.h"
#import "CloudTransferRegistry.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackController (PlayerEvents) <AudioPlayerDelegate, CloudTransferRegistryObserver>
@end

NS_ASSUME_NONNULL_END
