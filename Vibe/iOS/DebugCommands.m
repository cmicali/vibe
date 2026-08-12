//
//  DebugCommands.m
//  Vibe (iOS)
//

#import "DebugCommands.h"

#if DEBUG

#import <UIKit/UIKit.h>
#import "DebugChannel.h"
#import "DebugShared.h"
#import "PlayerViewController.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"

static NSString *VibeErrorJSON(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static NSString *VibeErrorJSON(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return VibeJSONString(@{@"error": message});
}

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

// One handler per verb, tokens[0] the verb itself, same contract as the mac
// table in DebugUtil.m. Returning nil means the command replies asynchronously
// through VibeWriteDebugResponse.
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
            VibeCmd(@"dump_state", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                return VibeJSONString(controller.debugStateDictionary);
            }),
            VibeCmd(@"dump_view_tree", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                return VibeViewTreeDump();
            }),
            VibeCmd(@"dump_screenshot", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                return VibeScreenshotJSON(commandId);
            }),
            VibeCmd(@"play_pause", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                [controller debugPlayPause];
                return VibeJSONString(controller.debugActionSummary);
            }),
            VibeCmd(@"next", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                [controller debugNext];
                return VibeJSONString(controller.debugActionSummary);
            }),
            VibeCmd(@"previous", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                [controller debugPrevious];
                return VibeJSONString(controller.debugActionSummary);
            }),
            VibeCmd(@"seek <seconds>", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                double seconds = 0;
                if (tokens.count != 2 || !VibeParseDouble(tokens[1], &seconds)) {
                    return VibeErrorJSON(@"usage: seek <seconds>");
                }
                [controller debugSeekToSeconds:seconds];
                return VibeJSONString(controller.debugActionSummary);
            }),
            VibeCmd(@"open <path>", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: open <path>");
                }
                // Rejoined with single spaces as a convenience for an unquoted
                // multi-word path; a quoted one arrives as one token.
                NSString *path = [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]
                        componentsJoinedByString:@" "].stringByExpandingTildeInPath;
                if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                    return VibeErrorJSON(@"no such file: %@", path);
                }
                [controller debugOpenPath:path];
                return VibeJSONString(@{@"ok": @YES, @"opening": path});
            }),
            VibeCmd(@"clear_caches", ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, PlayerViewController *controller) {
                // Blocks the main thread until both PINCache stores are empty,
                // same tradeoff as the mac verb: acceptable for debug-only.
                dispatch_group_t group = dispatch_group_create();
                dispatch_group_enter(group);
                [controller.debugMetadataCache invalidateWithCompletion:^{
                    dispatch_group_leave(group);
                }];
                dispatch_group_enter(group);
                [controller.debugWaveformCache invalidateWithCompletion:^{
                    dispatch_group_leave(group);
                }];
                if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC))) {
                    return VibeErrorJSON(@"cache clear timed out after 15s");
                }
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"cleared": @[AudioTrackMetadataCache.cacheName, AudioWaveformCache.cacheName],
                });
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
    for (NSDictionary *spec in VibeiOSCommandTable()) {
        NSString *usage = spec[@"usage"];
        NSRange space = [usage rangeOfString:@" "];
        NSString *specVerb = space.location == NSNotFound ? usage : [usage substringToIndex:space.location];
        if ([specVerb isEqualToString:verb]) {
            VibeiOSCommandHandler handler = spec[@"handler"];
            return handler(tokens, commandId, controller);
        }
    }
    // The unknown-command reply is the channel's authoritative command list,
    // as on the mac.
    NSMutableArray<NSString *> *usages = [NSMutableArray array];
    for (NSDictionary *spec in VibeiOSCommandTable()) {
        [usages addObject:spec[@"usage"]];
    }
    return VibeErrorJSON(@"unknown command '%@'. Commands: %@",
            verb, [usages componentsJoinedByString:@", "]);
}

void VibeiOSInstallDebugCommandHook(void) {
    VibeInstallDebugCommandChannel(^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeiOSExecuteDebugCommand(args, commandId);
    });
}

#endif
