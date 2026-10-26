//
//  DebugMacConsistency.m
//  Vibe
//

#import "DebugMacConsistency.h"
#import "DebugConsistency.h"

#if DEBUG

#import <AppKit/AppKit.h>
#import "AudioPlayer+Debug.h"
#import "ArtworkDisplayController+Debug.h"
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Debug.h"
#import "MainPlayerController+Playlist.h"
#import "TrackDisplayController.h"
#import "PlaylistController.h"
#import "PlaylistTableView.h"
#import "PitchControlPanel.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "MusicalKey.h"
#import "VibeStrings.h"

#pragma mark - check_consistency

// The header checks are render-lag-sensitive: renderState runs from the
// updateUI funnel, so a state that flipped this run-loop turn may not be drawn
// yet. Re-check after a settle before believing them.
NSUInteger VibeDebugCheckMac(NSMutableArray<NSDictionary *> *v,
                                        MainPlayerController *controller) {
    NSUInteger checked = 0;

    AudioPlayer *player = controller.audioPlayer;
    TrackDisplayController *display = controller.trackDisplay;
    TrackDisplayState state = [controller displayState];
    NSUInteger count = controller.playlistController.count;

    checked++;
    NSInteger rows = controller.playlistTableView.numberOfRows;
    if (rows != (NSInteger)count) {
        VibeDebugViolation(v, @"playlist.table_rows_match",
                @"table has %ld rows, playlist has %lu tracks", (long)rows, (unsigned long)count);
    }

    // Both of VibePlaylist's row indexes against the array they index. Every
    // structural edit rebuilds them wholesale, so a rebuild that drops or
    // doubles an entry leaves lookups answering a neighbouring row forever —
    // silently, since the counts still agree and every row still draws. The
    // identity lookup also catches one object in two rows, which a move that
    // copies instead of relocating produces.
    checked++;
    PlaylistController *list = controller.playlistController;
    for (NSUInteger i = 0; i < count; i++) {
        AudioTrack *track = [list trackAtIndex:i];
        if (!track) {
            VibeDebugViolation(v, @"playlist.indexes_agree",
                    @"row %lu is nil among %lu tracks", (unsigned long)i, (unsigned long)count);
            break;
        }
        NSInteger mapped = [list getIndexForTrack:track];
        if (mapped != (NSInteger)i) {
            VibeDebugViolation(v, @"playlist.indexes_agree",
                    @"row %lu (%@) maps to %ld", (unsigned long)i,
                    track.url.lastPathComponent ?: @"(nil)", (long)mapped);
            break;
        }
        if (![[list indexesOfTracksWithURL:track.url] containsIndex:i]) {
            VibeDebugViolation(v, @"playlist.indexes_agree",
                    @"row %lu (%@) missing from its URL index", (unsigned long)i,
                    track.url.lastPathComponent ?: @"(nil)");
            break;
        }
    }

    // The table clamps its own selection, so one reaching past the rows is a
    // structural edit whose precise row operations left it describing the old
    // shape.
    checked++;
    NSIndexSet *selection = controller.playlistTableView.selectedRowIndexes;
    if (selection.count > 0 && selection.lastIndex >= count) {
        VibeDebugViolation(v, @"playlist.selection_in_range",
                @"selection reaches row %lu with %lu tracks",
                (unsigned long)selection.lastIndex, (unsigned long)count);
    }

    checked++;
    float faderPitch = controller.pitchPanel.pitch;
    if (fabsf(faderPitch - player.pitch) > 0.01f) {
        VibeDebugViolation(v, @"pitch.fader_matches_player",
                @"fader %.4f, player %.4f", faderPitch, player.pitch);
    }

    // The tick rate is scaled to the playhead's on-screen speed. A mismatch
    // means some path moved the waveform width, the duration cache or the
    // varispeed rate without resyncing the timer.
    checked++;
    NSUInteger armedHz = controller.debugUIUpdateHz;
    NSUInteger expectedHz = controller.debugExpectedUIUpdateHz;
    if (armedHz != expectedHz) {
        VibeDebugViolation(v, @"ui.update_rate_follows_inputs",
                @"timer armed at %lu Hz, inputs ask for %lu Hz",
                (unsigned long)armedHz, (unsigned long)expectedHz);
    }

    // ---- Header artwork against the settled display track ----

    AudioTrack *shown = [controller displayedTrack];
    AudioTrackMetadata *metadata = shown.metadata;
    NSImage *cachedArt = metadata.cachedArt;
    BOOL metadataArtworkSettled = metadata && !metadata.artNeedsLoad &&
            !metadata.artLoadPending;
    ArtworkDisplayController *artwork = controller.debugArtworkController;
    AudioTrack *target = artwork.debugArtworkTargetTrack;
    AudioTrackMetadata *targetMetadata = artwork.debugArtworkTargetMetadata;
    NSImage *targetArt = artwork.debugArtworkTargetArt;
    BOOL targetIsCurrent = target == shown && targetMetadata == metadata &&
            targetArt == cachedArt;
    if (state == TrackDisplayStateTrack && shown && metadataArtworkSettled &&
            targetIsCurrent && !artwork.debugArtworkRenderPending) {
        AudioTrack *owner = artwork.debugInstalledArtworkOwnerTrack;
        AudioTrackMetadata *installedMetadata = artwork.debugInstalledArtworkMetadata;
        NSImage *installedSource = artwork.debugInstalledArtworkSource;
        if (cachedArt != nil) {
            checked++;
            if (owner != shown || installedMetadata != metadata ||
                    installedSource != cachedArt) {
                VibeDebugViolation(v, @"artwork.owner_matches_displayed_track",
                        @"header track %@, installed owner %@; metadata %@, source %@",
                        shown.url.lastPathComponent ?: @"(nil)",
                        owner.url.lastPathComponent ?: @"(nil)",
                        installedMetadata == metadata ? @"current" : @"stale",
                        installedSource == cachedArt ? @"current" : @"stale");
            }
        }
        else {
            checked++;
            if (!artwork.debugShowingDefaultArtwork) {
                VibeDebugViolation(v, @"artwork.default_matches_artless_track",
                        @"header track %@ settled without art; installed owner %@",
                        shown.url.lastPathComponent ?: @"(nil)",
                        owner.url.lastPathComponent ?: @"(nil)");
            }
        }
    }

    // ---- Header labels against the resolved state ----

    NSString *title = display.titleTextField.stringValue ?: @"";
    NSString *artist = display.artistTextField.stringValue ?: @"";
    // The header's own state: a notice covers the display state's labels.
    TrackDisplayState header = [controller headerState];

    if (header == TrackDisplayStateNotice) {
        checked++;
        NSString *status = controller.noticeStatus ?: @"";
        if (![artist isEqualToString:status]) {
            VibeDebugViolation(v, @"display.notice_shown",
                    @"a notice is held but the header shows \"%@\"", artist);
        }
    }

    if (header == TrackDisplayStateTrack || header == TrackDisplayStateLoading) {
        checked++;
        NSString *expectedTitle = shown.displayTitle;
        if (shown && ![title isEqualToString:expectedTitle ?: @""]) {
            VibeDebugViolation(v, @"display.title_matches_track",
                    @"header shows \"%@\", track is \"%@\"", title, expectedTitle ?: @"");
        }
        checked++;
        NSString *expectedArtist = shown.displayArtist ?: @"";
        if (shown && ![artist isEqualToString:expectedArtist]) {
            VibeDebugViolation(v, @"display.artist_matches_track",
                    @"header shows \"%@\", track is \"%@\"", artist, expectedArtist);
        }
    }

    if (header == TrackDisplayStateEmpty || header == TrackDisplayStateLaunchGrace) {
        checked++;
        if (title.length > 0) {
            VibeDebugViolation(v, @"display.empty_state_clears_title",
                    @"no current track but the header shows \"%@\"", title);
        }
    }

    // Every state but Track and the launch grace renders the placeholder
    // rather than a time: a real clock there means a previous track's position
    // survived the transition.
    if (header != TrackDisplayStateTrack && header != TrackDisplayStateLaunchGrace) {
        NSString *placeholder = STR_LABEL_TIME_UNKNOWN;
        checked++;
        NSString *elapsed = display.currentTimeTextField.stringValue ?: @"";
        if (![elapsed isEqualToString:placeholder]) {
            VibeDebugViolation(v, @"display.elapsed_time_placeholder",
                    @"state %ld shows elapsed \"%@\"", (long)header, elapsed);
        }
        checked++;
        NSString *total = display.totalTimeTextField.stringValue ?: @"";
        if (![total isEqualToString:placeholder]) {
            VibeDebugViolation(v, @"display.total_time_placeholder",
                    @"state %ld shows total \"%@\"", (long)header, total);
        }
    }

    return checked;
}

#endif
