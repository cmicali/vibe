//
// Created by Christopher Micali on 12/18/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "NSURLUtil.h"
#import "PlaylistFile.h"

#include <sys/stat.h>
#include <unistd.h>

// Installed once at launch, read from the expansion workers, so the handoff
// takes a lock rather than assuming the install lands first.
static VibePlaylistFolderGrantHandler sPlaylistFolderGrantHandler;

static VibePlaylistFolderGrantHandler PlaylistFolderGrantHandler(void) {
    @synchronized (NSURLUtil.class) {
        return sPlaylistFolderGrantHandler;
    }
}


@implementation NSURLUtil

+ (void)setPlaylistFolderGrantHandler:(VibePlaylistFolderGrantHandler)handler {
    @synchronized (self) {
        sPlaylistFolderGrantHandler = [handler copy];
    }
}

+ (BOOL)isDatalessFile:(NSURL *)url {
    struct stat st;
    if (stat(url.fileSystemRepresentation, &st) != 0) {
        return NO;
    }
    return (st.st_flags & SF_DATALESS) != 0;
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

+ (NSArray<NSURL*>*) expandDirectory:(NSURL*)dir {

    NSMutableArray<NSURL*> *results = [[NSMutableArray alloc] init];
    NSFileManager *fileManager = [NSFileManager defaultManager];

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
    // Filtered here rather than only by the caller's pass, so a folder of
    // thousands of non-audio files costs neither the retain nor its share of
    // the sort below. Hoisted out of the loop: it is consulted once per entry.
    NSSet<NSString *> *supported = [self supportedExtensions];
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
        if (isFile && [supported containsObject:url.pathExtension.lowercaseString]) {
            [results addObject:url];
        }
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
    list = [NSURLUtil expandFileList:list folderCount:folderCount];
    NSSet<NSString*> *supported = [NSURLUtil supportedExtensions];
    list = [list filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary* bindings) {
        return [supported containsObject:[url.pathExtension lowercaseString]];
    }]];
    return list;
}

+ (NSArray<NSURL*>*) expandFileList:(NSArray<NSURL*>*)list folderCount:(NSUInteger *)folderCount {
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
            [results addObjectsFromArray:[self expandPlaylistFile:url]];
        }
        else {
            [results addObject:url];
        }
    }
    return results;
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
