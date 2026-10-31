//
//  DebugHealth.m
//  Vibe
//

#import "DebugHealth.h"

#if DEBUG

#import <TargetConditionals.h>
#import <mach/mach.h>
#import <malloc/malloc.h>
#import <fcntl.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <unistd.h>
#if TARGET_OS_OSX
#import <libproc.h>
#endif
#if __has_feature(address_sanitizer) || __has_feature(thread_sanitizer)
#import <sanitizer/allocator_interface.h>
#endif
#import "DebugWireFormat.h"
#import "AudioPlayer+Debug.h"
#import "AudioFileMaterializationCoordinator+Debug.h"
#import "AudioFileMaterializationCoordinatorInternal.h"
#import "AudioTrackMetadataCache+Debug.h"
#import "AudioTrackMetadataCacheInternal.h"
#import "AudioTrackMetadataCache.h"
#import "AudioPlayer.h"

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
#if !TARGET_OS_OSX
    // No libproc: probe each slot of the table instead.
    NSUInteger open = 0;
    for (int fd = 0, end = getdtablesize(); fd < end; fd++) {
        open += fcntl(fd, F_GETFD) != -1;
    }
    return open;
#else
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
#endif
}

// Live allocations help distinguish retained objects from freed pages the
// allocator still holds. Sum every registered zone.
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

static double VibeDebugUptimeSeconds(void) {
    int name[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    if (sysctl(name, 4, &info, &size, NULL, 0) != 0 || size != sizeof(info)) {
        return 0;
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    struct timeval start = info.kp_proc.p_starttime;
    return (double)now.tv_sec - (double)start.tv_sec + ((double)now.tv_usec - (double)start.tv_usec) / 1e6;
}

#pragma mark - UI counters

NSUInteger VibeDebugLayerCount(CALayer *layer) {
    NSUInteger total = 1;
    for (CALayer *sub in layer.sublayers) {
        total += VibeDebugLayerCount(sub);
    }
    return total;
}

#pragma mark - Pending work

// App-owned work that must return to zero at rest; VibeIsSettled scores
// every entry, so whatever holds out names itself. The containers are leak
// signals too small for the process counters to see; the in-flight gauges
// name work stuck below them. engineCounts comes from the caller so the
// player's queue is crossed once per dump. The surface adds its platform's
// own (the mac's open funnel).
static NSDictionary<NSString *, NSNumber *> *VibePendingCounts(id<VibeDebugPlayerSurface> surface,
                                                              NSDictionary *engineCounts) {
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
    AudioTrackMetadataCache *metadataCache = [surface debugMetadataCache];
    // Each source reports in its own vocabulary; the schema's names are set here.
    NSDictionary<NSString *, NSNumber *> *parse = [metadataCache.parseCoordinator pendingCounts];
    out[@"metadataHolders"] = parse[@"holders"];
    out[@"metadataWaiters"] = parse[@"waiters"];
    if ([surface respondsToSelector:@selector(debugPendingCounts)]) {
        [out addEntriesFromDictionary:[surface debugPendingCounts]];
    }
    out[@"retiredFades"] = engineCounts[@"retiredFades"];
    // A queued cloud parse that never ran is a row stuck on its filename
    // forever. A lane still held at rest is the whole sweep suspended: the
    // hold is set when a slow open starts and cleared when it settles, so a
    // teardown that loses the clearing edge shows up here and nowhere else.
    out[@"cloudParsesPending"] = @([metadataCache debugPendingBackgroundMaterializationCount]);
    out[@"cloudLaneHeld"] = @([metadataCache debugBackgroundMaterializationHeld] ? 1 : 0);
    // A priority record outliving its play is a strand no other counter shows.
    out[@"priorityRecordsPending"] =
            @([(NSArray *)[metadataCache debugPriorityLaneState][@"pending"] count]);
    // Counted from before the scheduler/worker handoff, so a probe outliving
    // the claim whose last waiter detached never reads zero in between. At
    // rest it separates stuck classification from transfer or open work.
    out[@"datalessProbesInFlight"] =
            @([AudioFileMaterializationCoordinator.sharedCoordinator
                    datalessProbesInFlight]);
    // Outstanding handle opens retain admission capacity until they return.
    // Read lock-free because quiesce polls this every 100ms.
    out[@"handleOpensInFlight"] =
            @([AudioFileMaterializationCoordinator.sharedCoordinator handleOpensInFlight]);
    return out;
}

#pragma mark - dump_health

NSString *VibeDebugHealthJSON(id<VibeDebugPlayerSurface> surface) {
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
    process[@"uptimeSeconds"] = @(VibeDebugUptimeSeconds());

    AudioPlayer *player = [surface debugPlayer];

    // Blocks on the player's serial queue, so a wedged queue times the command
    // out rather than letting it answer from stale state.
    NSDictionary *counts = [player debugRenderCounts];

    NSMutableDictionary *app = [@{
            @"playlistCount": @([surface debugPlaylistCount]),
            @"currentIndex": @([surface debugPlaylistCurrentIndex]),
            @"playerLoading": @(player.isLoading),
            @"gaplessArmed": @(player.isGaplessArmed),
            // Warm every effect before comparing against a leak baseline.
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
    } mutableCopy];
    if ([surface respondsToSelector:@selector(debugHealthApp)]) {
        [app addEntriesFromDictionary:[surface debugHealthApp]];
    }
    return VibeJSONString(@{
        @"ok": @YES,
        @"process": process,
        @"ui": [surface debugHealthUI],
        @"app": app,
        @"pending": VibePendingCounts(surface, counts),
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

static BOOL VibeIsSettled(id<VibeDebugPlayerSurface> surface, NSDictionary *pending) {
    for (NSNumber *count in pending.objectEnumerator) {
        if (count.unsignedIntegerValue > 0) {
            return NO;
        }
    }
    AudioPlayer *player = [surface debugPlayer];
    return player.isStopped && !player.isLoading;
}

void VibeDebugQuiesce(id<VibeDebugPlayerSurface> surface, void (^completion)(NSString *)) {
    // Close is the whole teardown; quiescing is that plus waiting for what it
    // cancelled to unwind.
    [surface debugCloseFile];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:kQuiesceDeadline];
    __block NSDate *started = [NSDate date];
    __block void (^poll)(void);
    __weak id<VibeDebugPlayerSurface> weakSurface = surface;
    poll = ^{
        id<VibeDebugPlayerSurface> strong = weakSurface;
        if (!strong) {
            completion(VibeJSONString(@{@"error": @"controller went away"}));
            poll = nil;
            return;
        }
        NSDictionary *pending = VibePendingCounts(strong, [[strong debugPlayer] debugRenderCounts]);
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

#endif
