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
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *gWork;
static NSString *gLabel;
static uint64_t gWindowStart;

void VibeWorkTallyBeginWindow(const char *label) {
    os_unfair_lock_lock(&gTallyLock);
    gLabel = @(label);
    gWindowStart = VibeMonotonicNanos();
    gWork = [NSMutableDictionary dictionary];
    os_unfair_lock_unlock(&gTallyLock);
}

void VibeWorkTallyAdd(const char *name, uint64_t nanos) {
    os_unfair_lock_lock(&gTallyLock);
    if (gWork) {
        NSString *key = @(name);
        NSMutableDictionary *entry = gWork[key];
        if (!entry) gWork[key] = entry = [NSMutableDictionary dictionary];
        entry[@"count"] = @([entry[@"count"] unsignedIntegerValue] + 1);
        entry[@"nanos"] = @([entry[@"nanos"] unsignedLongLongValue] + nanos);
        entry[@"maxNanos"] = @(MAX([entry[@"maxNanos"] unsignedLongLongValue], nanos));
    }
    os_unfair_lock_unlock(&gTallyLock);
}

NSDictionary *VibeWorkTallyTakeWindow(void) {
    os_unfair_lock_lock(&gTallyLock);
    NSString *label = gLabel;
    NSDictionary *entries = gWork;
    uint64_t elapsed = gWindowStart > 0 ? VibeMonotonicNanos() - gWindowStart : 0;
    gLabel = nil;
    gWork = nil;
    gWindowStart = 0;
    os_unfair_lock_unlock(&gTallyLock);

    NSMutableDictionary *work = [NSMutableDictionary dictionary];
    for (NSString *key in entries) {
        NSDictionary *entry = entries[key];
        work[key] = @{@"count": entry[@"count"],
                      @"totalMs": @([entry[@"nanos"] unsignedLongLongValue] / 1e6),
                      @"maxMs": @([entry[@"maxNanos"] unsignedLongLongValue] / 1e6)};
    }
    return @{@"active": @(entries != nil), @"label": label ?: @"",
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
