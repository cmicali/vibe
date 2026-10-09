//
//  FileSearchRules.h
//  Vibe (iOS)
//
//  What a query matches, for both of the search screen's sections, which must
//  agree where they overlap. Then the Files tab's decisions: the root's rows,
//  what Recents names, which open the next launch restores, and which links a
//  launch keeps. Header-only and Foundation-only so the macOS suite can test
//  it.
//

#ifndef FileSearchRules_h
#define FileSearchRules_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - What a query matches

// Case, diacritic and width insensitive, anywhere in the text. An empty query
// matches everything, for the playlist's browse list; the files section tests
// the length itself, since a dump of a provider tree is no browse list.
static inline BOOL VibeSearchTextMatchesQuery(NSString *_Nullable text, NSString *query) {
    if (query.length == 0) {
        return YES;
    }
    if (text.length == 0) {
        return NO;
    }
    NSStringCompareOptions options =
            NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    return [text rangeOfString:query
                       options:options
                         range:NSMakeRange(0, text.length)
                        locale:NSLocale.currentLocale].location != NSNotFound;
}

// Folded once per file by the walk: folding per row per keystroke costs far
// more than the search.
static inline NSString *VibeSearchFoldedText(NSString *_Nullable text) {
    if (text.length == 0) {
        return @"";
    }
    NSStringCompareOptions options =
            NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
    return [text stringByFoldingWithOptions:options locale:NSLocale.currentLocale];
}

static inline BOOL VibeSearchFoldedTextContainsQuery(NSString *foldedText,
                                                      NSString *foldedQuery) {
    return foldedQuery.length > 0
            && [foldedText rangeOfString:foldedQuery].location != NSNotFound;
}

static inline BOOL VibeSearchTrackMatchesQuery(NSString *_Nullable title,
                                               NSString *_Nullable artist,
                                               NSString *fileName,
                                               NSString *query) {
    return VibeSearchTextMatchesQuery(title, query)
            || (artist.length > 0 && VibeSearchTextMatchesQuery(artist, query))
            || VibeSearchTextMatchesQuery(fileName, query);
}

// The root IS the path or contains it. Both must be standardized; no disk. The
// separator on BOTH sides keeps "/Music" from covering "/Music Videos" while an
// exact match still counts.
static inline BOOL VibeSearchRootCoversPath(NSString *rootPath, NSString *path) {
    if (rootPath.length == 0 || path.length == 0) {
        return NO;
    }
    NSString *rootPrefix = [rootPath hasSuffix:@"/"] ? rootPath
                                                     : [rootPath stringByAppendingString:@"/"];
    NSString *pathPrefix = [path hasSuffix:@"/"] ? path : [path stringByAppendingString:@"/"];
    return [pathPrefix hasPrefix:rootPrefix];
}

// SearchFolderStore's merge keeps roots minimal: an existing ancestor absorbs a
// candidate (an exact duplicate included), and a candidate ancestor removes
// every descendant.
static inline NSUInteger VibeSearchFolderCoveringRootIndex(
        NSArray<NSString *> *rootPaths, NSString *candidatePath) {
    for (NSUInteger index = 0; index < rootPaths.count; index++) {
        if (VibeSearchRootCoversPath(rootPaths[index], candidatePath)) {
            return index;
        }
    }
    return NSNotFound;
}

static inline NSIndexSet *VibeSearchFolderIndexesCoveredByRoot(
        NSArray<NSString *> *rootPaths, NSString *candidatePath) {
    NSMutableIndexSet *covered = [NSMutableIndexSet indexSet];
    for (NSUInteger index = 0; index < rootPaths.count; index++) {
        if (VibeSearchRootCoversPath(candidatePath, rootPaths[index])) {
            [covered addIndex:index];
        }
    }
    return covered;
}

// A removed covering root suppresses only pending bookmarks inside it. A live
// root that now covers the bookmark is an explicit re-add and wins over that
// older removal.
static inline BOOL VibeSearchPendingRestoreShouldBeSuppressed(
        NSArray<NSString *> *suppressedRootPaths,
        NSArray<NSString *> *liveRootPaths,
        NSString *resolvedPath) {
    return VibeSearchFolderCoveringRootIndex(suppressedRootPaths, resolvedPath) != NSNotFound
            && VibeSearchFolderCoveringRootIndex(liveRootPaths, resolvedPath) == NSNotFound;
}

#pragma mark - The root's rows

typedef NS_ENUM(NSInteger, VibeBrowserRootSection) {
    VibeBrowserRootSectionSources = 0,
    // Its own group: a place to go back to, not a place files live.
    VibeBrowserRootSectionRecents,
    // Last: its footer needs the room a last section has.
    VibeBrowserRootSectionLocations,
    VibeBrowserRootSectionCount,
};

typedef NS_ENUM(NSInteger, VibeBrowserRootRow) {
    VibeBrowserRootRowDevice = 0,
    VibeBrowserRootRowDropbox,
    VibeBrowserRootRowRecents,
    VibeBrowserRootRowLocation,
    VibeBrowserRootRowConnectDropbox,
    VibeBrowserRootRowAddFolder,
    VibeBrowserRootRowBrowseFiles,
    VibeBrowserRootRowOpenURL,
};

// The rows of one root section. Sources: the device, and Dropbox once linked.
// Recents, alone. Locations: the granted folders first, so a location's row
// is its index in the store. Then Connect to Dropbox until an account is
// linked, Add Folder…, Browse Files…, and Open URL….
static inline NSArray<NSNumber *> *VibeBrowserRootRows(VibeBrowserRootSection section,
                                                       BOOL dropboxLinked,
                                                       NSUInteger locations) {
    if (section == VibeBrowserRootSectionSources) {
        return dropboxLinked ? @[@(VibeBrowserRootRowDevice), @(VibeBrowserRootRowDropbox)]
                             : @[@(VibeBrowserRootRowDevice)];
    }
    if (section == VibeBrowserRootSectionRecents) {
        return @[@(VibeBrowserRootRowRecents)];
    }
    if (section != VibeBrowserRootSectionLocations) {
        return @[];
    }
    NSMutableArray<NSNumber *> *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < locations; i++) {
        [rows addObject:@(VibeBrowserRootRowLocation)];
    }
    if (!dropboxLinked) {
        [rows addObject:@(VibeBrowserRootRowConnectDropbox)];
    }
    [rows addObject:@(VibeBrowserRootRowAddFolder)];
    [rows addObject:@(VibeBrowserRootRowBrowseFiles)];
    [rows addObject:@(VibeBrowserRootRowOpenURL)];
    return rows;
}

#pragma mark - Recents

// A recent's second line. A link is named by its host, from its record, else
// from the record's URL. Anything else, and a link with neither, by its
// folder's name.
static inline NSString *VibeRecentLocationName(NSDictionary *_Nullable linkRecord, NSString *folderName) {
    id host = linkRecord[@"host"];
    if ([host isKindOfClass:NSString.class] && [host length] > 0) {
        return host;
    }
    id url = linkRecord[@"url"];
    NSString *urlHost = [url isKindOfClass:NSString.class] ? [NSURL URLWithString:url].host.lowercaseString : nil;
    return urlHost.length > 0 ? urlHost : folderName;
}

// The recents' file URLs, from the paths they recorded. A launch's pruning
// keeps every link these name.
static inline NSArray<NSURL *> *VibeRecentItemURLs(NSArray *items) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (id item in items) {
        id path = [item isKindOfClass:NSDictionary.class] ? ((NSDictionary *)item)[@"path"] : nil;
        if ([path isKindOfClass:NSString.class] && [path length] > 0) {
            [urls addObject:[NSURL fileURLWithPath:path]];
        }
    }
    return urls;
}

#pragma mark - The restored playlist

// Whether an open's base becomes the bookmark the next launch restores. An
// open strictly inside a one-off pick's grant keeps the session's. A one-file
// open keeps a folder bookmark, whose grant reaches more than the file. A
// link is the one exception. It needs no grant, a web address is the only
// other way back to it, and the next launch restores it from its
// placeholder. A mirror file opened alone keeps the folder bookmark.
static inline BOOL VibeFolderSessionPersistsBase(BOOL keepsSessionBookmark,
                                                 BOOL openedFolder,
                                                 BOOL persistedBaseIsFolder,
                                                 BOOL baseIsLink) {
    if (keepsSessionBookmark) {
        return NO;
    }
    return openedFolder || baseIsLink || !persistedBaseIsFolder;
}

NS_ASSUME_NONNULL_END

#endif /* FileSearchRules_h */
