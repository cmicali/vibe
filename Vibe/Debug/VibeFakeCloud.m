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

// Everything below is touched from the metadata workers, the player's open
// queue and the debug channel's main thread at once, so it all lives under one
// lock. Contention is nil: the probe is a set lookup.
static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static BOOL sInstalled;
static NSUInteger sPercent;
// Paths whose download has run to term. A materialized file stops answering
// the probe, or the same track would download forever and no run would ever
// settle.
static NSMutableSet<NSString *> *sMaterialized;
// Counted at the transfer, never at the probe: the probe is consulted at
// several sites that lead to no download at all — the loader's lane routing,
// the priority lane's skip, the player's open — so probe hits are not attempts.
static NSUInteger sCompleted, sCancelled;
// When each transfer in flight began, which is the whole of what the progress
// side needs: how long a file takes is already a function of its path, so
// elapsed-over-total is the fraction. Stamped when the transfer takes the
// shared slot — a transfer queued for capacity has not begun — and dropped
// when that download ends either way.
static NSMutableDictionary<NSString *, NSNumber *> *sTransferStartedAt;
// Which roles hold a slot for each path right now, and how many times a
// METADATA transfer overlapped another transfer of the same file. That overlap
// is the duplicate whole-file download the lane's stand-aside exists to
// prevent, and it is invisible in every other counter here: both transfers
// complete, so the tally reads as ordinary work.
//
// TRAP: a plain same-path overlap is NOT a defect. A prefetch already
// materializing a file the user then plays is a designed race — purpose-keyed
// claims, whichever open finishes first consumes the play request (Audio/
// CLAUDE.md) — so counting every duplicate would fire on ordinary playback of
// a prefetched cloud track. Only the metadata lane is supposed to stand aside.
static NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *sInFlightRolesByPath;
static NSUInteger sMetadataOverlapTransfers;
// How many transfers of each role are in flight across all paths, and how many
// times a metadata transfer took a slot while a PLAYBACK transfer already held
// one. That is the foreground hold's whole job stated as a number: from play
// submission until the open settles the background lane is closed, so a
// background download beginning inside that window means the hold was lost —
// whichever edge lost it. It is the one symptom every lost-release bug shares,
// and no other counter shows it.
//
// The reverse order is NOT counted and must not be: a metadata transfer already
// running when a play is submitted is exactly what the hold cancels, and it is
// still briefly in flight while that cancel travels.
static NSMutableDictionary<NSString *, NSNumber *> *sInFlightByRole;
static NSUInteger sForegroundContentionStarts;
static NSTimeInterval sBaseSeconds;
// Fault injection; see setStickyDataless:.
static BOOL sSticky;
// The provider's scarce resource; 0 is unlimited. See setTransferCapacity:.
static NSUInteger sCapacity;
static NSUInteger sExecuting, sQueued, sMaxObservedConcurrency;
// Determinism switches; see the header.
static BOOL sUniform;
static VibeFakeCloudProgressMode sProgressMode;
static BOOL sUnflagged;
// The admission trace: a bounded ring of event dictionaries, oldest dropped.
static NSMutableArray<NSDictionary *> *sTrace;
static NSUInteger sTraceSeq;
static CFAbsoluteTime sInstalledAt;

static const NSUInteger kTraceCapacity = 512;
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

// Stable across launches and across runs, so a seeded run picks the same files
// as placeholders and gives them the same speeds. FNV-1a over the path: a hash
// of convenience, not of quality.
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

// A real folder is not uniform, and the interesting cases live in its tail.
// One in ten files is SLOW — long enough that a listener gives up and taps
// something else, which is what puts a cancel in the middle of a transfer
// rather than between two — and one in fifty is effectively STUCK, long enough
// to outlast the player's own open deadline. Nothing else reaches that
// deadline: it is the path where the request is abandoned while its worker is
// still blocked, which is exactly the case the materializer was added to make
// survivable.
static const NSUInteger kSlowPercent = 10;
static const NSUInteger kStuckPercent = 2;
static const NSTimeInterval kSlowMultiplier = 18.0;
static const NSTimeInterval kStuckSeconds = 600.0;

// The file's own transfer time, spread around the base so that a folder has a
// range rather than one speed. Uniform mode skips the whole spread; ordering
// assertions must not fight the hash.
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
    // 0.5x to 2x, so the ordinary files still differ from each other.
    double spread = 0.5 + ((hash / 10000) % 150) / 100.0;
    return base * spread;
}

// How far a transfer that began elapsed seconds ago has got, in the default
// Hashed mode. Two things it is deliberately not: smooth, and linear in the
// time elapsed.
//
// Not smooth, because a real provider's fraction arrives as ~1 Hz steps and
// the indicator eases between them (WaveformUI/CLAUDE.md) — a ramp fed a
// per-tick 1% would exercise an easing production never sees. So the answer is
// quantized to kProgressChunks.
//
// And a third of the corpus STALLS partway, because "the fill never runs past
// what was reported, leaving a stall honest" is a rule with no other way to
// test it: it needs a transfer that stops moving and then resumes. Which files
// stall, and where, come off the path hash like everything else here, so a
// file behaves the same on every run.
static const NSUInteger kProgressChunks = 12;
static const NSUInteger kStallPercent = 33;
static const double kStallShareOfTransfer = 0.3;

static double VibeHashedProgressForPath(NSString *path, NSTimeInterval elapsed, NSTimeInterval total) {
    if (total <= 0 || elapsed <= 0) {
        return 0;
    }
    uint64_t hash = VibePathHash(path);
    // Its own decimal window, so stalling is independent of the cloud draw and
    // of the speed bucket.
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

+ (void)installWithTransferSeconds:(NSTimeInterval)transferSeconds
                   datalessPercent:(NSUInteger)percent {
    os_unfair_lock_lock(&sLock);
    sInstalled = YES;
    sPercent = percent;
    sBaseSeconds = transferSeconds;
    // Re-arming forgets what had materialized — that is the point of a churn,
    // it puts the corpus back in the cloud — but deliberately NOT the tally.
    // Resetting that made a run's final numbers cover only since the last
    // re-arm, which read as "almost nothing downloaded" on a run that had
    // downloaded plenty.
    sMaterialized = [NSMutableSet set];
    sTransferStartedAt = [NSMutableDictionary dictionary];
    sInFlightRolesByPath = [NSMutableDictionary dictionary];
    sMetadataOverlapTransfers = 0;
    sInFlightByRole = [NSMutableDictionary dictionary];
    sForegroundContentionStarts = 0;
    sSticky = NO;
    // Every determinism switch resets: an install describes a whole scenario,
    // and a leftover mode from the previous one would silently reshape it.
    sCapacity = 1;
    sUniform = NO;
    sProgressMode = VibeFakeCloudProgressHashed;
    sUnflagged = NO;
    sTrace = [NSMutableArray array];
    sTraceSeq = 0;
    sInstalledAt = CFAbsoluteTimeGetCurrent();
    sExecuting = 0;
    sQueued = 0;
    sMaxObservedConcurrency = 0;
    os_unfair_lock_unlock(&sLock);

    [NSURLUtil setDatalessProbe:^BOOL(NSURL *url) {
        NSString *path = url.path;
        if (!path) {
            return NO;
        }
        os_unfair_lock_lock(&sLock);
        // Unflagged mode is the whole probe answering NO: the kernel flag a
        // provider never set. The transfer side keeps working off the cloud
        // draw, which is exactly the mismatch the mode exists to stage.
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
        // A completed transfer answers 0, which is what keeps the fake-first
        // ordering in materializeURL: from re-downloading a replayed file.
        // Sticky deliberately re-downloads: the probe never clears, and the
        // shape under test is exactly that nothing ever reads as local.
        BOOL wants = (sSticky || ![sMaterialized containsObject:path])
                && VibePathIsCloud(path, sPercent);
        NSTimeInterval seconds = wants
                ? VibeTransferSecondsForPath(path, sBaseSeconds, sUniform) : 0;
        if (seconds > 0) {
            VibeTraceLocked(@"requested", role, path, nil);
        }
        os_unfair_lock_unlock(&sLock);
        return seconds;
    }                                   acquireSlot:^BOOL(NSURL *url, NSString *role,
                                                          BOOL (^cancelled)(void)) {
        NSString *path = url.path ?: @"";
        os_unfair_lock_lock(&sLock);
        sQueued++;
        CFAbsoluteTime queuedAt = CFAbsoluteTimeGetCurrent();
        os_unfair_lock_unlock(&sLock);
        for (;;) {
            if (cancelled()) {
                os_unfair_lock_lock(&sLock);
                sQueued--;
                os_unfair_lock_unlock(&sLock);
                return NO;
            }
            os_unfair_lock_lock(&sLock);
            if (sCapacity == 0 || sExecuting < sCapacity) {
                sQueued--;
                sExecuting++;
                sMaxObservedConcurrency = MAX(sMaxObservedConcurrency, sExecuting);
                // The transfer's clock starts when it takes the slot, never
                // when it asked: a queued transfer has not begun, and the
                // progress side must read it as motionless.
                sTransferStartedAt[path] = @(CFAbsoluteTimeGetCurrent());
                NSString *whose = role ?: @"unlabeled";
                NSMutableArray<NSString *> *roles = sInFlightRolesByPath[path];
                if (!roles) {
                    roles = [NSMutableArray array];
                    sInFlightRolesByPath[path] = roles;
                }
                [roles addObject:whose];
                NSUInteger playbackInFlight = sInFlightByRole[@"playback"].unsignedIntegerValue;
                sInFlightByRole[whose] = @(sInFlightByRole[whose].unsignedIntegerValue + 1);
                VibeTraceLocked(@"started", role, path, @{
                    @"queuedMs": @((NSUInteger)((CFAbsoluteTimeGetCurrent() - queuedAt) * 1000.0)),
                });
                if (roles.count > 1 && VibeFakeCloudRolesContainMetadata(roles)) {
                    sMetadataOverlapTransfers++;
                    VibeTraceLocked(@"overlap", role, path, @{@"roles": [roles copy]});
                }
                if (VibeFakeCloudRoleIsMetadata(whose) && playbackInFlight > 0) {
                    sForegroundContentionStarts++;
                    VibeTraceLocked(@"contention", role, path,
                                    @{@"playbackInFlight": @(playbackInFlight)});
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
        if (sExecuting > 0) {
            sExecuting--;
        }
        // Paired with the acquire that stamped them, which is why both live
        // here and not in didFinish: didFinish also fires for a transfer
        // cancelled while still queued, which never took a slot.
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

    // The determinate half of the loading indicator. Negative is "not a file
    // of ours", which sends the monitor to its real sources; zero is "mine,
    // but nothing to report yet", which leaves the shimmer indeterminate —
    // the distinction matters, because a real local file's poll answers an
    // instant 100% and would fill the bar before the transfer had begun.
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
    sTrace = nil;
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
