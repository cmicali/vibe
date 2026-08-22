//
//  DebugHealth.m
//  Vibe
//

#import "DebugHealth.h"
#import "DebugConsistency.h"   // VibeDebugViolation, shared with the cross-platform checks

#if DEBUG

#import <AppKit/AppKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <libproc.h>
#import <malloc/malloc.h>
#import <sys/time.h>

#import "DebugWireFormat.h"
#import "AppDelegate+Debug.h"
#import "AudioPlayer+Debug.h"
#import "OpenBurstCoalescer+Debug.h"
#import "OpenRequestCoordinator+Debug.h"
#import "AudioFileMaterializationCoordinator+Debug.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioTrackMetadataCache+Debug.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "AppDelegate.h"
#import "OpenRequestCoordinator.h"
#import "AudioTrackMetadataCache.h"
#import "ArtworkDisplayController+Debug.h"
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
// TRAP: the sizing call is not a count. proc_pidinfo(PROC_PIDLISTFDS) with a
// NULL buffer answers how big the process's descriptor TABLE is, and that table
// grows with peak concurrency and never shrinks — so using it as the count
// reports every burst of parallel opens as a permanent leak that survives even
// a quiesce. Measured: 420 "descriptors" against lsof's 41 after 400 rapid
// plays. The listing has to be fetched for real; the bytes it actually writes
// are the open ones.
static NSUInteger VibeOpenFileDescriptorCount(void) {
    int capacity = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
    if (capacity <= 0) {
        return 0;
    }
    struct proc_fdinfo *entries = malloc((size_t)capacity);
    if (!entries) {
        return 0;
    }
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, entries, capacity);
    free(entries);
    if (bytes <= 0) {
        return 0;
    }
    return (NSUInteger)(bytes / (int)PROC_PIDLISTFD_SIZE);
}

// The split phys_footprint cannot make. A footprint of hundreds of megabytes
// over a live heap of twenty is the allocator holding freed pages, not a leak,
// and only `liveBytes` distinguishes the two — it is the sensitive signal the
// footprint was standing in for. Every registered zone is summed, CoreAudio's
// own caulk zones included, since a per-zone breakdown is vmmap's job.
static void VibeMallocBytes(uint64_t *live, uint64_t *reserved) {
    *live = 0;
    *reserved = 0;
    vm_address_t *zones = NULL;
    unsigned count = 0;
    if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &count) != KERN_SUCCESS) {
        return;
    }
    for (unsigned i = 0; i < count; i++) {
        malloc_statistics_t stats = {0};
        malloc_zone_statistics((malloc_zone_t *)zones[i], &stats);
        *live += stats.size_in_use;
        *reserved += stats.size_allocated;
    }
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
    NSDictionary<NSString *, NSNumber *> *parse = [controller.metadataCache.parseCoordinator pendingCounts];
    out[@"metadataHolders"] = parse[@"holders"];
    out[@"metadataWaiters"] = parse[@"waiters"];
    out[@"openResultsBuffered"] = @([OpenRequestCoordinator.sharedCoordinator debugBufferedResultCount]);
    AppDelegate *appDelegate = (AppDelegate *)NSApp.delegate;
    if ([appDelegate isKindOfClass:AppDelegate.class]) {
        out[@"openBurstQueued"] = @([appDelegate debugQueuedOpenCount]);
    }
    out[@"retiredFades"] = engineCounts[@"retiredFades"];
    // Both belong at rest. A queued cloud parse that never ran is a row stuck
    // on its filename forever, and a lane still HELD once everything has
    // settled is the whole sweep suspended — the hold is set when a slow open
    // starts and cleared when it settles, so any teardown that loses the
    // clearing edge shows up here and nowhere else.
    out[@"cloudParsesPending"] = @([controller.metadataCache debugPendingBackgroundMaterializationCount]);
    out[@"cloudLaneHeld"] = @([controller.metadataCache debugBackgroundMaterializationHeld] ? 1 : 0);
    // Unlike the two above, this one IS a growth metric at quiescence: a
    // priority record outliving its play is a strand, and the 37-entry one
    // the stress soak missed was invisible precisely because no health
    // counter carried it.
    out[@"priorityRecordsPending"] =
            @([(NSArray *)[controller.metadataCache debugPriorityLaneState][@"pending"] count]);
    // An AVAudioFile call the OS still owes an answer for. Unlike everything
    // above it is not a container the app can drain — a never-returning open
    // cannot be cancelled — so nonzero here at rest is not "work still in
    // flight" but "work that will never finish", which is the only reading
    // quiesce can give it. That is also why it belongs in this dictionary
    // rather than beside the diagnostic numbers: VibeIsSettled scores every
    // entry, so a stranded open holds the settle open and names itself.
    // The lock-free reader, not debugState: quiesce polls this every 100ms and
    // must not take the coordinator's state queue to do it.
    out[@"handleOpensInFlight"] =
            @([AudioFileMaterializationCoordinator.sharedCoordinator handleOpensInFlight]);
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
    uint64_t mallocLive = 0;
    uint64_t mallocReserved = 0;
    VibeMallocBytes(&mallocLive, &mallocReserved);
    process[@"mallocLiveBytes"] = @(mallocLive);
    process[@"mallocReservedBytes"] = @(mallocReserved);
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
        // Diagnosis, not scoring: the lane gauges and the cumulative outcome
        // counters that say whether work is still being *attempted*. The one
        // number here that belongs at zero at rest is already in `pending`.
        @"materialization":
                [AudioFileMaterializationCoordinator.sharedCoordinator debugState],
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
        //
        // The released count is reported because this call is not reliably
        // effective: measured against a run that had churned through hundreds
        // of large files, it returned nothing while vmmap showed 67 MB of
        // dirty pages sitting in MALLOC_LARGE regions with no live
        // allocations. A caller that assumes it worked is reading a footprint
        // that still carries the high-water mark.
        uint64_t liveBefore = 0, reservedBefore = 0;
        VibeMallocBytes(&liveBefore, &reservedBefore);
        size_t released = malloc_zone_pressure_relief(NULL, 0);
        uint64_t liveAfter = 0, reservedAfter = 0;
        VibeMallocBytes(&liveAfter, &reservedAfter);
        // Reported rather than treated as an error: work that will not unwind
        // within the deadline is itself the finding, and the caller can see
        // which counter held out.
        completion(VibeJSONString(@{
            @"ok": @YES,
            @"settled": @(settled),
            @"waitedSeconds": @(-[started timeIntervalSinceNow]),
            @"pending": pending,
            @"pressureRelief": @{
                @"releasedBytes": @(released),
                @"mallocLiveBytes": @(liveAfter),
                @"mallocReservedBytes": @(reservedAfter),
                @"reservedFreedBytes": @(reservedBefore > reservedAfter
                                         ? reservedBefore - reservedAfter : 0),
            },
        }));
        poll = nil;
    };
    poll();
}

#pragma mark - check_consistency

// The macOS-only checks: the header labels and artwork the mac renders, the
// pitch fader, the playlist table's row count, and the scaled UI tick rate.
// Everything that holds on both platforms is VibeDebugCheckShared, in
// Debug/DebugConsistency.m, and `check_consistency` runs that first and
// this through the surface protocol's optional hook.
//
// These are the render-lag-sensitive ones: renderState runs from the updateUI
// funnel, so a state that flipped this runloop turn may not have been drawn
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

    checked++;
    float faderPitch = controller.pitchPanel.pitch;
    if (fabsf(faderPitch - player.pitch) > 0.01f) {
        VibeDebugViolation(v, @"pitch.fader_matches_player",
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

    if (state == TrackDisplayStateTrack || state == TrackDisplayStateLoading) {
        checked++;
        NSString *expectedTitle = shown.hasArtistAndTitle ? shown.title : shown.singleLineTitle;
        if (shown && ![title isEqualToString:expectedTitle ?: @""]) {
            VibeDebugViolation(v, @"display.title_matches_track",
                    @"header shows \"%@\", track is \"%@\"", title, expectedTitle ?: @"");
        }
        checked++;
        NSString *expectedArtist = shown.hasArtistAndTitle ? (shown.artist ?: @"") : @"";
        if (shown && ![artist isEqualToString:expectedArtist]) {
            VibeDebugViolation(v, @"display.artist_matches_track",
                    @"header shows \"%@\", track is \"%@\"", artist, expectedArtist);
        }
    }

    if (state == TrackDisplayStateEmpty || state == TrackDisplayStateLaunchGrace) {
        checked++;
        if (title.length > 0) {
            VibeDebugViolation(v, @"display.empty_state_clears_title",
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
            VibeDebugViolation(v, @"display.elapsed_time_placeholder",
                    @"state %ld shows elapsed \"%@\"", (long)state, elapsed);
        }
        checked++;
        NSString *total = display.totalTimeTextField.stringValue ?: @"";
        if (![total isEqualToString:placeholder]) {
            VibeDebugViolation(v, @"display.total_time_placeholder",
                    @"state %ld shows total \"%@\"", (long)state, total);
        }
    }

    return checked;
}

#endif
