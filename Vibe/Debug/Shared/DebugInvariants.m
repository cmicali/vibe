//
//  DebugInvariants.m
//  Vibe
//
//  See DebugInvariants.h.
//

#import "DebugInvariants.h"

#if DEBUG

#import <MediaPlayer/MediaPlayer.h>

#import "AudioPlayer.h"
#import "AudioPlayer+Debug.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "MusicalKey.h"
#import "AppSettings.h"

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

static BOOL VibeIsFiniteNonNegative(double value) {
    return isfinite(value) && value >= 0;
}

NSUInteger VibeDebugAppendSharedInvariants(NSMutableArray<NSDictionary *> *v,
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

    checked++;
    if (fabsf(player.maxPitch - Settings.pitchRange) > 0.001f) {
        VibeDebugViolation(v, @"player.max_pitch_matches_setting",
                @"player maxPitch %.4f, setting %ld", player.maxPitch, (long)Settings.pitchRange);
    }

    checked++;
    NSUInteger nodes = [player debugEngineCounts][@"attachedNodes"].unsignedIntegerValue;
    if (nodes > kVibeMaxReasonableEngineNodes) {
        VibeDebugViolation(v, @"engine.node_count_bounded",
                @"%lu nodes attached to the engine", (unsigned long)nodes);
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
        checked++;
        NSString *publishedTitle = published[MPMediaItemPropertyTitle] ?: @"";
        NSString *expected = displayed.singleLineTitle ?: @"";
        if (![publishedTitle isEqualToString:expected]) {
            VibeDebugViolation(v, @"nowplaying.title_matches_track",
                    @"card shows \"%@\", track is \"%@\"", publishedTitle, expected);
        }

        checked++;
        NSString *publishedArtist = published[MPMediaItemPropertyArtist] ?: @"";
        NSString *expectedArtist = displayed.artist.length > 0 ? displayed.artist : @"";
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
