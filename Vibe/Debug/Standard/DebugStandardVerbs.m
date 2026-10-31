//
//  DebugStandardVerbs.m
//  vibe-libs
//
//  The shared verbs: the build, quit, the work tally, process health, and
//  the main-thread stalls.
//

#import "DebugStandardVerbs.h"

#if DEBUG

#import <TargetConditionals.h>
#import <unistd.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif
#import "DebugChannel.h"
#import "DebugCommandDispatch.h"
#import "DebugProcessHealth.h"
#import "DebugWireFormat.h"
#import "HelperMacros.h"
#import "NSBundle+BuildInfo.h"
#import "VibeWorkTally.h"

@implementation VibeDebugStandardOptions
@end

// Well under a stress driver's 20 s liveness probe, so a stray block is never
// mistaken for the hang it imitates.
static const double kMaxBlockMainSeconds = 5.0;

// Holds main from under `depth` real frames, so a stall-stack sample must span
// a stack as deep as a layout recursion. Alternating call sites give
// neighbouring frames different return addresses, as a layout <-> subview
// recursion does. Not a tail call, or the compiler flattens it into a loop.
__attribute__((noinline)) static NSUInteger VibeDebugRecurseThenBlock(NSUInteger depth, useconds_t micros,
                                                                        BOOL alternating) {
    if (depth == 0) {
        usleep(micros);
        return 0;
    }
    volatile NSUInteger kept = depth;
    if (alternating && depth % 2) {
        return VibeDebugRecurseThenBlock(depth - 1, micros, alternating) + kept + 1;
    }
    return VibeDebugRecurseThenBlock(depth - 1, micros, alternating) + kept;
}

// Every shared verb but block_main, which chains them.
static NSArray<NSDictionary *> *VibeDebugChainableSharedVerbs(VibeDebugStandardOptions *options) {
    return @[
        // The tally exists only where the app defines VIBE_SIGNPOSTS, so a
        // build without it answers an error.
        VibeDebugCmd(@"work_tally <begin|end>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                              id controller) {
#if VIBE_SIGNPOSTS
            if (tokens.count == 2 && [tokens[1] isEqualToString:@"begin"]) {
                VibeWorkTallyBeginWindow("debug");
                return VibeJSONString(@{@"ok": @YES});
            }
            if (tokens.count == 2 && [tokens[1] isEqualToString:@"end"]) {
                return VibeJSONString(VibeWorkTallyTakeWindow());
            }
            return VibeErrorJSON(@"usage: work_tally <begin|end>");
#else
            return VibeErrorJSON(@"work_tally needs a build that defines VIBE_SIGNPOSTS");
#endif
        }),
        // Which build answered: two instances race for the channel, and a
        // stale one replies like a fresh one.
        VibeDebugCmd(@"dump_build", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                   id controller) {
            NSBundle *bundle = NSBundle.mainBundle;
            NSString *channel = VibeDebugChannelName();
            NSDictionary *extras = options.buildExtras ? options.buildExtras(controller) : nil;
            NSMutableDictionary *reply = extras ? [extras mutableCopy] : [NSMutableDictionary dictionary];
            [reply addEntriesFromDictionary:@{
                @"bundleId": bundle.bundleIdentifier ?: NSNull.null,
                @"executable": bundle.executablePath.lastPathComponent ?: NSNull.null,
                @"channel": channel ? VibeDebugCommandNotificationName(channel) : NSNull.null,
                @"version": bundle.vibeVersionString,
                @"git": bundle.vibeGitString,
                @"built": bundle.vibeBuildTimeString,
                @"pid": @(NSProcessInfo.processInfo.processIdentifier),
                @"path": bundle.bundlePath,
            }];
            return VibeJSONString(reply);
        }),
        // 10 s: an app's extras may read a queue a wedge would hold, so the
        // verb times out rather than answering from stale state.
        VibeDebugCmd(@"dump_health", 10, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                     id controller) {
            NSDictionary *process = VibeDebugProcessHealth();
            NSDictionary *extras = options.healthExtras ? options.healthExtras(controller) : nil;
            NSMutableDictionary *reply = extras ? [extras mutableCopy] : [NSMutableDictionary dictionary];
            reply[@"ok"] = @YES;
            reply[@"process"] = process;
            return VibeJSONString(reply);
        }),
        // Ends the app without a signal, the only way to end one Xcode is
        // debugging (the debugger traps SIGTERM), and on macOS the only exit
        // that runs applicationWillTerminate:. The reply is written first
        // because nothing survives to write it; the exit is deferred so the
        // calling drain finishes.
        VibeDebugCmd(@"quit", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                             id controller) {
            VibeWriteDebugResponse(commandId, VibeJSONString(@{@"ok": @YES, @"quitting": @YES}));
            run_on_main_thread({
#if TARGET_OS_OSX
                [NSApp terminate:nil];
#else
                // UIKit has no terminate; the simulator test loop wants
                // exactly this.
                exit(0);
#endif
            });
            return nil; // written above, before the app goes away
        }),
        VibeDebugCmd(@"block_main_deep <seconds> <depth> [alternating]", 30,
                     ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            double seconds = 0, depth = 0;
            BOOL alternating = tokens.count == 4 && [tokens[3] isEqualToString:@"alternating"];
            if ((tokens.count != 3 && !alternating) || !VibeParseDouble(tokens[1], &seconds)
                    || !VibeParseDouble(tokens[2], &depth)
                    || seconds <= 0 || seconds > kMaxBlockMainSeconds || depth < 0 || depth > 4000) {
                return VibeErrorJSON(@"usage: block_main_deep <seconds 0-%g> <depth 0-4000> [alternating]",
                                     kMaxBlockMainSeconds);
            }
            VibeDebugRecurseThenBlock((NSUInteger)depth, (useconds_t)(seconds * 1e6), alternating);
            return VibeJSONString(@{@"ok": @YES, @"blockedSeconds": @(seconds), @"depth": @(depth),
                                    @"alternating": @(alternating)});
        }),
    ];
}

static NSArray<NSDictionary *> *VibeDebugSharedVerbs(VibeDebugStandardOptions *options) {
    NSArray<NSDictionary *> *chainable = VibeDebugChainableSharedVerbs(options);
    // Holds main, then runs a chained verb WITHOUT yielding it: one turn, not
    // two. It stages a worker's main-queue callback that was raised before a
    // user action but runs after it, which two channel commands cannot, since
    // the channel's own intake is on main. Only the shared verbs and the app's
    // chainable ones, so the platform verbs stay unchainable.
    NSDictionary *blockMain = VibeDebugCmd(@"block_main <seconds> [<verb> ...]", 30,
                                           ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                       id controller) {
        double seconds = 0;
        if (tokens.count < 2 || !VibeParseDouble(tokens[1], &seconds)
                || seconds <= 0 || seconds > kMaxBlockMainSeconds) {
            return VibeErrorJSON(@"usage: block_main <seconds 0-%g> [<verb> ...]", kMaxBlockMainSeconds);
        }
        NSArray<NSString *> *then = tokens.count > 2
                ? [tokens subarrayWithRange:NSMakeRange(2, tokens.count - 2)] : nil;
        if ([then.firstObject isEqualToString:@"block_main"]) {
            return VibeErrorJSON(@"block_main cannot chain itself");
        }
        NSDictionary *spec = nil;
        if (then) {
            spec = VibeDebugSpecForVerb(chainable, then.firstObject);
            if (!spec && options.chainableVerbs) {
                NSArray<NSDictionary *> *app = options.chainableVerbs();
                spec = app ? VibeDebugSpecForVerb(app, then.firstObject) : nil;
            }
            if (!spec) {
                return VibeErrorJSON(@"block_main can only chain a shared verb, not '%@'", then.firstObject);
            }
        }
        usleep((useconds_t)(seconds * 1e6));
        if (!spec) {
            return VibeJSONString(@{@"ok": @YES, @"blockedSeconds": @(seconds)});
        }
        VibeDebugCommandHandler handler = spec[@"handler"];
        NSString *chained = handler(then, commandId, controller);
        // The chained verb replies asynchronously under this commandId; a
        // reply here would be a second response.
        if (!chained) {
            return nil;
        }
        return VibeJSONString(@{@"ok": @YES, @"blockedSeconds": @(seconds),
                                @"then": then.firstObject,
                                @"thenReply": chained});
    });
    return [chainable arrayByAddingObject:blockMain];
}

NSArray<NSDictionary *> *VibeDebugStandardVerbs(VibeDebugStandardOptions *options) {
    return [VibeDebugSharedVerbs(options) arrayByAddingObjectsFromArray:VibeDebugStandardPlatformVerbs(options)];
}

#endif
