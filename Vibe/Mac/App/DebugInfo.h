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

// The report text from a snapshot. Blocks on coreaudiod for every device, on
// the player queue for the bound device and on the log store, so the button
// runs it off main.
NSString *VibeDebugInfoText(NSDictionary<NSString *, id> *snapshot, AudioPlayer *player);

NS_ASSUME_NONNULL_END
