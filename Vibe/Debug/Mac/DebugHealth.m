//
//  DebugHealth.m
//  Vibe
//

#import "DebugHealth.h"
#import "DebugConsistency.h"

#if DEBUG

#import <AppKit/AppKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <libproc.h>
#import <malloc/malloc.h>
#import <sys/time.h>
#if __has_feature(address_sanitizer) || __has_feature(thread_sanitizer)
#import <sanitizer/allocator_interface.h>
#endif

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
#import "MainPlayerControllerInternal.h"
#import "MainPlayerController+Debug.h"
#import "TrackDisplayController.h"
#import "MainWindow.h"
#import "PlaylistController.h"
#import "PlaylistTableView.h"
#import "PitchControlPanel.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "MusicalKey.h"
#import "VibeStrings.h"

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

// A leaked AudioFileHandle or an unclosed cache handle shows here long before it
// shows in the footprint.
// TRAP: the NULL-buffer sizing call is not a count. It answers the size of the
// descriptor TABLE, which grows with peak concurrency and never shrinks, so
// every burst of parallel opens would read as a permanent leak. Fetch the
// listing; the bytes it writes are the open descriptors.
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

// The split phys_footprint cannot make: hundreds of megabytes of footprint
// over a live heap of twenty is the allocator holding freed pages, not a leak,
// and only the live bytes tell the two apart. Every registered zone is summed,
// CoreAudio's caulk zones included; a per-zone breakdown is vmmap's job.
static void VibeMallocBytes(uint64_t *live, uint64_t *reserved) {
    *live = 0;
    *reserved = 0;
    vm_address_t *zones = NULL;
    unsigned count = 0;
    if (malloc_get_all_zones(mach_task_self(), NULL, &zones, &count) != KERN_SUCCESS) {
        return;
    }
    for (unsigned i = 0; i < count; i++) {
        malloc_zone_t *zone = (malloc_zone_t *)zones[i];
#if __has_feature(address_sanitizer) || __has_feature(thread_sanitizer)
        // ASan's zone statistics count freed blocks too; TSan's report zero.
        // Both allocator APIs report the bytes that are still live.
        if (zone->zone_name && (strcmp(zone->zone_name, "asan") == 0
                               || strcmp(zone->zone_name, "tsan") == 0)) {
            *live += __sanitizer_get_current_allocated_bytes();
            *reserved += __sanitizer_get_heap_size();
            continue;
        }
#endif
        malloc_statistics_t stats = {0};
        malloc_zone_statistics(zone, &stats);
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

// App-owned work that must return to zero at rest; VibeIsSettled scores
// every entry, so whatever holds out names itself. The containers are leak
// signals too small for the process counters to see; the in-flight gauges
// name work stuck below them. engineCounts comes from the caller so the
// player's queue is crossed once per dump.
static NSDictionary<NSString *, NSNumber *> *VibePendingCounts(MainPlayerController *controller,
                                                              NSDictionary *engineCounts) {
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
    // Each source reports in its own vocabulary; the schema's names are set here.
    NSDictionary<NSString *, NSNumber *> *parse = [controller.metadataCache.parseCoordinator pendingCounts];
    out[@"metadataHolders"] = parse[@"holders"];
    out[@"metadataWaiters"] = parse[@"waiters"];
    out[@"openResultsBuffered"] = @([OpenRequestCoordinator.sharedCoordinator debugBufferedResultCount]);
    AppDelegate *appDelegate = (AppDelegate *)NSApp.delegate;
    if ([appDelegate isKindOfClass:AppDelegate.class]) {
        out[@"openBurstQueued"] = @([appDelegate debugQueuedOpenCount]);
    }
    out[@"retiredFades"] = engineCounts[@"retiredFades"];
    // A queued cloud parse that never ran is a row stuck on its filename
    // forever. A lane still held at rest is the whole sweep suspended: the
    // hold is set when a slow open starts and cleared when it settles, so a
    // teardown that loses the clearing edge shows up here and nowhere else.
    out[@"cloudParsesPending"] = @([controller.metadataCache debugPendingBackgroundMaterializationCount]);
    out[@"cloudLaneHeld"] = @([controller.metadataCache debugBackgroundMaterializationHeld] ? 1 : 0);
    // A priority record outliving its play is a strand no other counter shows.
    out[@"priorityRecordsPending"] =
            @([(NSArray *)[controller.metadataCache debugPriorityLaneState][@"pending"] count]);
    // Counted from before the scheduler/worker handoff, so a probe outliving
    // the claim whose last waiter detached never reads zero in between. At
    // rest it separates stuck classification from transfer or open work.
    out[@"datalessProbesInFlight"] =
            @([AudioFileMaterializationCoordinator.sharedCoordinator
                    datalessProbesInFlight]);
    // AudioFileHandle calls the OS still owes an answer. Not drainable — a
    // never-returning open cannot be cancelled — so nonzero at rest means work
    // that will never finish, and it belongs here rather than in the
    // diagnostics so a stranded open holds the settle open and names itself.
    // Read lock-free rather than through debugState: quiesce polls every 100ms
    // and must not take the coordinator's state queue.
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

    // TRAP: NSApp.windows includes closed windows the app keeps for reuse
    // (AppDelegate's settingsWindowController, the shared NSColorPanel), so
    // counting their views makes one visit to Settings read as a permanent
    // leak. Views, layers and tracking areas count VISIBLE windows only;
    // `windows` below stays over NSApp.windows so stranded windows still show.
    NSUInteger views = 0;
    NSUInteger trackingAreas = 0;
    NSUInteger layers = 0;
    NSUInteger visibleWindows = 0;
    for (NSWindow *window in NSApp.windows) {
        NSView *content = window.contentView;
        if (!content || !window.isVisible) {
            continue;
        }
        visibleWindows++;
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
    NSDictionary *counts = [player debugRenderCounts];

    return VibeJSONString(@{
        @"ok": @YES,
        @"process": process,
        @"ui": @{
            @"windows": @(NSApp.windows.count),
            @"visibleWindows": @(visibleWindows),
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
            // Hosted units, the FX chain's: created once and kept, so a
            // count that moves is a rebuild that leaked.
            @"hostedUnits": counts[@"hostedUnits"],
            // The bus's drain timer: on only while the output runs voices, so
            // 1 at rest is a wakeup the idle guarantee forbids.
            @"drainPolling": counts[@"pollActive"],
            // IO cycles the hosted output unit wrote as silence because the
            // pipeline failed to render; cumulative, and a soak holds it at 0.
            @"outputDropouts": counts[@"outputDropouts"],
            // Renders the pipeline turned away because a stuck one was still
            // inside when the next output unit's callback came; cumulative, 0.
            @"renderRefusals": counts[@"renderRefusals"],
            // The output unit's callback cost over the cycles it rendered:
            // cumulative, so diff across a run, and mean against max.
            @"renderCycles": counts[@"renderCycles"],
            @"renderMeanMicros": counts[@"renderMeanMicros"],
            @"renderMaxMicros": counts[@"renderMaxMicros"],
            @"canUndo": @(window.undoManager.canUndo),
            @"canRedo": @(window.undoManager.canRedo),
        },
        @"pending": VibePendingCounts(controller, counts),
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
    // closeFile: is the whole teardown; quiescing is that plus waiting for
    // what it cancelled to unwind.
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
        NSDictionary *pending = VibePendingCounts(strong, [strong.audioPlayer debugRenderCounts]);
        BOOL settled = VibeIsSettled(strong, pending);
        if (!settled && [deadline timeIntervalSinceNow] > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kQuiescePollInterval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), poll);
            return;
        }
        // Hand every zone's free pages back before the caller samples, or
        // phys_footprint reports the allocator's high-water mark and a freed
        // decode buffer reads as a leak that never comes down. releasedBytes
        // is reported because the call is not reliably effective: it can
        // return nothing while MALLOC_LARGE regions still hold dirty pages
        // with no live allocations.
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

    // Both of Playlist's row indexes against the array they index. Every
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
    if (header == TrackDisplayStateLoading || header == TrackDisplayStateEmpty
            || header == TrackDisplayStateError || header == TrackDisplayStateNotice) {
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
