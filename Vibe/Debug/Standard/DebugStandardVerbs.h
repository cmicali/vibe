//
//  DebugStandardVerbs.h
//  vibe-libs
//
//  The standard debug verbs: the ones that know nothing of the app, so every
//  app's channel answers them the same way. The app adds the table to the
//  ones its dispatcher looks a verb up in.
//
//  Compiled in every configuration. Each .m wraps its body in #if DEBUG, so a
//  release build has none of it, and a call from release code fails to link.
//

#import <Foundation/Foundation.h>

@class NSWindow, NSMenuItem;

NS_ASSUME_NONNULL_BEGIN

// What the standard verbs need from the app. Each block runs on main with the
// controller the app's dispatcher hands every handler. Every one is optional.
@interface VibeDebugStandardOptions : NSObject
// Keys merged into dump_build's reply. The verb's own keys win.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *_Nullable (^buildExtras)(id controller);
// Blocks merged into dump_health's reply, beside "ok" and "process".
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *_Nullable (^healthExtras)(id controller);
// The app's verbs block_main may chain, after the shared verbs.
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *_Nullable (^chainableVerbs)(void);
// macOS: the window the mouse verbs aim at and raise_window raises. Nil, or a
// nil answer: NSApp.mainWindow.
@property (nonatomic, copy, nullable) NSWindow *_Nullable (^targetWindow)(id controller);
// macOS: click_menu's dispatch. NO when nothing handled the item. Nil: NSApp
// sends the item's action, after the validation opening the menu would run.
@property (nonatomic, copy, nullable) BOOL (^performMenuItem)(id controller, NSMenuItem *item);
@end

// The shared verbs, then the verbs for the platform it is built on. Build it
// once, at install.
NSArray<NSDictionary *> *VibeDebugStandardVerbs(VibeDebugStandardOptions *options);

// The platform's verbs, in Mac/DebugStandardMacVerbs.m or
// iOS/DebugStandardiOSVerbs.m. Only VibeDebugStandardVerbs reads it.
NSArray<NSDictionary *> *VibeDebugStandardPlatformVerbs(VibeDebugStandardOptions *options);

NS_ASSUME_NONNULL_END
