//
//  DebugiOSEntry.m
//  Vibe (iOS)
//
//  The iOS dispatcher over the shared, standard and iOS tables. The transport
//  is vibe-libs' dev/DebugChannel; the iOS verbs are DebugiOSVerbs.m and its
//  topic table.
//

#import "DebugiOSEntry.h"

#if DEBUG

#import <UIKit/UIKit.h>
#import "DebugChannel.h"
#import "DebugWireFormat.h"
#import "DebugCommandDispatch.h"
#import "DebugCommonVerbs.h"
#import "DebugHealth.h"
#import "DebugStandardVerbs.h"
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

// Looked up in this order. A verb in two tables runs from the first.
static NSArray<NSArray<NSDictionary *> *> *VibeDebugiOSTables(void) {
    static NSArray<NSArray<NSDictionary *> *> *tables;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VibeDebugStandardOptions *options = [VibeDebugStandardOptions new];
        options.healthExtras = ^NSDictionary *(RootViewController *controller) {
            return VibeDebugHealthExtras(controller);
        };
        options.chainableVerbs = ^NSArray<NSDictionary *> *{
            return VibeDebugCommonCommandTable();
        };
        tables = @[VibeDebugCommonCommandTable(), VibeDebugStandardVerbs(options), VibeiOSCommandTable()];
    });
    return tables;
}

static NSString *VibeiOSExecuteDebugCommand(NSArray<NSString *> *tokens, NSString *commandId) {
    NSString *verb = tokens.firstObject ?: @"";
    RootViewController *controller = VibeDebugRootController();
    if (!controller) {
        return VibeErrorJSON(@"app not fully launched");
    }
    NSDictionary *spec = nil;
    for (NSArray<NSDictionary *> *table in VibeDebugiOSTables()) {
        if ((spec = VibeDebugSpecForVerb(table, verb))) {
            break;
        }
    }
    if (!spec) {
        return VibeDebugUnknownCommandReply(verb, VibeDebugiOSTables(), nil);
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
    NSArray<NSString *> *duplicates = VibeDebugDuplicateVerbs(VibeDebugiOSTables());
    NSCAssert(duplicates.count == 0, @"verbs in two debug tables, which run from the first: %@", duplicates);
    VibeInstallDebugCommandChannel(NSBundle.mainBundle.bundleIdentifier, ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeiOSExecuteDebugCommand(args, commandId);
    });
    VibeiOSStartLaunchProbes();
}

#endif
