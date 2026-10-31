//
//  DebugiOSCapture.h
//  vibe-libs
//
//  What dump_view_tree and dump_screenshot read on iOS: the key window, every
//  window's view tree, and the key window's render.
//
//  Compiled in every configuration. The .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The key window of any connected window scene, or nil.
UIWindow *_Nullable VibeDebugKeyWindow(void);

// Every scene's windows and their view trees, as the JSON reply.
NSString *VibeViewTreeDump(void);

// Renders the key window to the command's screenshot path, and answers the
// reply: the path, the window's size in points, and the scale.
NSString *VibeScreenshotJSON(NSString *commandId);

NS_ASSUME_NONNULL_END
