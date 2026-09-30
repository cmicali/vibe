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
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#if DEBUG
#include <stdatomic.h>
#endif

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
    BOOL dataless = (st.st_flags & SF_DATALESS) != 0;
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
// the enumeration did not prefetch is a file-provider round trip.
static void VibeSortAudioURLs(NSMutableArray<NSURL*> *urls, VibeFolderOpenSort sort,
                              BOOL byFullPath) {
    if (sort == VibeFolderOpenSortAsReceived) {
        return;
    }
    NSMutableDictionary<NSURL*, NSString*> *nameByURL =
            [NSMutableDictionary dictionaryWithCapacity:urls.count];
    for (NSURL *url in urls) {
        nameByURL[url] = (byFullPath ? url.path : url.lastPathComponent) ?: @"";
    }
    NSComparisonResult (^byName)(NSURL *, NSURL *) = ^(NSURL *a, NSURL *b) {
        return [nameByURL[a] localizedStandardCompare:nameByURL[b]];
    };
    if (sort != VibeFolderOpenSortNewestFirst) {
        [urls sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return byName(a, b);
        }];
        return;
    }
    NSMutableDictionary<NSURL*, NSDate*> *dateByURL =
            [NSMutableDictionary dictionaryWithCapacity:urls.count];
    for (NSURL *url in urls) {
        NSDate *modified = nil;
        if ([url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:NULL]
                && modified) {
            dateByURL[url] = modified;
        }
    }
    // Undated files sort last, by name, keeping the order total.
    [urls sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *dateA = dateByURL[a];
        NSDate *dateB = dateByURL[b];
        if (!dateA || !dateB) {
            if (dateA != dateB) {
                return dateA ? NSOrderedAscending : NSOrderedDescending;
            }
            return byName(a, b);
        }
        NSComparisonResult newestFirst = [dateB compare:dateA];
        return newestFirst != NSOrderedSame ? newestFirst : byName(a, b);
    }];
}

// The walk ranks cover candidates on the way past, so the walked-directories
// handler gets each folder's answer for free. Only directories with playable
// audio are reported.
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
    // as unplayable rows. Every key is one more attribute the provider must
    // answer, so the date is prefetched only when the sort needs it.
    NSArray<NSURLResourceKey> *keys = sort == VibeFolderOpenSortNewestFirst
            ? @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLContentModificationDateKey]
            : @[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey];

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
            if ([url getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:NULL] &&
                isLink.boolValue) {
                NSString *linked = VibeResolvedDirectoryPath(path);
                if (linked) {
                    [linkedRoots addObject:linked];
                    continue;
                }
                // A dangling link is dropped here: the emptiness filter passes
                // anything it cannot stat, so the real open can report a
                // sandbox denial, and would keep it as an unplayable row. The
                // link was just enumerated, so ENOENT means its target.
                struct stat targetInfo;
                if (stat(path.fileSystemRepresentation, &targetInfo) != 0 && errno == ENOENT) {
                    continue;
                }
            }
            NSString *extension = path.pathExtension.lowercaseString;
            BOOL isAudio = [supported containsObject:extension];
            // A sheet sorts among the audio and stands in for its files
            // (rowsForWalk:); an M3U here would double what the walk found.
            if (isAudio || [extension isEqualToString:@"cue"]) {
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

// Each audio file its own row, and each sheet its rows in its sorted place.
// A sheet resolves against the walk's own listing first, so one whose files
// were listed costs no probe, and claims its files, so none also appears
// whole; a row whose file is neither listed nor readable is dropped, a sheet
// naming a long-gone image being one.
+ (NSArray<AudioTrack *> *)rowsForWalk:(NSArray<NSURL *> *)urls {
    NSMutableArray<NSURL *> *sheets = [NSMutableArray array];
    for (NSURL *url in urls) {
        if ([url.pathExtension.lowercaseString isEqualToString:@"cue"]) {
            [sheets addObject:url];
        }
    }
    NSMutableDictionary<NSString *, NSURL *> *listed = nil;
    if (sheets.count > 0) {
        listed = [NSMutableDictionary dictionaryWithCapacity:urls.count];
        for (NSURL *url in urls) {
            listed[[PlaylistFile knownFileKeyForPath:url.path]] = url;
        }
    }
    NSMutableDictionary<NSURL *, NSArray<AudioTrack *> *> *rowsBySheet = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *claimed = [NSMutableSet set];
    for (NSURL *sheet in sheets) {
        NSMutableArray<AudioTrack *> *rows = [NSMutableArray array];
        for (AudioTrack *row in [PlaylistFile cueRowsForSheetAtURL:sheet knownFiles:listed]) {
            NSString *key = [PlaylistFile knownFileKeyForPath:row.url.path];
            if (listed[key] || access(row.url.fileSystemRepresentation, R_OK) == 0) {
                [rows addObject:row];
                [claimed addObject:key];
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
        else if (!listed || ![claimed containsObject:[PlaylistFile knownFileKeyForPath:url.path]]) {
            [rows addObject:[AudioTrack withURL:url]];
        }
    }
    return rows;
}

+ (NSArray<AudioTrack*>*) rowsInDirectory:(NSURL*)dir sortedBy:(VibeFolderOpenSort)sort {
    // Skipping hidden files drops AppleDouble sidecars, as in expandDirectory.
    NSError *error = nil;
    NSArray<NSURL*> *contents = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:dir
          includingPropertiesForKeys:(sort == VibeFolderOpenSortNewestFirst
                                              ? @[NSURLContentModificationDateKey] : @[])
                             options:NSDirectoryEnumerationSkipsHiddenFiles
                               error:&error];
    if (!contents) {
        LogWarn(@"Error listing %@: %@", dir, error);
        return @[];
    }
    NSSet<NSString*> *supported = [self supportedExtensions];
    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] init];
    for (NSURL *url in contents) {
        NSString *extension = url.pathExtension.lowercaseString;
        if (![supported containsObject:extension] && ![extension isEqualToString:@"cue"]) {
            continue;
        }
        if (!url.isEmptyOrDirectory) {
            [results addObject:url];
        }
    }
    VibeSortAudioURLs(results, sort, NO);
    return [self rowsForWalk:results];
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
    NSArray<AudioTrack*> *rows = [NSURLUtil expandFileList:list
                                                  sortedBy:sort
                                               folderCount:folderCount
                                      looseFileDirectories:looseFileDirectories];
    NSUInteger expandedCount = rows.count;
    NSSet<NSString*> *supported = [NSURLUtil supportedExtensions];
    // Nothing can play an empty file. Second, so only extension matches pay
    // the stat, once per file however many rows it has.
    NSMutableDictionary<NSURL*, NSNumber*> *playable = [NSMutableDictionary dictionary];
    rows = [rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(AudioTrack *row, NSDictionary* bindings) {
        NSNumber *verdict = playable[row.url];
        if (!verdict) {
            verdict = @([supported containsObject:[row.url.pathExtension lowercaseString]] && !row.url.isEmptyOrDirectory);
            playable[row.url] = verdict;
        }
        return verdict.boolValue;
    }]];
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
                    looseFileDirectories:(NSMutableSet<NSString*> *)looseFileDirectories {
    NSMutableArray<AudioTrack*> *results = [[NSMutableArray alloc] initWithCapacity:list.count];
    for (NSURL *url in list) {
        // Ask the file system: hasDirectoryPath reads only the trailing slash,
        // which a URL from argv or some pasteboards lacks. The link flag rides
        // along, since a folder link must be resolved (VibeResolvedDirectoryPath).
        NSDictionary<NSURLResourceKey, id> *values =
                [url resourceValuesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
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
            [results addObjectsFromArray:[self expandDirectory:url sortedBy:sort]];
        }
        else if ([PlaylistFile isPlaylistExtension:[url.pathExtension lowercaseString]]) {
            NSArray<AudioTrack*> *rows = [self expandPlaylistFile:url];
            [results addObjectsFromArray:rows];
            for (AudioTrack *row in rows) {
                [self noteLooseFileDirectoryOf:row.url into:looseFileDirectories];
            }
        }
        else {
            [results addObject:[AudioTrack withURL:url]];
            [self noteLooseFileDirectoryOf:url into:looseFileDirectories];
        }
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
        if (scannedAccessByPath[url.path]) {
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
