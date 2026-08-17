//
//  VibeWorkTally.m
//  Vibe
//
//  See VibeWorkTally.h.
//

#import "VibeWorkTally.h"

#if DEBUG

#import <os/lock.h>

// The bake's pixel pass runs on a global queue while everything else tallying
// is on main, so the table is locked rather than main-thread-only. Contention
// is two threads a few hundred times a window; an unfair lock is the cheapest
// thing that is actually correct here.
static os_unfair_lock gTallyLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, NSNumber *> *gCounts;
static NSMutableDictionary<NSString *, NSNumber *> *gNanos;
static NSString *gLabel;
static uint64_t gWindowStart;

void VibeWorkTallyBeginWindow(const char *label) {
    os_unfair_lock_lock(&gTallyLock);
    gLabel = @(label);
    gWindowStart = VibeMonotonicNanos();
    gCounts = [NSMutableDictionary dictionary];
    gNanos = [NSMutableDictionary dictionary];
    os_unfair_lock_unlock(&gTallyLock);
}

void VibeWorkTallyAdd(const char *name, uint64_t nanos) {
    os_unfair_lock_lock(&gTallyLock);
    if (gCounts) {
        NSString *key = @(name);
        gCounts[key] = @(gCounts[key].unsignedIntegerValue + 1);
        gNanos[key] = @(gNanos[key].unsignedLongLongValue + nanos);
    }
    os_unfair_lock_unlock(&gTallyLock);
}

void VibeWorkTallyEndWindow(void) {
    os_unfair_lock_lock(&gTallyLock);
    NSString *label = gLabel;
    NSDictionary *counts = gCounts;
    NSDictionary *nanos = gNanos;
    uint64_t elapsed = gWindowStart > 0 ? VibeMonotonicNanos() - gWindowStart : 0;
    gLabel = nil;
    gCounts = nil;
    gNanos = nil;
    gWindowStart = 0;
    os_unfair_lock_unlock(&gTallyLock);

    if (!counts) {
        return;
    }
    // Slowest total first: the ordering the reader wants is "what did this
    // window spend its main thread on", and a pure count sorts to the bottom
    // where it belongs.
    NSArray<NSString *> *keys = [counts.allKeys sortedArrayUsingComparator:
            ^NSComparisonResult(NSString *a, NSString *b) {
        unsigned long long na = [nanos[a] unsignedLongLongValue];
        unsigned long long nb = [nanos[b] unsignedLongLongValue];
        if (na != nb) {
            return na > nb ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a compare:b];
    }];
    NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:keys.count];
    for (NSString *key in keys) {
        [rows addObject:[NSString stringWithFormat:@"%@ x%@ %.2fms", key, counts[key],
                                                   [nanos[key] unsignedLongLongValue] / 1e6]];
    }
    LogInfo(@"[tally] %@ over %.1fms: %@", label, elapsed / 1e6,
            rows.count ? [rows componentsJoinedByString:@", "] : @"(nothing)");
}

#endif
