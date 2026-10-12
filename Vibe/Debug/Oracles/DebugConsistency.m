//
//  DebugConsistency.m
//  Vibe
//

#import "DebugConsistency.h"
#import "AudioFileMaterializationCoordinator+Debug.h"
#import "AudioFileMaterializationCoordinatorInternal.h"

#if DEBUG

#import <MediaPlayer/MediaPlayer.h>

#import "AudioPlayer.h"
#import "AudioPlayer+Debug.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache+Debug.h"
#import "EqualizerIndicatorView+Debug.h"
#import "MusicalKey.h"
#import "AppSettings.h"
#if TARGET_OS_OSX
#import "AppSettings+Mac.h"
#endif
#import "VibeFakeCloud.h"

void VibeDebugViolation(NSMutableArray<NSDictionary *> *violations, NSString *identifier,
                        NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *detail = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [violations addObject:@{@"id": identifier, @"detail": detail}];
}

// Headroom over the FX chain's ten lazily hosted units. Compare settled
// counts after warming the effects to detect smaller leaks.
static const NSUInteger kVibeMaxReasonableHostedUnits = 16;

// Playback-position threshold for the metadata progress oracle.
static const NSTimeInterval kVibeMetadataDeadlineSeconds = 5.0;

static BOOL VibeIsFiniteNonNegative(double value) {
    return isfinite(value) && value >= 0;
}

NSUInteger VibeDebugCheckShared(NSMutableArray<NSDictionary *> *v,
                                id<VibeDebugPlayerSurface> surface) {
    NSUInteger checked = 0;

    AudioPlayer *player = surface.debugPlayer;
    AudioTrack *current = surface.debugPlaylistCurrentTrack;
    AudioTrack *displayed = surface.debugDisplayedTrack;
    NSUInteger count = surface.debugPlaylistCount;
    NSUInteger index = surface.debugPlaylistCurrentIndex;
    BOOL isLoading = surface.debugIsLoading;

    checked++;
    if (count == 0) {
        if (index != 0) {
            VibeDebugViolation(v, @"playlist.index_in_range",
                    @"empty playlist but currentIndex is %lu", (unsigned long)index);
        }
    }
    else if (index >= count) {
        VibeDebugViolation(v, @"playlist.index_in_range",
                @"currentIndex %lu with %lu tracks", (unsigned long)index, (unsigned long)count);
    }

    checked++;
    AudioTrack *atIndex = [surface debugPlaylistTrackAtIndex:index];
    if (current != atIndex) {
        VibeDebugViolation(v, @"playlist.current_track_matches_index",
                @"currentTrack %@ but track at index %lu is %@",
                current.url.lastPathComponent ?: @"(nil)", (unsigned long)index,
                atIndex.url.lastPathComponent ?: @"(nil)");
    }

    checked++;
    if (!VibeIsFiniteNonNegative(player.duration)) {
        VibeDebugViolation(v, @"player.duration_finite", @"duration is %f", player.duration);
    }

    checked++;
    if (!VibeIsFiniteNonNegative(player.position)) {
        VibeDebugViolation(v, @"player.position_finite", @"position is %f", player.position);
    }

    // Compare only outside Loading. A pending seek can still report the old position.
    checked++;
    if (displayed && !isLoading && player.duration > 0
            && player.position > player.duration + 0.5) {
        VibeDebugViolation(v, @"player.position_within_duration",
                @"position %.3f past duration %.3f", player.position, player.duration);
    }

    checked++;
    if (fabsf(player.pitch) > player.maxPitch + 0.001f) {
        VibeDebugViolation(v, @"player.pitch_clamped",
                @"pitch %.4f outside ±%.4f", player.pitch, player.maxPitch);
    }

#if TARGET_OS_OSX
    // The pitch fader and its range setting are macOS-only; iOS never leaves
    // the default, so there is no setting to agree with.
    checked++;
    if (fabsf(player.maxPitch - AppSettings.sharedInstance.pitchRange) > 0.001f) {
        VibeDebugViolation(v, @"player.max_pitch_matches_setting",
                @"player maxPitch %.4f, setting %ld", player.maxPitch, (long)AppSettings.sharedInstance.pitchRange);
    }
#endif

    NSDictionary<NSString *, NSNumber *> *engine = [player debugRenderCounts];
    checked++;
    NSUInteger units = engine[@"hostedUnits"].unsignedIntegerValue;
    if (units > kVibeMaxReasonableHostedUnits) {
        VibeDebugViolation(v, @"graph.hosted_units_bounded",
                @"%lu units hosted by the pipeline", (unsigned long)units);
    }

    // The pipeline admits one render at a time; a refusal means a render found a
    // stuck one inside, which never happens in a healthy run.
    checked++;
    NSUInteger refusals = engine[@"renderRefusals"].unsignedIntegerValue;
    if (refusals > 0) {
        VibeDebugViolation(v, @"graph.no_render_refused",
                @"%lu renders refused by the pipeline", (unsigned long)refusals);
    }

    // debugRenderCounts drains the player queue, not callbacks waiting on main,
    // so a gapless promotion can be one valid transient ahead of the playlist;
    // the re-check clears it. Loading has cleared currentTrack.
    checked++;
    AudioTrack *playerTrack = player.currentTrack;
    if (playerTrack && playerTrack != current) {
        VibeDebugViolation(v, @"player.current_track_matches_playlist",
                @"player has %@ (%p), playlist has %@ (%p)",
                playerTrack.url.lastPathComponent ?: @"(nil)",
                (__bridge void *)playerTrack,
                current.url.lastPathComponent ?: @"(nil)",
                (__bridge void *)current);
    }

    NSDictionary *equalizer = [player debugEqualizerState];
    NSUInteger activeLinks =
            (NSUInteger)[EqualizerIndicatorView vibeDebugActiveDisplayLinkCount];
    BOOL queueRequested = [equalizer[@"requested"] boolValue];
    BOOL meterObject = [equalizer[@"meterObject"] boolValue];
    BOOL meterInstalled = [equalizer[@"installed"] boolValue];
    BOOL signalProbe = [equalizer[@"signalProbe"] boolValue];

    checked++;
    if (activeLinks > 1) {
        VibeDebugViolation(v, @"equalizer.single_visible_renderer",
                @"%lu equalizer display links are active", (unsigned long)activeLinks);
    }

    checked++;
    if ((activeLinks > 0) != player.levelsEnabled
            || queueRequested != player.levelsEnabled) {
        VibeDebugViolation(v, @"equalizer.demand_balanced",
                @"links=%lu, main request=%d, queue request=%d",
                (unsigned long)activeLinks, player.levelsEnabled, queueRequested);
    }

    checked++;
    // Beta builds also hold the meter for each start's signal capture. The meter
    // object is kept across demand; its installation is what follows it.
    if (meterInstalled && !queueRequested && !signalProbe) {
        VibeDebugViolation(v, @"equalizer.meter_follows_demand",
                @"installed=%d, meter object=%d, requested=%d, signal probe=%d",
                meterInstalled, meterObject, queueRequested, signalProbe);
    }

    checked++;
    // A beta capture may finish after transport pauses; pixels never keep polling.
    if ((activeLinks > 0 || (meterInstalled && !signalProbe)) && !player.outputAudioActive) {
        VibeDebugViolation(v, @"equalizer.requires_audio_output",
                @"links=%lu and installed=%d while output is inactive",
                (unsigned long)activeLinks, meterInstalled);
    }

    // Nil metadata means no parse result has arrived. A failed parse can
    // legitimately leave parsedOK NO. Streams can still be downloading here.
    checked++;
    if (current && player.isPlaying && !surface.debugIsLoading
            && player.position > kVibeMetadataDeadlineSeconds && !current.metadata) {
        VibeDebugViolation(v, @"track.metadata_arrives_for_playing_track",
                @"%@ has played %.1fs with no metadata parse attempted",
                current.url.lastPathComponent, player.position);
    }

    if (current) {
        // One snapshot: AudioTrack's accessors re-read the atomic metadata, and
        // a delivery between two reads would disagree without a real fault.
        AudioTrackMetadata *metadata = current.rowTagMetadata;

        checked++;
        float taggedBPM = metadata.bpm;
        float expectedBPM = taggedBPM > 0 ? taggedBPM : current.detectedBPM;
        if (fabsf(current.bpm - expectedBPM) > 0.001f) {
            VibeDebugViolation(v, @"track.bpm_precedence",
                    @"bpm %.3f, tagged %.3f, detected %.3f",
                    current.bpm, taggedBPM, current.detectedBPM);
        }

        checked++;
        VibeMusicalKey taggedKey = metadata ? metadata.key : VibeMusicalKeyNone;
        VibeMusicalKey expectedKey = taggedKey >= 0 ? taggedKey : current.detectedKey;
        if (current.key != expectedKey) {
            VibeDebugViolation(v, @"track.key_precedence",
                    @"key %ld, tagged %ld, detected %ld",
                    (long)current.key, (long)taggedKey, (long)current.detectedKey);
        }

        // This range check cannot distinguish zero-filled state from C major.
        checked++;
        if (!VibeMusicalKeyIsValid(current.key) && current.key != VibeMusicalKeyNone) {
            VibeDebugViolation(v, @"track.key_in_range", @"resolved key is %ld", (long)current.key);
        }
        checked++;
        if (!VibeMusicalKeyIsValid(current.detectedKey) && current.detectedKey != VibeMusicalKeyNone) {
            VibeDebugViolation(v, @"track.detected_key_in_range",
                    @"detectedKey is %ld", (long)current.detectedKey);
        }
    }

    // The hold is derived from the coordinator's foreground claims, so with the
    // player stopped and nothing loading it must read NO; otherwise a claim was
    // never settled and the sweep is suspended for good. The player's state
    // settles on its queue, so a mid-transition sample can disagree until the
    // re-check.
    checked++;
    if ([surface.debugMetadataCache debugBackgroundMaterializationHeld]
            && player.isStopped && !isLoading) {
        VibeDebugViolation(v, @"cloud.hold_outlives_playback",
                @"cloud lane held with the player stopped and no open in flight");
    }

    // Outstanding opens retain admission capacity. Re-check after settling:
    // a superseded open may still be returning from the OS.
    checked++;
    uint64_t strandedOpens =
            [AudioFileMaterializationCoordinator.sharedCoordinator handleOpensInFlight];
    if (strandedOpens > 0 && player.isStopped && !isLoading) {
        VibeDebugViolation(v, @"cloud.handle_open_stranded",
                @"%llu AudioFileHandle open(s) still outstanding with the player "
                @"stopped — that much admission capacity is gone for good",
                strandedOpens);
    }

    // What only the fake provider can see; silent in every other counter.
    // Cumulative per install, so one occurrence keeps failing until the next
    // re-arm rather than being filtered by the re-check: none is ever
    // transiently true.
    NSDictionary *fake = [VibeFakeCloud statistics];
    if ([fake[@"installed"] boolValue]) {
        NSUInteger capacity = [fake[@"capacity"] unsignedIntegerValue];
        checked++;
        if (capacity > 0 && [fake[@"maxConcurrency"] unsignedIntegerValue] > capacity) {
            VibeDebugViolation(v, @"cloud.concurrency_within_capacity",
                    @"%@ transfers ran at once against a capacity of %lu",
                    fake[@"maxConcurrency"], (unsigned long)capacity);
        }

        checked++;
        if ([fake[@"metadataOverlapTransfers"] unsignedIntegerValue] > 0) {
            VibeDebugViolation(v, @"cloud.metadata_lane_stands_aside",
                    @"a second transfer began for a file already in transfer %@ time(s)",
                    fake[@"metadataOverlapTransfers"]);
        }

        // The hold's job as a number: a background download that began while
        // the user's own ran means the lane was open when it should have been
        // closed.
        checked++;
        if ([fake[@"foregroundContentionStarts"] unsignedIntegerValue] > 0) {
            VibeDebugViolation(v, @"cloud.foreground_outranks_background",
                    @"a metadata download began during foreground provider work %@ time(s)",
                    fake[@"foregroundContentionStarts"]);
        }
    }

    // System Now Playing against its source. Gated on nowPlayingInfo, which a
    // --no-audio-hw launch leaves nil. Elapsed is not compared: the system
    // extrapolates it. The publish rides the UI funnel, so a transition
    // republishes a tick later (the header's re-check caveat).
    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    NSDictionary *published = center.nowPlayingInfo;

    checked++;
    if (published && !displayed) {
        VibeDebugViolation(v, @"nowplaying.cleared_without_track",
                @"no displayed track but the system card still shows \"%@\"",
                published[MPMediaItemPropertyTitle] ?: @"");
    }

    if (published && displayed) {
        // As NowPlayingController publishes them: a nil displayArtist publishes
        // no artist key.
        checked++;
        NSString *publishedTitle = published[MPMediaItemPropertyTitle] ?: @"";
        NSString *expected = displayed.displayTitle ?: @"";
        if (![publishedTitle isEqualToString:expected]) {
            VibeDebugViolation(v, @"nowplaying.title_matches_track",
                    @"card shows \"%@\", track is \"%@\"", publishedTitle, expected);
        }

        checked++;
        NSString *publishedArtist = published[MPMediaItemPropertyArtist] ?: @"";
        NSString *expectedArtist = displayed.displayArtist ?: @"";
        if (![publishedArtist isEqualToString:expectedArtist]) {
            VibeDebugViolation(v, @"nowplaying.artist_matches_track",
                    @"card shows \"%@\", track is \"%@\"", publishedArtist, expectedArtist);
        }

#if TARGET_OS_OSX
        // macOS-only API. isPaused before isPlaying, the publish's order: during
        // Loading the pending start intent decides both.
        checked++;
        MPNowPlayingPlaybackState expectedState =
                player.isPaused ? MPNowPlayingPlaybackStatePaused
                : player.isPlaying ? MPNowPlayingPlaybackStatePlaying
                : MPNowPlayingPlaybackStateStopped;
        if (center.playbackState != expectedState) {
            VibeDebugViolation(v, @"nowplaying.state_matches_player",
                    @"card is %ld, player is %ld",
                    (long)center.playbackState, (long)expectedState);
        }
#endif

        // Wall-clock, like the app's labels, so a pitch change that never
        // republished shows up here.
        checked++;
        NSNumber *publishedDuration = published[MPMediaItemPropertyPlaybackDuration];
        double rate = surface.debugPlaybackRate;
        double expectedDuration = isLoading ? displayed.duration : player.duration;
        if (rate > 0) {
            expectedDuration /= rate;
        }
        if (publishedDuration && expectedDuration > 0
                && fabs(publishedDuration.doubleValue - expectedDuration) > 1.0) {
            VibeDebugViolation(v, @"nowplaying.duration_matches_track",
                    @"card says %.3f, track is %.3f at rate %.4f",
                    publishedDuration.doubleValue, expectedDuration, rate);
        }
    }

    return checked;
}

#endif
