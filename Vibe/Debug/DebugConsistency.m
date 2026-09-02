//
//  DebugConsistency.m
//  Vibe
//
//  See DebugConsistency.h.
//

#import "DebugConsistency.h"
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

// A generous ceiling, not a tight one. The engine carries the output and main
// mixer, the FX chain, and a player node plus varispeed per live track, which
// measures 25 at rest and does not move across a burst of track changes, so
// this is roughly 5x headroom. A leak is unbounded and blows past it either
// way; the sensitive detector is the stress driver diffing the same number
// against its own baseline.
static const NSUInteger kVibeMaxReasonableEngineNodes = 128;

// How long a track may render before its metadata not having been attempted
// counts as a fault rather than a race. Generous on purpose: the parse itself
// is milliseconds on a local file, and the only thing this needs to clear is
// the window between the open landing and the priority lane's op running.
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

    // ---- Playlist ----

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

    // ---- Player ----

    checked++;
    if (!VibeIsFiniteNonNegative(player.duration)) {
        VibeDebugViolation(v, @"player.duration_finite", @"duration is %f", player.duration);
    }

    checked++;
    if (!VibeIsFiniteNonNegative(player.position)) {
        VibeDebugViolation(v, @"player.position_finite", @"position is %f", player.position);
    }

    // Only in the settled track state: Loading reads both as 0 by contract,
    // and a seek in flight can momentarily report the old playhead.
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

    checked++;
    NSUInteger nodes = [player debugEngineCounts][@"attachedNodes"].unsignedIntegerValue;
    if (nodes > kVibeMaxReasonableEngineNodes) {
        VibeDebugViolation(v, @"engine.node_count_bounded",
                @"%lu nodes attached to the engine", (unsigned long)nodes);
    }

    // The barrier above drains the player queue, not callbacks waiting on main:
    // a gapless promotion can still be one valid transient ahead of the
    // playlist. Re-checking after settlement clears it; any persistent non-nil
    // mismatch is bad state. A real Loading state has cleared currentTrack.
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

    // ---- Equalizer producer and renderer ----

    NSDictionary *equalizer = [player debugEqualizerState];
    NSUInteger activeLinks =
            (NSUInteger)[EqualizerIndicatorView vibeDebugActiveDisplayLinkCount];
    BOOL queueRequested = [equalizer[@"requested"] boolValue];
    BOOL tapObject = [equalizer[@"tapObject"] boolValue];
    BOOL tapInstalled = [equalizer[@"installed"] boolValue];

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
    if (tapInstalled != tapObject || (tapInstalled && !queueRequested)) {
        VibeDebugViolation(v, @"equalizer.tap_follows_demand",
                @"installed=%d, tap object=%d, requested=%d",
                tapInstalled, tapObject, queueRequested);
    }

    checked++;
    if ((activeLinks > 0 || tapInstalled) && !player.outputAudioActive) {
        VibeDebugViolation(v, @"equalizer.requires_audio_output",
                @"links=%lu and installed=%d while output is inactive",
                (unsigned long)activeLinks, tapInstalled);
    }

    // ---- Track: the now-playing track's metadata actually arrives ----

    // The whole point of the current-track lane is that the playing track's
    // tags and art never wait behind the playlist sweep. Nothing observed
    // whether they arrived, and the one time that lane silently stopped
    // working — a stale NSURL resource value freezing the dataless test, so
    // every retry skipped the parse — the symptom was art appearing half a
    // minute late, from the background sweep, and no check anywhere noticed.
    //
    // Nil metadata is the signal, and it means "no parse was ever attempted":
    // a parse that ran and FAILED leaves a non-nil object with parsedOK NO,
    // which is legitimate and stays legitimate. Audio rendering past the
    // deadline means the file opened, so it is local, so the priority lane's
    // parse is milliseconds of work it has had seconds to do. The rare
    // in-flight window is what the caller's settle-and-re-check filters.
    checked++;
    if (current && player.isPlaying && !surface.debugIsLoading
            && player.position > kVibeMetadataDeadlineSeconds && !current.metadata) {
        VibeDebugViolation(v, @"track.metadata_arrives_for_playing_track",
                @"%@ has played %.1fs with no metadata parse attempted",
                current.url.lastPathComponent, player.position);
    }

    // ---- Track: tag-over-analysis precedence ----

    if (current) {
        // One snapshot of the atomic metadata, because AudioTrack's own
        // accessors re-read it; a delivery landing between the two reads is a
        // real (and rare) source of a disagreement that the caller's re-check
        // will not reproduce.
        AudioTrackMetadata *metadata = current.metadata;

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

        // Guards the zero-fill trap from the other side: a key that is neither
        // a valid 0-23 nor exactly VibeMusicalKeyNone is uninitialized memory
        // or a bad parse, and 0 reads as tagged C major wherever it came from.
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

    // ---- The cloud lane ----
    //
    // The foreground hold is asserted at play submission and released by
    // exactly one settlement — the successor prefetch's claim acknowledgement,
    // the error path, or Close. Every one of those edges either has a pending
    // open behind it or ends playback, so a hold that outlives a stopped,
    // not-loading player is an edge that was lost. That is the only symptom a
    // lost release produces until the sweep visibly never runs, and it is
    // invisible to every other check here.
    //
    // The state settles on the player queue while the hold is taken
    // synchronously on main, so a sample taken between the two reads as a
    // violation. The caller's settle-and-re-check is what filters that, the
    // same way it filters an in-flight metadata parse above.
    checked++;
    if ([surface.debugMetadataCache debugBackgroundMaterializationHeld]
            && player.isStopped && !isLoading) {
        VibeDebugViolation(v, @"cloud.hold_outlives_playback",
                @"cloud lane held with the player stopped and no open in flight");
    }

    // The generalisation of the check above, and the reason it is here rather
    // than in the one scenario that stages it: the comment above says a lost
    // release is invisible "until the sweep visibly never runs", and a stranded
    // handle open is a second, unrelated cause of exactly that. It holds
    // admission capacity that is never given back — an AVAudioFile call cannot
    // be cancelled — so with the player stopped and nothing loading, a nonzero
    // count is not work in flight but work that will never finish.
    //
    // Same settle-and-re-check caveat: an open that was superseded moments ago
    // is still returning, and that is not a strand.
    checked++;
    uint64_t strandedOpens =
            [AudioFileMaterializationCoordinator.sharedCoordinator handleOpensInFlight];
    if (strandedOpens > 0 && player.isStopped && !isLoading) {
        VibeDebugViolation(v, @"cloud.handle_open_stranded",
                @"%llu AVAudioFile open(s) still outstanding with the player "
                @"stopped — that much admission capacity is gone for good",
                strandedOpens);
    }

    // What the fake provider can see and nothing else can, checked only while
    // it is installed. All three are silent in every other counter: a run whose
    // transfers all completed looks identical whether or not more of them ran
    // at once than the provider had slots, the metadata lane downloaded a file
    // another role was already downloading, or it began a download inside the
    // user's own.
    //
    // The counters are cumulative for the life of the install, so one
    // occurrence keeps failing until the next re-arm rather than being filtered
    // away by the caller's re-check. Deliberate: unlike the churn that re-check
    // exists to absorb, none of these is ever transiently true. Each re-arm
    // resets them, which is what keeps a churn run scoring the current install
    // rather than the whole session.
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
                    @"the metadata lane downloaded a file already in transfer %@ time(s)",
                    fake[@"metadataOverlapTransfers"]);
        }

        // The hold's whole job, as a number. A background download that BEGAN
        // while the user's own was still running says the lane was open when
        // it should have been closed, whichever release edge lost it — which
        // is why this is checked here rather than only in the scenario that
        // stages one particular way of losing it.
        checked++;
        if ([fake[@"foregroundContentionStarts"] unsignedIntegerValue] > 0) {
            VibeDebugViolation(v, @"cloud.foreground_outranks_background",
                    @"a metadata download began during foreground provider work %@ time(s)",
                    fake[@"foregroundContentionStarts"]);
        }
    }

    // ---- System Now Playing against what it was published from ----
    //
    // Every check is gated on nowPlayingInfo being non-nil, which is also what
    // --no-audio-hw's suppressed publish leaves it as, so a suppressed launch
    // simply checks nothing here. Elapsed is deliberately not compared: the
    // system extrapolates it from the last publish, so it is expected to run
    // ahead of the published value. These share the render-lag caveat in the
    // header — the publish rides the UI funnel, so a transition republishes a
    // tick later.
    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    NSDictionary *published = center.nowPlayingInfo;

    checked++;
    if (published && !displayed) {
        VibeDebugViolation(v, @"nowplaying.cleared_without_track",
                @"no displayed track but the system card still shows \"%@\"",
                published[MPMediaItemPropertyTitle] ?: @"");
    }

    if (published && displayed) {
        // Derived exactly as NowPlayingController publishes them: displayTitle
        // and displayArtist, where a nil displayArtist publishes no artist key.
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
        // playbackState is macOS-only API. isPaused before isPlaying, the
        // order the publish resolves them in: during Loading the two are
        // decided by the pending start intent.
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

        // Wall-clock, like the app's own labels: the published duration is the
        // file duration divided by the varispeed rate, so a pitch change that
        // never republished shows up here.
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
