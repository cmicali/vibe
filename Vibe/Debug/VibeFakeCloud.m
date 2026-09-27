//
//  VibeFakeCloud.m
//  Vibe
//

#import "VibeFakeCloud.h"

#if DEBUG

#import "CloudFileMaterializer+Debug.h"
#import "CloudFileMaterializer.h"
#import "DownloadProgressMonitor+Debug.h"
#import "NSURLUtil+Debug.h"
#import "NSURLUtil.h"

#include <os/lock.h>

// Touched from the metadata workers, the player's open queue and the channel's
// main thread at once, so all of it lives under one lock.
static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static BOOL sInstalled;
static NSUInteger sPercent;
// Paths whose download ran to term. They stop answering the probe, or a track
// would download forever and no run would settle.
static NSMutableSet<NSString *> *sMaterialized;
// Counted at the transfer, never at the probe, which is consulted at sites
// that download nothing.
static NSUInteger sCompleted, sCancelled;
// When each transfer in flight took its slot. A file's duration is a function
// of its path, so this is all the progress side needs.
static NSMutableDictionary<NSString *, NSNumber *> *sTransferStartedAt;
// Which roles hold a slot for each path right now, and how many times a
// METADATA transfer overlapped another transfer of the same file: the duplicate
// download path-wide single-flight prevents, invisible in every other counter
// because both transfers complete.
static NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *sInFlightRolesByPath;
static NSUInteger sMetadataOverlapTransfers;
// Transfers in flight per role, and how many times a metadata transfer took a
// slot while a playback or prefetch transfer held one. Both foreground roles
// close the background lane, so such a start means the hold failed, which no
// other counter shows. The reverse order is not counted: a metadata transfer
// running when a play is submitted is what the hold cancels, and it stays in
// flight while the cancel travels.
static NSMutableDictionary<NSString *, NSNumber *> *sInFlightByRole;
static NSUInteger sForegroundContentionStarts;
// The contention culprits, kept apart from the trace ring, which a churny run
// rotates past the one event the oracle fails on. Bounded; oldest dropped.
static NSMutableArray<NSDictionary *> *sContentionEvents;
static NSTimeInterval sBaseSeconds;
static BOOL sSticky;
static NSString *sFailBasename;
static NSUInteger sCapacity; // 0 is unlimited
static NSUInteger sExecuting, sQueued, sMaxObservedConcurrency;
static BOOL sUniform;
static VibeFakeCloudProgressMode sProgressMode;
static BOOL sUnflagged;
// Bounded; oldest dropped.
static NSMutableArray<NSDictionary *> *sTrace;
static NSUInteger sTraceSeq;
static CFAbsoluteTime sInstalledAt;

static const NSUInteger kTraceCapacity = 512;
static const NSUInteger kContentionEventCapacity = 32;
static const useconds_t kSlotPollMicroseconds = 20000;   // 20ms
static const NSTimeInterval kSparseProgressStepSeconds = 10.0;
static const double kStallProgressCeiling = 0.4;

static BOOL VibeFakeCloudRoleIsMetadata(NSString *role) {
    return [role hasPrefix:@"metadata"];
}

static BOOL VibeFakeCloudRolesContainMetadata(NSArray<NSString *> *roles) {
    for (NSString *role in roles) {
        if (VibeFakeCloudRoleIsMetadata(role)) {
            return YES;
        }
    }
    return NO;
}

// Stable across launches, so a seeded run picks the same placeholders and
// speeds. FNV-1a: convenience, not quality.
static uint64_t VibePathHash(NSString *path) {
    uint64_t hash = 1469598103934665603ULL;
    const char *bytes = path.fileSystemRepresentation;
    for (const char *c = bytes; c && *c; c++) {
        hash = (hash ^ (unsigned char)*c) * 1099511628211ULL;
    }
    return hash;
}

static BOOL VibePathIsCloud(NSString *path, NSUInteger percent) {
    if (percent >= 100) {
        return YES;
    }
    if (percent == 0) {
        return NO;
    }
    return (VibePathHash(path) % 100) < percent;
}

// The tail is the point. One file in ten is SLOW, so a listener gives up
// mid-transfer and a cancel lands inside a download rather than between two;
// one in fifty is STUCK past the player's open deadline, which nothing else
// reaches: the request abandoned while its worker is still blocked.
static const NSUInteger kSlowPercent = 10;
static const NSUInteger kStuckPercent = 2;
static const NSTimeInterval kSlowMultiplier = 18.0;
static const NSTimeInterval kStuckSeconds = 600.0;

// Uniform mode skips the spread, so ordering assertions need not fight the
// hash.
static NSTimeInterval VibeTransferSecondsForPath(NSString *path, NSTimeInterval base, BOOL uniform) {
    if (uniform) {
        return base;
    }
    uint64_t hash = VibePathHash(path);
    NSUInteger bucket = (hash / 100) % 100;   // independent of the cloud/local draw
    if (bucket < kStuckPercent) {
        return kStuckSeconds;
    }
    if (bucket < kStuckPercent + kSlowPercent) {
        return base * kSlowMultiplier;
    }
    // 0.5x to 2x.
    double spread = 0.5 + ((hash / 10000) % 150) / 100.0;
    return base * spread;
}

// The Hashed mode's fraction. Quantized to kProgressChunks because a real
// provider reports in ~1 Hz steps the indicator eases between (WaveformUI/
// CLAUDE.md); a per-tick ramp would exercise easing production never sees. A
// third of the corpus stalls partway and resumes, the only way to test that
// the fill never runs past what was reported. Which files stall, and where,
// come off the path hash.
static const NSUInteger kProgressChunks = 12;
static const NSUInteger kStallPercent = 33;
static const double kStallShareOfTransfer = 0.3;

static double VibeHashedProgressForPath(NSString *path, NSTimeInterval elapsed, NSTimeInterval total) {
    if (total <= 0 || elapsed <= 0) {
        return 0;
    }
    uint64_t hash = VibePathHash(path);
    // Its own decimal window, independent of the cloud draw and the speed
    // bucket.
    NSUInteger bucket = (hash / 1000000) % 100;
    double stallSeconds = 0, stallAt = 0, moving = total;
    if (bucket < kStallPercent) {
        stallSeconds = total * kStallShareOfTransfer;
        moving = total - stallSeconds;   // the transfer still takes `total` in all
        stallAt = 0.35 + (double)((hash / 100000000) % 40) / 100.0;
    }
    double fraction;
    double stallBegins = stallAt * moving;
    if (stallSeconds <= 0 || elapsed < stallBegins) {
        fraction = elapsed / moving;
    }
    else if (elapsed < stallBegins + stallSeconds) {
        fraction = stallAt;              // motionless, and the fill must stay put
    }
    else {
        fraction = (elapsed - stallSeconds) / moving;
    }
    fraction = MIN(1.0, MAX(0.0, fraction));
    // The last chunk is never rounded down, or a finished transfer would sit
    // at 11/12 for good.
    return fraction >= 1.0 ? 1.0 : floor(fraction * kProgressChunks) / kProgressChunks;
}

// The scripted modes; see VibeFakeCloudProgressMode.
static double VibeScriptedProgress(VibeFakeCloudProgressMode mode,
                                   NSTimeInterval elapsed, NSTimeInterval total) {
    if (total <= 0 || elapsed <= 0) {
        return 0;
    }
    switch (mode) {
        case VibeFakeCloudProgressNone:
            return 0;
        case VibeFakeCloudProgressLinear:
            return MIN(1.0, elapsed / total);
        case VibeFakeCloudProgressSparse: {
            NSTimeInterval stepped = floor(elapsed / kSparseProgressStepSeconds)
                    * kSparseProgressStepSeconds;
            return MIN(1.0, stepped / total);
        }
        case VibeFakeCloudProgressStall:
            return MIN(kStallProgressCeiling, elapsed / total);
        case VibeFakeCloudProgressHashed:
            return 0;   // unreached; the caller branches to the hashed path
    }
    return 0;
}

// Appends one trace event under sLock, already held by the caller.
static void VibeTraceLocked(NSString *event, NSString *role, NSString *path,
                            NSDictionary *extra) {
    if (!sTrace) {
        return;
    }
    NSMutableDictionary *entry = [@{
        @"seq": @(sTraceSeq++),
        @"tMs": @((NSUInteger)((CFAbsoluteTimeGetCurrent() - sInstalledAt) * 1000.0)),
        @"event": event,
        @"role": role ?: @"unlabeled",
        @"file": path.lastPathComponent ?: @"",
    } mutableCopy];
    [entry addEntriesFromDictionary:extra ?: @{}];
    [sTrace addObject:entry];
    if (sTrace.count > kTraceCapacity) {
        [sTrace removeObjectsInRange:NSMakeRange(0, sTrace.count - kTraceCapacity)];
    }
}

@implementation VibeFakeCloud

// The per-install configuration and counters, back to their defaults: an
// install describes a whole scenario, and a leftover mode would silently
// reshape it. Shared by install and uninstall so the two cannot drift. Caller
// holds sLock. The completed/cancelled tally deliberately survives both.
static void VibeResetScenarioLocked(void) {
    sPercent = 0;
    sBaseSeconds = 0;
    sSticky = NO;
    sFailBasename = nil;
    sCapacity = 1;
    sUniform = NO;
    sProgressMode = VibeFakeCloudProgressHashed;
    sUnflagged = NO;
    sMetadataOverlapTransfers = 0;
    sForegroundContentionStarts = 0;
    sExecuting = 0;
    sQueued = 0;
    sMaxObservedConcurrency = 0;
}

+ (void)installWithTransferSeconds:(NSTimeInterval)transferSeconds
                   datalessPercent:(NSUInteger)percent {
    os_unfair_lock_lock(&sLock);
    VibeResetScenarioLocked();
    sInstalled = YES;
    sPercent = percent;
    sBaseSeconds = transferSeconds;
    // Re-arming puts the corpus back in the cloud but keeps the tally, so a
    // run's final numbers cover the whole run, not just since the last re-arm.
    sMaterialized = [NSMutableSet set];
    sTransferStartedAt = [NSMutableDictionary dictionary];
    sInFlightRolesByPath = [NSMutableDictionary dictionary];
    sInFlightByRole = [NSMutableDictionary dictionary];
    sContentionEvents = [NSMutableArray array];
    sTrace = [NSMutableArray array];
    sTraceSeq = 0;
    sInstalledAt = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_unlock(&sLock);

    [NSURLUtil setDatalessProbe:^BOOL(NSURL *url) {
        NSString *path = url.path;
        if (!path) {
            return NO;
        }
        os_unfair_lock_lock(&sLock);
        // Unflagged: the probe answers NO while the transfer side keeps
        // working off the cloud draw, the mismatch the mode stages.
        BOOL dataless = !sUnflagged
                && (sSticky || ![sMaterialized containsObject:path])
                && VibePathIsCloud(path, sPercent);
        os_unfair_lock_unlock(&sLock);
        return dataless;
    }];

    [CloudFileMaterializer setFakeTransferProvider:^NSTimeInterval(NSURL *url, NSString *role) {
        NSString *path = url.path;
        if (!path) {
            return 0;
        }
        os_unfair_lock_lock(&sLock);
        // A completed transfer answers 0, so materializeURL:'s fake-first
        // ordering does not re-download a replayed file. Sticky re-downloads:
        // under test is that nothing ever reads as local.
        BOOL wants = (sSticky || ![sMaterialized containsObject:path])
                && VibePathIsCloud(path, sPercent);
        NSTimeInterval seconds = wants
                ? VibeTransferSecondsForPath(path, sBaseSeconds, sUniform) : 0;
        if (seconds > 0) {
            VibeTraceLocked(@"requested", role, path, nil);
        }
        BOOL fails = seconds > 0 && sFailBasename != nil
                && [path.lastPathComponent isEqualToString:sFailBasename];
        os_unfair_lock_unlock(&sLock);
        // Negative is the materializer's failure sentinel: run, then fail.
        return fails ? -seconds : seconds;
    }                                   acquireSlot:^BOOL(NSURL *url, NSString *role,
                                                          BOOL (^cancelled)(void)) {
        NSString *path = url.path ?: @"";
        os_unfair_lock_lock(&sLock);
        if (!sInstalled) {
            os_unfair_lock_unlock(&sLock);
            return NO;
        }
        sQueued++;
        CFAbsoluteTime queuedAt = CFAbsoluteTimeGetCurrent();
        os_unfair_lock_unlock(&sLock);
        for (;;) {
            if (cancelled()) {
                os_unfair_lock_lock(&sLock);
                // Balance only against a live install: uninstall already
                // zeroed the counters this acquire had incremented.
                if (sInstalled && sQueued > 0) {
                    sQueued--;
                }
                os_unfair_lock_unlock(&sLock);
                return NO;
            }
            os_unfair_lock_lock(&sLock);
            if (!sInstalled) {
                os_unfair_lock_unlock(&sLock);
                return NO;
            }
            if (sCapacity == 0 || sExecuting < sCapacity) {
                // Reserve the slot, then re-check cancel with no lock held
                // before the bookkeeping. The loop-top check is a poll
                // interval stale, and a cancel inside it would count as a
                // metadata transfer starting against the hold with no byte
                // moved; production's token check and transfer start share
                // one critical section. A cancel after this re-check is the
                // transfer genuinely starting first.
                sQueued--;
                sExecuting++;
                os_unfair_lock_unlock(&sLock);
                if (cancelled()) {
                    os_unfair_lock_lock(&sLock);
                    if (sInstalled && sExecuting > 0) {
                        sExecuting--;
                    }
                    os_unfair_lock_unlock(&sLock);
                    return NO;
                }
                os_unfair_lock_lock(&sLock);
                if (!sInstalled) {
                    os_unfair_lock_unlock(&sLock);
                    return NO;
                }
                sMaxObservedConcurrency = MAX(sMaxObservedConcurrency, sExecuting);
                // The clock starts at the slot, not the request: a queued
                // transfer reads as motionless. Only the first acquire for a
                // path stamps it, so an overlapping one cannot make reported
                // progress regress.
                if (!sTransferStartedAt[path]) {
                    sTransferStartedAt[path] = @(CFAbsoluteTimeGetCurrent());
                }
                NSString *whose = role ?: @"unlabeled";
                NSMutableArray<NSString *> *roles = sInFlightRolesByPath[path];
                if (!roles) {
                    roles = [NSMutableArray array];
                    sInFlightRolesByPath[path] = roles;
                }
                [roles addObject:whose];
                NSUInteger foregroundInFlight =
                        sInFlightByRole[@"playback"].unsignedIntegerValue
                        + sInFlightByRole[@"prefetch"].unsignedIntegerValue;
                sInFlightByRole[whose] = @(sInFlightByRole[whose].unsignedIntegerValue + 1);
                VibeTraceLocked(@"started", role, path, @{
                    @"queuedMs": @((NSUInteger)((CFAbsoluteTimeGetCurrent() - queuedAt) * 1000.0)),
                });
                if (roles.count > 1 && VibeFakeCloudRolesContainMetadata(roles)) {
                    sMetadataOverlapTransfers++;
                    VibeTraceLocked(@"overlap", role, path, @{@"roles": [roles copy]});
                }
                if (VibeFakeCloudRoleIsMetadata(whose) && foregroundInFlight > 0) {
                    sForegroundContentionStarts++;
                    if (sContentionEvents.count >= kContentionEventCapacity) {
                        [sContentionEvents removeObjectAtIndex:0];
                    }
                    [sContentionEvents addObject:@{
                        @"at": @(CFAbsoluteTimeGetCurrent() - sInstalledAt),
                        @"role": whose,
                        @"file": path.lastPathComponent ?: @"",
                        @"foregroundInFlight": @(foregroundInFlight),
                    }];
                    VibeTraceLocked(@"contention", role, path,
                                    @{@"foregroundInFlight": @(foregroundInFlight)});
                    // Warn level: the trace ring may rotate this event out.
                    LogWarn(@"Fake cloud contention: %@ transfer of %@ started with %lu foreground transfer(s) in flight",
                            whose, path.lastPathComponent, (unsigned long)foregroundInFlight);
                }
                os_unfair_lock_unlock(&sLock);
                return YES;
            }
            os_unfair_lock_unlock(&sLock);
            usleep(kSlotPollMicroseconds);
        }
    }                                   releaseSlot:^(NSURL *url, NSString *role) {
        NSString *path = url.path ?: @"";
        os_unfair_lock_lock(&sLock);
        // A transfer in flight across uninstall still calls these captured
        // blocks; its bookkeeping is already gone, so mutate nothing.
        if (!sInstalled) {
            os_unfair_lock_unlock(&sLock);
            return;
        }
        if (sExecuting > 0) {
            sExecuting--;
        }
        // Here, not in didFinish, which also fires for a transfer cancelled
        // while queued that never took a slot.
        NSString *whose = role ?: @"unlabeled";
        NSMutableArray<NSString *> *roles = sInFlightRolesByPath[path];
        NSUInteger which = [roles indexOfObject:whose];
        if (which != NSNotFound) {
            [roles removeObjectAtIndex:which];
        }
        NSUInteger byRole = sInFlightByRole[whose].unsignedIntegerValue;
        sInFlightByRole[whose] = @(byRole > 0 ? byRole - 1 : 0);
        if (roles.count == 0) {
            [sInFlightRolesByPath removeObjectForKey:path];
            [sTransferStartedAt removeObjectForKey:path];
        }
        os_unfair_lock_unlock(&sLock);
    }                                     didFinish:^(NSURL *url, NSString *role, BOOL completed) {
        NSString *path = url.path;
        if (!path) {
            return;
        }
        os_unfair_lock_lock(&sLock);
        if (!sInstalled) {
            os_unfair_lock_unlock(&sLock);
            return;
        }
        if (completed) {
            [sMaterialized addObject:path];
            sCompleted++;
        }
        else {
            sCancelled++;
        }
        VibeTraceLocked(completed ? @"completed" : @"cancelled", role, path, nil);
        os_unfair_lock_unlock(&sLock);
    }];

    // Negative is "not ours", which sends the monitor to its real sources;
    // zero is "ours, nothing yet", which leaves the shimmer indeterminate. A
    // real source would read the local file as an instant 100%.
    [DownloadProgressMonitor setFakeProgressProvider:^float(NSURL *url) {
        NSString *path = url.path;
        if (!path) {
            return -1;
        }
        os_unfair_lock_lock(&sLock);
        BOOL mine = VibePathIsCloud(path, sPercent);
        NSNumber *startedAt = mine ? sTransferStartedAt[path] : nil;
        NSTimeInterval total = startedAt
                ? VibeTransferSecondsForPath(path, sBaseSeconds, sUniform) : 0;
        VibeFakeCloudProgressMode mode = sProgressMode;
        os_unfair_lock_unlock(&sLock);
        if (!mine) {
            return -1;
        }
        if (!startedAt) {
            return 0;   // queued for the slot, or between transfers
        }
        NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - startedAt.doubleValue;
        if (mode == VibeFakeCloudProgressHashed) {
            return (float)VibeHashedProgressForPath(path, elapsed, total);
        }
        return (float)VibeScriptedProgress(mode, elapsed, total);
    }];
}

+ (void)setStickyDataless:(BOOL)sticky {
    os_unfair_lock_lock(&sLock);
    sSticky = sticky;
    os_unfair_lock_unlock(&sLock);
}

+ (void)setTransferCapacity:(NSUInteger)capacity {
    os_unfair_lock_lock(&sLock);
    sCapacity = capacity;
    os_unfair_lock_unlock(&sLock);
}

+ (void)setUniformDurations:(BOOL)uniform {
    os_unfair_lock_lock(&sLock);
    sUniform = uniform;
    os_unfair_lock_unlock(&sLock);
}

+ (void)setProgressMode:(VibeFakeCloudProgressMode)mode {
    os_unfair_lock_lock(&sLock);
    sProgressMode = mode;
    os_unfair_lock_unlock(&sLock);
}

+ (void)setUnflaggedPlaceholders:(BOOL)unflagged {
    os_unfair_lock_lock(&sLock);
    sUnflagged = unflagged;
    os_unfair_lock_unlock(&sLock);
}

+ (void)setFailingBasename:(NSString *)basename {
    os_unfair_lock_lock(&sLock);
    sFailBasename = [basename copy];
    os_unfair_lock_unlock(&sLock);
}

+ (void)uninstall {
    [NSURLUtil setDatalessProbe:nil];
    [CloudFileMaterializer setFakeTransferProvider:nil acquireSlot:nil
                                       releaseSlot:nil didFinish:nil];
    [DownloadProgressMonitor setFakeProgressProvider:nil];
    os_unfair_lock_lock(&sLock);
    sInstalled = NO;
    sMaterialized = nil;
    sTransferStartedAt = nil;
    sInFlightRolesByPath = nil;
    sInFlightByRole = nil;
    sContentionEvents = nil;
    sTrace = nil;
    // The captured blocks bail on !sInstalled, so a transfer still in flight
    // stops mutating stats here.
    VibeResetScenarioLocked();
    os_unfair_lock_unlock(&sLock);
}

+ (BOOL)isInstalled {
    os_unfair_lock_lock(&sLock);
    BOOL installed = sInstalled;
    os_unfair_lock_unlock(&sLock);
    return installed;
}

+ (NSDictionary *)statistics {
    static NSString *const modeNames[] = {@"hashed", @"none", @"linear", @"sparse", @"stall"};
    os_unfair_lock_lock(&sLock);
    NSDictionary *stats = @{
        @"installed": @(sInstalled),
        @"percent": @(sPercent),
        @"materialized": @(sMaterialized.count),
        @"completed": @(sCompleted),
        @"cancelled": @(sCancelled),
        @"sticky": @(sSticky),
        @"failingBasename": sFailBasename ?: @"",
        @"baseSeconds": @(sBaseSeconds),
        @"slowPercent": @(kSlowPercent),
        @"stuckPercent": @(kStuckPercent),
        @"capacity": @(sCapacity),
        @"uniform": @(sUniform),
        @"progressMode": modeNames[MIN((NSUInteger)sProgressMode, (NSUInteger)4)],
        @"unflagged": @(sUnflagged),
        @"executing": @(sExecuting),
        @"queued": @(sQueued),
        @"maxConcurrency": @(sMaxObservedConcurrency),
        @"metadataOverlapTransfers": @(sMetadataOverlapTransfers),
        @"foregroundContentionStarts": @(sForegroundContentionStarts),
        @"contentionEvents": [sContentionEvents copy] ?: @[],
        @"traceCount": @(sTrace.count),
    };
    os_unfair_lock_unlock(&sLock);
    return stats;
}

+ (NSArray<NSDictionary *> *)traceEvents {
    os_unfair_lock_lock(&sLock);
    NSArray *events = [sTrace copy] ?: @[];
    os_unfair_lock_unlock(&sLock);
    return events;
}

+ (void)clearTrace {
    os_unfair_lock_lock(&sLock);
    [sTrace removeAllObjects];
    os_unfair_lock_unlock(&sLock);
}

@end

#endif
