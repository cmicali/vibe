//
//  DebugClient.m
//  Vibe
//

#import "DebugUtil.h"

#if DEBUG

#import <notify.h>
#import <unistd.h>
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "DebugWireFormat.h"

// The CLI half of the debug command channel. The local verbs (sleep, script,
// scan_bpm, scan_key, clear_disk_caches, set_analysis) run in this process;
// everything else rides the transport DebugUtil.h describes.

#pragma mark Client side

// Script-mode replies are re-serialized compact — one line per command — so
// script output is real NDJSON a wrapper can line-split (run-script.sh does).
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
// verbs whose I/O cannot compose with NDJSON output: dump_screenshot carries
// the PNG as base64 instead of raw bytes, and the stdin scan forms and nested
// script are rejected.
static int VibeDebugClientRunOne(NSArray<NSString *> *args, BOOL inScript) {
    @autoreleasepool {
        // Client-side pause, for scripts: the app's main thread never sleeps.
        if ([args.firstObject isEqualToString:@"sleep"]) {
            double seconds = 0;
            BOOL valid = args.count == 2 && VibeParseDouble(args[1], &seconds)
                    && seconds > 0 && seconds <= 600;
            if (!valid) {
                fprintf(stderr, "usage: Vibe --debug-cmd sleep <seconds 0-600>\n");
                return 64;
            }
            usleep((useconds_t)(seconds * 1e6));
            VibeClientPrintReply(VibeJSONString(@{@"ok": @YES, @"slept": @(seconds)}), inScript);
            return 0;
        }
        if (inScript && [args.firstObject isEqualToString:@"script"]) {
            fprintf(stderr, "vibe: scripts cannot nest\n");
            return 64;
        }
        // The stdin form stages the bytes in this process's own container
        // tmp: a shell cp into ~/Library/Containers/<id>/ trips macOS 14+
        // app-data protection, while inherited fds cross the sandbox freely.
        // The staged file has no extension; CoreAudio identifies the format
        // by content (verified for WAV/FLAC/MP4/ADTS).
        BOOL isScanBPM = [args.firstObject isEqualToString:@"scan_bpm"];
        if (isScanBPM || [args.firstObject isEqualToString:@"scan_key"]) {
            const char *verb = args.firstObject.UTF8String;
            NSString *(*scan)(NSString *) = isScanBPM ? VibeDebugBPMScanJSON : VibeDebugKeyScanJSON;
            NSString *json = nil;
            if (args.count == 2 && [args[1] isEqualToString:@"-"]) {
                if (inScript) {
                    // The script source may itself be riding stdin.
                    fprintf(stderr, "vibe: %s - (stdin) is not available inside a script — pass a file path\n", verb);
                    return 64;
                }
                NSData *audio = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
                if (audio.length == 0) {
                    fprintf(stderr, "vibe: empty stdin — usage: Vibe --debug-cmd %s - < file\n", verb);
                    return 64;
                }
                NSString *staged = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"analysis-scan-%@", NSUUID.UUID.UUIDString]];
                if (![audio writeToFile:staged atomically:YES]) {
                    fprintf(stderr, "vibe: cannot write %s\n", staged.fileSystemRepresentation);
                    return 1;
                }
                json = scan(staged);
                [NSFileManager.defaultManager removeItemAtPath:staged error:nil];
            }
            else if (args.count == 2) {
                json = scan(args[1]);
            }
            else {
                fprintf(stderr, "usage: Vibe --debug-cmd %s <file | ->\n", verb);
                return 64;
            }
            VibeClientPrintReply(json, inScript);
            NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:
                    [json dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data
                                                                  options:0
                                                                    error:nil];
            return reply[@"error"] != nil ? 2 : 0;
        }
        // In-process for the same container-ownership reason (a shell rm -rf
        // into the container prompts). Only with no app running: deleting
        // under a live app races its open caches, which is why clear-caches.sh
        // checks pgrep and uses the channel's clear_caches instead.
        if ([args.firstObject isEqualToString:@"clear_disk_caches"]) {
            NSString *caches = NSSearchPathForDirectoriesInDomains(
                    NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            NSFileManager *fm = NSFileManager.defaultManager;
            NSMutableArray<NSString *> *cleared = [NSMutableArray array];
            for (NSString *name in [fm contentsOfDirectoryAtPath:caches error:nil]) {
                if ([name hasPrefix:@"com.pinterest.PINDiskCache."]
                        && [fm removeItemAtPath:[caches stringByAppendingPathComponent:name] error:nil]) {
                    [cleared addObject:name];
                }
            }
            VibeClientPrintReply(VibeJSONString(@{@"ok": @YES, @"cleared": cleared}), inScript);
            return 0;
        }
        // A prefs write from the CLI process. AppSettings reads these from
        // defaults on every access, so a running app's next waveform decode
        // sees them with no relaunch — A/B timing of the analyzers without
        // the UI.
        if ([args.firstObject isEqualToString:@"set_analysis"]) {
            BOOL on = args.count == 3 && [args[2] isEqualToString:@"on"];
            BOOL off = args.count == 3 && [args[2] isEqualToString:@"off"];
            BOOL isBPM = args.count == 3 && [args[1] isEqualToString:@"bpm"];
            BOOL isKey = args.count == 3 && [args[1] isEqualToString:@"key"];
            if ((!on && !off) || (!isBPM && !isKey)) {
                fprintf(stderr, "usage: Vibe --debug-cmd set_analysis <bpm|key> <on|off>\n");
                return 64;
            }
            if (isBPM) {
                AppSettings.sharedInstance.analyzeBPM = on;
            }
            else {
                AppSettings.sharedInstance.analyzeKey = on;
            }
            [NSUserDefaults.standardUserDefaults synchronize];
            VibeClientPrintReply(VibeJSONString(@{@"ok": @YES,
                                                  @"analyzeBPM": @(AppSettings.sharedInstance.analyzeBPM),
                                                  @"analyzeKey": @(AppSettings.sharedInstance.analyzeKey)}), inScript);
            return 0;
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
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        NSString *commandPath = VibeDebugCommandPath(commandId);
        if (![data writeToFile:commandPath atomically:YES]) {
            fprintf(stderr, "vibe: cannot write %s\n", commandPath.fileSystemRepresentation);
            return 1;
        }
        notify_post(kVibeDebugCommandNotification.UTF8String);

        NSString *responsePath = VibeDebugResponsePath(commandId);
        NSFileManager *fileManager = NSFileManager.defaultManager;
        // Slow verbs declare their own wait in the table the app dispatches
        // with. Everything else gets 5s, or VIBE_DEBUG_TIMEOUT: a script
        // driving the failure fixtures (the bit-perfect verifier) knows the
        // app's main thread waits out a dead device for longer than that.
        NSTimeInterval timeout = [VibeCommandSpecForVerb(args.firstObject)[@"clientTimeout"] doubleValue];
        if (timeout <= 0) {
            timeout = [NSProcessInfo.processInfo.environment[@"VIBE_DEBUG_TIMEOUT"] doubleValue];
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
                // Only this process may read the PNG: it lives in the app
                // container, and another process reading it trips macOS 14+
                // app-data protection, while the inherited stdout fd crosses
                // the sandbox freely. `dump_screenshot -` writes raw PNG bytes
                // to stdout and the JSON reply to stderr. In a script the reply
                // line carries the PNG as base64 plus any label, which
                // run-script.sh decodes to numbered files.
                if (!failed && [args.firstObject isEqualToString:@"dump_screenshot"]
                            && (inScript || [args containsObject:@"-"])) {
                    NSString *pngPath = [reply[@"path"] isKindOfClass:NSString.class] ? reply[@"path"] : nil;
                    NSData *png = pngPath ? [NSData dataWithContentsOfFile:pngPath] : nil;
                    // Consumed here, or the per-command PNGs pile up all run.
                    if (pngPath) {
                        [fileManager removeItemAtPath:pngPath error:nil];
                    }
                    if (png.length == 0) {
                        fprintf(stderr, "vibe: no screenshot at %s\n",
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
        fprintf(stderr, "vibe: no response after %.0fs — is a debug build of Vibe running?\n", timeout);
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
static int VibeDebugClientRunScript(NSString *source) {
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
            fprintf(stderr, "vibe: script line %lu: %s\n", (unsigned long)lineNumber, error.UTF8String);
            return 64;
        }
        if (tokens.count == 0) {
            continue;
        }
        int status = VibeDebugClientRunOne(tokens, YES);
        if (status != 0) {
            fprintf(stderr, "vibe: script line %lu failed (exit %d): %s\n",
                    (unsigned long)lineNumber, status,
                    [tokens componentsJoinedByString:@" "].UTF8String);
            return status;
        }
    }
    return 0;
}

int VibeDebugCommandClientMain(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 2; i < argc; i++) {
            [args addObject:@(argv[i])];
        }
        if (args.count == 0) {
            fprintf(stderr, "usage: Vibe --debug-cmd <command> [args...]\n");
            return 64;
        }
        if ([args.firstObject isEqualToString:@"script"]) {
            if (args.count != 2) {
                fprintf(stderr, "usage: Vibe --debug-cmd script <file | ->\n");
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
                // paths (same as argv audio files). stdin always crosses.
                fprintf(stderr, "vibe: cannot read script '%s' (sandbox?) — use: script - < %s\n",
                        [args[1] UTF8String], [args[1] UTF8String]);
                return 64;
            }
            return VibeDebugClientRunScript(source);
        }
        return VibeDebugClientRunOne(args, NO);
    }
}

#endif
