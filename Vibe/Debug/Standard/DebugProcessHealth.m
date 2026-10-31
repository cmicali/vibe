//
//  DebugProcessHealth.m
//  vibe-libs
//

#import "DebugProcessHealth.h"

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

// A leaked file handle or an unclosed cache shows here long before it shows in
// the footprint.
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

// Sums every registered zone.
void VibeDebugMallocBytes(uint64_t *live, uint64_t *reserved) {
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

#pragma mark - Layers

NSUInteger VibeDebugLayerCount(CALayer *layer) {
    NSUInteger total = 1;
    for (CALayer *sub in layer.sublayers) {
        total += VibeDebugLayerCount(sub);
    }
    return total;
}

#pragma mark - The process block

NSDictionary<NSString *, NSNumber *> *VibeDebugProcessHealth(void) {
    NSMutableDictionary<NSString *, NSNumber *> *process = [NSMutableDictionary dictionary];
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
    VibeDebugMallocBytes(&mallocLive, &mallocReserved);
    process[@"mallocLiveBytes"] = @(mallocLive);
    process[@"mallocReservedBytes"] = @(mallocReserved);
    process[@"threads"] = @(VibeThreadCount());
    process[@"fileDescriptors"] = @(VibeOpenFileDescriptorCount());
    process[@"machPorts"] = @(VibeMachPortCount());
    process[@"uptimeSeconds"] = @(VibeDebugUptimeSeconds());
    return process;
}

#endif
