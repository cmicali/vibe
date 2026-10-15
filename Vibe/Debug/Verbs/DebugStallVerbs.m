//
//  DebugStallVerbs.m
//  Vibe
//
//  The verbs that stall the app on purpose: main, the render, the decoder,
//  an open and every read-ahead.
//

#import "DebugCommonVerbs.h"

#if DEBUG

#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"
#import "AudioFileHandle.h"
#import "AudioFileHandle+Debug.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioFileMaterializationCoordinator+Debug.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Debug.h"

// Well under the stress driver's 20s liveness probe, so a stray block is never
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

// set_slow_volume's state. The verb writes it on main. The read-ahead hook
// reads it on read-ahead threads. Both hold the condition's lock. A held read
// waits on the condition until its due time or until the next
// set_slow_volume moves slowVolumeGeneration.
static NSString *sSlowVolumeMode = @"off";
static double sSlowVolumeBytesPerSecond;
static int sSlowVolumeErrno;
static uint64_t sSlowVolumeGeneration;
static CFAbsoluteTime sSlowVolumeNextDue;
static NSInteger sSlowVolumeHeldReads;
static NSInteger sSlowVolumeReads;

static NSCondition *VibeSlowVolumeCondition(void) {
    static NSCondition *condition;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        condition = [NSCondition new];
    });
    return condition;
}

// A throttle paces every read-ahead together, as one slow link would. Each
// read is due once the reads before it have had their share of the rate.
static int VibeSlowVolumeBeforeRead(uint64_t length) {
    NSCondition *condition = VibeSlowVolumeCondition();
    @autoreleasepool {
        [condition lock];
        sSlowVolumeReads++;
        int failure = sSlowVolumeErrno;
        NSDate *until = nil;
        if ([sSlowVolumeMode isEqualToString:@"stall"]) {
            until = NSDate.distantFuture;
        } else if (sSlowVolumeBytesPerSecond > 0) {
            sSlowVolumeNextDue = MAX(CFAbsoluteTimeGetCurrent(), sSlowVolumeNextDue)
                    + (double)length / sSlowVolumeBytesPerSecond;
            until = [NSDate dateWithTimeIntervalSinceReferenceDate:sSlowVolumeNextDue];
        }
        uint64_t generation = sSlowVolumeGeneration;
        if (until) {
            sSlowVolumeHeldReads++;
            while (generation == sSlowVolumeGeneration && [condition waitUntilDate:until]) {
            }
            sSlowVolumeHeldReads--;
        }
        [condition unlock];
        return failure;
    }
}

// Lets every held read go, then applies the new mode. Answers how many reads
// it let go.
static NSInteger VibeSetSlowVolume(NSString *mode, double bytesPerSecond, int failure) {
    NSCondition *condition = VibeSlowVolumeCondition();
    [condition lock];
    NSInteger released = sSlowVolumeHeldReads;
    sSlowVolumeGeneration++;
    sSlowVolumeMode = mode;
    sSlowVolumeBytesPerSecond = bytesPerSecond;
    sSlowVolumeErrno = failure;
    sSlowVolumeNextDue = 0;
    sSlowVolumeReads = 0;
    [condition broadcast];
    [condition unlock];
    BOOL forced = ![mode isEqualToString:@"off"];
    [AudioFileHandle debugSetMountRule:forced ? ^NSNumber *(NSURL *url) {
        return @YES;
    } : nil];
    [AudioFileHandle debugSetBeforeRead:forced ? ^int(NSURL *url, uint64_t offset, uint64_t length) {
        return VibeSlowVolumeBeforeRead(length);
    } : nil];
    return released;
}

static NSDictionary *VibeSlowVolumeReply(NSNumber *released) {
    NSCondition *condition = VibeSlowVolumeCondition();
    [condition lock];
    NSMutableDictionary *reply = [@{
        @"ok": @YES,
        @"mode": sSlowVolumeMode,
        @"forced": @(![sSlowVolumeMode isEqualToString:@"off"]),
        @"reads": @(sSlowVolumeReads),
        @"heldReads": @(sSlowVolumeHeldReads),
    } mutableCopy];
    if (sSlowVolumeBytesPerSecond > 0) {
        reply[@"bytesPerSecond"] = @(sSlowVolumeBytesPerSecond);
    }
    if (sSlowVolumeErrno) {
        reply[@"errno"] = @(sSlowVolumeErrno);
        // Not `error`: the client reads that key as the verb failing.
        reply[@"errnoName"] = @(strerror(sSlowVolumeErrno));
    }
    [condition unlock];
    if (released) {
        reply[@"releasedReads"] = released;
    }
    reply[@"liveReadAheads"] = @(AudioFileHandle.debugLiveReadAheads);
    reply[@"orphanedReadAheads"] = @(AudioFileHandle.debugOrphanedReadAheads);
    return reply;
}

NSArray<NSDictionary *> *VibeDebugStallVerbs(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            VibeDebugCmd(@"block_main_deep <seconds> <depth> [alternating]", 30,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
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
            // The next real render spins inside the pipeline until the hold
            // lifts, so the render clock stops and the beta watcher samples the
            // IO thread. Bounded like block_main; audible as a gap.
            VibeDebugCmd(@"block_render <seconds>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                double seconds = 0;
                if (tokens.count != 2 || !VibeParseDouble(tokens[1], &seconds)
                        || seconds <= 0 || seconds > kMaxBlockMainSeconds) {
                    return VibeErrorJSON(@"usage: block_render <seconds 0-%g>", kMaxBlockMainSeconds);
                }
                AudioPlayer *player = surface.debugPlayer;
                [player debugHoldRenderInside:YES];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    [player debugHoldRenderInside:NO];
                });
                return VibeJSONString(@{@"ok": @YES, @"heldSeconds": @(seconds)});
            }),
            // Every decode turn waits for the hold, as one stuck in a stalled read
            // would: the rings drain, and a hold past what they buffered
            // underruns (the voice's underrunFrames). Bounded like block_main.
            VibeDebugCmd(@"block_decoder <seconds>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                double seconds = 0;
                if (tokens.count != 2 || !VibeParseDouble(tokens[1], &seconds)
                        || seconds <= 0 || seconds > kMaxBlockMainSeconds) {
                    return VibeErrorJSON(@"usage: block_decoder <seconds 0-%g>", kMaxBlockMainSeconds);
                }
                AudioPlayer *player = surface.debugPlayer;
                [player debugHoldDecoder:YES];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    [player debugHoldDecoder:NO];
                });
                return VibeJSONString(@{@"ok": @YES, @"heldSeconds": @(seconds)});
            }),
            // Holds main, then runs a shared verb WITHOUT yielding it: one turn,
            // not two. It stages a worker's main-queue callback that was raised
            // before a user action but runs after it, which two channel commands
            // cannot, since the channel's own intake is on main. Only shared
            // verbs, because the platform tables are typed to their own
            // controllers.
            VibeDebugCmd(@"block_main <seconds> [<verb> ...]", 30,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                double seconds = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &seconds)
                        || seconds <= 0 || seconds > kMaxBlockMainSeconds) {
                    return VibeErrorJSON(@"usage: block_main <seconds 0-%g> [<verb> ...]",
                                         kMaxBlockMainSeconds);
                }
                NSArray<NSString *> *then = tokens.count > 2
                        ? [tokens subarrayWithRange:NSMakeRange(2, tokens.count - 2)] : nil;
                NSDictionary *spec = then
                        ? VibeDebugSpecForVerb(VibeDebugCommonCommandTable(), then.firstObject)
                        : nil;
                if (then && !spec) {
                    return VibeErrorJSON(@"block_main can only chain a shared verb, not '%@'",
                                         then.firstObject);
                }
                if ([then.firstObject isEqualToString:@"block_main"]) {
                    return VibeErrorJSON(@"block_main cannot chain itself");
                }
                usleep((useconds_t)(seconds * 1e6));
                if (!spec) {
                    return VibeJSONString(@{@"ok": @YES, @"blockedSeconds": @(seconds)});
                }
                VibeDebugCommandHandler handler = spec[@"handler"];
                NSString *chained = handler(then, commandId, surface);
                // The chained verb replies asynchronously under this commandId;
                // a reply here would be a second response.
                if (!chained) {
                    return nil;
                }
                return VibeJSONString(@{@"ok": @YES, @"blockedSeconds": @(seconds),
                                        @"then": then.firstObject,
                                        @"thenReply": chained});
            }),
            // set_fake_cloud shapes stage 1, the download; this holds stage 2,
            // the uncancellable AudioFileHandle call, which a locally backed
            // fake cannot stage on its own.
            VibeDebugCmd(@"hang_open <basename>|release", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: hang_open <basename>|release");
                }
                if ([tokens[1] isEqualToString:@"release"]) {
                    [AudioFileMaterializationCoordinator debugReleaseHungOpens];
                }
                else {
                    [AudioFileMaterializationCoordinator debugHangOpensForBasename:tokens[1]];
                }
                BOOL releasing = [tokens[1] isEqualToString:@"release"];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"hangingBasename": releasing ? (id)NSNull.null : tokens[1],
                    @"hungOpens": @([AudioFileMaterializationCoordinator debugHungOpenCount]),
                });
            }),
            // Every file opened from now on reads ahead, as if on a share. See
            // AudioFileHandle+Debug.h. No argument reports and changes nothing.
            VibeDebugCmd(@"set_slow_volume [off|on|throttle <bytes-per-second>|stall|fail [<errno>]]", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                if (tokens.count == 1) {
                    return VibeJSONString(VibeSlowVolumeReply(nil));
                }
                NSString *mode = tokens[1].lowercaseString;
                double bytesPerSecond = 0;
                NSUInteger failure = EIO;
                BOOL valid = tokens.count == 2 && [@[@"off", @"on", @"stall"] containsObject:mode];
                if ([mode isEqualToString:@"throttle"]) {
                    valid = tokens.count == 3 && VibeParseDouble(tokens[2], &bytesPerSecond) && bytesPerSecond > 0;
                }
                else if ([mode isEqualToString:@"fail"]) {
                    valid = tokens.count == 2 || (tokens.count == 3 && VibeParseNonnegativeInteger(tokens[2], &failure)
                            && failure > 0 && failure <= ELAST);
                }
                if (!valid) {
                    return VibeErrorJSON(@"usage: set_slow_volume [off|on|throttle <bytes-per-second>|stall"
                                         @"|fail [<errno 1-%d>]]", ELAST);
                }
                NSInteger released = VibeSetSlowVolume(mode, bytesPerSecond,
                                                       [mode isEqualToString:@"fail"] ? (int)failure : 0);
                return VibeJSONString(VibeSlowVolumeReply(@(released)));
            }),
        ];
    });
    return table;
}

#endif
