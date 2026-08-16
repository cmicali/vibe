//
//  DebugCommonVerbs.m
//  Vibe
//
//  See DebugCommonVerbs.h.
//

#import "DebugCommonVerbs.h"

#if DEBUG

#import <MediaPlayer/MediaPlayer.h>

#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"
#import "DebugChannel.h"
#import "DebugInvariants.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformCache+Debug.h"
#import "AudioLoadTiming.h"
#import "MusicalKey.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"

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

NSMutableDictionary *VibeDebugCommonStateDictionary(id<VibeDebugPlayerSurface> surface) {
    AudioPlayer *player = surface.debugPlayer;
    AudioTrack *track = surface.debugPlaylistCurrentTrack;
    NSUInteger count = surface.debugPlaylistCount;

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
            VibeDebugCmd(@"check_invariants", 10, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                              id<VibeDebugPlayerSurface> surface) {
                NSMutableArray<NSDictionary *> *violations = [NSMutableArray array];
                NSUInteger checked = VibeDebugAppendSharedInvariants(violations, surface);
                if ([surface respondsToSelector:@selector(debugAppendPlatformInvariants:)]) {
                    checked += [surface debugAppendPlatformInvariants:violations];
                }
                return VibeJSONString(@{
                    @"ok": @(violations.count == 0),
                    @"checked": @(checked),
                    @"violations": violations,
                });
            }),
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
