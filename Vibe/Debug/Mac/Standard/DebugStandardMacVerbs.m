//
//  DebugStandardMacVerbs.m
//  vibe-libs
//
//  The standard table's mac verbs: the view tree, the menus, the screenshot,
//  and the window raise.
//

#import "DebugStandardVerbs.h"

#if DEBUG

#import <AppKit/AppKit.h>
#import "DebugChannel.h"
#import "DebugCommandDispatch.h"
#import "DebugScreenshot.h"
#import "DebugViewTree.h"
#import "DebugWireFormat.h"

static NSWindow *VibeDebugTargetWindow(VibeDebugStandardOptions *options, id controller) {
    return (options.targetWindow ? options.targetWindow(controller) : nil) ?: NSApp.mainWindow;
}

// click_menu's dispatch when the app passes none.
static BOOL VibeDebugPerformMenuItem(NSMenuItem *item) {
    // TRAP: AppKit gives a submenu parent submenuAction: even when it was
    // built with action:NULL, and sending that to a responder that does not
    // implement it aborts the app.
    if (item.hasSubmenu) {
        return NO;
    }
    [item.menu update]; // the validation pass opening the menu would run
    return item.isEnabled && !item.isHiddenOrHasHiddenAncestor && item.action
            && [NSApp sendAction:item.action to:item.target from:item];
}

NSArray<NSDictionary *> *VibeDebugStandardPlatformVerbs(VibeDebugStandardOptions *options) {
    return @[
        VibeDebugCmd(@"dump_view_tree", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            return VibeViewTreeDump();
        }),
        VibeDebugCmd(@"dump_menu", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            return VibeJSONString(@{@"menu": VibeMenuArray(NSApp.mainMenu)});
        }),
        VibeDebugCmd(@"dump_screenshot [- | <label>]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            // The arguments are the client's; see DebugClient.m.
            NSString *path = VibeDebugScreenshotPathForCommand(VibeDebugChannelName(), commandId);
            if (!VibeDumpWindowSnapshot(path)) {
                return VibeErrorJSON(@"screenshot failed to render or write; see app log");
            }
            return VibeJSONString(@{@"path": path});
        }),
        VibeDebugCmd(@"click_menu <identifier-or-title>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            if (tokens.count < 2) {
                return VibeErrorJSON(@"usage: click_menu <identifier-or-title>");
            }
            // The rest of the tokens, so titles with spaces work unquoted.
            NSString *name = VibeRestArgument(tokens);
            NSMenuItem *item = VibeFindMenuItem(NSApp.mainMenu, name);
            if (!item) {
                return VibeErrorJSON(@"no menu item with identifier or title '%@' (run `dump_menu` to list)", name);
            }
            BOOL performed = options.performMenuItem ? options.performMenuItem(controller, item)
                                                     : VibeDebugPerformMenuItem(item);
            if (!performed) {
                if (item.hasSubmenu) {
                    return VibeErrorJSON(@"menu item '%@' opens a submenu; click one of its items", item.title);
                }
                if (item.isHiddenOrHasHiddenAncestor) {
                    return VibeErrorJSON(@"menu item '%@' is hidden", item.title);
                }
                return item.isEnabled
                        ? VibeErrorJSON(@"no responder handled %@", NSStringFromSelector(item.action))
                        : VibeErrorJSON(@"menu item '%@' is disabled", item.title);
            }
            return VibeJSONString(@{
                @"ok": @YES,
                @"clicked": item.title,
                @"action": item.action ? NSStringFromSelector(item.action) : (id)NSNull.null,
            });
        }),
        // TRAP: a shell-driven launch lands behind the frontmost app (the
        // launch's cooperative activate is declined). An occluded window
        // shows nothing to a real capture, and the app may stop drawing it.
        // The channel keeps the app from being napped meanwhile
        // (dev/DebugChannel). Ordered front without activating, so the
        // frontmost app keeps the keyboard. No ordering helps a sleeping
        // display or a locked screen, where every window reads occluded.
        // Occlusion settles asynchronously, hence the spin.
        VibeDebugCmd(@"raise_window", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            NSWindow *window = VibeDebugTargetWindow(options, controller);
            if (!window) {
                return VibeErrorJSON(@"no window to raise");
            }
            [window orderFrontRegardless];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
            while (!(window.occlusionState & NSWindowOcclusionStateVisible) && deadline.timeIntervalSinceNow > 0) {
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                                       beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            return VibeJSONString(@{@"ok": @YES,
                    @"visible": @((BOOL)((window.occlusionState & NSWindowOcclusionStateVisible) != 0)),
                    @"displayAsleep": @((BOOL)(CGDisplayIsAsleep(CGMainDisplayID()) != 0))});
        }),
    ];
}

#endif
