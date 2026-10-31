//
//  DebugClientLocalVerbs.m
//  Vibe
//
//  The verbs Vibe's CLI client runs in its own process, and the client's
//  options. The client itself is vibe-libs' dev/DebugChannel (DebugClient.m).
//

#import "DebugMacEntry.h"

#if DEBUG

#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "DebugClient.h"
#import "DebugCommonVerbs.h"
#import "DebugWireFormat.h"

// scan_bpm, scan_key, clear_disk_caches, and set_analysis. Answers the exit
// code, or -1 for any other verb.
static int VibeDebugClientLocalVerb(NSArray<NSString *> *args, BOOL inScript, void (^print)(NSString *json)) {
    // The stdin form stages the bytes in this process's own container
    // tmp: a shell cp into ~/Library/Containers/<id>/ trips macOS 14+
    // app-data protection, while inherited fds cross the sandbox freely.
    // The staged file has no extension; CoreAudio identifies the format
    // by content.
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
        print(json);
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
        print(VibeJSONString(@{@"ok": @YES, @"cleared": cleared}));
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
        print(VibeJSONString(@{@"ok": @YES,
                               @"analyzeBPM": @(AppSettings.sharedInstance.analyzeBPM),
                               @"analyzeKey": @(AppSettings.sharedInstance.analyzeKey)}));
        return 0;
    }
    return -1;
}

int VibeDebugCommandClientMain(int argc, const char *argv[]) {
    VibeDebugClientOptions *options = [VibeDebugClientOptions new];
    // The bundle ID names the channel, as the app installs it.
    options.channel = NSBundle.mainBundle.bundleIdentifier;
    options.displayName = @"Vibe";
    options.messagePrefix = @"vibe";
    // The bit-perfect verifier sets it: the app's main thread waits out a
    // dead device for longer than the default wait.
    options.timeoutEnvironmentKey = @"VIBE_DEBUG_TIMEOUT";
    options.waitForVerb = ^NSTimeInterval(NSString *verb) {
        return [VibeCommandSpecForVerb(verb)[@"clientTimeout"] doubleValue];
    };
    // run-script.sh decodes a script's screenshots to numbered files.
    options.fileVerbs = @[@"dump_screenshot"];
    options.localVerb = ^int(NSArray<NSString *> *args, BOOL inScript, void (^print)(NSString *json)) {
        return VibeDebugClientLocalVerb(args, inScript, print);
    };
    return VibeDebugClientMain(argc, argv, options);
}

#endif
