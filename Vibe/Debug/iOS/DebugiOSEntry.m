//
//  DebugiOSEntry.m
//  Vibe (iOS)
//
//  The iOS dispatcher over the shared and iOS tables. The transport is
//  DebugChannel.m; the iOS verbs are DebugiOSVerbs.m and its topic table.
//

#import "DebugiOSEntry.h"

#if DEBUG

#import <UIKit/UIKit.h>
#import "DebugChannel.h"
#import "DebugWireFormat.h"
#import "DebugCommandDispatch.h"
#import "DebugCommonVerbs.h"
#import "PlaceholderFiles.h"
#import "PlaceholderFiles+Debug.h"
#import "RootViewController.h"
#import "RootViewController+Debug.h"
#import "DebugFrameProbe.h"

// The shell adopts VibeDebugPlayerSurface: the one object that reaches both
// the model and the card.
static RootViewController *VibeDebugRootController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *root = window.rootViewController;
            if ([root isKindOfClass:RootViewController.class]) {
                return (RootViewController *)root;
            }
        }
    }
    return nil;
}

static NSString *VibeiOSExecuteDebugCommand(NSArray<NSString *> *tokens, NSString *commandId) {
    NSString *verb = tokens.firstObject ?: @"";
    RootViewController *controller = VibeDebugRootController();
    if (!controller) {
        return VibeErrorJSON(@"app not fully launched");
    }
    NSDictionary *spec = VibeDebugSpecForVerb(VibeDebugCommonCommandTable(), verb)
            ?: VibeDebugSpecForVerb(VibeiOSCommandTable(), verb);
    if (!spec) {
        return VibeDebugUnknownCommandReply(verb,
                @[VibeDebugCommonCommandTable(), VibeiOSCommandTable()], nil);
    }
    return ((VibeDebugCommandHandler)spec[@"handler"])(tokens, commandId, controller);
}

// The device's road to the probes: no channel reaches a phone, so each flag
// starts one that logs, and the device console relays it (OS_ACTIVITY_DT_MODE).
static void VibeiOSStartLaunchProbes(void) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    if ([arguments containsObject:@"--frame-rate-probe"]) {
        VibeDebugBeginFrameProbe(0);
    }
    if ([arguments containsObject:@"--dataless-diag"]) {
        [PlaceholderFiles setDatalessDiagnosticsEnabled:YES];
    }
}

void VibeiOSInstallDebugCommandHook(void) {
    VibeInstallDebugCommandChannel(NSBundle.mainBundle.bundleIdentifier, ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeiOSExecuteDebugCommand(args, commandId);
    });
    VibeiOSStartLaunchProbes();
}

#endif
