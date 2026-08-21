//
//  DebugCommands.h
//  Vibe (iOS)
//

#import <Foundation/Foundation.h>

#if DEBUG

// The iOS app side of the debug command channel: the command table over the
// shared transport in Vibe/Debug/DebugChannel.m. There is no CLI client on
// iOS — the simulator's container tmp is a plain host directory, so the
// host-side debug-ios.sh writes command files and reads replies directly.
// Call at launch.

#ifdef __cplusplus
extern "C" {
#endif

void VibeiOSInstallDebugCommandHook(void);

#ifdef __cplusplus
}
#endif

#endif
