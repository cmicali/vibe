//
//  DebugCommonVerbs.m
//  Vibe
//
//  See DebugCommonVerbs.h.
//

#import "DebugCommonVerbs.h"
// kLevelBandCount, for dump_equalizer.
#import "AudioLevelMath.h"

#if DEBUG

#import <MediaPlayer/MediaPlayer.h>

#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"
#import "DebugChannel.h"
#import "DebugConsistency.h"
#import "AudioFileMaterializationCoordinator.h"
#import "AudioFileMaterializationCoordinator+Debug.h"
#import "AudioLoadingConfiguration.h"
#import "AudioLoadingConfiguration+Debug.h"
#import "AudioTrackMetadataCache.h"
#import "AudioTrackMetadataCache+Debug.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformCache+Debug.h"
#import "AudioLoadTiming.h"
#import "MusicalKey.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Debug.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "CloudTransferRegistryInternal.h"
#import "EqualizerIndicatorView+Debug.h"
#import "NSURLUtil.h"
#import "NSURLUtil+Debug.h"
#import "VibeFakeCloud.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

// The transport verbs: run the action, then reply with the surface's compact
// summary. Every one of them answers in the same shape, which is the point.
static NSDictionary *VibeTransportCmd(NSString *usage,
                                      void (^action)(id<VibeDebugPlayerSurface> surface)) {
    return VibeDebugCmd(usage, 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                              id<VibeDebugPlayerSurface> surface) {
        action(surface);
        return VibeJSONString(surface.debugActionSummary);
    });
}

NSString *VibeDebugPlayerStateName(AudioPlayer *player) {
    if (player.isPlaying) {
        return @"playing";
    }
    return player.isPaused ? @"paused" : @"stopped";
}

// How many filenames dump_state lists before it summarises the rest. A big
// folder would otherwise put tens of thousands of names through the channel.
static const NSUInteger kMaxListedFiles = 100;

// A runaway guard, not a budget: the burst below is one main-queue turn per
// jump, so even the ceiling costs under a second of wall clock.
static const NSUInteger kMaxBurstJumps = 5000;
// block_main's ceiling. Well under the stress driver's 20s liveness probe, so
// a stray one is never mistaken for the hang it deliberately imitates.
static const double kMaxBlockMainSeconds = 5.0;

static BOOL VibeParseConfigurationCount(NSString *text, NSUInteger *value) {
    return VibeParseNonnegativeInteger(text, value);
}

// Track changes at the rate the main queue will take them, which is the only
// way to reach the interleavings that matter.
//
// The channel itself cannot: one --debug-cmd invocation per op costs ~80ms
// against a plain build and ~2.4 SECONDS against a ThreadSanitizer one, almost
// all of it spawning an instrumented sandboxed client. At that rate two threads
// never collide, so a race hunt through the channel is hunting with the safety
// on. In-process, a jump lands every main-queue turn — hundreds a second,
// concurrent with a sweep's four stage-1 workers, which is exactly the pressure
// the cloud lane's lock and the materializer slots are there to survive.
//
// Re-dispatched rather than looped, deliberately: a tight loop on main would
// starve the very deliveries it is trying to race, and the app would look busy
// while nothing interleaved. The LCG makes a burst reproducible from its seed.
static void VibeBurstJumps(__weak id<VibeDebugPlayerSurface> surface,
                           NSUInteger remaining, uint32_t state) {
    id<VibeDebugPlayerSurface> strongSurface = surface;
    if (!strongSurface || remaining == 0) {
        return;
    }
    NSUInteger count = strongSurface.debugPlaylistCount;
    if (count > 0) {
        state = state * 1664525u + 1013904223u;
        [strongSurface debugPlayIndex:(state >> 16) % count];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        VibeBurstJumps(surface, remaining - 1, state);
    });
}

NSMutableDictionary *VibeDebugCommonStateDictionary(id<VibeDebugPlayerSurface> surface) {
    AudioPlayer *player = surface.debugPlayer;
    AudioTrack *track = surface.debugPlaylistCurrentTrack;
    NSUInteger count = surface.debugPlaylistCount;

    // Convergence, stated the way a user would: how many rows have had their
    // metadata land. `files` is capped, so this counts the whole playlist
    // separately rather than being derived from it. A nil metadata is the
    // scan not having reached the row — not the file lacking tags, which is a
    // parsed result like any other.
    NSUInteger resolvedRows = 0;
    for (NSUInteger i = 0; i < count; i++) {
        if ([surface debugPlaylistTrackAtIndex:i].metadata) {
            resolvedRows++;
        }
    }

    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        if (files.count == kMaxListedFiles) {
            [files addObject:[NSString stringWithFormat:@"… %lu more",
                    (unsigned long)(count - kMaxListedFiles)]];
            break;
        }
        [files addObject:[surface debugPlaylistTrackAtIndex:i].url.lastPathComponent ?: @""];
    }

    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    return [@{
        @"player": [@{
            @"state": VibeDebugPlayerStateName(player),
            @"position": @(player.position),
            @"duration": @(player.duration),
            @"numChannels": @(player.numChannels),
            @"gaplessArmed": @(player.isGaplessArmed),
            @"silent": @([arguments containsObject:@"--silent"]),
            @"noAudioHw": @([arguments containsObject:@"--no-audio-hw"]),
        } mutableCopy],
        @"currentTrack": track ? [@{
            @"url": track.url.path ?: @"",
            @"title": track.title ?: @"",
            @"artist": track.artist ?: @"",
            // The resolved values (tag over analysis); the key strings are
            // empty when unknown, and the BPM 0.
            @"bpm": @(track.bpm),
            @"key": VibeMusicalKeyMusicalName(track.key),
            @"camelot": VibeMusicalKeyCamelotName(track.key),
        } mutableCopy] : (id)NSNull.null,
        @"playlist": [@{
            @"count": @(count),
            @"currentIndex": @(surface.debugPlaylistCurrentIndex),
            @"resolvedRows": @(resolvedRows),
            @"files": files,
        } mutableCopy],
    } mutableCopy];
}

NSArray<NSDictionary *> *VibeDebugCommonCommandTable(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            VibeDebugCmd(@"dump_state", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                       id<VibeDebugPlayerSurface> surface) {
                return VibeJSONString(surface.debugStateDictionary);
            }),
            VibeDebugCmd(@"dump_now_playing", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                             id<VibeDebugPlayerSurface> surface) {
                // What we publish to the system Now Playing UI — Control
                // Center, the media keys, the lock screen. It cross-checks the
                // NowPlayingController wiring without a private-framework
                // reader.
                //
                // TRAP: --no-audio-hw suppresses the publish and the command
                // registration outright, so under it this always reports
                // hasInfo: 0. See NowPlayingController's header.
                NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"hasInfo"] = @(info != nil);
                if (info) {
                    out[@"title"] = info[MPMediaItemPropertyTitle] ?: NSNull.null;
                    out[@"artist"] = info[MPMediaItemPropertyArtist] ?: NSNull.null;
                    out[@"duration"] = info[MPMediaItemPropertyPlaybackDuration] ?: NSNull.null;
                    out[@"elapsed"] = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?: NSNull.null;
                    out[@"rate"] = info[MPNowPlayingInfoPropertyPlaybackRate] ?: NSNull.null;
                    out[@"hasArtwork"] = @(info[MPMediaItemPropertyArtwork] != nil);
                }
#if TARGET_OS_OSX
                // playbackState is macOS-only API; iOS derives its state from
                // the audio session and the published rate.
                out[@"playbackState"] = @(MPNowPlayingInfoCenter.defaultCenter.playbackState);
#endif
                return VibeJSONString(out);
            }),
            VibeTransportCmd(@"play_pause", ^(id<VibeDebugPlayerSurface> surface) {
                [surface debugPlayPause];
            }),
            VibeTransportCmd(@"next", ^(id<VibeDebugPlayerSurface> surface) {
                [surface debugNext];
            }),
            VibeTransportCmd(@"previous", ^(id<VibeDebugPlayerSurface> surface) {
                [surface debugPrevious];
            }),
            VibeDebugCmd(@"seek <seconds>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                           id<VibeDebugPlayerSurface> surface) {
                double seconds = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &seconds)) {
                    return VibeErrorJSON(@"usage: seek <seconds>");
                }
                [surface debugSeekToSeconds:seconds];
                return VibeJSONString(surface.debugActionSummary);
            }),
            // The cost of the dataless test itself, which is the ONLY price the
            // cloud machinery makes a local file pay — the materialize step is
            // gated behind it, so a local file never reaches one. End-to-end
            // timing cannot see it: the whole test is microseconds against a
            // TagLib parse of milliseconds, and both scale with the corpus, so
            // the ratio stays under the noise at any size. Hence a direct
            // measurement rather than a bigger folder.
            // Iterations first, path LAST: a path argument swallows every token
            // after it, so that a filename with spaces needs no quoting.
            VibeDebugCmd(@"bench_dataless <iterations> <file>", 30,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                double iterations = 0;
                if (tokens.count < 3 || !VibeParseDouble(tokens[1], &iterations) || iterations < 1) {
                    return VibeErrorJSON(@"usage: bench_dataless <iterations> <file>");
                }
                // The shared path contract (join, tilde expansion), minus the
                // iterations token it treats as the verb slot.
                NSString *path = VibePathArgument(
                        [tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]);
                if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                    return VibeErrorJSON(@"no file at '%@'", path);
                }
                NSUInteger count = MAX((NSUInteger)iterations, (NSUInteger)1);
                // A fresh NSURL per call, deliberately: the app asks about a
                // long-lived AudioTrack.url, and measuring one URL over and
                // over would measure NSURL's own resource-value memoization
                // instead of the work.
                CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
                NSUInteger dataless = 0;
                for (NSUInteger i = 0; i < count; i++) {
                    if ([NSURLUtil isDatalessFile:[NSURL fileURLWithPath:path]]) {
                        dataless++;
                    }
                }
                double elapsed = CFAbsoluteTimeGetCurrent() - started;
                return VibeJSONString(@{@"iterations": @(count),
                                        @"totalMs": @(elapsed * 1000.0),
                                        @"perCallMicroseconds": @(elapsed * 1e6 / count),
                                        @"datalessAnswers": @(dataless)});
            }),
            // How far the metadata sweep has actually got. Nothing else says:
            // dump_state describes the current track alone, and the sweep is
            // otherwise observable only as rows filling in on screen. It is
            // what turns "has the scan finished" into a number, which is what
            // any measurement of the scan's cost needs.
            //
            // parsed counts real metadata; attempted counts tracks a parse has
            // landed on at all, so a file that failed to parse — legitimate,
            // and permanent — is not mistaken for one still waiting.
            VibeDebugCmd(@"dump_metadata_progress", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                NSUInteger total = surface.debugPlaylistCount, parsed = 0, attempted = 0;
                for (NSUInteger i = 0; i < total; i++) {
                    AudioTrackMetadata *metadata = [surface debugPlaylistTrackAtIndex:i].metadata;
                    if (!metadata) {
                        continue;
                    }
                    attempted++;
                    if (metadata.parsedOK) {
                        parsed++;
                    }
                }
                return VibeJSONString(@{@"total": @(total), @"parsed": @(parsed),
                                        @"attempted": @(attempted)});
            }),
            // Occupy the main thread for a while and then, WITHOUT yielding it,
            // run another verb — one main-thread turn, not two.
            //
            // It stages one class of defect and could not be replaced by two
            // commands: a callback the app dispatched to main from a worker,
            // arriving while a user action is already underway, and therefore
            // running AFTER that action even though it was raised before it.
            // A click handler is such an action; so is a menu item. Two
            // separate channel commands cannot imitate one, because the
            // channel's own intake is on the main queue — while main is held,
            // nothing else can even be enqueued, so the callback always wins.
            //
            // Only the shared table's verbs can be run this way; the platform
            // tables are typed to their own controllers. Bounded hard, because
            // a wedged main thread is indistinguishable from a hang to every
            // oracle that watches this app.
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
                VibeDebugSurfaceHandler handler = spec[@"handler"];
                NSString *chained = handler(then, commandId, surface);
                // A nil reply means the chained verb answers asynchronously
                // through VibeWriteDebugResponse under this same commandId, so
                // returning anything here would write a second response for one
                // command. Its reply is the authoritative one; stand down.
                if (!chained) {
                    return nil;
                }
                return VibeJSONString(@{@"ok": @YES, @"blockedSeconds": @(seconds),
                                        @"then": then.firstObject,
                                        @"thenReply": chained});
            }),
            // The producer and renderer clocks in one reply. All counters are
            // cumulative. Once an activity transition and any cell/layout
            // work settle, two samples prove that an inactive state did no
            // callbacks, FFT windows or display ticks. Geometry and layer-write
            // counters additionally require stable bounds and cell population.
            //
            // `--silent` zeroes the mixer before this downstream tap and must
            // therefore never be used to judge reactive motion. In contrast,
            // `--no-audio-hw` can engage the manual renderer without zeroing
            // the signal; the three launch facts make that distinction visible.
            VibeDebugCmd(@"dump_equalizer", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                AudioPlayer *player = surface.debugPlayer;
                // Drain any queued tap install/removal before reading the
                // lock-free publication, so one reply never combines opposite
                // sides of an activity edge.
                NSDictionary *audio = [player debugEqualizerState];
                float levels[kLevelBandCount] = {0};
                uint64_t sequence = 0;
                BOOL published = [player copyBandLevels:levels
                                                  count:kLevelBandCount
                                               sequence:&sequence];
                NSMutableArray<NSNumber *> *bands =
                        [NSMutableArray arrayWithCapacity:kLevelBandCount];
                for (NSUInteger i = 0; i < kLevelBandCount; i++) {
                    [bands addObject:@(published ? levels[i] : 0)];
                }
                NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
                NSDictionary *renderer = @{
                    @"activeDisplayLinks":
                            @([EqualizerIndicatorView vibeDebugActiveDisplayLinkCount]),
                    @"displayTicks":
                            @([EqualizerIndicatorView vibeDebugTotalDisplayTickCount]),
                    @"geometryLayouts":
                            @([EqualizerIndicatorView vibeDebugTotalGeometryLayoutCount]),
                    @"transformWrites":
                            @([EqualizerIndicatorView vibeDebugTotalTransformWriteCount]),
                };
                return VibeJSONString(@{
                    // Kept at top level for existing stress/debug consumers.
                    @"levelsEnabled": @(player.levelsEnabled),
                    @"outputAudioActive": @(player.outputAudioActive),
                    @"published": @(published),
                    @"sequence": @(sequence),
                    @"bands": bands,
                    @"audio": audio,
                    @"renderer": renderer,
                    @"silent": @([arguments containsObject:@"--silent"]),
                    @"noAudioHw": @([arguments containsObject:@"--no-audio-hw"]),
                    @"manualRendering": @([player manualRenderingActive]),
                });
            }),
            VibeDebugCmd(@"set_equalizer_mode <balanced|activity|spectrum>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                if (tokens.count != 2) {
                    return VibeErrorJSON(
                            @"usage: set_equalizer_mode <balanced|activity|spectrum>");
                }
                VibeAudioLevelNormalizationMode normalizationMode;
                if ([tokens[1] isEqualToString:@"balanced"]) {
                    normalizationMode = VibeAudioLevelNormalizationModeBalancedSpectrum;
                }
                else if ([tokens[1] isEqualToString:@"activity"]) {
                    normalizationMode = VibeAudioLevelNormalizationModeRelativeActivity;
                }
                else if ([tokens[1] isEqualToString:@"spectrum"]) {
                    normalizationMode = VibeAudioLevelNormalizationModeSharedSpectrum;
                }
                else {
                    return VibeErrorJSON(
                            @"usage: set_equalizer_mode <balanced|activity|spectrum>");
                }
                AudioPlayer *player = surface.debugPlayer;
                [player debugSetEqualizerNormalizationMode:normalizationMode];
                NSDictionary<NSString *, id> *audio = [player debugEqualizerState];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"normalizationMode": audio[@"normalizationMode"],
                    @"requested": audio[@"requested"],
                    @"tapObject": audio[@"tapObject"],
                    @"installed": audio[@"installed"],
                });
            }),
            // The cloud lane's two at-rest facts, on both platforms. macOS also
            // reports them inside dump_health, which is where its stress driver
            // scores them; iOS has no dump_health and no quiesce, so without
            // this verb an iOS run cannot see a stuck hold or a stranded
            // pending parse at all — and the hold lifecycle is the same code on
            // both. Both belong at zero once a sweep has settled.
            VibeDebugCmd(@"dump_cloud_health", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                AudioTrackMetadataCache *cache = surface.debugMetadataCache;
                return VibeJSONString(@{
                    @"cloudParsesPending": @([cache debugPendingBackgroundMaterializationCount]),
                    @"cloudLaneHeld": @([cache debugBackgroundMaterializationHeld] ? 1 : 0),
                    @"priorityLane": [cache debugPriorityLaneState],
                    @"materialization":
                            [AudioFileMaterializationCoordinator.sharedCoordinator debugState],
                });
            }),
            VibeDebugCmd(@"dump_row_loading", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                // Both halves of the row-loading guarantee, so a mismatch is
                // visible: the registry's live transfers, and every playlist
                // row the registry would mark. Lane capacity bounds both.
                CloudTransferRegistry *registry = CloudTransferRegistry.sharedRegistry;
                NSDictionary<NSString *, NSNumber *> *snapshot = [registry transferSnapshot];
                NSMutableArray *transfers = [NSMutableArray arrayWithCapacity:snapshot.count];
                [snapshot enumerateKeysAndObjectsUsingBlock:^(NSString *path,
                        NSNumber *progress, BOOL *stop) {
                    [transfers addObject:@{
                        @"file": path.lastPathComponent,
                        @"progress": progress,
                    }];
                }];
                NSMutableArray *rows = [NSMutableArray array];
                NSUInteger count = surface.debugPlaylistCount;
                for (NSUInteger index = 0; index < count; index++) {
                    AudioTrack *track = [surface debugPlaylistTrackAtIndex:index];
                    if (!track.url || ![registry isTransferringURL:track.url]) {
                        continue;
                    }
                    [rows addObject:@{
                        @"index": @(index),
                        @"file": track.url.lastPathComponent ?: @"",
                        @"progress": @([registry progressForURL:track.url]),
                    }];
                }
                return VibeJSONString(@{
                    @"transfers": transfers,
                    @"loadingRows": rows,
                    @"playlistCount": @(count),
                });
            }),
            VibeDebugCmd(@"dump_audio_loading", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                AudioLoadingConfiguration *materialization =
                        AudioFileMaterializationCoordinator.sharedCoordinator.currentConfiguration;
                AudioLoadingConfiguration *player = surface.debugPlayer.loadingConfiguration;
                AudioLoadingConfiguration *metadata = surface.debugMetadataCache.loadingConfiguration;
                return VibeJSONString([AudioLoadingConfiguration
                        debugConsumerDictionaryWithMaterialization:materialization
                                                           player:player
                                                         metadata:metadata]);
            }),
            VibeDebugCmd(@"set_audio_loading <defaults | key=value ...>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: set_audio_loading <defaults | key=value ...>");
                }
                AudioLoadingConfiguration *current = AudioFileMaterializationCoordinator
                        .sharedCoordinator.currentConfiguration;
                NSError *error = nil;
                NSArray<NSString *> *arguments = [tokens subarrayWithRange:
                        NSMakeRange(1, tokens.count - 1)];
                AudioLoadingConfiguration *configuration = [AudioLoadingConfiguration
                        debugConfigurationByApplyingArguments:arguments
                        toConfiguration:current error:&error];
                if (!configuration) {
                    return VibeErrorJSON(@"%@", error.localizedDescription);
                }
                [surface.debugPlayer applyLoadingConfiguration:configuration];
                [surface.debugMetadataCache applyLoadingConfiguration:configuration];
                [AudioFileMaterializationCoordinator.sharedCoordinator
                        applyConfiguration:configuration];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"configuration": configuration.debugDictionary,
                    @"appliesTo": @"new admissions, loaders, prefetch decisions, and opens",
                });
            }),
            VibeDebugCmd(@"burst <jumps> [<seed>]", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                double jumps = 0, seed = 1;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &jumps) || jumps < 1) {
                    return VibeErrorJSON(@"usage: burst <jumps> [<seed>]");
                }
                if (tokens.count > 2 && !VibeParseDouble(tokens[2], &seed)) {
                    return VibeErrorJSON(@"seed must be a number");
                }
                NSUInteger count = MIN((NSUInteger)jumps, kMaxBurstJumps);
                // Replies at once and keeps firing: the caller's NEXT command
                // then lands mid-burst, which is more contention rather than
                // less, and the oracles' settle-and-re-check absorbs the
                // transients that come with sampling a moving app.
                VibeBurstJumps(surface, count, (uint32_t)seed);
                return VibeJSONString(@{@"ok": @YES, @"jumps": @(count),
                                        @"playlist": @(surface.debugPlaylistCount)});
            }),
            VibeDebugCmd(@"play_index <n>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                            id<VibeDebugPlayerSurface> surface) {
                double index = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &index) || index < 0) {
                    return VibeErrorJSON(@"usage: play_index <n>");
                }
                [surface debugPlayIndex:(NSUInteger)index];
                return VibeJSONString(surface.debugActionSummary);
            }),
            VibeDebugCmd(@"open <file-or-directory>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                                     id<VibeDebugPlayerSurface> surface) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: open <file-or-directory>");
                }
                NSString *path = VibePathArgument(tokens);
                if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                    return VibeErrorJSON(@"no file or directory at '%@'", path);
                }
                // Asynchronous on both platforms — a large folder walk must not
                // stall the channel — so the reply only acks the request; poll
                // dump_state for the resulting playlist. On the sandbox: an
                // arbitrary path the app has not been granted may be denied at
                // read time, the same caveat as with command-line arguments.
                [surface debugOpenPath:path];
                return VibeJSONString(@{@"ok": @YES, @"opening": path});
            }),
            // clientTimeout 20 exceeds the 15-second dispatch_group_wait
            // below: the waveform clear queues behind any in-flight waveform
            // load, and a flat 5-second client wait could give up on a clear
            // that then succeeds.
            VibeDebugCmd(@"clear_caches", 20, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                          id<VibeDebugPlayerSurface> surface) {
                // This blocks the main thread until both PINCache stores are
                // empty, which is acceptable for a debug-only command: the
                // clears are file deletes at utility QoS.
                dispatch_group_t group = dispatch_group_create();
                dispatch_group_enter(group);
                [surface.debugMetadataCache invalidateWithCompletion:^{
                    dispatch_group_leave(group);
                }];
                dispatch_group_enter(group);
                [surface.debugWaveformCache invalidateWithCompletion:^{
                    dispatch_group_leave(group);
                }];
                if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC))) {
                    return VibeErrorJSON(@"cache clear timed out after 15s");
                }
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"cleared": @[AudioTrackMetadataCache.cacheName, AudioWaveformCache.cacheName],
                });
            }),
            // 10s: it reaches the player's serial queue for the engine node count, so a
            // wedged queue must time the verb out rather than let it answer from
            // stale state.
            VibeDebugCmd(@"check_consistency", 10, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                              id<VibeDebugPlayerSurface> surface) {
                NSMutableArray<NSDictionary *> *violations = [NSMutableArray array];
                NSUInteger checked = VibeDebugCheckShared(violations, surface);
                if ([surface respondsToSelector:@selector(debugCheckPlatform:)]) {
                    checked += [surface debugCheckPlatform:violations];
                }
                return VibeJSONString(@{
                    @"ok": @(violations.count == 0),
                    @"checked": @(checked),
                    @"violations": violations,
                });
            }),
            // The stress harness's cloud simulator; see VibeFakeCloud. Seconds
            // of 0 uninstalls and puts the real dataless test and the real
            // coordinated read back. The options after percent select the
            // deterministic modes: capacity=N shares one provider pool,
            // uniform flattens the per-path speed spread, progress= picks a
            // scripted progress source, unflagged stages placeholders whose
            // probe answers NO, sticky is the fault-injection mode.
            // The open side of the fake provider. set_fake_cloud shapes stage 1
            // (which download runs, how fast, whether it fails); this holds
            // stage 2 — the uncancellable AVAudioFile call — which is the one
            // provider failure a locally-backed fake cannot stage on its own.
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
            VibeDebugCmd(@"set_fake_cloud <seconds> [<percent>] [capacity=N] [uniform] "
                         @"[progress=none|linear|sparse|stall] [unflagged] [sticky] "
                         @"[fail=<basename>]", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                double seconds = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &seconds) || seconds < 0) {
                    return VibeErrorJSON(@"usage: set_fake_cloud <seconds> [<percent>] [options]");
                }
                if (seconds == 0) {
                    [VibeFakeCloud uninstall];
                    return VibeJSONString([VibeFakeCloud statistics]);
                }
                double percent = 100;
                NSUInteger firstOption = 2;
                if (tokens.count > 2 && VibeParseDouble(tokens[2], &percent)) {
                    if (percent < 0 || percent > 100) {
                        return VibeErrorJSON(@"percent must be 0-100");
                    }
                    firstOption = 3;
                }
                else {
                    percent = 100;
                }
                static NSDictionary<NSString *, NSNumber *> *progressModes;
                static dispatch_once_t modesOnce;
                dispatch_once(&modesOnce, ^{
                    progressModes = @{@"none": @(VibeFakeCloudProgressNone),
                                      @"linear": @(VibeFakeCloudProgressLinear),
                                      @"sparse": @(VibeFakeCloudProgressSparse),
                                      @"stall": @(VibeFakeCloudProgressStall)};
                });
                // Every option is validated before the install re-arms, so a
                // rejected command leaves the previous install untouched.
                BOOL sticky = NO, uniform = NO, unflagged = NO, hasCapacity = NO;
                NSUInteger capacity = 0;
                NSNumber *progressMode = nil;
                NSString *failingBasename = nil;
                for (NSUInteger i = firstOption; i < tokens.count; i++) {
                    NSString *option = tokens[i];
                    if ([option isEqualToString:@"sticky"]) {
                        sticky = YES;
                    }
                    else if ([option isEqualToString:@"uniform"]) {
                        uniform = YES;
                    }
                    else if ([option isEqualToString:@"unflagged"]) {
                        unflagged = YES;
                    }
                    else if ([option hasPrefix:@"capacity="]) {
                        if (!VibeParseConfigurationCount(
                                [option substringFromIndex:9], &capacity)) {
                            return VibeErrorJSON(@"capacity must be a non-negative integer");
                        }
                        hasCapacity = YES;
                    }
                    else if ([option hasPrefix:@"fail="]) {
                        failingBasename = [option substringFromIndex:5];
                        if (failingBasename.length == 0) {
                            return VibeErrorJSON(@"fail= needs a basename");
                        }
                    }
                    else if ([option hasPrefix:@"progress="]) {
                        progressMode = progressModes[[option substringFromIndex:9]];
                        if (!progressMode) {
                            return VibeErrorJSON(@"progress must be none, linear, sparse, or stall");
                        }
                    }
                    else {
                        return VibeErrorJSON(@"unknown option '%@'", option);
                    }
                }
                [VibeFakeCloud installWithTransferSeconds:seconds
                                          datalessPercent:(NSUInteger)percent];
                if (sticky) {
                    [VibeFakeCloud setStickyDataless:YES];
                }
                if (uniform) {
                    [VibeFakeCloud setUniformDurations:YES];
                }
                if (unflagged) {
                    [VibeFakeCloud setUnflaggedPlaceholders:YES];
                }
                if (hasCapacity) {
                    [VibeFakeCloud setTransferCapacity:capacity];
                }
                if (progressMode) {
                    [VibeFakeCloud setProgressMode:
                            (VibeFakeCloudProgressMode)progressMode.integerValue];
                }
                if (failingBasename) {
                    [VibeFakeCloud setFailingBasename:failingBasename];
                }
                return VibeJSONString([VibeFakeCloud statistics]);
            }),
            // The fake cloud's admission trace: which transfer was requested,
            // started, completed, or cancelled, in order, with roles. This is
            // what ordering regressions assert on.
            VibeDebugCmd(@"dump_cloud_trace", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                return VibeJSONString(@{@"stats": [VibeFakeCloud statistics],
                                        @"events": [VibeFakeCloud traceEvents]});
            }),
            VibeDebugCmd(@"clear_cloud_trace", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                [VibeFakeCloud clearTrace];
                return VibeJSONString(@{@"ok": @YES});
            }),
            // The real-provider lane-routing measurement; see NSURLUtil+Debug.h.
            VibeDebugCmd(@"set_dataless_diag <on|off>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                if (tokens.count < 2 || (![tokens[1] isEqualToString:@"on"]
                        && ![tokens[1] isEqualToString:@"off"])) {
                    return VibeErrorJSON(@"usage: set_dataless_diag <on|off>");
                }
                [NSURLUtil setDatalessDiagnosticsEnabled:[tokens[1] isEqualToString:@"on"]];
                return VibeJSONString(@{@"ok": @YES});
            }),
            VibeDebugCmd(@"dump_dataless_diag", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                return VibeJSONString([NSURLUtil datalessDiagnostics]);
            }),
            // The in-process phase timings of recent waveform decodes, newest
            // first — every load, whether it came from playing a track or from
            // file_cache. This is the accurate measure of what the BPM and key
            // analyzers cost: the app's total CPU also carries the render pump,
            // the metadata scan and the UI.
            VibeDebugCmd(@"dump_timing", 5, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                        id<VibeDebugPlayerSurface> surface) {
                return VibeJSONString(@{@"loads": [AudioLoadTiming recentJSON]});
            }),
            VibeDebugCmd(@"clear_timing", 5, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                         id<VibeDebugPlayerSurface> surface) {
                [AudioLoadTiming reset];
                return VibeJSONString(@{@"ok": @YES});
            }),
            VibeDebugCmd(@"file_cache <file>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                               id<VibeDebugPlayerSurface> surface) {
                NSString *errorJSON = nil;
                NSString *path = VibeExistingFileArgument(tokens, &errorJSON);
                if (!path) {
                    return errorJSON;
                }
                // Decode and persist this file's waveform without disturbing
                // the current load, then reply with its detected BPM and key
                // once the entry is on disk. A cold decode of a long file runs
                // well past the default client wait, hence the 60-second
                // clientTimeout.
                [surface.debugWaveformCache cacheWaveformForURL:[NSURL fileURLWithPath:path]
                                                     completion:^(BOOL ok, BOOL wasCached, float bpm, NSInteger key) {
                    // The decode's own phase timings, measured in-process, or
                    // absent on a cache hit, where no decode ran.
                    NSDictionary *timing = [AudioLoadTiming newestJSONForPath:path];
                    NSMutableDictionary *body = [@{@"ok": @YES, @"path": path, @"wasCached": @(wasCached),
                                                   @"bpm": @(bpm), @"key": VibeMusicalKeyMusicalName(key),
                                                   @"camelot": VibeMusicalKeyCamelotName(key)} mutableCopy];
                    if (timing && !wasCached) {
                        body[@"timing"] = timing;
                    }
                    NSString *reply = ok ? VibeJSONString(body)
                            : VibeErrorJSON(@"waveform decode failed for '%@'", path);
                    VibeWriteDebugResponse(commandId, reply);
                }];
                return nil; // response written by the completion above
            }),
            VibeDebugCmd(@"file_clear_cache <file>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                                    id<VibeDebugPlayerSurface> surface) {
                NSString *errorJSON = nil;
                NSString *path = VibeExistingFileArgument(tokens, &errorJSON);
                if (!path) {
                    return errorJSON;
                }
                [surface.debugWaveformCache clearCachedWaveformForURL:[NSURL fileURLWithPath:path]
                                                           completion:^(BOOL wasPresent) {
                    VibeWriteDebugResponse(commandId, VibeJSONString(@{
                        @"ok": @YES, @"path": path, @"wasPresent": @(wasPresent),
                    }));
                }];
                return nil; // response written by the completion above
            }),
            // Ending the app without a signal, which is the only way to end an
            // instance Xcode is debugging: an attached debugger traps SIGTERM
            // and stops the process instead of killing it, so a pkill leaves it
            // in the process table, answering nothing. On macOS this is also
            // the only exit that runs applicationWillTerminate:, so the
            // AppStats flush happens; SIGKILL loses it. The reply is written
            // here because nothing survives to write it afterwards, and the
            // exit is deferred so the drain loop that called us finishes first.
            VibeDebugCmd(@"quit", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                 id<VibeDebugPlayerSurface> surface) {
                VibeWriteDebugResponse(commandId, VibeJSONString(@{@"ok": @YES, @"quitting": @YES}));
                dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_OSX
                    [NSApp terminate:nil];
#else
                    // UIKit has no terminate: an iOS app is not supposed to
                    // end itself, but under the simulator this is exactly what
                    // the test loop wants, and the scene delegate has no say.
                    exit(0);
#endif
                });
                return nil; // written above, before the app goes away
            }),
        ];
    });
    return table;
}

#endif
