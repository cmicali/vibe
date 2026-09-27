//
//  DebugUtil.m
//  Vibe
//
//  The mac dispatcher over the shared and mac tables. The transport is
//  DebugChannel.m; the mac verbs are DebugCommandTable.m.
//

#import "DebugInternal.h"

#if DEBUG

// Both tables: the client reads clientTimeout through this, and shared verbs
// declare one too.
NSDictionary *VibeCommandSpecForVerb(NSString *verb) {
    return VibeDebugSpecForVerb(VibeDebugCommonCommandTable(), verb)
            ?: VibeDebugSpecForVerb(VibeDebugCommandTable(), verb);
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
    NSDictionary *common = VibeDebugSpecForVerb(VibeDebugCommonCommandTable(), verb);
    NSDictionary *spec = common ?: VibeDebugSpecForVerb(VibeDebugCommandTable(), verb);
    if (!spec) {
        // The unknown-command reply is the authoritative verb list, so it
        // also advertises the client-only verbs, which never reach the app
        // (VibeDebugCommandClientMain).
        return VibeDebugUnknownCommandReply(verb,
                @[VibeDebugCommonCommandTable(), VibeDebugCommandTable()],
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
    VibeInstallDebugCommandChannel(^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeExecuteDebugCommand(args, commandId);
    });
}

#endif
