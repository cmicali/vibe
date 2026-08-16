//
//  DebugUtil.m
//  Vibe
//
//  The transport: the notification hook, the command files, and dispatch.
//  The verbs themselves are in DebugCommandTable.m.
//

#import "DebugInternal.h"

#if DEBUG

// Both tables, because the client reads clientTimeout through this and the
// cross-platform verbs carry one too — clear_caches waits 20s.
NSDictionary *VibeCommandSpecForVerb(NSString *verb) {
    return VibeDebugSpecForVerb(VibeDebugCommonCommandTable(), verb)
            ?: VibeDebugSpecForVerb(VibeDebugCommandTable(), verb);
}

// Returns the JSON response to write, or nil if the command completes
// asynchronously and writes its own response through VibeWriteDebugResponse.
// file_cache does that, since it runs a full waveform decode off the main
// thread.
static NSString *VibeExecuteDebugCommand(NSArray<NSString *> *tokens, NSString *commandId) {
    NSString *verb = tokens.firstObject ?: @"";
    AppDelegate *appDelegate = (AppDelegate *)NSApp.delegate;
    MainPlayerController *controller = [appDelegate isKindOfClass:AppDelegate.class]
            ? appDelegate.mainPlayerController : nil;
    if (!controller) {
        return VibeErrorJSON(@"app not fully launched");
    }
    // The cross-platform verbs first: they are written once, against
    // VibeDebugPlayerSurface, which this controller adopts.
    NSDictionary *common = VibeDebugSpecForVerb(VibeDebugCommonCommandTable(), verb);
    if (common) {
        VibeDebugSurfaceHandler handler = common[@"handler"];
        return handler(tokens, commandId, controller);
    }
    NSDictionary *spec = VibeDebugSpecForVerb(VibeDebugCommandTable(), verb);
    if (!spec) {
        // The unknown-command reply is the channel's authoritative command
        // list, and CLAUDE.md points here, so it must also advertise the verbs
        // the CLI client runs in its own process without ever posting a
        // command file; see VibeDebugCommandClientMain.
        return VibeDebugUnknownCommandReply(verb,
                @[VibeDebugCommonCommandTable(), VibeDebugCommandTable()],
                @[@"clear_disk_caches",
                  @"set_appearance <light|dark|system>",
                  @"set_analysis <bpm|key> <on|off>",
                  @"set_key_display <camelot|musical> <colors|plain>",
                  @"sleep <seconds>",
                  @"script <file | ->"]);
    }
    VibeDebugCommandHandler handler = spec[@"handler"];
    return handler(tokens, commandId, controller);
}

void VibeInstallDebugCommandHook(void) {
    // The transport — drain, validation, sweep, listeners — lives in
    // DebugChannel.m, shared with the iOS command table.
    VibeInstallDebugCommandChannel(^NSString *(NSArray<NSString *> *args, NSString *commandId) {
        return VibeExecuteDebugCommand(args, commandId);
    });
}

#endif
