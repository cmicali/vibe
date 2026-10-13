//
//  DebugAudioVerbs.m
//  Vibe
//
//  The audio path: the equalizer meter, the decoder and resampler, the
//  metadata and waveform caches and the waveform decode timings.
//

#import "DebugCommonVerbs.h"

#if DEBUG

#import "DebugCommandDispatch.h"
#import "DebugWireFormat.h"
#import "DebugChannel.h"
#import "AudioFileHandle.h"
#import "AudioLevelMath.h"
#import "AudioLoadTiming.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Debug.h"
#import "AudioTrackMetadataCache.h"
#import "AudioTrackMetadataCache+Debug.h"
#import "AudioWaveformCache.h"
#import "AudioWaveformCache+Debug.h"
#import "EqualizerIndicatorView+Debug.h"
#import "MusicalKey.h"

NSArray<NSDictionary *> *VibeDebugAudioVerbs(void) {
    static NSArray<NSDictionary *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @[
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
            // A session override of the MPEG decoder, iOS's only switch;
            // applies from the next open, so replay the row to hear it.
            VibeDebugCmd(@"set_decoder <apple|dr_mp3>", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                NSString *arg = tokens.count == 2 ? tokens[1].lowercaseString : @"";
                BOOL apple = [arg isEqualToString:@"apple"];
                if (!apple && ![arg isEqualToString:@"dr_mp3"]) {
                    return VibeErrorJSON(@"usage: set_decoder <apple|dr_mp3>");
                }
                AudioFileHandle.appleMPEGDecoder = apple;
                return VibeJSONString(@{@"ok": @YES, @"decoder": arg});
            }),
            // The resampler's decode-thread CPU since the bus was made or the
            // last reset, file reads excluded; corePercent is the real-time cost.
            VibeDebugCmd(@"dump_resampler_costs [reset]", 0,
                         ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                     id<VibeDebugPlayerSurface> surface) {
                BOOL reset = tokens.count == 2 && [tokens[1].lowercaseString isEqualToString:@"reset"];
                if (tokens.count > 2 || (tokens.count == 2 && !reset)) {
                    return VibeErrorJSON(@"usage: dump_resampler_costs [reset]");
                }
                AudioPlayer *player = surface.debugPlayer;
                return VibeJSONString(@{
                    @"costs": [player debugResamplerCostsResetting:reset] ?: @{},
                    @"conversion": player.debugCurrentConversion ?: [NSNull null],
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
                    @"meterObject": audio[@"meterObject"],
                    @"installed": audio[@"installed"],
                });
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
            // The data the renderers read, for checking a picture against
            // its source off the app. The columns default to the chunks.
            VibeDebugCmd(@"dump_waveform [columns] <file>", 60, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                                            id<VibeDebugPlayerSurface> surface) {
                // The count comes first, as file_drag_drop's point does: the
                // path is every token after it.
                double columns = 0;
                if (tokens.count > 2 && VibeParseDouble(tokens[1], &columns)) {
                    if (columns < 1) {
                        return VibeErrorJSON(@"usage: dump_waveform [columns >= 1] <file>");
                    }
                    tokens = [@[tokens[0]] arrayByAddingObjectsFromArray:[tokens subarrayWithRange:NSMakeRange(2, tokens.count - 2)]];
                }
                NSString *errorJSON = nil;
                NSString *path = VibeExistingFileArgument(tokens, &errorJSON);
                if (!path) {
                    return errorJSON;
                }
                [surface.debugWaveformCache dumpWaveformForURL:[NSURL fileURLWithPath:path]
                                                       columns:(NSUInteger)columns
                                                    completion:^(NSDictionary *dump) {
                    VibeWriteDebugResponse(commandId, dump ? VibeJSONString(dump)
                            : VibeErrorJSON(@"waveform decode failed for '%@'", path));
                }];
                return nil; // response written by the completion above
            }),
            VibeDebugCmd(@"set_waveform_decode_seconds <seconds>", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
                                                                                 id<VibeDebugPlayerSurface> surface) {
                // A progressive load on any local file, through the real
                // loader and deliveries: what a long file's decode looks like.
                double seconds = 0;
                if (tokens.count < 2 || !VibeParseDouble(tokens[1], &seconds) || seconds < 0) {
                    return VibeErrorJSON(@"usage: set_waveform_decode_seconds <seconds, 0 = full speed>");
                }
                AudioWaveformCache.debugDecodeSeconds = seconds;
                return VibeJSONString(@{@"ok": @YES, @"seconds": @(AudioWaveformCache.debugDecodeSeconds)});
            }),
            VibeDebugCmd(@"file_clear_cache <file>", 0,^NSString *(NSArray<NSString *> *tokens, NSString *commandId,
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
        ];
    });
    return table;
}

#endif
