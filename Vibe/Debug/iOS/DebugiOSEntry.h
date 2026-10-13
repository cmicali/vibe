//
//  DebugiOSEntry.h
//  Vibe (iOS)
//

#import <Foundation/Foundation.h>

#if DEBUG

// The iOS entry point and dispatcher over the shared transport
// (DebugChannel.m); the verb table is DebugiOSVerbs.m. There is no CLI client: debug-ios.sh writes command files into the simulator
// container's tmp and reads replies directly. Call at launch.

#ifdef __cplusplus
extern "C" {
#endif

void VibeiOSInstallDebugCommandHook(void);

// The iOS verb table (DebugiOSVerbs.m), which only the dispatcher reads.
NSArray<NSDictionary *> *VibeiOSCommandTable(void);

// The Dropbox verbs (DebugDropboxVerbs.m), which only the iOS table reads.
NSArray<NSDictionary *> *VibeDebugDropboxVerbs(void);

#ifdef __cplusplus
}
#endif

#endif
