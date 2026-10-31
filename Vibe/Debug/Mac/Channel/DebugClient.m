//
//  DebugClient.m
//  vibe-libs
//

#import "DebugClient.h"

#if DEBUG

#import <notify.h>
#import <stdio.h>
#import <unistd.h>
#import "DebugWireFormat.h"

@implementation VibeDebugClientOptions

- (instancetype)init {
    if ((self = [super init])) {
        _channel = NSBundle.mainBundle.bundleIdentifier ?: @"";
        _displayName = NSProcessInfo.processInfo.processName;
        _messagePrefix = NSProcessInfo.processInfo.processName;
        _fileVerbs = @[];
    }
    return self;
}

@end

// sleep and script run in this process, and so does each of the app's local
// verbs. Everything else rides the transport: the command file, the
// notification, and the poll for the reply.

#pragma mark Client side

// Script-mode replies are re-serialized compact — one line per command — so
// script output is real NDJSON a wrapper can line-split.
// Top-level replies keep the human-friendly pretty print.
static void VibeClientPrintReply(NSString *json, BOOL inScript) {
    if (inScript) {
        NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
        id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSData *compact = object
                ? [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil]
                : nil;
        NSString *line = compact ? [[NSString alloc] initWithData:compact encoding:NSUTF8StringEncoding] : nil;
        if (line) {
            json = line;
        }
    }
    printf("%s\n", json.UTF8String);
}

// Prints one command's reply and returns its exit code. inScript switches the
// verbs whose I/O cannot compose with NDJSON output: a file verb carries its
// file as base64 instead of raw bytes, and a nested script is rejected.
static int VibeDebugClientRunOne(NSArray<NSString *> *args, BOOL inScript, VibeDebugClientOptions *options,
                                 const char *flag) {
    @autoreleasepool {
        // Client-side pause, for scripts: the app's main thread never sleeps.
        if ([args.firstObject isEqualToString:@"sleep"]) {
            double seconds = 0;
            BOOL valid = args.count == 2 && VibeParseDouble(args[1], &seconds)
                    && seconds > 0 && seconds <= 600;
            if (!valid) {
                fprintf(stderr, "usage: %s %s sleep <seconds 0-600>\n", options.displayName.UTF8String, flag);
                return 64;
            }
            usleep((useconds_t)(seconds * 1e6));
            VibeClientPrintReply(VibeJSONString(@{@"ok": @YES, @"slept": @(seconds)}), inScript);
            return 0;
        }
        if (inScript && [args.firstObject isEqualToString:@"script"]) {
            fprintf(stderr, "%s: scripts cannot nest\n", options.messagePrefix.UTF8String);
            return 64;
        }
        if (options.localVerb) {
            int status = options.localVerb(args, inScript, ^(NSString *json) {
                VibeClientPrintReply(json, inScript);
            });
            if (status >= 0) {
                return status;
            }
        }
        NSString *commandId = NSUUID.UUID.UUIDString;
        // One array element per argv entry, never joined and re-tokenized, so
        // a path with any whitespace reaches the handler byte-exact.
        NSDictionary *payload = @{
            @"id": commandId,
            @"args": args,
        };
        // Same bundle ID + sandbox entitlements as the app, so NSTemporaryDirectory()
        // resolves to the same container tmp the app-side handler reads.
        NSString *channel = options.channel;
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        NSString *commandPath = VibeDebugCommandPath(channel, commandId);
        if (![data writeToFile:commandPath atomically:YES]) {
            fprintf(stderr, "%s: cannot write %s\n", options.messagePrefix.UTF8String,
                    commandPath.fileSystemRepresentation);
            return 1;
        }
        notify_post(VibeDebugCommandNotificationName(channel).UTF8String);

        NSString *responsePath = VibeDebugResponsePath(channel, commandId);
        NSFileManager *fileManager = NSFileManager.defaultManager;
        // Slow verbs declare their own wait in the table the app dispatches
        // with. Everything else gets 5s, or the environment's: a script
        // driving a failure fixture may know the app's main thread waits out
        // a dead device for longer than that.
        NSTimeInterval timeout = options.waitForVerb ? options.waitForVerb(args.firstObject) : 0;
        if (timeout <= 0 && options.timeoutEnvironmentKey) {
            timeout = [NSProcessInfo.processInfo.environment[options.timeoutEnvironmentKey] doubleValue];
        }
        if (timeout <= 0) {
            timeout = 5;
        }
        // Check before sleeping, backing off from 0.5ms to a 20ms ceiling: a
        // fixed pre-sleep would charge every command the full interval, most
        // of a fast round trip, while a slow verb's polling stays sparse.
        useconds_t backoff = 500;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
        while (YES) {
            if ([fileManager fileExistsAtPath:responsePath]) {
                NSString *response = [NSString stringWithContentsOfFile:responsePath
                                                               encoding:NSUTF8StringEncoding
                                                                  error:nil];
                [fileManager removeItemAtPath:responsePath error:nil];
                // Replies are always a single JSON object; {"error": ...}
                // means the command failed.
                NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:
                        [response dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data
                                                                      options:0
                                                                        error:nil];
                BOOL failed = ![reply isKindOfClass:NSDictionary.class] || reply[@"error"] != nil;
                // Only this process may read the file: it lives in the app
                // container, and another process reading it trips macOS 14+
                // app-data protection, while the inherited stdout fd crosses
                // the sandbox freely. `<verb> -` writes the raw bytes to
                // stdout and the JSON reply to stderr. In a script the reply
                // line carries the bytes as base64 plus any label.
                if (!failed && [options.fileVerbs containsObject:args.firstObject]
                            && (inScript || [args containsObject:@"-"])) {
                    NSString *pngPath = [reply[@"path"] isKindOfClass:NSString.class] ? reply[@"path"] : nil;
                    NSData *png = pngPath ? [NSData dataWithContentsOfFile:pngPath] : nil;
                    // Consumed here, or the per-command files pile up all run.
                    if (pngPath) {
                        [fileManager removeItemAtPath:pngPath error:nil];
                    }
                    if (png.length == 0) {
                        fprintf(stderr, "%s: no file at %s\n", options.messagePrefix.UTF8String,
                                pngPath.fileSystemRepresentation ?: "(no path in reply)");
                        return 2;
                    }
                    if (inScript) {
                        NSMutableDictionary *out = [NSMutableDictionary dictionary];
                        out[@"ok"] = @YES;
                        out[@"pngBase64"] = [png base64EncodedStringWithOptions:0];
                        for (NSUInteger i = 1; i < args.count; i++) {
                            if (![args[i] isEqualToString:@"-"]) {
                                out[@"label"] = args[i];
                                break;
                            }
                        }
                        VibeClientPrintReply(VibeJSONString(out), YES);
                        return 0;
                    }
                    fwrite(png.bytes, 1, png.length, stdout);
                    fprintf(stderr, "%s\n", response.UTF8String);
                    return 0;
                }
                if (response.length) {
                    VibeClientPrintReply(response, inScript);
                }
                return failed ? 2 : 0;
            }
            if ([deadline timeIntervalSinceNow] <= 0) {
                break;
            }
            usleep(backoff);
            backoff = MIN(backoff * 2, 20 * 1000);
        }
        [fileManager removeItemAtPath:commandPath error:nil];
        // Tenths for a wait that is not whole, or 0.5 s prints as 0 s.
        int decimals = timeout == floor(timeout) ? 0 : 1;
        fprintf(stderr, "%s: no response after %.*fs — is a debug build of %s running?\n",
                options.messagePrefix.UTF8String, decimals, timeout, options.displayName.UTF8String);
        return 1;
    }
}

#pragma mark Script mode

// Whitespace-splits one script line into tokens; single or double quotes
// group a token containing spaces (no escape sequences — this is a command
// list, not a shell). Returns nil with *error set on an unterminated quote.
static NSArray<NSString *> *VibeTokenizeScriptLine(NSString *line, NSString **error) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSMutableString *current = nil;
    unichar quote = 0;
    for (NSUInteger i = 0; i < line.length; i++) {
        unichar ch = [line characterAtIndex:i];
        if (quote) {
            if (ch == quote) {
                quote = 0;
            }
            else {
                [current appendFormat:@"%C", ch];
            }
        }
        else if (ch == '\'' || ch == '"') {
            quote = ch;
            if (!current) {
                current = [NSMutableString string];
            }
        }
        else if (ch == ' ' || ch == '\t') {
            if (current) {
                [tokens addObject:current];
                current = nil;
            }
        }
        else {
            if (!current) {
                current = [NSMutableString string];
            }
            [current appendFormat:@"%C", ch];
        }
    }
    if (quote) {
        *error = @"unterminated quote";
        return nil;
    }
    if (current) {
        [tokens addObject:current];
    }
    return tokens;
}

// One command per line, run in order; blank lines and full-line # comments
// are skipped. Output is one JSON reply per command (NDJSON). Stops at the
// first failing command and returns its exit code, so a script doubles as a
// test: exit 0 means every command succeeded.
static int VibeDebugClientRunScript(NSString *source, VibeDebugClientOptions *options, const char *flag) {
    NSUInteger lineNumber = 0;
    for (NSString *rawLine in [source componentsSeparatedByString:@"\n"]) {
        lineNumber++;
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceCharacterSet];
        if (line.length == 0 || [line hasPrefix:@"#"]) {
            continue;
        }
        NSString *error = nil;
        NSArray<NSString *> *tokens = VibeTokenizeScriptLine(line, &error);
        if (!tokens) {
            fprintf(stderr, "%s: script line %lu: %s\n", options.messagePrefix.UTF8String,
                    (unsigned long)lineNumber, error.UTF8String);
            return 64;
        }
        if (tokens.count == 0) {
            continue;
        }
        int status = VibeDebugClientRunOne(tokens, YES, options, flag);
        if (status != 0) {
            fprintf(stderr, "%s: script line %lu failed (exit %d): %s\n", options.messagePrefix.UTF8String,
                    (unsigned long)lineNumber, status,
                    [tokens componentsJoinedByString:@" "].UTF8String);
            return status;
        }
    }
    return 0;
}

int VibeDebugClientMain(int argc, const char *argv[], VibeDebugClientOptions *options) {
    @autoreleasepool {
        const char *flag = argc >= 2 ? argv[1] : "";
        const char *name = options.displayName.UTF8String;
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 2; i < argc; i++) {
            [args addObject:@(argv[i])];
        }
        if (args.count == 0) {
            fprintf(stderr, "usage: %s %s <command> [args...]\n", name, flag);
            return 64;
        }
        if ([args.firstObject isEqualToString:@"script"]) {
            if (args.count != 2) {
                fprintf(stderr, "usage: %s %s script <file | ->\n", name, flag);
                return 64;
            }
            NSString *source;
            if ([args[1] isEqualToString:@"-"]) {
                NSData *data = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
                source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            }
            else {
                source = [NSString stringWithContentsOfFile:args[1].stringByExpandingTildeInPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
            }
            if (!source) {
                // Usually the sandbox: this process can't read arbitrary user
                // paths (as with argv files). stdin always crosses.
                fprintf(stderr, "%s: cannot read script '%s' (sandbox?) — use: script - < %s\n",
                        options.messagePrefix.UTF8String, [args[1] UTF8String], [args[1] UTF8String]);
                return 64;
            }
            return VibeDebugClientRunScript(source, options, flag);
        }
        return VibeDebugClientRunOne(args, NO, options, flag);
    }
}

#endif
