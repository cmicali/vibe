//
//  DebugCommands.m
//  Vibe (iOS)
//

#import "DebugCommands.h"

#if DEBUG

#import <UIKit/UIKit.h>
#import "DebugChannel.h"
#import "DebugShared.h"
#import "DebugCommandDispatch.h"
#import "DebugCommonVerbs.h"
#import "PlayerViewController.h"
#import "PlayerViewController+Debug.h"

static UIWindow *VibeDebugKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
}

static PlayerViewController *VibeDebugPlayerController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *root = window.rootViewController;
            if ([root isKindOfClass:PlayerViewController.class]) {
                return (PlayerViewController *)root;
            }
        }
    }
    return nil;
}

#pragma mark View tree and screenshot

static NSDictionary *VibeViewDictionary(UIView *view) {
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    node[@"class"] = NSStringFromClass(view.class);
    node[@"frame"] = NSStringFromCGRect(view.frame);
    if (view.isHidden) {
        node[@"hidden"] = @YES;
    }
    if (view.alpha < 1.0) {
        node[@"alpha"] = @(view.alpha);
    }
    if ([view isKindOfClass:UILabel.class]) {
        node[@"text"] = ((UILabel *)view).text ?: @"";
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSString *label = button.currentTitle ?: button.accessibilityLabel;
        if (label.length) {
            node[@"label"] = label;
        }
    }
    if (view.subviews.count) {
        NSMutableArray *subviews = [NSMutableArray array];
        for (UIView *subview in view.subviews) {
            [subviews addObject:VibeViewDictionary(subview)];
        }
        node[@"subviews"] = subviews;
    }
    return node;
}

static NSString *VibeViewTreeDump(void) {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [windows addObject:@{
                @"class": NSStringFromClass(window.class),
                @"frame": NSStringFromCGRect(window.frame),
                @"keyWindow": @(window.isKeyWindow),
                @"rootViewController": NSStringFromClass(window.rootViewController.class) ?: @"",
                @"contentView": VibeViewDictionary(window),
            }];
        }
    }
    return VibeJSONString(@{@"windows": windows});
}

// In-process render of the key window's hierarchy. UIVisualEffectView blurs
// render only approximately this way; `simctl io booted screenshot` is the
// ground truth for real pixels, and this path is for a device or for reading
// alongside dump_view_tree.
static NSString *VibeScreenshotJSON(NSString *commandId) {
    UIWindow *window = VibeDebugKeyWindow();
    if (!window) {
        return VibeErrorJSON(@"no key window");
    }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds format:format];
    NSData *png = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    NSString *path = VibeDebugScreenshotPathForCommand(commandId);
    if (![png writeToFile:path atomically:YES]) {
        return VibeErrorJSON(@"could not write %@", path);
    }
    return VibeJSONString(@{@"ok": @YES, @"path": path,
                            @"pointWidth": @(window.bounds.size.width),
                            @"pointHeight": @(window.bounds.size.height),
                            @"scale": @(format.scale)});
}

#pragma mark Command table

// The UIKit-only verbs. Everything both platforms answer the same way is in
// Debug/Shared/DebugCommonVerbs.m, over VibeDebugPlayerSurface; this table is
// only what needs a UIView tree or a UIWindow render. Returning nil means the
// command replies asynchronously through VibeWriteDebugResponse.
typedef NSString * _Nullable (^VibeiOSCommandHandler)(NSArray<NSString *> *tokens,
                                                      NSString *commandId,
                                                      PlayerViewController *controller);

static NSDictionary *VibeCmd(NSString *usage, VibeiOSCommandHandler handler) {
    return @{@"usage": usage, @"handler": [handler copy]};
}

static NSArray<NSDictionary *> *VibeiOSCommandTable(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            VibeCmd(@"dump_view_tree", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                return VibeViewTreeDump();
            }),
            VibeCmd(@"dump_screenshot", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                return VibeScreenshotJSON(commandId);
            }),
        ];
    });
    return table;
}

static NSString *VibeiOSExecuteDebugCommand(NSArray<NSString *> *tokens, NSString *commandId) {
    NSString *verb = tokens.firstObject ?: @"";
    PlayerViewController *controller = VibeDebugPlayerController();
    if (!controller) {
        return VibeErrorJSON(@"app not fully launched");
    }
    NSDictionary *common = VibeDebugSpecForVerb(VibeDebugCommonCommandTable(), verb);
    if (common) {
        VibeDebugSurfaceHandler handler = common[@"handler"];
        return handler(tokens, commandId, controller);
    }
    NSDictionary *spec = VibeDebugSpecForVerb(VibeiOSCommandTable(), verb);
    if (spec) {
        VibeiOSCommandHandler handler = spec[@"handler"];
        return handler(tokens, commandId, controller);
    }
    return VibeDebugUnknownCommandReply(verb,
            @[VibeDebugCommonCommandTable(), VibeiOSCommandTable()], nil);
}

void VibeiOSInstallDebugCommandHook(void) {
    VibeInstallDebugCommandChannel(^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeiOSExecuteDebugCommand(args, commandId);
    });
}

#endif
