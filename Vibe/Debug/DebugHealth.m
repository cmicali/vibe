//
// Created by Christopher Micali on 8/14/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "DebugHealth.h"

#if DEBUG

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <libproc.h>
#import <malloc/malloc.h>
#import <sys/time.h>

#import "DebugShared.h"
#import "AppDelegate.h"
#import "OpenRequestCoordinator.h"
#import "AudioTrackMetadataCache.h"
#import "MainPlayerController+Debug.h"
#import "MainPlayerController+NowPlaying.h"   // displayState, displayedTrack
#import "TrackDisplayController.h"
#import "MainWindow.h"
#import "PlaylistController.h"
#import "PlaylistTableView.h"
#import "PitchControlPanel.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "MusicalKey.h"
#import "VibeStrings.h"   // STR_LABEL_TIME_UNKNOWN, compared against the live label

#pragma mark - Process counters

static NSUInteger VibeThreadCount(void) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
        return 0;
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
    return count;
}

static NSUInteger VibeMachPortCount(void) {
    mach_port_name_array_t names = NULL;
    mach_msg_type_number_t nameCount = 0;
    mach_port_type_array_t types = NULL;
    mach_msg_type_number_t typeCount = 0;
    if (mach_port_names(mach_task_self(), &names, &nameCount, &types, &typeCount) != KERN_SUCCESS) {
        return 0;
    }
    vm_deallocate(mach_task_self(), (vm_address_t)names, nameCount * sizeof(*names));
    vm_deallocate(mach_task_self(), (vm_address_t)types, typeCount * sizeof(*types));
    return nameCount;
}

// A leaked AVAudioFile or an unclosed cache handle shows here long before it
// shows in the footprint. Passing a null buffer asks only for the size.
static NSUInteger VibeOpenFileDescriptorCount(void) {
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (bytes <= 0) {
        return 0;
    }
    return (NSUInteger)(bytes / (int)PROC_PIDLISTFD_SIZE);
}

static double VibeProcessUptimeSeconds(void) {
    struct proc_taskallinfo info;
    if (proc_pidinfo(getpid(), PROC_PIDTASKALLINFO, 0, &info, sizeof(info)) != (int)sizeof(info)) {
        return 0;
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    return (double)now.tv_sec - (double)info.pbsd.pbi_start_tvsec
            + ((double)now.tv_usec - (double)info.pbsd.pbi_start_tvusec) / 1e6;
}

#pragma mark - UI counters

static NSUInteger VibeLayerCount(CALayer *layer) {
    NSUInteger total = 1;
    for (CALayer *sub in layer.sublayers) {
        total += VibeLayerCount(sub);
    }
    return total;
}

// Views recurse through the view tree and layers through the layer tree, so a
// layer-backed subview's layer is counted once, as a sublayer of its
// superview's.
static void VibeCountViews(NSView *view, NSUInteger *views, NSUInteger *trackingAreas) {
    (*views)++;
    *trackingAreas += view.trackingAreas.count;
    for (NSView *sub in view.subviews) {
        VibeCountViews(sub, views, trackingAreas);
    }
}

#pragma mark - Pending work

// Every unbounded container in the app that holds work in flight. These are
// the leak signals the process counters cannot see: a stranded parse claim or
// an undelivered open result is a few hundred bytes, so a thousand of them
// would not move the footprint, yet each one is a piece of work that will
// never finish. All of them belong at zero once the app settles, which is why
// the quiesce verb exists and why the stress driver holds them to a growth
// limit of a few rather than a few hundred megabytes.
// engineCounts comes from the caller so the player's queue is crossed once per
// dump, not once per section.
static NSDictionary<NSString *, NSNumber *> *VibePendingCounts(MainPlayerController *controller,
                                                              NSDictionary *engineCounts) {
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
    // The health schema's names are this file's business; each source reports
    // in its own vocabulary and is namespaced here.
    NSDictionary<NSString *, NSNumber *> *parse = [controller.metadataCache debugPendingCounts];
    out[@"metadataHolders"] = parse[@"holders"];
    out[@"metadataWaiters"] = parse[@"waiters"];
    out[@"openResultsBuffered"] = @([OpenRequestCoordinator.sharedCoordinator debugBufferedResultCount]);
    AppDelegate *appDelegate = (AppDelegate *)NSApp.delegate;
    if ([appDelegate isKindOfClass:AppDelegate.class]) {
        out[@"openBurstQueued"] = @([appDelegate debugQueuedOpenCount]);
    }
    out[@"retiredFades"] = engineCounts[@"retiredFades"];
    return out;
}

#pragma mark - dump_health

NSString *VibeDebugHealthJSON(MainPlayerController *controller) {
    NSMutableDictionary *process = [NSMutableDictionary dictionary];
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vmInfo, &vmCount) == KERN_SUCCESS) {
        // phys_footprint is the number macOS itself judges the process by, and
        // the only one that tracks purgeable and compressed memory correctly.
        process[@"footprintBytes"] = @(vmInfo.phys_footprint);
        process[@"residentBytes"] = @(vmInfo.resident_size);
        process[@"residentPeakBytes"] = @(vmInfo.resident_size_peak);
    }
    process[@"threads"] = @(VibeThreadCount());
    process[@"fileDescriptors"] = @(VibeOpenFileDescriptorCount());
    process[@"machPorts"] = @(VibeMachPortCount());
    process[@"uptimeSeconds"] = @(VibeProcessUptimeSeconds());

    NSUInteger views = 0;
    NSUInteger trackingAreas = 0;
    NSUInteger layers = 0;
    for (NSWindow *window in NSApp.windows) {
        NSView *content = window.contentView;
        if (!content) {
            continue;
        }
        VibeCountViews(content, &views, &trackingAreas);
        if (content.layer) {
            layers += VibeLayerCount(content.layer);
        }
    }

    AudioPlayer *player = controller.audioPlayer;
    PlaylistController *playlist = controller.playlistController;
    MainWindow *window = (MainWindow *)controller.window;

    // Blocks on the player's serial queue, so a wedged queue times the command
    // out rather than letting it answer from stale state.
    NSDictionary *engine = [player debugEngineCounts];

    return VibeJSONString(@{
        @"ok": @YES,
        @"process": process,
        @"ui": @{
            @"windows": @(NSApp.windows.count),
            @"views": @(views),
            @"layers": @(layers),
            @"trackingAreas": @(trackingAreas),
        },
        @"app": @{
            @"playlistCount": @(playlist.count),
            @"currentIndex": @(playlist.currentIndex),
            @"tableRows": @(controller.playlistTableView.numberOfRows),
            @"playerLoading": @(player.isLoading),
            @"gaplessArmed": @(player.isGaplessArmed),
            @"engineNodes": engine[@"attachedNodes"],
            @"canUndo": @(window.undoManager.canUndo),
            @"canRedo": @(window.undoManager.canRedo),
        },
        @"pending": VibePendingCounts(controller, engine),
    });
}

#pragma mark - quiesce

static const NSTimeInterval kQuiesceDeadline = 15.0;
static const NSTimeInterval kQuiescePollInterval = 0.1;

static BOOL VibeIsSettled(MainPlayerController *controller, NSDictionary *pending) {
    for (NSNumber *count in pending.objectEnumerator) {
        if (count.unsignedIntegerValue > 0) {
            return NO;
        }
    }
    return controller.audioPlayer.isStopped && !controller.audioPlayer.isLoading;
}

void VibeDebugQuiesce(MainPlayerController *controller, void (^completion)(NSString *)) {
    // closeFile: is already the whole teardown — stop, drop the prefetch
    // handle, cancel the waveform load and the deferred metadata scan, clear
    // the playlist, reset the UI — so quiescing is that plus waiting for what
    // it cancelled to actually unwind.
    [controller closeFile:nil];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kQuiesceDeadline];
    __block NSDate *started = [NSDate date];
    __block void (^poll)(void);
    __weak MainPlayerController *weakController = controller;
    poll = ^{
        MainPlayerController *strong = weakController;
        if (!strong) {
            completion(VibeJSONString(@{@"error": @"controller went away"}));
            poll = nil;
            return;
        }
        NSDictionary *pending = VibePendingCounts(strong, [strong.audioPlayer debugEngineCounts]);
        BOOL settled = VibeIsSettled(strong, pending);
        if (!settled && [deadline timeIntervalSinceNow] > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQuiescePollInterval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), poll);
            return;
        }
        // Hand every zone's free pages back to the OS before the caller
        // samples. Without it phys_footprint reports the allocator's
        // high-water mark rather than what is still live — a decode buffer
        // freed to malloc keeps the footprint hundreds of megabytes up, which
        // reads exactly like a leak and never comes back down.
        malloc_zone_pressure_relief(NULL, 0);
        // Reported rather than treated as an error: work that will not unwind
        // within the deadline is itself the finding, and the caller can see
        // which counter held out.
        completion(VibeJSONString(@{
            @"ok": @YES,
            @"settled": @(settled),
            @"waitedSeconds": @(-[started timeIntervalSinceNow]),
            @"pending": pending,
        }));
        poll = nil;
    };
    poll();
}

#pragma mark - check_invariants

static void VibeViolation(NSMutableArray<NSDictionary *> *out, NSString *identifier,
                          NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);
static void VibeViolation(NSMutableArray<NSDictionary *> *out, NSString *identifier,
                          NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *detail = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [out addObject:@{@"id": identifier, @"detail": detail}];
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

NSString *VibeDebugInvariantsJSON(MainPlayerController *controller) {
    NSMutableArray<NSDictionary *> *v = [NSMutableArray array];
    NSUInteger checked = 0;

    AudioPlayer *player = controller.audioPlayer;
    PlaylistController *playlist = controller.playlistController;
    TrackDisplayController *display = controller.trackDisplay;
    TrackDisplayState state = [controller displayState];
    AudioTrack *current = playlist.currentTrack;
    NSUInteger count = playlist.count;
    NSUInteger index = playlist.currentIndex;

    // ---- Playlist ----

    checked++;
    if (count == 0) {
        if (index != 0) {
            VibeViolation(v, @"playlist.index_in_range",
                    @"empty playlist but currentIndex is %lu", (unsigned long)index);
        }
    }
    else if (index >= count) {
        VibeViolation(v, @"playlist.index_in_range",
                @"currentIndex %lu with %lu tracks", (unsigned long)index, (unsigned long)count);
    }

    checked++;
    AudioTrack *atIndex = [playlist trackAtIndex:index];
    if (current != atIndex) {
        VibeViolation(v, @"playlist.current_track_matches_index",
                @"currentTrack %@ but track at index %lu is %@",
                current.url.lastPathComponent ?: @"(nil)", (unsigned long)index,
                atIndex.url.lastPathComponent ?: @"(nil)");
    }

    checked++;
    NSInteger rows = controller.playlistTableView.numberOfRows;
    if (rows != (NSInteger)count) {
        VibeViolation(v, @"playlist.table_rows_match",
                @"table has %ld rows, playlist has %lu tracks", (long)rows, (unsigned long)count);
    }

    // ---- Player ----

    checked++;
    if (!VibeIsFiniteNonNegative(player.duration)) {
        VibeViolation(v, @"player.duration_finite", @"duration is %f", player.duration);
    }

    checked++;
    if (!VibeIsFiniteNonNegative(player.position)) {
        VibeViolation(v, @"player.position_finite", @"position is %f", player.position);
    }

    // Only in the settled Track state: Loading reads both as 0 by contract,
    // and a seek in flight can momentarily report the old playhead.
    checked++;
    if (state == TrackDisplayStateTrack && player.duration > 0
            && player.position > player.duration + 0.5) {
        VibeViolation(v, @"player.position_within_duration",
                @"position %.3f past duration %.3f", player.position, player.duration);
    }

    checked++;
    if (fabsf(player.pitch) > player.maxPitch + 0.001f) {
        VibeViolation(v, @"player.pitch_clamped",
                @"pitch %.4f outside ±%.4f", player.pitch, player.maxPitch);
    }

    checked++;
    if (fabsf(player.maxPitch - Settings.pitchRange) > 0.001f) {
        VibeViolation(v, @"player.max_pitch_matches_setting",
                @"player maxPitch %.4f, setting %.4f", player.maxPitch, Settings.pitchRange);
    }

    checked++;
    float faderPitch = controller.pitchPanel.pitch;
    if (fabsf(faderPitch - player.pitch) > 0.01f) {
        VibeViolation(v, @"pitch.fader_matches_player",
                @"fader %.4f, player %.4f", faderPitch, player.pitch);
    }

    // The UI tick rate is scaled to the playhead's on-screen speed, so it must
    // follow its three inputs. A disagreement means some path moved the
    // waveform width, the duration cache or the varispeed rate without
    // resyncing the timer, and the playhead is being drawn at the previous
    // track's or window's cadence.
    checked++;
    NSUInteger armedHz = controller.debugUIUpdateHz;
    NSUInteger expectedHz = controller.debugExpectedUIUpdateHz;
    if (armedHz != expectedHz) {
        VibeViolation(v, @"ui.update_rate_follows_inputs",
                @"timer armed at %lu Hz, inputs ask for %lu Hz",
                (unsigned long)armedHz, (unsigned long)expectedHz);
    }

    checked++;
    NSUInteger nodes = [player debugEngineCounts][@"attachedNodes"].unsignedIntegerValue;
    if (nodes > kVibeMaxReasonableEngineNodes) {
        VibeViolation(v, @"engine.node_count_bounded",
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
            VibeViolation(v, @"track.bpm_precedence",
                    @"bpm %.3f, tagged %.3f, detected %.3f",
                    current.bpm, taggedBPM, current.detectedBPM);
        }

        checked++;
        VibeMusicalKey taggedKey = metadata ? metadata.key : VibeMusicalKeyNone;
        VibeMusicalKey expectedKey = taggedKey >= 0 ? taggedKey : current.detectedKey;
        if (current.key != expectedKey) {
            VibeViolation(v, @"track.key_precedence",
                    @"key %ld, tagged %ld, detected %ld",
                    (long)current.key, (long)taggedKey, (long)current.detectedKey);
        }

        // Guards the zero-fill trap from the other side: a key that is neither
        // a valid 0-23 nor exactly VibeMusicalKeyNone is uninitialized memory
        // or a bad parse, and 0 reads as tagged C major wherever it came from.
        checked++;
        if (!VibeMusicalKeyIsValid(current.key) && current.key != VibeMusicalKeyNone) {
            VibeViolation(v, @"track.key_in_range", @"resolved key is %ld", (long)current.key);
        }
        checked++;
        if (!VibeMusicalKeyIsValid(current.detectedKey) && current.detectedKey != VibeMusicalKeyNone) {
            VibeViolation(v, @"track.detected_key_in_range",
                    @"detectedKey is %ld", (long)current.detectedKey);
        }
    }

    // ---- Header labels against the resolved state ----
    //
    // These are the render-lag-sensitive ones: renderState runs from the
    // updateUI funnel, so a state that flipped this runloop turn may not have
    // been drawn yet. Re-check after a settle before believing them.

    NSString *title = display.titleTextField.stringValue ?: @"";
    NSString *artist = display.artistTextField.stringValue ?: @"";

    if (state == TrackDisplayStateTrack || state == TrackDisplayStateLoading) {
        AudioTrack *shown = [controller displayedTrack];
        checked++;
        NSString *expectedTitle = shown.hasArtistAndTitle ? shown.title : shown.singleLineTitle;
        if (shown && ![title isEqualToString:expectedTitle ?: @""]) {
            VibeViolation(v, @"display.title_matches_track",
                    @"header shows \"%@\", track is \"%@\"", title, expectedTitle ?: @"");
        }
        checked++;
        NSString *expectedArtist = shown.hasArtistAndTitle ? (shown.artist ?: @"") : @"";
        if (shown && ![artist isEqualToString:expectedArtist]) {
            VibeViolation(v, @"display.artist_matches_track",
                    @"header shows \"%@\", track is \"%@\"", artist, expectedArtist);
        }
    }

    if (state == TrackDisplayStateEmpty || state == TrackDisplayStateLaunchGrace) {
        checked++;
        if (title.length > 0) {
            VibeViolation(v, @"display.empty_state_clears_title",
                    @"no current track but the header shows \"%@\"", title);
        }
    }

    // Loading, Empty and Error all render the placeholder rather than a time:
    // a real clock there means a previous track's position survived the
    // transition.
    if (state == TrackDisplayStateLoading || state == TrackDisplayStateEmpty
            || state == TrackDisplayStateError) {
        NSString *placeholder = STR_LABEL_TIME_UNKNOWN;
        checked++;
        NSString *elapsed = display.currentTimeTextField.stringValue ?: @"";
        if (![elapsed isEqualToString:placeholder]) {
            VibeViolation(v, @"display.elapsed_time_placeholder",
                    @"state %ld shows elapsed \"%@\"", (long)state, elapsed);
        }
        checked++;
        NSString *total = display.totalTimeTextField.stringValue ?: @"";
        if (![total isEqualToString:placeholder]) {
            VibeViolation(v, @"display.total_time_placeholder",
                    @"state %ld shows total \"%@\"", (long)state, total);
        }
    }

    return VibeJSONString(@{
        @"ok": @(v.count == 0),
        @"checked": @(checked),
        @"state": @(state),
        @"violations": v,
    });
}

#endif
