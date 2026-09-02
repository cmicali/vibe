//
//  NSURLUtil.m
//  Vibe
//

#import "NSURLUtilInternal.h"
#if DEBUG
#import "NSURLUtil+Debug.h"   // the dataless probe, declared out of the shipping header
#endif
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

// Installed once at launch, read from the expansion workers, so each handoff
// takes a lock rather than assuming the install lands first.
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

// The lane-routing measurement; see NSURLUtil+Debug.h. Guarded by the class
// @synchronized like the probe, and consulted only after an atomic flag says
// it is on, so the 2.3us stat path pays one relaxed load when it is not.
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

// One stat, and SF_DATALESS is the whole answer.
//
// TRAP: do not second-guess it with NSURLUbiquitousItemDownloadingStatus, or
// with any other NSURL resource value. NSURL memoizes resource values on the
// INSTANCE, and these URLs live as long as their AudioTrack, so the first
// answer freezes for the file's whole life — a placeholder read while
// downloading still reads "not downloaded" once it has materialized, and the
// current-track lane, which skips a dataless file and retries when the open
// lands, then skips forever. It is a getattrlist round trip besides, on a test
// the scan's lane routing runs once per track.
//
// If a provider ever does appear whose placeholders carry no flag, the symptom
// is specific: its files route to the wide scan lane instead of the serial
// cloud one, so opening a folder starts four downloads at once and starves the
// track the user picked. Fix it there, and pay the round trip once per
// directory rather than once per file.
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

// The directory a symbolic link names, canonically spelled, or nil when it
// names anything else — a file, or nothing at all because the link is broken.
//
// TRAP: NSURLIsDirectoryKey is lstat-shaped. A link to a folder answers NO to
// it, and the enumerator refuses such a link as its root outright (ENOTDIR,
// every URL spelling), so a folder link left unresolved is taken for a file and
// then dropped by the extension filter: a dragged ~/Music/NAS link opened to
// nothing. realpath, not URLByResolvingSymlinksInPath, which leaves a /private
// prefix as it found it — the enumerator answers in fully resolved paths, so
// only realpath's spelling can be compared against them.
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

// Whether path names a file sitting directly in directory — a string test, so a
// walk can tell it is still in the same folder without rebuilding that folder's
// path for every entry.
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

// A static set, consulted once per file in a folder drop. The spellings are
// Common/PlayableExtensions', which the playlist fallback walks in order.
+ (NSSet<NSString*>*) supportedExtensions {
    return PlayableExtensions.lookup;
}

// Puts one folder's audio into the order the user picked. byFullPath is the
// name comparator's subject: the whole path for a recursive walk, which groups
// subfolders, and the filename alone for a flat listing. It is also
// newest-first's tiebreak, so a batch of files copied in one go — one shared
// mtime — still reads in track order rather than arbitrarily.
//
// TRAP: the dates are decorated onto the list once rather than read inside the
// comparator, which runs O(n log n) times. The enumeration prefetches the key,
// so each read here is served from that batch instead of costing a round trip
// to the file provider.
static void VibeSortAudioURLs(NSMutableArray<NSURL*> *urls, VibeFolderOpenSort sort,
                              BOOL byFullPath) {
    if (sort == VibeFolderOpenSortAsReceived) {
        return;
    }
    NSComparisonResult (^byName)(NSURL *, NSURL *) = ^(NSURL *a, NSURL *b) {
        return byFullPath ? [a.path localizedStandardCompare:b.path]
                          : [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
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
    // A file whose date the file system or provider would not give up sorts
    // after every dated one, then by name, so the order stays total and
    // repeatable instead of the missing date reading as the epoch.
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

// The walk picks the album cover out on the way past: it already touches every
// entry, so the walked-directories handler gets the whole folder's answer for
// the cost of a rank lookup per name. Only directories contributing playable
// audio are handed over; nothing will ask about an "Artwork" subfolder.
+ (NSArray<NSURL*>*) expandDirectory:(NSURL*)dir sortedBy:(VibeFolderOpenSort)sort {

    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] init];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // directory -> the best cover filename seen in it so far, and its rank.
    NSMutableDictionary<NSString*, NSString*> *artByDirectory = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*> *artRankByDirectory = [NSMutableDictionary dictionary];
    NSMutableSet<NSString*> *directoriesWalked = [NSMutableSet set];
    NSSet<NSString*> *supported = [self supportedExtensions];

    // The enumerator neither follows a directory symlink nor opens one as its
    // root, so the walk owns them: each one found becomes another root here,
    // and the top-level folder is resolved so every path below is canonical
    // like the enumerator's own answers. covered holds every directory an
    // enumeration has passed through, which is what ends a link cycle and
    // keeps a link into an already-walked subtree from listing it twice.
    NSMutableArray<NSString*> *pendingRoots = [NSMutableArray array];
    NSMutableSet<NSString*> *covered = [NSMutableSet set];
    NSString *resolvedRoot = VibeResolvedDirectoryPath(dir.path);
    if (resolvedRoot) {
        [pendingRoots addObject:resolvedRoot];
    }

    // Skip hidden files. On exFAT, SMB and USB volumes macOS writes
    // AppleDouble sidecars such as "._Song.mp3", whose extension passes the
    // filetype filter but which hold resource-fork metadata rather than audio;
    // each one showed up as a duplicate, unplayable playlist row. Skipping
    // package descendants keeps the walk out of app and bundle internals.
    // The modification date is prefetched only when the sort needs it; every
    // key here is one more attribute the provider has to answer for — the link
    // flag rides along rather than costing a getattrlist per entry.
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
        // Directory links seen under this root. Held back until it has been
        // enumerated in full, so each can be tested against everything the
        // enumeration actually covered rather than against a partial answer.
        NSMutableArray<NSString*> *linkedRoots = [NSMutableArray array];
        // The enumerator is depth-first, so entries arrive in long runs from one
        // directory; remembering the last one avoids rebuilding the parent path for
        // every file in a folder.
        NSString *lastDirectory = nil;
        NSDirectoryEnumerator *enumerator = [fileManager
                enumeratorAtURL:[NSURL fileURLWithPath:rootPath isDirectory:YES]
     includingPropertiesForKeys:keys
                        options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                   errorHandler:^(NSURL *url, NSError *error) {
                       // Skip the unreadable entry or subtree, but keep
                       // enumerating the rest of the drop.
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
                // Log it and treat it as a file, the same fallback
                // expandFileList:folderCount: uses, so that it still reaches the
                // extension filter rather than vanishing.
                LogWarn(@"Could not read directory flag for %@: %@", url, error);
                isFile = YES;
            }
            // One string per entry, rather than the URL and two strings
            // URLByDeletingLastPathComponent.path would cost. Non-audio entries
            // stay out of results but still reach the folder-art bookkeeping
            // below: a cover is exactly a non-audio entry.
            NSString *path = url.path;
            if (!isFile) {
                // A real subdirectory the enumerator descends itself: record it
                // so a link pointing anywhere into this subtree is recognized as
                // covered. One a link already made a root of is skipped whole.
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
                // A link to a file stays a file, reaching the extension filter
                // and the emptiness stat like any other entry. One pointing at
                // nothing is dropped here instead: that filter answers NO to
                // anything it cannot stat, deliberately, so that a sandbox
                // denial is left for the real open to report (NSURL+AudioOpen)
                // — which means a dangling Song.mp3 link would otherwise
                // survive as an unplayable row. The link itself just came out
                // of the enumeration, so ENOENT can only be its target.
                struct stat targetInfo;
                if (stat(path.fileSystemRepresentation, &targetInfo) != 0 && errno == ENOENT) {
                    continue;
                }
            }
            BOOL isAudio = [supported containsObject:path.pathExtension.lowercaseString];
            if (isAudio) {
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

    // The enumerator returns APFS hash order, which is effectively random —
    // which is also what Settings > Files' "Keep folder order" leaves in place
    // here, since a local volume has no meaningful order to preserve. The
    // other two choices sort by full path with Finder's numeric comparator,
    // which groups subfolders, or by date. An explicit multi-file drop keeps its pasteboard
    // order either way; see expandFileList:folderCount:.
    VibeSortAudioURLs(results, sort, YES);

    return results;
}

+ (NSArray<NSURL*>*) audioFilesInDirectory:(NSURL*)dir sortedBy:(VibeFolderOpenSort)sort {
    // Non-recursive, unlike expandDirectory:sortedBy:. Skipping hidden files
    // also drops the AppleDouble "._Song.mp3" sidecars; see that method.
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
        if (![supported containsObject:[url.pathExtension lowercaseString]]) {
            continue;
        }
        if (!url.isEmptyOrDirectory) {
            [results addObject:url];
        }
    }
    VibeSortAudioURLs(results, sort, NO);
    return results;
}

// Folder walks are independent and can block on unrelated mounts, so they run
// concurrently rather than serially: one dead folder must not hold every later
// open hostage. Callers that can issue overlapping opens own their ordering and
// replacement policy through OpenRequestCoordinator.
//
// Bounded at four workers, the same width as the metadata scan. A walk that
// blocks holds its worker for as long as the mount takes, and an unbounded
// concurrent queue would answer a burst of such drops by spawning a thread
// each, up to GCD's ceiling, all at user-initiated priority.
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
                  completion:(void (^)(NSArray<NSURL*>*, NSUInteger))completion {
    [[self expansionQueue] addOperationWithBlock:^{
        NSUInteger folderCount = 0;
        NSArray<NSURL*> *results = [self expandAndFilterList:list sortedBy:sort
                                                 folderCount:&folderCount];
        run_on_main_thread({
            completion(results, folderCount);
        });
    }];
}

+ (NSArray<NSURL*>*) expandAndFilterList:(NSArray<NSURL*>*)list
                                sortedBy:(VibeFolderOpenSort)sort
                             folderCount:(NSUInteger *)folderCount {
    NSUInteger inputCount = list.count;
    NSMutableSet<NSString*> *looseFileDirectories = [NSMutableSet set];
    list = [NSURLUtil expandFileList:list
                            sortedBy:sort
                         folderCount:folderCount
                looseFileDirectories:looseFileDirectories];
    NSUInteger expandedCount = list.count;
    NSSet<NSString*> *supported = [NSURLUtil supportedExtensions];
    // Empty entries go the way of the AppleDouble sidecars the walk skips:
    // nothing can play them, and one reaching an open would leak a descriptor
    // (NSURL+AudioOpen). Ordered second so it stats only the extension matches.
    list = [list filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary* bindings) {
        return [supported containsObject:[url.pathExtension lowercaseString]] && !url.isEmptyOrDirectory;
    }]];
    NSMutableSet<NSString *> *supportedLooseDirectories = [NSMutableSet set];
    for (NSURL *url in list) {
        [self noteLooseFileDirectoryOf:url into:supportedLooseDirectories];
    }
    [looseFileDirectories intersectSet:supportedLooseDirectories];
    // Anything but a single file is a bulk open, whose folders are worth one
    // listing each rather than the lone file's stat probes. A dropped folder's
    // directories were walked above and are settled, so only the loose files'
    // folders are left to mark — including a playlist file's tracks, which is
    // why the post-expansion count matters: a dropped .cue is one file that
    // names a whole album.
    BOOL bulkOpen = inputCount > 1 || (folderCount && *folderCount > 0) ||
                    looseFileDirectories.count > 1 || expandedCount > inputCount;
    VibeBulkOpenDirectoriesHandler bulk = BulkOpenDirectoriesHandler();
    if (bulkOpen && bulk && looseFileDirectories.count > 0) {
        bulk(looseFileDirectories);
    }
    return list;
}

// looseFileDirectories collects the folders of files that did NOT come from
// walking a folder — a multi-file open, or a playlist file's tracks. Only those
// still need their artwork resolved; a walked folder settled its own.
+ (NSArray<NSURL*>*) expandFileList:(NSArray<NSURL*>*)list
                           sortedBy:(VibeFolderOpenSort)sort
                        folderCount:(NSUInteger *)folderCount
               looseFileDirectories:(NSMutableSet<NSString*> *)looseFileDirectories {
    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] initWithCapacity:list.count];
    for (NSURL *url in list) {
        // Ask the filesystem rather than the URL. hasDirectoryPath inspects
        // only the trailing slash, so a directory URL built without
        // isDirectory:YES — from an argv path or some pasteboards — would be
        // treated as a file and then silently dropped by the extension filter.
        // Both keys in one read: NSURLIsDirectoryKey answers for the link
        // itself, so a dropped ~/Music/NAS folder link needs resolving before
        // that same filter drops it (VibeResolvedDirectoryPath).
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
            NSArray<NSURL*> *tracks = [self expandPlaylistFile:url];
            [results addObjectsFromArray:tracks];
            for (NSURL *track in tracks) {
                [self noteLooseFileDirectoryOf:track into:looseFileDirectories];
            }
        }
        else {
            [results addObject:url];
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

// access(2) rather than NSFileManager, because the errno is the only way to
// tell a file that is not there from one the sandbox will not let us read —
// and only the latter is worth interrupting the user with a grant prompt.
static VibeReadAccess ReadAccessForURL(NSURL *url) {
    if (access(url.fileSystemRepresentation, R_OK) == 0) {
        return VibeReadAccessReadable;
    }
    return (errno == EPERM || errno == EACCES) ? VibeReadAccessDenied : VibeReadAccessMissing;
}

// A top-level playlist file (.cue, .m3u, .m3u8) expands like a directory: the
// audio files it lists, in list order. Only explicitly opened ones expand —
// one found inside a folder walk is dropped by the extension filter, since
// the walk already yields the folder's audio and expanding it too would
// double every track.
//
// Opening a playlist file grants sandbox access to it alone, not to the files
// it names, so a denied entry raises a one-shot folder grant through the
// installed handler; granting is what extends the sandbox, and the re-resolve
// then also gets a working basename fallback. Entries unreadable after all
// that are skipped.
#if TARGET_OS_OSX
// Only the macOS grant-panel path below reads the handler; the setter stays
// unconditional so the app can install one on either platform.
static VibePlaylistFolderGrantHandler PlaylistFolderGrantHandler(void) {
    @synchronized (NSURLUtil.class) {
        return sPlaylistFolderGrantHandler;
    }
}
#endif

+ (NSArray<NSURL *> *)expandPlaylistFile:(NSURL *)playlistURL {
    NSArray<NSURL *> *resolved = [PlaylistFile resolvedFileURLsForPlaylistAtURL:playlistURL];
#if TARGET_OS_OSX
    // Each probe is a blocking syscall that can hang on a dead mount, so the
    // scan's verdicts are kept for the readable filter below (partial when the
    // scan exits early) and dropped only when a grant re-resolve replaces the
    // URLs — a grant changes readability.
    NSMutableDictionary<NSString *, NSNumber *> *scannedAccessByPath =
            [NSMutableDictionary dictionaryWithCapacity:resolved.count];
    BOOL anyUnreadable = NO;
    BOOL anyDenied = NO;
    for (NSURL *url in resolved) {
        VibeReadAccess access = ReadAccessForURL(url);
        scannedAccessByPath[url.path] = @(access);
        anyUnreadable |= (access != VibeReadAccessReadable);
        anyDenied |= (access == VibeReadAccessDenied);
        if (anyUnreadable && anyDenied) {
            break;  // both facts settled; stop paying probes
        }
    }
    // A missing-looking entry still warrants the grant prompt while the
    // playlist's own folder is denied: unresolved entries fall back to their
    // as-written path, which can be genuinely absent (a foreign subfolder
    // spelling) and so read as "missing" — but with the folder unreadable,
    // the fallback candidates beside the playlist could not be probed at all,
    // so "missing" cannot be trusted until the folder opens up.
    BOOL folderDenied =
            ReadAccessForURL(playlistURL.URLByDeletingLastPathComponent) == VibeReadAccessDenied;
    VibePlaylistFolderGrantHandler grantHandler = PlaylistFolderGrantHandler();
    if (anyUnreadable && (anyDenied || folderDenied)
            && grantHandler && grantHandler(playlistURL)) {
        resolved = [PlaylistFile resolvedFileURLsForPlaylistAtURL:playlistURL];
        [scannedAccessByPath removeAllObjects];
    }
#endif
    NSMutableArray<NSURL *> *readable = [NSMutableArray arrayWithCapacity:resolved.count];
    for (NSURL *url in resolved) {
#if TARGET_OS_OSX
        NSNumber *scanned = scannedAccessByPath[url.path];
        VibeReadAccess access = scanned != nil
                ? (VibeReadAccess)scanned.integerValue : ReadAccessForURL(url);
#else
        VibeReadAccess access = ReadAccessForURL(url);
#endif
        if (access == VibeReadAccessReadable) {
            [readable addObject:url];
        }
        else {
            LogWarn(@"Skipping unreadable playlist entry: %@", url.path);
        }
    }
    LogInfo(@"Playlist file %@ expanded to %lu of %lu entries", playlistURL.lastPathComponent,
            (unsigned long)readable.count, (unsigned long)resolved.count);
    return readable;
}

@end
