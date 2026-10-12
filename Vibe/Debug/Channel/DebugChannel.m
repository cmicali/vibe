//
//  DebugChannel.m
//  Vibe
//

#import "DebugChannel.h"

#if DEBUG

#import <notify.h>
#import "DebugWireFormat.h"

static VibeDebugChannelExecutor gExecutor;

// Joins a command's log line to its reply's.
static NSString *VibeDebugLogTag(NSString *commandId) {
    return commandId.length > 8 ? [commandId substringToIndex:8] : (commandId ?: @"?");
}

// Every reply is logged, so a failure is visible even to a client that threw
// the reply away. Errors are Warn and whole; successes are Info and trimmed,
// since some replies run to tens of kilobytes. Only a short reply is parsed:
// nothing large is an error.
static void VibeLogDebugReply(NSString *commandId, NSString *response) {
    NSString *tag = VibeDebugLogTag(commandId);
    if (response.length < 4096 && [response containsString:@"\"error\""]) {
        NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id error = [json isKindOfClass:NSDictionary.class] ? json[@"error"] : nil;
        if ([error isKindOfClass:NSString.class]) {
            LogWarn(@"Debug reply %@ ERROR: %@", tag, error);
            return;
        }
    }
    NSString *flat = [[response componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@" "];
    while ([flat containsString:@"  "]) {
        flat = [flat stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    if (flat.length > 300) {
        flat = [NSString stringWithFormat:@"%@… (%lu bytes)", [flat substringToIndex:300],
                (unsigned long)response.length];
    }
    LogInfo(@"Debug reply %@: %@", tag, flat);
}

void VibeWriteDebugResponse(NSString *commandId, NSString *response) {
    [response writeToFile:VibeDebugResponsePath(commandId)
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
    VibeLogDebugReply(commandId, response);
}

static void VibeHandleOneDebugCommandFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    // A malformed payload still gets an error reply whenever the id is
    // recoverable; a silent drop leaves the client polling out its window.
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
        VibeWriteDebugResponse(commandId, VibeJSONString(@{@"error": malformed}));
        return;
    }
    // Before the verb runs, so one that hangs or crashes has still logged it.
    LogInfo(@"Debug command %@: %@", VibeDebugLogTag(commandId), [args componentsJoinedByString:@" "]);
    NSString *response = gExecutor(args, commandId);
    if (response) {
        VibeWriteDebugResponse(commandId, response);
    }
}

// notify_post coalesces back-to-back posts, so one wake-up drains every
// pending command file.
static void VibeHandleDebugCommandFiles(void) {
    // A command can spin the main run loop (VibeMakeWindowKeyForInjection),
    // which services this handler: without the guard a second client's command
    // would run reentrantly inside the first. The deferred pass re-drains once
    // the outer command finishes. Main thread.
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

// Anything present before the channel is live belongs to a dead client:
// responses and screenshots nobody collected, and, dangerously, commands a
// killed client left behind, which the next drain would otherwise EXECUTE
// (a days-old convert_to_flac delete).
static void VibeSweepStaleChannelFiles(void) {
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
}

#if TARGET_OS_IPHONE
// Fires on any tmp mutation, response writes included; a spurious drain costs
// one readdir. The host must rename complete command files into place: a file
// read mid-write is deleted unexecuted.
static dispatch_source_t gTmpWatcher;

static void VibeInstallTmpDirectoryWatcher(void) {
    int fd = open(NSTemporaryDirectory().fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) {
        LogError(@"Debug channel: cannot watch tmp directory (errno %d)", errno);
        return;
    }
    gTmpWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
                                         DISPATCH_VNODE_WRITE, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gTmpWatcher, ^{
        VibeHandleDebugCommandFiles();
    });
    dispatch_source_set_cancel_handler(gTmpWatcher, ^{
        close(fd);
    });
    dispatch_resume(gTmpWatcher);
}
#endif

void VibeInstallDebugCommandChannel(VibeDebugChannelExecutor executor) {
    gExecutor = [executor copy];
    VibeSweepStaleChannelFiles();
    static int token;
    notify_register_dispatch(kVibeDebugCommandNotification.UTF8String, &token,
                             dispatch_get_main_queue(), ^(int t) {
        VibeHandleDebugCommandFiles();
    });
#if TARGET_OS_IPHONE
    VibeInstallTmpDirectoryWatcher();
#endif
}

#endif
