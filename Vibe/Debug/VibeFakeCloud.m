//
//  VibeFakeCloud.m
//  Vibe
//

#import "VibeFakeCloud.h"

#if DEBUG

#import "CloudFileMaterializer+Debug.h"
#import "CloudFileMaterializer.h"
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
        os_unfair_lock_unlock(&sLock);
        return seconds;
    }                                    didFinish:^(NSURL *url, BOOL completed) {
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
        os_unfair_lock_unlock(&sLock);
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
    os_unfair_lock_lock(&sLock);
    sInstalled = NO;
    sMaterialized = nil;
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
