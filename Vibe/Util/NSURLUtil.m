//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSURLUtilInternal.h"
#import "FolderArtRules.h"
#import "NSURL+AudioOpen.h"
#import "PlaylistFile.h"

#include <sys/stat.h>
#include <unistd.h>

// Installed once at launch, read from the expansion workers, so each handoff
// takes a lock rather than assuming the install lands first.
static VibePlaylistFolderGrantHandler sPlaylistFolderGrantHandler;
static VibeWalkedDirectoriesHandler sWalkedDirectoriesHandler;
static VibeBulkOpenDirectoriesHandler sBulkOpenDirectoriesHandler;

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

+ (BOOL)isDatalessFile:(NSURL *)url {
    struct stat st;
    if (stat(url.fileSystemRepresentation, &st) != 0) {
        return NO;
    }
    return (st.st_flags & SF_DATALESS) != 0;
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

// A static set, consulted once per file in a folder drop. Must cover every
// spelling the CFBundleDocumentTypes claim admits: com.microsoft.waveform-audio
// declares wav, wave, AND bwf, so dropping one here would let Finder offer
// Vibe for a file the filter then silently discards.
+ (NSSet<NSString*>*) supportedExtensions {
    static NSSet<NSString*> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithObjects:@"mp2", @"mp3", @"aac", @"aif", @"aiff",
                                           @"wav", @"wave", @"bwf", @"flac", @"m4a", @"mp4", nil];
    });
    return extensions;
}

// The walk picks the album cover out on the way past: it already touches every
// entry, so the walked-directories handler gets the whole folder's answer for
// the cost of a rank lookup per name. Only directories contributing playable
// audio are handed over; nothing will ask about an "Artwork" subfolder.
+ (NSArray<NSURL*>*) expandDirectory:(NSURL*)dir {

    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] init];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    // directory -> the best cover filename seen in it so far, and its rank.
    NSMutableDictionary<NSString*, NSString*> *artByDirectory = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSNumber*> *artRankByDirectory = [NSMutableDictionary dictionary];
    NSMutableSet<NSString*> *directoriesWalked = [NSMutableSet set];
    NSSet<NSString*> *supported = [self supportedExtensions];
    // The enumerator is depth-first, so entries arrive in long runs from one
    // directory; remembering the last one avoids rebuilding the parent path for
    // every file in a folder.
    NSString *lastDirectory = nil;

    // Skip hidden files. On exFAT, SMB and USB volumes macOS writes
    // AppleDouble sidecars such as "._Song.mp3", whose extension passes the
    // filetype filter but which hold resource-fork metadata rather than audio;
    // each one showed up as a duplicate, unplayable playlist row. Skipping
    // package descendants keeps the walk out of app and bundle internals.
    NSDirectoryEnumerator *enumerator = [fileManager
            enumeratorAtURL:dir
 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
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
        if (!isFile) {
            continue;
        }
        // One string per entry, rather than the URL and two strings
        // URLByDeletingLastPathComponent.path would cost. Non-audio entries
        // stay out of results but still reach the folder-art bookkeeping
        // below: a cover is exactly a non-audio entry.
        NSString *path = url.path;
        if ([supported containsObject:path.pathExtension.lowercaseString]) {
            [results addObject:url];
        }
        if (!VibePathIsDirectlyInside(path, lastDirectory)) {
            lastDirectory = path.stringByDeletingLastPathComponent;
        }
        if (lastDirectory.length > 0 &&
                [supported containsObject:path.pathExtension.lowercaseString]) {
            [directoriesWalked addObject:lastDirectory];
        }
        VibeFolderArtNoteCandidate(lastDirectory, path.lastPathComponent,
                                   artByDirectory, artRankByDirectory);
    }

    VibeWalkedDirectoriesHandler walked = WalkedDirectoriesHandler();
    if (walked && directoriesWalked.count > 0) {
        walked(directoriesWalked, artByDirectory);
    }

    // The enumerator returns APFS hash order, which is effectively random, so
    // sort by full path with Finder's comparator, which is numeric and groups
    // subfolders. An explicit multi-file drop keeps its pasteboard order; see
    // expandFileList:folderCount:.
    [results sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.path localizedStandardCompare:b.path];
    }];

    return results;
}

+ (NSArray<NSURL*>*) audioFilesInDirectory:(NSURL*)dir {
    // Non-recursive, unlike expandDirectory:. Skipping hidden files also
    // drops the AppleDouble "._Song.mp3" sidecars; see expandDirectory:.
    NSError *error = nil;
    NSArray<NSURL*> *contents = [[NSFileManager defaultManager]
            contentsOfDirectoryAtURL:dir
          includingPropertiesForKeys:@[NSURLIsDirectoryKey]
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
        NSNumber *isDirectory = nil;
        BOOL isDir = [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL]
                ? isDirectory.boolValue
                : url.hasDirectoryPath;
        if (!isDir) {
            [results addObject:url];
        }
    }
    [results sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
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
                  completion:(void (^)(NSArray<NSURL*>*, NSUInteger))completion {
    [[self expansionQueue] addOperationWithBlock:^{
        NSUInteger folderCount = 0;
        NSArray<NSURL*> *results = [self expandAndFilterList:list folderCount:&folderCount];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(results, folderCount);
        });
    }];
}

+ (NSArray<NSURL*>*) expandAndFilterList:(NSArray<NSURL*>*)list folderCount:(NSUInteger *)folderCount {
    NSUInteger inputCount = list.count;
    NSMutableSet<NSString*> *looseFileDirectories = [NSMutableSet set];
    list = [NSURLUtil expandFileList:list
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
                        folderCount:(NSUInteger *)folderCount
               looseFileDirectories:(NSMutableSet<NSString*> *)looseFileDirectories {
    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] initWithCapacity:list.count];
    for (NSURL *url in list) {
        // Ask the filesystem rather than the URL. hasDirectoryPath inspects
        // only the trailing slash, so a directory URL built without
        // isDirectory:YES — from an argv path or some pasteboards — would be
        // treated as a file and then silently dropped by the extension filter.
        NSNumber *isDirectory = nil;
        BOOL isDir = [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL]
                ? isDirectory.boolValue
                : url.hasDirectoryPath; // resource read failed; fall back to the slash
        if (isDir) {
            if (folderCount) {
                (*folderCount)++;
            }
            [results addObjectsFromArray:[self expandDirectory:url]];
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
    BOOL anyUnreadable = NO;
    BOOL anyDenied = NO;
    for (NSURL *url in resolved) {
        VibeReadAccess access = ReadAccessForURL(url);
        anyUnreadable |= (access != VibeReadAccessReadable);
        anyDenied |= (access == VibeReadAccessDenied);
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
    }
#endif
    NSMutableArray<NSURL *> *readable = [NSMutableArray arrayWithCapacity:resolved.count];
    for (NSURL *url in resolved) {
        if (ReadAccessForURL(url) == VibeReadAccessReadable) {
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
