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
static NSMutableDictionary<NSString *, NSNumber *> *gMaxNanos;
static NSString *gLabel;
static uint64_t gWindowStart;

void VibeWorkTallyBeginWindow(const char *label) {
    os_unfair_lock_lock(&gTallyLock);
    gLabel = @(label);
    gWindowStart = VibeMonotonicNanos();
    gCounts = [NSMutableDictionary dictionary];
    gNanos = [NSMutableDictionary dictionary];
    gMaxNanos = [NSMutableDictionary dictionary];
    os_unfair_lock_unlock(&gTallyLock);
}

void VibeWorkTallyAdd(const char *name, uint64_t nanos) {
    os_unfair_lock_lock(&gTallyLock);
    if (gCounts) {
        NSString *key = @(name);
        gCounts[key] = @(gCounts[key].unsignedIntegerValue + 1);
        gNanos[key] = @(gNanos[key].unsignedLongLongValue + nanos);
        gMaxNanos[key] = @(MAX(gMaxNanos[key].unsignedLongLongValue, nanos));
    }
    os_unfair_lock_unlock(&gTallyLock);
}

NSDictionary *VibeWorkTallyTakeWindow(void) {
    os_unfair_lock_lock(&gTallyLock);
    NSString *label = gLabel;
    NSDictionary *counts = gCounts;
    NSDictionary *nanos = gNanos;
    NSDictionary *maxNanos = gMaxNanos;
    uint64_t elapsed = gWindowStart > 0 ? VibeMonotonicNanos() - gWindowStart : 0;
    gLabel = nil;
    gCounts = nil;
    gNanos = nil;
    gMaxNanos = nil;
    gWindowStart = 0;
    os_unfair_lock_unlock(&gTallyLock);

    NSMutableDictionary *work = [NSMutableDictionary dictionary];
    for (NSString *key in counts) {
        work[key] = @{@"count": counts[key],
                      @"totalMs": @([nanos[key] unsignedLongLongValue] / 1e6),
                      @"maxMs": @([maxNanos[key] unsignedLongLongValue] / 1e6)};
    }
    return @{@"active": @(counts != nil), @"label": label ?: @"",
             @"elapsedMs": @(elapsed / 1e6), @"work": work};
}

void VibeWorkTallyEndWindow(void) {
    NSDictionary *result = VibeWorkTallyTakeWindow();
    if (![result[@"active"] boolValue]) return;
    NSDictionary *work = result[@"work"];
    // Slowest total first: the ordering the reader wants is "what did this
    // window spend its main thread on", and a pure count sorts to the bottom
    // where it belongs.
    NSArray<NSString *> *keys = [work.allKeys sortedArrayUsingComparator:
            ^NSComparisonResult(NSString *a, NSString *b) {
        double na = [work[a][@"totalMs"] doubleValue];
        double nb = [work[b][@"totalMs"] doubleValue];
        if (na != nb) {
            return na > nb ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a compare:b];
    }];
    NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:keys.count];
    for (NSString *key in keys) {
        [rows addObject:[NSString stringWithFormat:@"%@ x%@ %.2fms", key, work[key][@"count"],
                                                   [work[key][@"totalMs"] doubleValue]]];
    }
    LogInfo(@"[tally] %@ over %.1fms: %@", result[@"label"], [result[@"elapsedMs"] doubleValue],
            rows.count ? [rows componentsJoinedByString:@", "] : @"(nothing)");
}

#endif
