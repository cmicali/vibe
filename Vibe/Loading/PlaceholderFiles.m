//
//  PlaceholderFiles.m
//  Vibe
//

#import "PlaceholderFiles.h"
#import "PlaceholderFiles+Debug.h"   // the dataless probe, declared out of the shipping header
#import "FilePaths.h"
#import "PlayableExtensions.h"

#include <os/lock.h>
#include <stdatomic.h>
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
    VibeDatalessProbe probe = VibeDatalessProbeHook();
    if (probe) {
        return probe(url);
    }
#endif
    struct stat st;
    if (stat(url.fileSystemRepresentation, &st) != 0) {
#if DEBUG
        if (atomic_load_explicit(&VibeDatalessDiagEnabled, memory_order_relaxed)) {
            VibeRecordDatalessStat(url, NO, 0, YES);
        }
#endif
        return NO;
    }
    BOOL dataless = (st.st_flags & SF_DATALESS) != 0
            || (VibeFileModeIsRemotePlaceholder(st.st_mode) && VibePathIsUnderRemotePlaceholderRoot(url.path));
#if DEBUG
    if (atomic_load_explicit(&VibeDatalessDiagEnabled, memory_order_relaxed)) {
        VibeRecordDatalessStat(url, dataless, st.st_flags, NO);
    }
#endif
    return dataless;
}

@end
