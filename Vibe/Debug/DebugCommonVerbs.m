//
//  DebugCommonVerbs.m
//  Vibe
//

#import "DebugCommonVerbs.h"
#import "AudioFX.h"
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
#import "AppSettings.h"
#import "AppStats.h"
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
#import "VibeWorkTally.h"

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

NSString *VibeDebugPlayerStateName(AudioPlayer *player) {
    if (player.isPlaying) {
        return @"playing";
    }
    return player.isPaused ? @"paused" : @"stopped";
}

// How many filenames dump_state lists before summarising the rest.
static const NSUInteger kMaxListedFiles = 100;

// A runaway guard: one main-queue turn per jump, so even this costs under a
// second.
static const NSUInteger kMaxBurstJumps = 5000;
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

// Track changes at the rate the main queue takes them. One channel command per
// jump costs ~80ms (~2.4s under ThreadSanitizer), too slow for threads to
// collide; in-process, a jump lands every main-queue turn. Re-dispatched, not
// looped: a tight loop on main would starve the deliveries it races. The LCG
// makes a burst reproducible from its seed.
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
    run_on_main_thread({
        VibeBurstJumps(surface, remaining - 1, state);
    });
}

NSMutableDictionary *VibeDebugCommonStateDictionary(id<VibeDebugPlayerSurface> surface) {
    AudioPlayer *player = surface.debugPlayer;
    AudioTrack *track = surface.debugPlaylistCurrentTrack;
    NSUInteger count = surface.debugPlaylistCount;

    // Rows whose metadata has landed, over the whole playlist (`files` is
    // capped). Nil metadata is a row the scan has not reached, not a file
    // lacking tags.
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
            @"crossfadeMilliseconds": @(player.crossfadeMilliseconds),
            @"declick": @(player.declick),
            @"silent": @([arguments containsObject:@"--silent"]),
            @"noAudioHw": @([arguments containsObject:@"--no-audio-hw"]),
        } mutableCopy],
        @"currentTrack": track ? [@{
            @"url": track.url.path ?: @"",
            @"title": track.title ?: @"",
            @"artist": track.artist ?: @"",
            // Resolved, tag over analysis; empty key strings and BPM 0 when
            // unknown.
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
        // Intent only, which no queue owns: a dump must answer while the
        // player queue is held. What the hosting says is dump_audio_path's.
        @"fx": player.fx.intentSnapshot,
    } mutableCopy];
}

NSArray<NSDictionary *> *VibeDebugCommonCommandTable(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
            VibeDebugCmd(@"work_tally <begin|end>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                                  id<VibeDebugPlayerSurface> surface) {
                if (tokens.count == 2 && [tokens[1] isEqualToString:@"begin"]) {
                    VibeWorkTallyBeginWindow("debug");
                    return VibeJSONString(@{@"ok": @YES});
                }
                if (tokens.count == 2 && [tokens[1] isEqualToString:@"end"]) {
                    return VibeJSONString(VibeWorkTallyTakeWindow());
                }
                return VibeErrorJSON(@"usage: work_tally <begin|end>");
            }),
            VibeDebugCmd(@"dump_state", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                       id<VibeDebugPlayerSurface> surface) {
                return VibeJSONString(surface.debugStateDictionary);
            }),
            VibeDebugCmd(@"dump_stats", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                       id<VibeDebugPlayerSurface> surface) {
                AppStats *stats = [AppStats sharedInstance];
                return VibeJSONString(@{
                    @"filesOpened": @(stats.totalFilesOpened),
                    @"foldersOpened": @(stats.totalFoldersOpened),
                    @"secondsPlayed": @(stats.totalSecondsPlayed),
                });
            }),
            VibeDebugCmd(@"dump_now_playing", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                             id<VibeDebugPlayerSurface> surface) {
                // TRAP: --no-audio-hw and --no-now-playing suppress the
                // publish and the command registration outright, so under
                // either this always reports hasInfo: 0 (NowPlayingController.h).
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
            // How far the metadata sweep has got. attempted counts every row a
            // parse has landed on, so a file that failed to parse is not
            // mistaken for one still waiting.
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
            // The producer and renderer counters, all cumulative: once a
            // transition settles, two samples prove an inactive state did no
            // callbacks, FFT windows or display ticks (geometry and layer-write
            // counters also need stable bounds and cells). `--silent` zeroes
            // after the meter, so the bars are live under it; the launch facts
            // say whether the output unit or the pump produced the counters.
            VibeDebugCmd(@"dump_equalizer", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                AudioPlayer *player = surface.debugPlayer;
                // First, so a queued meter install or removal has drained and
                // one reply never spans both sides of an activity edge.
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
                    // Top-level keys the stress tooling reads.
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
            // One entry per stage, source file to device: Settings > Advanced's
            // Audio group, raw.
            VibeDebugCmd(@"dump_audio_path", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                return VibeJSONString(@{@"stages": surface.debugPlayer.audioPathSnapshot});
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
                    @"meterObject": audio[@"meterObject"],
                    @"installed": audio[@"installed"],
                });
            }),
            // The cloud lane's at-rest facts, both zero once a sweep settles.
            // macOS also reports them in dump_health; this is iOS's only view.
            VibeDebugCmd(@"dump_cloud_health", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                AudioTrackMetadataCache *cache = surface.debugMetadataCache;
                return VibeJSONString(@{
                    @"cloudParsesPending": @([cache debugPendingBackgroundMaterializationCount]),
                    @"cloudLaneHeld": @([cache debugBackgroundMaterializationHeld] ? 1 : 0),
                    @"priorityLane": [cache debugPriorityLaneState],
                    @"scanLane": [cache debugScanLaneState],
                    @"materialization":
                            [AudioFileMaterializationCoordinator.sharedCoordinator debugState],
                });
            }),
            VibeDebugCmd(@"dump_row_loading", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                // Both halves of the row-loading guarantee, so a mismatch
                // shows: the registry's transfers and the rows it would mark.
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
                // Replies at once and keeps firing, so the caller's next
                // command lands mid-burst; the oracles' re-check absorbs the
                // transients.
                VibeBurstJumps(surface, count, (uint32_t)seed);
                return VibeJSONString(@{@"ok": @YES, @"jumps": @(count),
                                        @"playlist": @(surface.debugPlaylistCount)});
            }),
            VibeDebugCmd(@"set_pause_at_track_end <on|off>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                NSString *arg = tokens.count > 1 ? tokens[1].lowercaseString : @"";
                if (![arg isEqualToString:@"on"] && ![arg isEqualToString:@"off"]) {
                    return VibeErrorJSON(@"usage: set_pause_at_track_end <on|off>");
                }
                AppSettings.sharedInstance.pauseAtTrackEnd = [arg isEqualToString:@"on"];
                [surface debugApplyEndOfTrackSetting];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"pauseAtTrackEnd": @(AppSettings.sharedInstance.pauseAtTrackEnd),
                });
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
                // Asynchronous, so the reply only acks; poll dump_state. A path
                // the sandbox has not granted may be denied at read time.
                [surface debugOpenPath:path];
                return VibeJSONString(@{@"ok": @YES, @"opening": path});
            }),
            VibeDebugCmd(@"append <file-or-directory>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                                       id<VibeDebugPlayerSurface> surface) {
                if (tokens.count < 2) {
                    return VibeErrorJSON(@"usage: append <file-or-directory>");
                }
                NSString *path = VibePathArgument(tokens);
                if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
                    return VibeErrorJSON(@"no file or directory at '%@'", path);
                }
                [surface debugAppendPath:path];
                return VibeJSONString(@{@"ok": @YES, @"appending": path});
            }),
            // clientTimeout 20 exceeds the 15s wait below: the waveform clear
            // queues behind any in-flight load, and the default 5s client wait
            // could give up on a clear that then succeeds.
            VibeDebugCmd(@"clear_caches", 20, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                          id<VibeDebugPlayerSurface> surface) {
                // Blocks main until both stores are empty; the clears are file
                // deletes.
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
            // 10s: it syncs on the player queue, so a wedged queue times the
            // verb out rather than answering from stale state.
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
            // See VibeFakeCloud.h for the modes. Seconds of 0 uninstalls.
            VibeDebugCmd(@"set_fake_cloud <seconds> [<percent>] [capacity=N] [uniform] "
                         @"[progress=none|linear|sparse|stall] [sticky] "
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
                // Validated before the install re-arms, so a rejected command
                // leaves the previous install untouched.
                BOOL sticky = NO, uniform = NO, hasCapacity = NO;
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
                    else if ([option hasPrefix:@"capacity="]) {
                        if (!VibeParseNonnegativeInteger(
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
            // See NSURLUtil+Debug.h.
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
            // Every recent waveform decode, playback's or file_cache's. See
            // AudioLoadTiming.h.
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
                // A cold decode of a long file runs well past the default
                // client wait, hence the 60s clientTimeout.
                [surface.debugWaveformCache cacheWaveformForURL:[NSURL fileURLWithPath:path]
                                                     completion:^(BOOL ok, BOOL wasCached, float bpm, NSInteger key) {
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
            // Ends the app without a signal, the only way to end one Xcode is
            // debugging (the debugger traps SIGTERM), and on macOS the only
            // exit that runs applicationWillTerminate:'s AppStats flush. The
            // reply is written first because nothing survives to write it; the
            // exit is deferred so the calling drain finishes.
            VibeDebugCmd(@"quit", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                 id<VibeDebugPlayerSurface> surface) {
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
        ];
    });
    return table;
}

#endif
