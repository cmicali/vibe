//
//  DebugCommands.h
//  Vibe (iOS)
//

#import <Foundation/Foundation.h>

#if DEBUG

// The iOS command table over the shared transport (DebugChannel.m). There is
// no CLI client: debug-ios.sh writes command files into the simulator
// container's tmp and reads replies directly. Call at launch.

#ifdef __cplusplus
extern "C" {
#endif

void VibeiOSInstallDebugCommandHook(void);

#ifdef __cplusplus
}
#endif

#endif
