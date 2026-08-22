//
//  DebugChannel.m
//  Vibe
//

#import "DebugChannel.h"

#if DEBUG

#import <notify.h>
#import "DebugWireFormat.h"

static VibeDebugChannelExecutor gExecutor;

void VibeWriteDebugResponse(NSString *commandId, NSString *response) {
    [response writeToFile:VibeDebugResponsePath(commandId)
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:nil];
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
        VibeWriteDebugResponse(commandId, VibeJSONString(@{@"error": malformed}));
        return;
    }
    NSString *response = gExecutor(args, commandId);
    if (response) {
        VibeWriteDebugResponse(commandId, response);
    }
    LogInfo(@"Debug command dispatched: %@", [args componentsJoinedByString:@" "]);
}

// notify_post coalesces back-to-back posts into one delivery, so a single
// wake-up must drain every pending command file. Each reply pairs with its
// command through the id.
static void VibeHandleDebugCommandFiles(void) {
    // A command can spin the main run loop (the mac mouse verbs wait for key
    // status in VibeMakeWindowKeyForInjection), and that spin services this
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
// The vnode source fires on any tmp-directory mutation, response writes
// included; a spurious drain finds no command files and costs one readdir.
// The host must rename complete command files into place — a file the drain
// reads mid-write is deleted unexecuted.
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
