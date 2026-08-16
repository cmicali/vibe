//
// Created by Christopher Micali on 8/10/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "DebugUtil.h"

#if DEBUG

#import <notify.h>
#import <unistd.h>
#import "DebugWireFormat.h"

// The CLI half of the debug command channel: VibeDebugCommandClientMain, which
// main.m runs for `Vibe --debug-cmd ...` before NSApplicationMain. The local
// verbs (sleep, scan_bpm, clear_disk_caches, set_appearance) run in this
// process; everything else rides the file-and-notification transport to the
// running app. See DebugUtil.h for the transport contract and DebugUtil.m for
// the app side.

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

// Runs one command — local verbs in this process, everything else over the
// channel — printing its reply line and returning the exit code. Called both
// by the top-level main and per script line (inScript switches the verbs
// whose I/O contract can't compose with NDJSON-lines output: dump_screenshot
// replies carry the PNG as base64 instead of streaming raw bytes, and
// stdin-streaming scan_bpm - and nested script are rejected).
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
        // scan_bpm runs IN THIS PROCESS — a pure decode+analyze with no app
        // state — so the client skips the channel round-trip entirely: it
        // works with no app running and never disturbs a running instance.
        // `scan_bpm - < file` streams the audio via stdin: this process owns
        // the app container and stages the bytes in its own tmp — a shell cp
        // into ~/Library/Containers/<id>/ trips macOS 14+ app-data
        // protection, while inherited fds cross the sandbox freely. The
        // staged file carries no extension: CoreAudio identifies the format
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
        // into the container prompts). Only for when no app is running —
        // deleting under a live app races its open caches (clear-caches.sh
        // guards with pgrep and uses the channel's clear_caches instead).
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
        // In-process: shell `defaults write` into the container prompts; this
        // process writes its own domain. Persists for the next launch — with
        // the app running use click_menu view_appearance_* instead. "system"
        // writes the "" follow-OS sentinel (like the View menu) rather than
        // deleting the key, whose registered default is dark.
        if ([args.firstObject isEqualToString:@"set_appearance"]) {
            NSDictionary<NSString *, NSString *> *values = @{
                @"light": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT,
                @"dark": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK,
                @"system": SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT,
            };
            NSString *value = args.count == 2 ? values[args[1]] : nil;
            if (!value) {
                fprintf(stderr, "usage: Vibe --debug-cmd set_appearance <light|dark|system>\n");
                return 64;
            }
            Settings.windowAppearanceStyle = value;
            // Short-lived process: force the cfprefsd flush before exit.
            [NSUserDefaults.standardUserDefaults synchronize];
            VibeClientPrintReply(VibeJSONString(@{@"ok": @YES, @"windowAppearance": args[1]}), inScript);
            return 0;
        }
        // The key-label appearance settings. A CLI-process write reaches a
        // running app's reads immediately (same bundle ID and container, so
        // cfprefsd shares the domain — verified with dump_state), but nothing
        // repaints on the write itself: the label picks the change up at its
        // next re-render (a key delivery, fader tick, track change, or
        // updateUI). The Settings pane that owns these cannot be driven over
        // this channel.
        if ([args.firstObject isEqualToString:@"set_key_display"]) {
            NSDictionary<NSString *, NSString *> *notations = @{
                @"camelot": SETTINGS_VALUE_KEY_NOTATION_CAMELOT,
                @"musical": SETTINGS_VALUE_KEY_NOTATION_MUSICAL,
            };
            NSString *notation = args.count == 3 ? notations[args[1]] : nil;
            BOOL colorsOn = args.count == 3 && [args[2] isEqualToString:@"colors"];
            BOOL colorsOff = args.count == 3 && [args[2] isEqualToString:@"plain"];
            if (!notation || (!colorsOn && !colorsOff)) {
                fprintf(stderr, "usage: Vibe --debug-cmd set_key_display <camelot|musical> <colors|plain>\n");
                return 64;
            }
            Settings.keyNotation = notation;
            Settings.keyColorsEnabled = colorsOn;
            [NSUserDefaults.standardUserDefaults synchronize];
            VibeClientPrintReply(VibeJSONString(@{@"ok": @YES, @"keyNotation": notation,
                                                  @"keyColors": @(colorsOn)}), inScript);
            return 0;
        }
        // The analysis toggles — a CLI-process prefs write that, like
        // set_key_display above, a running app's reads see immediately:
        // the next waveform decode picks the new values up, no
        // relaunch needed. This exists to make the analyzers' cost
        // measurable: each decode pass reads these, so A/B timing needs them
        // settable without the UI.
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
                Settings.analyzeBPM = on;
            }
            else {
                Settings.analyzeKey = on;
            }
            [NSUserDefaults.standardUserDefaults synchronize];
            VibeClientPrintReply(VibeJSONString(@{@"ok": @YES,
                                                  @"analyzeBPM": @(Settings.analyzeBPM),
                                                  @"analyzeKey": @(Settings.analyzeKey)}), inScript);
            return 0;
        }
        NSString *commandId = NSUUID.UUID.UUIDString;
        // Args ride a JSON array, one element per argv entry — never joined
        // and re-tokenized — so a quoted path with any whitespace (including
        // consecutive spaces) reaches the handler byte-exact.
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
        // Per-verb wait from the same table the app dispatches with — slow
        // verbs (file_cache's full decode, clear_caches' blocking clear)
        // declare their own window there; everything else gets 5s.
        NSTimeInterval timeout = [VibeCommandSpecForVerb(args.firstObject)[@"clientTimeout"] doubleValue];
        if (timeout <= 0) {
            timeout = 5;
        }
        int maxPolls = (int)(timeout / 0.05);
        for (int i = 0; i < maxPolls; i++) {
            usleep(50 * 1000);
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
                // dump_screenshot payload delivery. Only this process may
                // read the PNG — it lives in the app container, and another
                // process reading it trips macOS 14+ app-data protection; the
                // inherited stdout fd crosses the sandbox freely.
                // Top level, `dump_screenshot -`: raw PNG bytes to stdout
                // (JSON reply moves to stderr); the caller opens its own
                // redirect target. In a script: the reply line carries the
                // PNG base64-encoded (raw bytes can't interleave with
                // one-JSON-object-per-line output) plus any label argument —
                // run-script.sh decodes them to numbered files.
                if (!failed && [args.firstObject isEqualToString:@"dump_screenshot"]
                            && (inScript || [args containsObject:@"-"])) {
                    NSString *pngPath = [reply[@"path"] isKindOfClass:NSString.class] ? reply[@"path"] : nil;
                    NSData *png = pngPath ? [NSData dataWithContentsOfFile:pngPath] : nil;
                    // Consumed here, so delete like the response file — the
                    // per-command PNGs would otherwise pile up all run long.
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
