//
//  DebugMacConsistency.h
//  Vibe
//

#import <Foundation/Foundation.h>

#if DEBUG

@class MainPlayerController;

// The macOS-only half of the shared `check_consistency` verb, reached through
// the surface protocol's debugCheckPlatform: hook after VibeDebugCheckShared:
// the playlist table and its row indexes, the pitch fader, the scaled tick
// rate, and the rendered header labels and artwork ownership. Main thread
// only; returns how many checks it ran. See DebugConsistency.h for the
// render-lag caveat.
NSUInteger VibeDebugCheckMac(NSMutableArray<NSDictionary *> *violations,
                                        MainPlayerController *controller);

#endif
