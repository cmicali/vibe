//
//  PlaceholderFiles+Debug.m
//  Vibe
//

#import "PlaceholderFiles+Debug.h"

#if DEBUG

#include <errno.h>
#include <string.h>
#include <sys/mount.h>

static VibeDatalessProbe sDatalessProbe;

VibeDatalessProbe VibeDatalessProbeHook(void) {
    @synchronized (PlaceholderFiles.class) {
        return sDatalessProbe;
    }
}

// See PlaceholderFiles+Debug.h. Behind an atomic flag, so the stat path pays
// one relaxed load while it is off.
_Atomic(BOOL) VibeDatalessDiagEnabled;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *sDatalessDiag;
static NSUInteger sDatalessDiagOverflow;
static const NSUInteger kDatalessDiagDirectoryCap = 128;

void VibeRecordDatalessStat(NSURL *url, BOOL dataless, uint32_t flags, BOOL statFailed) {
    NSString *directory = url.URLByDeletingLastPathComponent.path ?: @"?";
    NSString *bucket = statFailed ? @"statFailed" : (dataless ? @"dataless" : @"local");
    NSMutableDictionary *added = nil;
    @synchronized (PlaceholderFiles.class) {
        NSMutableDictionary *entry = sDatalessDiag[directory];
        if (!entry) {
            if (sDatalessDiag.count >= kDatalessDiagDirectoryCap) {
                sDatalessDiagOverflow++;
                return;
            }
            entry = [@{@"dataless": @0, @"local": @0, @"statFailed": @0} mutableCopy];
            sDatalessDiag[directory] = entry;
            added = entry;
        }
        entry[bucket] = @([entry[bucket] unsignedIntegerValue] + 1);
        if (!statFailed) {
            entry[@"lastFlags"] = [NSString stringWithFormat:@"0x%x", flags];
        }
    }
    if (!added) {
        return;
    }
    // Once per directory, outside the lock: a network mount can be slow to
    // answer. This is the phone's report, since no channel reaches a device.
    struct statfs fs;
    if (statfs(url.fileSystemRepresentation, &fs) != 0) {
        LogInfo(@"Dataless diag: %@: %@, flags 0x%x, no mount (%s)", directory, bucket, flags, strerror(errno));
        return;
    }
    BOOL localMount = (fs.f_flags & MNT_LOCAL) != 0;
    @synchronized (PlaceholderFiles.class) {
        added[@"fsType"] = @(fs.f_fstypename);
        added[@"mountedOn"] = @(fs.f_mntonname);
        added[@"localMount"] = @(localMount);
    }
    LogInfo(@"Dataless diag: %@: %@, flags 0x%x, %s mounted on %s, %@",
            directory, bucket, flags, fs.f_fstypename, fs.f_mntonname, localMount ? @"local mount" : @"network mount");
}

@implementation PlaceholderFiles (Debug)

+ (void)setDatalessProbe:(VibeDatalessProbe)probe {
    @synchronized (self) {
        sDatalessProbe = [probe copy];
    }
}

+ (void)setDatalessDiagnosticsEnabled:(BOOL)enabled {
    @synchronized (self) {
        sDatalessDiag = enabled ? [NSMutableDictionary dictionary] : nil;
        sDatalessDiagOverflow = 0;
    }
    atomic_store_explicit(&VibeDatalessDiagEnabled, enabled, memory_order_relaxed);
}

+ (NSDictionary *)datalessDiagnostics {
    @synchronized (self) {
        return @{
            @"enabled": @(atomic_load_explicit(&VibeDatalessDiagEnabled, memory_order_relaxed)),
            @"directories": [sDatalessDiag copy] ?: @{},
            @"overflowed": @(sDatalessDiagOverflow),
        };
    }
}

@end

#endif
