//
//  DebugCommonVerbs.m
//  Vibe
//
//  The state and transport verbs, and the shared table, which adds each
//  topic's verbs after them.
//

#import "DebugCommonVerbs.h"
#import "AudioFX.h"

#if DEBUG

#import <MediaPlayer/MediaPlayer.h>

#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"
#import "DebugChannel.h"
#import "DebugConsistency.h"
#import "AppSettings.h"
#import "SettingsRules.h"
#import "AppStats.h"
#import "NSBundle+BuildInfo.h"
#import "MusicalKey.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Debug.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
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

static const NSUInteger kMaxBurstJumps = 5000;

// Re-dispatch each jump so main-queue deliveries can race the burst.
// The LCG makes the row sequence reproducible from its seed.
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
            @"buffering": @(player.isBuffering),
            @"bufferingRecord": player.debugBufferingRecord,
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
        NSArray<NSDictionary *> *own = @[
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
            // Which build answered: two instances race for the channel, and a
            // stale one replies like a fresh one.
            VibeDebugCmd(@"dump_build", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                       id<VibeDebugPlayerSurface> surface) {
                NSBundle *bundle = NSBundle.mainBundle;
                return VibeJSONString(@{
                    @"version": bundle.vibeVersionString,
                    @"git": bundle.vibeGitString,
                    @"built": bundle.vibeBuildTimeString,
                    @"pid": @(NSProcessInfo.processInfo.processIdentifier),
                    @"path": bundle.bundlePath,
                });
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
                BOOL on = NO;
                if (!VibeParseOnOff(tokens, &on)) {
                    return VibeErrorJSON(@"usage: set_pause_at_track_end <on|off>");
                }
                AppSettings.sharedInstance.pauseAtTrackEnd = on;
                [surface debugApplyEndOfTrackSetting];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"pauseAtTrackEnd": @(AppSettings.sharedInstance.pauseAtTrackEnd),
                });
            }),
            VibeDebugCmd(@"set_repeat <off|all|one>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                NSString *arg = tokens.count > 1 ? tokens[1].lowercaseString : @"";
                VibeRepeatMode mode = VibeNormalizedRepeatMode(arg);
                if (![VibeRepeatModeIdentifier(mode) isEqualToString:arg]) {
                    return VibeErrorJSON(@"usage: set_repeat <off|all|one>");
                }
                AppSettings.sharedInstance.repeatMode = mode;
                [surface debugApplyEndOfTrackSetting];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"repeatMode": VibeRepeatModeIdentifier(AppSettings.sharedInstance.repeatMode),
                });
            }),
            VibeDebugCmd(@"set_shuffle <on|off>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                BOOL on = NO;
                if (!VibeParseOnOff(tokens, &on)) {
                    return VibeErrorJSON(@"usage: set_shuffle <on|off>");
                }
                AppSettings.sharedInstance.shuffleEnabled = on;
                [surface debugApplyEndOfTrackSetting];
                return VibeJSONString(@{
                    @"ok": @YES,
                    @"shuffleEnabled": @(AppSettings.sharedInstance.shuffleEnabled),
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
        table = [[[own arrayByAddingObjectsFromArray:VibeDebugStallVerbs()]
                arrayByAddingObjectsFromArray:VibeDebugAudioVerbs()]
                arrayByAddingObjectsFromArray:VibeDebugLoadingVerbs()];
    });
    return table;
}

#endif
