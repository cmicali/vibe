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
// elapsed-over-total is the fraction. Stamped in the transfer provider, which
// is asked exactly once per download and at its start, and dropped when that
// download ends either way.
static NSMutableDictionary<NSString *, NSNumber *> *sTransferStartedAt;
static NSTimeInterval sBaseSeconds;
// Fault injection; see setStickyDataless:.
static BOOL sSticky;

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
// to outlast the player's own open timeout (20s on macOS, 60s on iOS). Nothing
// else reaches that timeout: it is the path where the request is abandoned
// while its worker is still blocked, which is exactly the case the materializer
// was added to make survivable.
static const NSUInteger kSlowPercent = 10;
static const NSUInteger kStuckPercent = 2;
static const NSTimeInterval kSlowMultiplier = 18.0;
static const NSTimeInterval kStuckSeconds = 600.0;

// The file's own transfer time, spread around the base so that a folder has a
// range rather than one speed.
static NSTimeInterval VibeTransferSecondsForPath(NSString *path, NSTimeInterval base) {
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

// How far a transfer that began elapsed seconds ago has got. Two things it is
// deliberately not: smooth, and linear in the time elapsed.
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

static double VibeProgressForPath(NSString *path, NSTimeInterval elapsed, NSTimeInterval total) {
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
    sSticky = NO;
    os_unfair_lock_unlock(&sLock);

    [NSURLUtil setDatalessProbe:^BOOL(NSURL *url) {
        NSString *path = url.path;
        if (!path) {
            return NO;
        }
        os_unfair_lock_lock(&sLock);
        BOOL dataless = (sSticky || ![sMaterialized containsObject:path])
                && VibePathIsCloud(path, sPercent);
        os_unfair_lock_unlock(&sLock);
        return dataless;
    }];

    [CloudFileMaterializer setFakeTransferProvider:^NSTimeInterval(NSURL *url) {
        NSString *path = url.path;
        if (!path) {
            return 0;
        }
        os_unfair_lock_lock(&sLock);
        NSTimeInterval seconds = VibePathIsCloud(path, sPercent)
                ? VibeTransferSecondsForPath(path, sBaseSeconds) : 0;
        // Asked once per download, at its start, so this call IS the stamp the
        // progress side reads. A file that is not ours gets none.
        if (seconds > 0) {
            sTransferStartedAt[path] = @(CFAbsoluteTimeGetCurrent());
        }
        os_unfair_lock_unlock(&sLock);
        return seconds;
    }                                    didFinish:^(NSURL *url, BOOL completed) {
        NSString *path = url.path;
        if (!path) {
            return;
        }
        os_unfair_lock_lock(&sLock);
        [sTransferStartedAt removeObjectForKey:path];
        if (completed) {
            [sMaterialized addObject:path];
            sCompleted++;
        }
        else {
            sCancelled++;
        }
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
        NSTimeInterval total = startedAt ? VibeTransferSecondsForPath(path, sBaseSeconds) : 0;
        os_unfair_lock_unlock(&sLock);
        if (!mine) {
            return -1;
        }
        if (!startedAt) {
            return 0;   // between transfers: no download of ours is in flight
        }
        return (float)VibeProgressForPath(path,
                CFAbsoluteTimeGetCurrent() - startedAt.doubleValue, total);
    }];
}

+ (void)setStickyDataless:(BOOL)sticky {
    os_unfair_lock_lock(&sLock);
    sSticky = sticky;
    os_unfair_lock_unlock(&sLock);
}

+ (void)uninstall {
    [NSURLUtil setDatalessProbe:nil];
    [CloudFileMaterializer setFakeTransferProvider:nil didFinish:nil];
    [DownloadProgressMonitor setFakeProgressProvider:nil];
    os_unfair_lock_lock(&sLock);
    sInstalled = NO;
    sMaterialized = nil;
    sTransferStartedAt = nil;
    os_unfair_lock_unlock(&sLock);
}

+ (BOOL)isInstalled {
    os_unfair_lock_lock(&sLock);
    BOOL installed = sInstalled;
    os_unfair_lock_unlock(&sLock);
    return installed;
}

+ (NSDictionary *)statistics {
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
    };
    os_unfair_lock_unlock(&sLock);
    return stats;
}

@end

#endif
