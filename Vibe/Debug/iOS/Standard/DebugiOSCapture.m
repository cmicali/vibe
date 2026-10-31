//
//  DebugiOSCapture.m
//  vibe-libs
//

#import "DebugiOSCapture.h"

#if DEBUG

#import "DebugChannel.h"
#import "DebugWireFormat.h"

UIWindow *VibeDebugKeyWindow(void) {
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

NSString *VibeViewTreeDump(void) {
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

// In-process render of the key window. Blurs render only approximately this
// way; `simctl io booted screenshot` is the ground truth for pixels.
NSString *VibeScreenshotJSON(NSString *commandId) {
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
    NSString *path = VibeDebugScreenshotPathForCommand(VibeDebugChannelName(), commandId);
    if (![png writeToFile:path atomically:YES]) {
        return VibeErrorJSON(@"could not write %@", path);
    }
    return VibeJSONString(@{@"ok": @YES, @"path": path,
                            @"pointWidth": @(window.bounds.size.width),
                            @"pointHeight": @(window.bounds.size.height),
                            @"scale": @(format.scale)});
}

#endif
