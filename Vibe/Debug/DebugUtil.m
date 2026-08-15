//
//  DebugUtil.m
//  Vibe
//
//  The transport: the notification hook, the command files, and dispatch.
//  The verbs themselves are in DebugCommandTable.m.
//

#import "DebugInternal.h"

#if DEBUG

void VibeWriteDebugResponse(NSString *commandId, NSString *response) {
    [response writeToFile:VibeDebugResponsePath(commandId)
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
}

// tokens[0] is the verb and the rest are its arguments: one token per CLI argv
// entry, transported verbatim and never re-tokenized. They are rejoined with
// single spaces as a convenience, so that an unquoted multi-word title still
// works. A properly quoted argument arrives as one token and passes through
// exactly, consecutive spaces and all.
NSString *VibeRestArgument(NSArray<NSString *> *tokens) {
    return [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]
            componentsJoinedByString:@" "];
}

// A path argument: the rest of the tokens, with a leading ~ expanded.
NSString *VibePathArgument(NSArray<NSString *> *tokens) {
    return VibeRestArgument(tokens).stringByExpandingTildeInPath;
}

// Shared validation for the verbs that take one existing-file argument, which
// keeps file_cache's and file_clear_cache's argument contracts identical. It
// returns the path, or nil with *errorJSON set to the reply to send.
NSString *VibeExistingFileArgument(NSArray<NSString *> *tokens, NSString **errorJSON) {
    NSString *verb = tokens.firstObject;
    if (tokens.count < 2) {
        *errorJSON = VibeErrorJSON(@"usage: %@ <file>", verb);
        return nil;
    }
    NSString *path = VibePathArgument(tokens);
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) {
        *errorJSON = VibeErrorJSON(@"%@ expects an existing file: '%@'", verb, path);
        return nil;
    }
    return path;
}

static NSString *VibeVerbFromUsage(NSString *usage) {
    NSRange space = [usage rangeOfString:@" "];
    return space.location == NSNotFound ? usage : [usage substringToIndex:space.location];
}

NSDictionary *VibeCommandSpecForVerb(NSString *verb) {
    for (NSDictionary *spec in VibeDebugCommandTable()) {
        if ([VibeVerbFromUsage(spec[@"usage"]) isEqualToString:verb]) {
            return spec;
        }
    }
    return nil;
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
    NSDictionary *spec = VibeCommandSpecForVerb(verb);
    if (!spec) {
        // The unknown-command reply is the channel's authoritative command
        // list, and CLAUDE.md points here, so it must also advertise the verbs
        // the CLI client runs in its own process without ever posting a
        // command file; see VibeDebugCommandClientMain.
        NSMutableArray<NSString *> *usages = [NSMutableArray array];
        for (NSDictionary *entry in VibeDebugCommandTable()) {
            [usages addObject:entry[@"usage"]];
        }
        [usages addObject:@"clear_disk_caches"];
        [usages addObject:@"set_appearance <light|dark|system>"];
        [usages addObject:@"set_analysis <bpm|key> <on|off>"];
        [usages addObject:@"set_key_display <camelot|musical> <colors|plain>"];
        [usages addObject:@"sleep <seconds>"];
        [usages addObject:@"script <file | ->"];
        return VibeErrorJSON(@"unknown command '%@'. Commands: %@",
                verb, [usages componentsJoinedByString:@", "]);
    }
    VibeDebugCommandHandler handler = spec[@"handler"];
    return handler(tokens, commandId, controller);
}

static void VibeHandleOneDebugCommandFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    // A malformed payload still gets an {"error": ...} reply whenever the id
    // is recoverable. A silent drop leaves the client polling out its window
    // and blaming a missing debug build.
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *commandId = [payload isKindOfClass:NSDictionary.class] ? payload[@"id"] : nil;
    if (![commandId isKindOfClass:NSString.class] || commandId.length == 0) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"<not UTF-8>";
        if (raw.length > 256) {
            raw = [[raw substringToIndex:256] stringByAppendingString:@"…"];
        }
        LogError(@"Debug command payload has no usable id, dropping: %@", raw);
        return;
    }
    NSArray *args = payload[@"args"];
    NSString *malformed = nil;
    if (![args isKindOfClass:NSArray.class] || args.count == 0) {
        malformed = @"payload 'args' must be a non-empty JSON array";
    }
    else {
        for (id token in args) {
            if (![token isKindOfClass:NSString.class]) {
                malformed = @"payload 'args' must contain only strings";
                break;
            }
        }
    }
    if (malformed) {
        VibeWriteDebugResponse(commandId, VibeErrorJSON(@"%@", malformed));
        return;
    }
    NSString *response = VibeExecuteDebugCommand(args, commandId);
    // A nil response means the command completes asynchronously and writes its
    // own response through VibeWriteDebugResponse when done, as file_cache does.
    if (response) {
        VibeWriteDebugResponse(commandId, response);
    }
    LogInfo(@"Debug command dispatched: %@", [args componentsJoinedByString:@" "]);
}

// notify_post coalesces back-to-back posts into one delivery, so a single
// wake-up must drain every pending command file. Each reply pairs with its
// command through the id.
static void VibeHandleDebugCommandFiles(void) {
    // The mouse verbs spin the main run loop waiting for key status
    // (VibeMakeWindowKeyForInjection), and that spin services this notify
    // handler — without the guard a second client's queued command executes
    // reentrantly inside the first. Main-thread state; the deferred pass
    // re-drains once the outer command finishes.
    static BOOL draining = NO;
    static BOOL deferred = NO;
    if (draining) {
        deferred = YES;
        return;
    }
    draining = YES;
    do {
        deferred = NO;
        NSString *tmpDir = NSTemporaryDirectory();
        NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:tmpDir error:nil];
        for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
            if ([name hasPrefix:@"vibe-command-"] && [name hasSuffix:@".json"]) {
                VibeHandleOneDebugCommandFile([tmpDir stringByAppendingPathComponent:name]);
            }
        }
    } while (deferred);
    draining = NO;
}

void VibeInstallDebugCommandHook(void) {
    // Sweep files orphaned by earlier runs. An async verb that outlives its
    // client's poll window writes a response no one ever deletes, because the
    // client cleans up only its command file, so vibe-response-*.txt litter
    // accumulates in the container tmp until the OS purges it, as does any
    // per-command vibe-screenshot-*.png a client never streamed. Stale
    // vibe-command-*.json files are the dangerous ones: a client killed
    // mid-poll leaves its command behind, and the next notification's drain
    // would EXECUTE it — a days-old convert_to_flac delete, out of nowhere.
    // Anything present before this hook is live belongs to a dead
    // conversation, so delete all three kinds.
    NSString *tmpDir = NSTemporaryDirectory();
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:tmpDir error:nil];
    for (NSString *name in names) {
        if (([name hasPrefix:@"vibe-response-"] && [name hasSuffix:@".txt"])
                || ([name hasPrefix:@"vibe-screenshot-"] && [name hasSuffix:@".png"])
                || ([name hasPrefix:@"vibe-command-"] && [name hasSuffix:@".json"])) {
            [NSFileManager.defaultManager removeItemAtPath:[tmpDir stringByAppendingPathComponent:name]
                                                     error:nil];
        }
    }
    static int token;
    notify_register_dispatch(kVibeDebugCommandNotification.UTF8String, &token,
                             dispatch_get_main_queue(), ^(int t) {
        VibeHandleDebugCommandFiles();
    });
}

#endif
