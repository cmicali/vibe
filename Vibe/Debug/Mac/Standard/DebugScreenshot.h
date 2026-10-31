//
//  DebugScreenshot.h
//  vibe-libs
//
//  The in-process window render behind dump_screenshot, and a notifyutil hook
//  that runs the same render.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Renders the key window, else the main window, else the frontmost visible
// one, to a PNG at path. NO when there is no window or the write fails.
//
// It renders the window's layer tree in-process, with no window-server
// capture, so it needs no screen-recording permission and works with the
// display asleep or the window occluded. NSGlassEffectView layers cannot
// render this way: they are hidden, over an appearance-matched flat fill.
// Hiding them forces a model-tree render, so a glass-bearing window's
// animations land at their target values; glass-free windows render the
// presentation tree mid-flight. Metal content does not render either.
BOOL VibeDumpWindowSnapshot(NSString *path);

// Renders to path whenever notificationName is posted, so a terminal can take
// a screenshot with no client:
//
//     notifyutil -p <notificationName>
//
// A sandboxed app's path is in its own container, so read it from there.
// dump_screenshot writes a file per command instead, so two clients taking
// screenshots back to back never read each other's pixels.
void VibeInstallDebugScreenshotHook(NSString *notificationName, NSString *path);

NS_ASSUME_NONNULL_END
