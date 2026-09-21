//
//  DebugInfo.h
//  Vibe
//
//  Settings > Advanced > Save Debug Info: one text file holding what a bug
//  report otherwise costs round trips to collect — the build and the Mac, every
//  stored setting, the player and its bit-perfect report, every output device
//  as the HAL describes it, the granted folders, and this run's log. Passive:
//  it reads and changes nothing.
//

#import <Foundation/Foundation.h>

@class AudioPlayer;
@class MainPlayerController;

NS_ASSUME_NONNULL_BEGIN

// What only main may read: the controller, the windows, the settings. Cheap.
NSDictionary<NSString *, id> *VibeDebugInfoSnapshot(MainPlayerController *controller);

// Off main: reads the persisted log and bounds each optional hardware/player
// refresh to two seconds. Timed-out sections are explicitly unavailable or cached.
NSString *VibeDebugInfoText(NSDictionary<NSString *, id> *snapshot, AudioPlayer *player);

NS_ASSUME_NONNULL_END
