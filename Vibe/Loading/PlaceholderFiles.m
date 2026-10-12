//
//  PlaceholderFiles.m
//  Vibe
//

#import "PlaceholderFiles.h"
#if DEBUG
#import "PlaceholderFiles+Debug.h"   // the dataless probe, declared out of the shipping header
#endif
#import "FilePaths.h"
#import "PlayableExtensions.h"

#include <errno.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>

// The remote backends' roots as comparable paths ending in "/", set at
// launch. None means no file is a placeholder.
static os_unfair_lock sRemoteRootLock = OS_UNFAIR_LOCK_INIT;
static NSArray<NSString *> *sRemoteRootPrefixes;

static NSArray<NSString *> *VibeRemoteRootPrefixes(void) {
    os_unfair_lock_lock(&sRemoteRootLock);
    NSArray<NSString *> *prefixes = sRemoteRootPrefixes;
    os_unfair_lock_unlock(&sRemoteRootLock);
    return prefixes;
}

BOOL VibePathIsUnderRemotePlaceholderRoot(NSString *path) {
    NSArray<NSString *> *prefixes = VibeRemoteRootPrefixes();
    if (prefixes.count == 0) {
        return NO;
    }
    NSString *comparable = VibeComparablePath(path);
    for (NSString *prefix in prefixes) {
        if ([comparable hasPrefix:prefix]) {
            return YES;
        }
    }
    return NO;
}

#if DEBUG
static VibeDatalessProbe sDatalessProbe;

static VibeDatalessProbe DatalessProbe(void) {
    @synchronized (PlaceholderFiles.class) {
        return sDatalessProbe;
    }
}

// See PlaceholderFiles+Debug.h. Behind an atomic flag, so the stat path pays
// one relaxed load while it is off.
static _Atomic(BOOL) sDatalessDiagEnabled;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *sDatalessDiag;
static NSUInteger sDatalessDiagOverflow;
static const NSUInteger kDatalessDiagDirectoryCap = 128;

static void VibeRecordDatalessStat(NSURL *url, BOOL dataless, uint32_t flags, BOOL statFailed) {
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
#endif


@implementation PlaceholderFiles

+ (void)setRemotePlaceholderRoots:(NSArray<NSURL *> *)roots {
    NSMutableArray<NSString *> *prefixes = [NSMutableArray arrayWithCapacity:roots.count];
    for (NSURL *root in roots) {
        [prefixes addObject:[VibeComparablePath(root.path) stringByAppendingString:@"/"]];
    }
    os_unfair_lock_lock(&sRemoteRootLock);
    sRemoteRootPrefixes = prefixes.count ? [prefixes copy] : nil;
    os_unfair_lock_unlock(&sRemoteRootLock);
}

// The path first: a file under no root, as most are, pays no stat.
+ (BOOL)isRemotePlaceholderFile:(NSURL *)url {
    if (!VibePathIsUnderRemotePlaceholderRoot(url.path)) {
        return NO;
    }
    struct stat st;
    return stat(url.fileSystemRepresentation, &st) == 0 && VibeFileModeIsRemotePlaceholder(st.st_mode);
}

+ (BOOL)readsRemotePlaceholderByRange:(NSURL *)url {
    return [PlaceholderFiles isRemotePlaceholderFile:url]
            && [PlayableExtensions.tagParsed containsObject:url.pathExtension.lowercaseString];
}

NSString *const VibeRemotePlaceholderPartSuffix = @".vibe-download";

+ (NSURL *)remotePlaceholderPartURL:(NSURL *)url {
    NSString *name = [NSString stringWithFormat:@".%@%@", url.lastPathComponent, VibeRemotePlaceholderPartSuffix];
    return [url.URLByDeletingLastPathComponent URLByAppendingPathComponent:name isDirectory:NO];
}

#if DEBUG
+ (void)setDatalessProbe:(VibeDatalessProbe)probe {
    @synchronized (self) {
        sDatalessProbe = [probe copy];
    }
}
#endif

// TRAP: never second-guess SF_DATALESS with an NSURL resource value
// (NSURLUbiquitousItemDownloadingStatus or any other). NSURL memoizes them per
// instance, and these URLs live as long as their AudioTrack, so a placeholder
// would read "not downloaded" forever and the metadata loader's locality
// re-probes would never see it turn local.
//
// A provider whose placeholders carry no flag would read as local: the sweep
// would parse them on its local workers, several downloads at once outside the
// foreground hold. Fix it here, with a round trip per directory, not per file.
+ (BOOL)isDatalessFile:(NSURL *)url {
#if DEBUG
    VibeDatalessProbe probe = DatalessProbe();
    if (probe) {
        return probe(url);
    }
#endif
    struct stat st;
    if (stat(url.fileSystemRepresentation, &st) != 0) {
#if DEBUG
        if (atomic_load_explicit(&sDatalessDiagEnabled, memory_order_relaxed)) {
            VibeRecordDatalessStat(url, NO, 0, YES);
        }
#endif
        return NO;
    }
    BOOL dataless = (st.st_flags & SF_DATALESS) != 0
            || (VibeFileModeIsRemotePlaceholder(st.st_mode) && VibePathIsUnderRemotePlaceholderRoot(url.path));
#if DEBUG
    if (atomic_load_explicit(&sDatalessDiagEnabled, memory_order_relaxed)) {
        VibeRecordDatalessStat(url, dataless, st.st_flags, NO);
    }
#endif
    return dataless;
}

#if DEBUG
+ (void)setDatalessDiagnosticsEnabled:(BOOL)enabled {
    @synchronized (self) {
        sDatalessDiag = enabled ? [NSMutableDictionary dictionary] : nil;
        sDatalessDiagOverflow = 0;
    }
    atomic_store_explicit(&sDatalessDiagEnabled, enabled, memory_order_relaxed);
}

+ (NSDictionary *)datalessDiagnostics {
    @synchronized (self) {
        return @{
            @"enabled": @(atomic_load_explicit(&sDatalessDiagEnabled, memory_order_relaxed)),
            @"directories": [sDatalessDiag copy] ?: @{},
            @"overflowed": @(sDatalessDiagOverflow),
        };
    }
}
#endif

@end
