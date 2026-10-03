//
//  NSURLUtil.m
//  Vibe
//

#import "NSURLUtilInternal.h"
#if DEBUG
#import "NSURLUtil+Debug.h"   // the dataless probe, declared out of the shipping header
#endif
#import "AudioTrack.h"
#import "FolderArtRules.h"
#import "NSURL+AudioOpen.h"
#import "PlayableExtensions.h"
#import "PlaylistFile.h"

#include <errno.h>
#include <limits.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

// The remote backend's root as a comparable path ending in "/", set at
// launch. Nil (the mac) means no file is a placeholder.
static os_unfair_lock sRemoteRootLock = OS_UNFAIR_LOCK_INIT;
static NSString *sRemoteRootPrefix;

static NSString *VibeRemoteRootPrefix(void) {
    os_unfair_lock_lock(&sRemoteRootLock);
    NSString *prefix = sRemoteRootPrefix;
    os_unfair_lock_unlock(&sRemoteRootLock);
    return prefix;
}

NSString *VibeComparablePath(NSString *path) {
    NSString *standard = path.stringByStandardizingPath;
    if ([standard hasPrefix:@"/private/var/"]) {
        return [standard substringFromIndex:@"/private".length];
    }
    return standard;
}

BOOL VibePathIsUnderRemotePlaceholderRoot(NSString *path) {
    NSString *prefix = VibeRemoteRootPrefix();
    return prefix && [VibeComparablePath(path) hasPrefix:prefix];
}

// Installed at launch, read from the expansion workers: every access locks.
static VibePlaylistFolderGrantHandler sPlaylistFolderGrantHandler;
static VibeWalkedDirectoriesHandler sWalkedDirectoriesHandler;
static VibeBulkOpenDirectoriesHandler sBulkOpenDirectoriesHandler;

#if DEBUG
static VibeDatalessProbe sDatalessProbe;

static VibeDatalessProbe DatalessProbe(void) {
    @synchronized (NSURLUtil.class) {
        return sDatalessProbe;
    }
}

// See NSURLUtil+Debug.h. Behind an atomic flag, so the stat path pays one
// relaxed load while it is off.
static _Atomic(BOOL) sDatalessDiagEnabled;
static NSMutableDictionary<NSString *, NSMutableDictionary *> *sDatalessDiag;
static NSUInteger sDatalessDiagOverflow;
static const NSUInteger kDatalessDiagDirectoryCap = 128;

static void VibeRecordDatalessStat(NSURL *url, BOOL dataless, uint32_t flags, BOOL statFailed) {
    NSString *directory = url.URLByDeletingLastPathComponent.path ?: @"?";
    @synchronized (NSURLUtil.class) {
        NSMutableDictionary *entry = sDatalessDiag[directory];
        if (!entry) {
            if (sDatalessDiag.count >= kDatalessDiagDirectoryCap) {
                sDatalessDiagOverflow++;
                return;
            }
            entry = [@{@"dataless": @0, @"local": @0, @"statFailed": @0} mutableCopy];
            sDatalessDiag[directory] = entry;
        }
        NSString *bucket = statFailed ? @"statFailed" : (dataless ? @"dataless" : @"local");
        entry[bucket] = @([entry[bucket] unsignedIntegerValue] + 1);
        if (!statFailed) {
            entry[@"lastFlags"] = [NSString stringWithFormat:@"0x%x", flags];
        }
    }
}
#endif

static VibeWalkedDirectoriesHandler WalkedDirectoriesHandler(void) {
    @synchronized (NSURLUtil.class) {
        return sWalkedDirectoriesHandler;
    }
}

static VibeBulkOpenDirectoriesHandler BulkOpenDirectoriesHandler(void) {
    @synchronized (NSURLUtil.class) {
        return sBulkOpenDirectoriesHandler;
    }
}


@implementation NSURLUtil

+ (void)setPlaylistFolderGrantHandler:(VibePlaylistFolderGrantHandler)handler {
    @synchronized (self) {
        sPlaylistFolderGrantHandler = [handler copy];
    }
}

+ (void)setWalkedDirectoriesHandler:(VibeWalkedDirectoriesHandler)handler {
    @synchronized (self) {
        sWalkedDirectoriesHandler = [handler copy];
    }
}

+ (void)setBulkOpenDirectoriesHandler:(VibeBulkOpenDirectoriesHandler)handler {
    @synchronized (self) {
        sBulkOpenDirectoriesHandler = [handler copy];
    }
}

+ (void)setRemotePlaceholderRoot:(NSURL *)root {
    NSString *prefix = root ? [VibeComparablePath(root.path) stringByAppendingString:@"/"] : nil;
    os_unfair_lock_lock(&sRemoteRootLock);
    sRemoteRootPrefix = prefix;
    os_unfair_lock_unlock(&sRemoteRootLock);
}

// The root first: with none installed, as on the mac, no stat is paid.
+ (BOOL)isRemotePlaceholderFile:(NSURL *)url {
    if (!VibeRemoteRootPrefix()) {
        return NO;
    }
    struct stat st;
    return stat(url.fileSystemRepresentation, &st) == 0 && VibeFileModeIsRemotePlaceholder(st.st_mode)
            && VibePathIsUnderRemotePlaceholderRoot(url.path);
}

+ (BOOL)readsRemotePlaceholderByRange:(NSURL *)url {
    return [NSURLUtil isRemotePlaceholderFile:url]
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

// The directory a path resolves to, canonically spelled, or nil for a file or
// a broken link.
//
// TRAP: NSURLIsDirectoryKey is lstat-shaped: a link to a folder answers NO, and
// the enumerator refuses one as its root (ENOTDIR), so an unresolved folder
// link is taken for a file and dropped by the extension filter — a dragged
// ~/Music/NAS link opens to nothing. realpath, not URLByResolvingSymlinksInPath,
// which keeps a /private prefix: only realpath's spelling matches the
// enumerator's resolved paths.
static NSString *VibeResolvedDirectoryPath(NSString *path) {
    if (path.length == 0) {
        return nil;
    }
    char resolved[PATH_MAX];
    struct stat st;
    if (!realpath(path.fileSystemRepresentation, resolved) ||
        stat(resolved, &st) != 0 || !S_ISDIR(st.st_mode)) {
        return nil;
    }
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved
                                                                     length:strlen(resolved)];
}

// A string test, so the walk need not rebuild the parent path per entry.
static BOOL VibePathIsDirectlyInside(NSString *path, NSString *directory) {
    NSUInteger directoryLength = directory.length;
    if (directoryLength == 0 || path.length <= directoryLength + 1) {
        return NO;
    }
    if (![path hasPrefix:directory] || [path characterAtIndex:directoryLength] != '/') {
        return NO;
    }
    NSRange remainder = NSMakeRange(directoryLength + 1, path.length - directoryLength - 1);
    return [path rangeOfString:@"/" options:0 range:remainder].location == NSNotFound;
}

+ (NSSet<NSString*>*) supportedExtensions {
    return PlayableExtensions.lookup;
}

// byFullPath sorts a recursive walk by whole path, grouping subfolders. The
// name is also newest-first's tiebreak, so a batch copy reads in track order.
//
// TRAP: decorate the dates and names once, never read them in the comparator,
// which runs O(n log n) times: NSURL.path mints a string per read, and a date
// the enumeration did not prefetch is a file-provider round trip. They are
// read by position, as hashing an NSURL in the comparator costs a pass over
// its string; the positions sort as the URLs did, by the same comparisons.
static void VibeSortAudioURLs(NSMutableArray<NSURL*> *urls, VibeFolderOpenSort sort,
                              BOOL byFullPath) {
    if (sort == VibeFolderOpenSortAsReceived) {
        return;
    }
    NSUInteger count = urls.count;
    NSMutableArray<NSString*> *names = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSNumber*> *order = [NSMutableArray arrayWithCapacity:count];
    for (NSURL *url in urls) {
        [order addObject:@(names.count)];
        [names addObject:(byFullPath ? url.path : url.lastPathComponent) ?: @""];
    }
    NSComparisonResult (^byName)(NSUInteger, NSUInteger) = ^(NSUInteger a, NSUInteger b) {
        return [names[a] localizedStandardCompare:names[b]];
    };
    if (sort != VibeFolderOpenSortNewestFirst) {
        [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return byName(a.unsignedIntegerValue, b.unsignedIntegerValue);
        }];
    }
    else {
        // NSNull for undated.
        NSMutableArray *dates = [NSMutableArray arrayWithCapacity:count];
        for (NSURL *url in urls) {
            NSDate *modified = nil;
            [url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:NULL];
            [dates addObject:modified ?: NSNull.null];
        }
        // Undated files sort last, by name, keeping the order total.
        [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            NSUInteger indexA = a.unsignedIntegerValue;
            NSUInteger indexB = b.unsignedIntegerValue;
            id dateA = dates[indexA];
            id dateB = dates[indexB];
            if (dateA == NSNull.null || dateB == NSNull.null) {
                if (dateA != dateB) {
                    return dateA != NSNull.null ? NSOrderedAscending : NSOrderedDescending;
                }
                return byName(indexA, indexB);
            }
            NSComparisonResult newestFirst = [(NSDate *)dateB compare:dateA];
            return newestFirst != NSOrderedSame ? newestFirst : byName(indexA, indexB);
        }];
    }
    NSArray<NSURL*> *unsorted = [urls copy];
    for (NSUInteger position = 0; position < count; position++) {
        urls[position] = unsorted[order[position].unsignedIntegerValue];
    }
}

// The walk ranks cover candidates on the way past, so the walked-directories
// handler gets each folder's answer for free. Only directories with playable
// audio are reported.
// What both listings prefetch. Every key is one more attribute the provider
// must answer, so the date is asked for only when the sort needs it; the size
// rides the same bulk read the stat keys already cost, and spares a stat per
// file (rowsForFile: reads it again for a FLAC).
static NSArray<NSURLResourceKey> *VibeListingKeys(VibeFolderOpenSort sort) {
    return sort == VibeFolderOpenSortNewestFirst
            ? @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey, NSURLContentModificationDateKey]
            : @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey];
}

// A listed file's emptiness, so a listed file costs the filter no stat: a
// link's from its target's stat, with *dangling set when the target is gone;
// any other file's from the size its listing prefetched, which is the logical
// size the test requires, never the allocated one. Anything it cannot stat
// passes, so the real open can report a sandbox denial.
static BOOL VibeListedFileIsEmpty(NSURL *url, BOOL isLink, BOOL *dangling) {
    *dangling = NO;
    if (isLink) {
        struct stat targetInfo;
        if (stat(url.fileSystemRepresentation, &targetInfo) == 0) {
            return VibeStatIsEmptyOrDirectory(&targetInfo);
        }
        // The link was just listed, so ENOENT means its target.
        *dangling = errno == ENOENT;
        return NO;
    }
    NSNumber *size = nil;
    if ([url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL] && size != nil) {
        return size.longLongValue == 0;
    }
    return url.isEmptyOrDirectory;
}

+ (NSArray<AudioTrack*>*) expandDirectory:(NSURL*)dir sortedBy:(VibeFolderOpenSort)sort {

    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] init];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableDictionary<NSString*, NSString*> *artByDirectory = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*> *artRankByDirectory = [NSMutableDictionary dictionary];
    NSMutableSet<NSString*> *directoriesWalked = [NSMutableSet set];
    NSSet<NSString*> *supported = [self supportedExtensions];

    // The enumerator neither follows a directory link nor takes one as root,
    // so each link found becomes another root, resolved to canonical form.
    // covered ends a link cycle and keeps a link into an already-walked
    // subtree from listing it twice.
    NSMutableArray<NSString*> *pendingRoots = [NSMutableArray array];
    NSMutableSet<NSString*> *covered = [NSMutableSet set];
    NSString *resolvedRoot = VibeResolvedDirectoryPath(dir.path);
    if (resolvedRoot) {
        [pendingRoots addObject:resolvedRoot];
    }

    // Skipping hidden files drops the AppleDouble "._Song.mp3" sidecars that
    // exFAT, SMB and USB volumes carry, which would pass the extension filter
    // as unplayable rows.
    NSArray<NSURLResourceKey> *keys = VibeListingKeys(sort);

    while (pendingRoots.count > 0) {
        NSString *rootPath = pendingRoots.firstObject;
        [pendingRoots removeObjectAtIndex:0];
        if ([covered containsObject:rootPath]) {
            continue;
        }
        [covered addObject:rootPath];
        // Held back until this root is enumerated in full, so each is tested
        // against everything it covered.
        NSMutableArray<NSString*> *linkedRoots = [NSMutableArray array];
        // Depth-first, so entries arrive in runs from one directory.
        NSString *lastDirectory = nil;
        NSDirectoryEnumerator *enumerator = [fileManager
                enumeratorAtURL:[NSURL fileURLWithPath:rootPath isDirectory:YES]
     includingPropertiesForKeys:keys
                        options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                   errorHandler:^(NSURL *url, NSError *error) {
                       LogWarn(@"Error enumerating %@: %@", url, error);
                       return YES;
                   }];
        for (NSURL *url in enumerator) {
            NSError *error = nil;
            NSNumber *isDirectory = nil;
            BOOL isFile;
            if ([url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&error]) {
                isFile = !isDirectory.boolValue;
            }
            else {
                // Treat it as a file, so the extension filter still sees it.
                LogWarn(@"Could not read directory flag for %@: %@", url, error);
                isFile = YES;
            }
            // Non-audio entries still reach the folder-art bookkeeping below:
            // a cover is exactly a non-audio entry.
            NSString *path = url.path;
            if (!isFile) {
                // Recorded so a link into this subtree reads as covered; one a
                // link already walked is skipped whole.
                if (path.length == 0) {
                    continue;
                }
                if ([covered containsObject:path]) {
                    [enumerator skipDescendants];
                }
                else {
                    [covered addObject:path];
                }
                continue;
            }
            NSNumber *isLink = nil;
            [url getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:NULL];
            if (isLink.boolValue) {
                NSString *linked = VibeResolvedDirectoryPath(path);
                if (linked) {
                    [linkedRoots addObject:linked];
                    continue;
                }
            }
            NSString *extension = path.pathExtension.lowercaseString;
            BOOL isAudio = [supported containsObject:extension];
            BOOL empty = NO;
            if (isAudio || isLink.boolValue) {
                // A dangling link is dropped, or it would stay an unplayable row.
                BOOL dangling;
                empty = VibeListedFileIsEmpty(url, isLink.boolValue, &dangling);
                if (dangling) {
                    continue;
                }
            }
            // A sheet sorts among the audio and stands in for its files
            // (rowsForWalk:); an M3U here would double what the walk found.
            if ((isAudio && !empty) || [PlaylistFile isCueExtension:extension]) {
                [results addObject:url];
            }
            if (!VibePathIsDirectlyInside(path, lastDirectory)) {
                lastDirectory = path.stringByDeletingLastPathComponent;
            }
            if (lastDirectory.length > 0 && isAudio) {
                [directoriesWalked addObject:lastDirectory];
            }
            VibeFolderArtNoteCandidate(lastDirectory, path.lastPathComponent,
                                       artByDirectory, artRankByDirectory);
        }

        for (NSString *linked in linkedRoots) {
            if (![covered containsObject:linked]) {
                [pendingRoots addObject:linked];
            }
        }
    }

    VibeWalkedDirectoriesHandler walked = WalkedDirectoriesHandler();
    if (walked && directoriesWalked.count > 0) {
        walked(directoriesWalked, artByDirectory);
    }

    VibeSortAudioURLs(results, sort, YES);

    return [self rowsForWalk:results];
}

typedef NS_ENUM(NSInteger, VibeReadAccess) {
    VibeReadAccessReadable,
    VibeReadAccessMissing,
    VibeReadAccessDenied,
};

// access(2), because only its errno tells missing from sandbox-denied, and
// only denied is worth a grant prompt.
static VibeReadAccess ReadAccessForURL(NSURL *url) {
    if (access(url.fileSystemRepresentation, R_OK) == 0) {
        return VibeReadAccessReadable;
    }
    return (errno == EPERM || errno == EACCES) ? VibeReadAccessDenied : VibeReadAccessMissing;
}

// The files a sheet may name, by PlaylistFile's key, from one listing.
static NSDictionary<NSString *, NSArray<NSURL *> *> *VibeKnownFiles(NSArray<NSURL *> *urls) {
    NSMutableDictionary<NSString *, NSMutableArray<NSURL *> *> *knownFiles =
            [NSMutableDictionary dictionaryWithCapacity:urls.count];
    for (NSURL *url in urls) {
        NSString *key = [PlaylistFile knownFileKeyForPath:url.path];
        NSMutableArray<NSURL *> *matches = knownFiles[key];
        if (!matches) {
            knownFiles[key] = matches = [NSMutableArray array];
        }
        [matches addObject:url];
    }
    return knownFiles;
}

// A sheet's rows that name supported, nonempty files, listed or readable: a
// listed placeholder counts though no readability probe passes it. playable
// holds the verdict once per file, however many rows or sheets name it.
static NSArray<AudioTrack *> *VibePlayableSheetRows(NSURL *sheet, NSSet<NSURL *> *listed,
                                                   NSDictionary<NSString *, NSArray<NSURL *> *> *knownFiles,
                                                   NSMutableDictionary<NSURL *, NSNumber *> *playable) {
    NSSet<NSString *> *supported = PlayableExtensions.lookup;
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray array];
    for (AudioTrack *row in [PlaylistFile cueRowsForSheetAtURL:sheet knownFiles:knownFiles]) {
        NSNumber *verdict = playable[row.url];
        if (verdict == nil) {
            verdict = @([supported containsObject:row.url.pathExtension.lowercaseString]
                        && !row.url.isEmptyOrDirectory
                        && ([listed containsObject:row.url]
                            || ReadAccessForURL(row.url) == VibeReadAccessReadable));
            playable[row.url] = verdict;
        }
        if (verdict.boolValue) {
            [rows addObject:row];
        }
    }
    return rows;
}

// Each audio file its rows (rowsForFile:), and each sheet its rows in its
// sorted place. A sheet resolves against the walk's own listing first and
// claims its files, so none also appears whole or is opened for its own sheet,
// and none is cut again by a later sheet: Album.cue beside Album (UTF-8).cue
// would list every track twice. Sheet rows must name supported, nonempty
// files, listed or readable.
+ (NSArray<AudioTrack *> *)rowsForWalk:(NSArray<NSURL *> *)urls {
    NSMutableArray<NSURL *> *sheets = [NSMutableArray array];
    for (NSURL *url in urls) {
        if ([PlaylistFile isCueExtension:url.pathExtension.lowercaseString]) {
            [sheets addObject:url];
        }
    }
    if (sheets.count == 0) {
        NSMutableArray<AudioTrack *> *rows = [NSMutableArray arrayWithCapacity:urls.count];
        for (NSURL *url in urls) {
            [rows addObjectsFromArray:[self rowsForFile:url]];
        }
        return rows;
    }
    NSSet<NSURL *> *listed = [NSSet setWithArray:urls];
    NSDictionary<NSString *, NSArray<NSURL *> *> *knownFiles = VibeKnownFiles(urls);
    NSMutableDictionary<NSURL *, NSArray<AudioTrack *> *> *rowsBySheet = [NSMutableDictionary dictionary];
    // Each claimed file to the sheet that cut it.
    NSMutableDictionary<NSURL *, NSURL *> *claimed = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSURL *, NSNumber *> *playable = [NSMutableDictionary dictionary];
    for (NSURL *sheet in sheets) {
        NSMutableArray<AudioTrack *> *rows = [NSMutableArray array];
        for (AudioTrack *row in VibePlayableSheetRows(sheet, listed, knownFiles, playable)) {
            NSURL *cutBy = claimed[row.url];
            if (!cutBy || cutBy == sheet) {
                [rows addObject:row];
                claimed[row.url] = sheet;
            }
        }
        rowsBySheet[sheet] = rows;
    }
    NSMutableArray<AudioTrack *> *rows = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        NSArray<AudioTrack *> *sheetRows = rowsBySheet[url];
        if (sheetRows) {
            [rows addObjectsFromArray:sheetRows];
        }
        else if (!claimed[url]) {
            [rows addObjectsFromArray:[self rowsForFile:url]];
        }
    }
    return rows;
}

// A whole album or mix in one FLAC may carry its own sheet, and only such a
// file is opened to look: an ordinary track is under the size, and a cloud
// placeholder is never read, since the read would download it. The gate keeps
// a walk's only content reads to a few files even on a network volume.
static const long long kVibeEmbeddedCueMinimumBytes = 100LL * 1024 * 1024;

static NSMutableArray<NSURL *> *VibeListedAudioURLs(NSURL *dir, VibeFolderOpenSort sort,
                                                  NSMutableArray<NSURL *> *subfolders);

+ (NSArray<AudioTrack *> *)rowsForFile:(NSURL *)url {
    // A sheet alone resolves against its folder's listing, as a walk does,
    // and claims nothing from its siblings: picked, it is the user's choice.
    if ([PlaylistFile isCueExtension:url.pathExtension.lowercaseString]) {
        NSArray<NSURL *> *listed = VibeListedAudioURLs(url.URLByDeletingLastPathComponent,
                                                       VibeFolderOpenSortAsReceived, nil) ?: @[];
        return VibePlayableSheetRows(url, [NSSet setWithArray:listed], VibeKnownFiles(listed),
                                     [NSMutableDictionary dictionary]);
    }
    if ([url.pathExtension.lowercaseString isEqualToString:@"flac"]) {
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        if (size.longLongValue >= kVibeEmbeddedCueMinimumBytes && ![self isDatalessFile:url]) {
            NSArray<AudioTrack *> *rows = [PlaylistFile cueRowsEmbeddedInFLACAtURL:url];
            if (rows.count > 0) {
                return rows;
            }
        }
    }
    return @[[AudioTrack withURL:url]];
}

// The folder's nonempty audio files and sheets, listed with the keys `sort`
// needs, unsorted; nil when the listing fails. `subfolders`, when given,
// takes the directories of the same enumeration: a provider's listing is IPC,
// and a browser screen asking twice paid for it twice.
static NSMutableArray<NSURL *> *VibeListedAudioURLs(NSURL *dir, VibeFolderOpenSort sort,
                                                  NSMutableArray<NSURL *> *subfolders) {
    // Skipping hidden files drops AppleDouble sidecars.
    NSError *error = nil;
    NSArray<NSURL*> *contents = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:dir
          includingPropertiesForKeys:VibeListingKeys(sort)
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                               error:&error];
    if (!contents) {
        LogWarn(@"Error listing %@: %@", dir, error);
        return nil;
    }
    NSSet<NSString*> *supported = PlayableExtensions.lookup;
    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] init];
    for (NSURL *url in contents) {
        NSString *extension = url.pathExtension.lowercaseString;
        // The key is one of the listing's (VibeListingKeys): no I/O per entry.
        NSNumber *isDirectory = nil;
        [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL];
        if (isDirectory.boolValue) {
            [subfolders addObject:url];
            continue;
        }
        if (![supported containsObject:extension] && ![PlaylistFile isCueExtension:extension]) {
            continue;
        }
        NSNumber *isLink = nil;
        [url getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:NULL];
        BOOL dangling = NO;
        if (!VibeListedFileIsEmpty(url, isLink.boolValue, &dangling) && !dangling) {
            [results addObject:url];
        }
    }
    return results;
}

+ (NSArray<AudioTrack*>*) rowsInDirectory:(NSURL*)dir sortedBy:(VibeFolderOpenSort)sort {
    NSMutableArray<NSURL *> *results = VibeListedAudioURLs(dir, sort, nil);
    if (!results) {
        return @[];
    }
    VibeSortAudioURLs(results, sort, NO);
    return [self rowsForWalk:results];
}

+ (void)listDirectory:(NSURL *)dir
             sortedBy:(VibeFolderOpenSort)sort
              folders:(NSArray<NSURL *> **)folders
                audio:(NSArray<NSURL *> **)audio {
    NSMutableArray<NSURL *> *subfolders = folders ? [NSMutableArray array] : nil;
    NSMutableArray<NSURL *> *files = VibeListedAudioURLs(dir, sort, subfolders) ?: [NSMutableArray array];
    if (folders) {
        VibeSortAudioURLs(subfolders, sort, NO);
        *folders = subfolders;
    }
    VibeSortAudioURLs(files, sort, NO);
    if (audio) {
        *audio = files;
    }
}

// Concurrent, so one dead mount cannot hold every later open; bounded, so a
// burst of blocked walks cannot spawn a thread each. Callers order overlapping
// results (OpenRequestCoordinator).
+ (NSOperationQueue *)expansionQueue {
    static NSOperationQueue *queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.name = @"com.vibe.urlexpansion";
        queue.maxConcurrentOperationCount = 4;
        queue.qualityOfService = NSQualityOfServiceUserInitiated;
    });
    return queue;
}

+ (void) expandAndFilterList:(NSArray<NSURL*>*)list
                    sortedBy:(VibeFolderOpenSort)sort
                  completion:(void (^)(NSArray<AudioTrack*>*, NSUInteger))completion {
    [[self expansionQueue] addOperationWithBlock:^{
        NSUInteger folderCount = 0;
        NSArray<AudioTrack*> *results = [self expandAndFilterList:list sortedBy:sort
                                                      folderCount:&folderCount];
        run_on_main_thread({
            completion(results, folderCount);
        });
    }];
}

+ (NSArray<AudioTrack*>*) expandAndFilterList:(NSArray<NSURL*>*)list
                                     sortedBy:(VibeFolderOpenSort)sort
                                  folderCount:(NSUInteger *)folderCount {
    NSUInteger inputCount = list.count;
    NSMutableSet<NSString*> *looseFileDirectories = [NSMutableSet set];
    NSUInteger expandedCount = 0;
    NSArray<AudioTrack*> *rows = [NSURLUtil expandFileList:list
                                                  sortedBy:sort
                                               folderCount:folderCount
                                      looseFileDirectories:looseFileDirectories
                                             expandedCount:&expandedCount];
    NSMutableSet<NSString *> *supportedLooseDirectories = [NSMutableSet set];
    for (AudioTrack *row in rows) {
        [self noteLooseFileDirectoryOf:row.url into:supportedLooseDirectories];
    }
    [looseFileDirectories intersectSet:supportedLooseDirectories];
    // Anything but a single file is a bulk open, whose loose files' folders are
    // worth a listing each. The post-expansion count matters: a dropped .cue is
    // one file naming a whole album.
    BOOL bulkOpen = inputCount > 1 || (folderCount && *folderCount > 0) ||
                    looseFileDirectories.count > 1 || expandedCount > inputCount;
    VibeBulkOpenDirectoriesHandler bulk = BulkOpenDirectoriesHandler();
    if (bulkOpen && bulk && looseFileDirectories.count > 0) {
        bulk(looseFileDirectories);
    }
    return rows;
}

+ (NSArray<AudioTrack*>*) expandFileList:(NSArray<NSURL*>*)list
                                sortedBy:(VibeFolderOpenSort)sort
                             folderCount:(NSUInteger *)folderCount
                    looseFileDirectories:(NSMutableSet<NSString*> *)looseFileDirectories
                           expandedCount:(NSUInteger *)expandedCount {
    NSMutableArray<AudioTrack*> *results = [[NSMutableArray alloc] initWithCapacity:list.count];
    NSSet<NSString*> *supported = [NSURLUtil supportedExtensions];
    // Nothing can play an empty file. Second, so only extension matches pay
    // the stat, once per file however many rows it has. A walk's rows skip
    // it: the walk drops what it would, unplayable names and empty files.
    NSMutableDictionary<NSURL*, NSNumber*> *playable = [NSMutableDictionary dictionary];
    void (^addPlayable)(NSArray<AudioTrack*> *) = ^(NSArray<AudioTrack*> *rows) {
        for (AudioTrack *row in rows) {
            NSNumber *verdict = playable[row.url];
            if (verdict == nil) {
                verdict = @([supported containsObject:row.url.pathExtension.lowercaseString]
                            && !row.url.isEmptyOrDirectory);
                playable[row.url] = verdict;
            }
            if (verdict.boolValue) {
                [results addObject:row];
            }
        }
    };
    NSUInteger expanded = 0;
    for (NSURL *url in list) {
        // Ask the file system: hasDirectoryPath reads only the trailing slash,
        // which a URL from argv or some pasteboards lacks. The link flag rides
        // along, since a folder link must be resolved (VibeResolvedDirectoryPath).
        NSDictionary<NSURLResourceKey, id> *values =
                [url resourceValuesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey]
                                     error:NULL];
        NSNumber *isDirectory = values[NSURLIsDirectoryKey];
        BOOL isDir = isDirectory != nil
                ? isDirectory.boolValue
                : url.hasDirectoryPath; // resource read failed; fall back to the slash
        if (!isDir && [values[NSURLIsSymbolicLinkKey] boolValue]) {
            isDir = VibeResolvedDirectoryPath(url.path) != nil;
        }
        if (isDir) {
            if (folderCount) {
                (*folderCount)++;
            }
            NSArray<AudioTrack*> *rows = [self expandDirectory:url sortedBy:sort];
            expanded += rows.count;
            [results addObjectsFromArray:rows];
        }
        else if ([PlaylistFile isPlaylistExtension:[url.pathExtension lowercaseString]]) {
            NSArray<AudioTrack*> *rows = [self expandPlaylistFile:url];
            expanded += rows.count;
            addPlayable(rows);
            for (AudioTrack *row in rows) {
                [self noteLooseFileDirectoryOf:row.url into:looseFileDirectories];
            }
        }
        else {
            NSArray<AudioTrack*> *rows = [self rowsForFile:url];
            expanded += rows.count;
            addPlayable(rows);
            [self noteLooseFileDirectoryOf:url into:looseFileDirectories];
        }
    }
    if (expandedCount) {
        *expandedCount = expanded;
    }
    return results;
}

+ (void)noteLooseFileDirectoryOf:(NSURL *)url into:(NSMutableSet<NSString*> *)directories {
    NSString *directory = url.path.stringByDeletingLastPathComponent;
    if (directories && directory.length > 0) {
        [directories addObject:directory];
    }
}

#pragma mark - Playlist files (CUE, M3U)

// Only an explicitly opened playlist file expands; one met in a folder walk
// would double every track, and the extension filter drops it.
//
// Opening a playlist file grants access to it alone, so a denied entry raises
// one folder grant through the handler, and the re-resolve then also gets a
// working basename fallback. Entries still unreadable are skipped.
#if TARGET_OS_OSX
static VibePlaylistFolderGrantHandler PlaylistFolderGrantHandler(void) {
    @synchronized (NSURLUtil.class) {
        return sPlaylistFolderGrantHandler;
    }
}
#endif

+ (NSArray<AudioTrack *> *)expandPlaylistFile:(NSURL *)playlistURL {
    NSArray<AudioTrack *> *resolved = [PlaylistFile rowsForPlaylistAtURL:playlistURL];
    // A probe can hang on a dead mount, so verdicts are reused by the filter
    // below, and dropped only when a grant changes readability. One per file,
    // however many rows a sheet cuts it into.
    NSMutableDictionary<NSString *, NSNumber *> *scannedAccessByPath =
            [NSMutableDictionary dictionaryWithCapacity:resolved.count];
#if TARGET_OS_OSX
    BOOL anyUnreadable = NO;
    BOOL anyDenied = NO;
    for (AudioTrack *row in resolved) {
        NSURL *url = row.url;
        if (scannedAccessByPath[url.path] != nil) {
            continue;
        }
        VibeReadAccess access = ReadAccessForURL(url);
        scannedAccessByPath[url.path] = @(access);
        anyUnreadable |= (access != VibeReadAccessReadable);
        anyDenied |= (access == VibeReadAccessDenied);
        if (anyUnreadable && anyDenied) {
            break;  // both facts settled; stop paying probes
        }
    }
    // With the playlist's own folder denied, "missing" cannot be trusted: the
    // fallback candidates beside the playlist could not be probed.
    BOOL folderDenied =
            ReadAccessForURL(playlistURL.URLByDeletingLastPathComponent) == VibeReadAccessDenied;
    VibePlaylistFolderGrantHandler grantHandler = PlaylistFolderGrantHandler();
    if (anyUnreadable && (anyDenied || folderDenied)
            && grantHandler && grantHandler(playlistURL)) {
        resolved = [PlaylistFile rowsForPlaylistAtURL:playlistURL];
        [scannedAccessByPath removeAllObjects];
    }
#endif
    NSMutableArray<AudioTrack *> *readable = [NSMutableArray arrayWithCapacity:resolved.count];
    NSMutableSet<NSString *> *skipped = [NSMutableSet set];
    for (AudioTrack *row in resolved) {
        NSString *path = row.url.path;
        NSNumber *scanned = scannedAccessByPath[path];
        VibeReadAccess access = scanned != nil ? (VibeReadAccess)scanned.integerValue : ReadAccessForURL(row.url);
        scannedAccessByPath[path] = @(access);
        if (access == VibeReadAccessReadable) {
            [readable addObject:row];
        }
        else if (![skipped containsObject:path]) {
            [skipped addObject:path];
            LogWarn(@"Skipping unreadable playlist entry: %@", path);
        }
    }
    LogInfo(@"Playlist file %@ expanded to %lu of %lu entries", playlistURL.lastPathComponent,
            (unsigned long)readable.count, (unsigned long)resolved.count);
    return readable;
}

@end
