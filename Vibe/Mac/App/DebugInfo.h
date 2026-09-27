//
//  DebugInfo.h
//  Vibe
//
//  Settings > Advanced > Save Debug Info. Passive: it reads and changes nothing.
//

#import <Foundation/Foundation.h>

@class AudioPlayer;
@class MainPlayerController;

NS_ASSUME_NONNULL_BEGIN

// What only main may read: the controller, the windows, the settings. Cheap.
NSDictionary<NSString *, id> *VibeDebugInfoSnapshot(MainPlayerController *controller);

// Off main. Each live section is bounded at two seconds; a timed-out one
// reports cached data or unavailable.
NSString *VibeDebugInfoText(NSDictionary<NSString *, id> *snapshot, AudioPlayer *player);

NS_ASSUME_NONNULL_END
