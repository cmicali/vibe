//
//  DebugMacEntry.m
//  Vibe
//
//  The mac dispatcher over the shared, standard, input and mac tables. The
//  transport is vibe-libs' dev/DebugChannel; the mac verbs are DebugMacVerbs.m
//  and its topic tables.
//

#import "DebugInternal.h"
#import "DebugStandardVerbs.h"
#import "MainPlayerController+Menus.h"

#if DEBUG

static VibeDebugStandardOptions *VibeDebugMacStandardOptions(void) {
    static VibeDebugStandardOptions *options;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        options = [VibeDebugStandardOptions new];
        options.healthExtras = ^NSDictionary *(MainPlayerController *controller) {
            return VibeDebugHealthExtras(controller);
        };
        options.chainableVerbs = ^NSArray<NSDictionary *> *{
            return VibeDebugCommonCommandTable();
        };
        options.targetWindow = ^NSWindow *(MainPlayerController *controller) {
            return controller.window;
        };
        // The key monitor's dispatch, so a click proves what a shortcut does.
        options.performMenuItem = ^BOOL(MainPlayerController *controller, NSMenuItem *item) {
            return [controller performMenuItem:item];
        };
    });
    return options;
}

// Looked up in this order. A verb in two tables runs from the first.
static NSArray<NSArray<NSDictionary *> *> *VibeDebugMacTables(void) {
    static NSArray<NSArray<NSDictionary *> *> *tables;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tables = @[
            VibeDebugCommonCommandTable(),
            VibeDebugStandardVerbs(VibeDebugMacStandardOptions()),
            VibeDebugInputVerbs(VibeDebugMacStandardOptions()),
            VibeDebugCommandTable(),
        ];
    });
    return tables;
}

// Every table: the client reads clientTimeout through this, and shared verbs
// declare one too.
NSDictionary *VibeCommandSpecForVerb(NSString *verb) {
    for (NSArray<NSDictionary *> *table in VibeDebugMacTables()) {
        NSDictionary *spec = VibeDebugSpecForVerb(table, verb);
        if (spec) {
            return spec;
        }
    }
    return nil;
}

// Returns the JSON response to write, or nil when the verb completes
// asynchronously and writes its own through VibeWriteDebugResponse.
static NSString *VibeExecuteDebugCommand(NSArray<NSString *> *tokens, NSString *commandId) {
    NSString *verb = tokens.firstObject ?: @"";
    AppDelegate *appDelegate = (AppDelegate *)NSApp.delegate;
    MainPlayerController *controller = [appDelegate isKindOfClass:AppDelegate.class]
            ? appDelegate.mainPlayerController : nil;
    if (!controller) {
        return VibeErrorJSON(@"app not fully launched");
    }
    NSDictionary *spec = VibeCommandSpecForVerb(verb);
    if (!spec) {
        // The unknown-command reply is the authoritative verb list, so it
        // also advertises the client-only verbs, which never reach the app
        // (VibeDebugCommandClientMain).
        return VibeDebugUnknownCommandReply(verb, VibeDebugMacTables(),
                @[@"clear_disk_caches",
                  @"set_analysis <bpm|key> <on|off>",
                  @"sleep <seconds>",
                  @"script <file | ->"]);
    }
    NSString *response = ((VibeDebugCommandHandler)spec[@"handler"])(tokens, commandId, controller);
    // None of a pane's own refresh triggers fire for a scripted store write,
    // so refresh after every verb rather than make each verb say it writes.
    VibeDebugSettingsRefreshSelectedPane();
    return response;
}

void VibeInstallDebugCommandHook(void) {
    NSArray<NSString *> *duplicates = VibeDebugDuplicateVerbs(VibeDebugMacTables());
    NSCAssert(duplicates.count == 0, @"verbs in two debug tables, which run from the first: %@", duplicates);
    VibeInstallDebugCommandChannel(NSBundle.mainBundle.bundleIdentifier, ^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeExecuteDebugCommand(args, commandId);
    });
}

#endif
