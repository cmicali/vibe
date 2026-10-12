//
//  FileSearchRules.h
//  Vibe (iOS)
//
//  What a query matches, for both of the search screen's sections, which must
//  agree where they overlap. Then the Files tab's decisions: the root's rows,
//  what Recents names, which open the next launch restores, and which links a
//  launch keeps. Last, how FolderSession's open intents settle. Header-only
//  and Foundation-only so the macOS suite can test it.
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
    VibeBrowserRootSectionLocations = 0,
    // Its own group: a place to go back to, not a place files live.
    VibeBrowserRootSectionRecents,
    VibeBrowserRootSectionActions,
    VibeBrowserRootSectionCount,
};

typedef NS_ENUM(NSInteger, VibeBrowserRootRow) {
    VibeBrowserRootRowDevice = 0,
    VibeBrowserRootRowDropbox,
    VibeBrowserRootRowLocation,
    VibeBrowserRootRowRecents,
    VibeBrowserRootRowChooseFile,
    VibeBrowserRootRowOpenURL,
    VibeBrowserRootRowPasteURL,
};

// The rows of one root section. Locations: the device, Dropbox once linked,
// then the granted folders in the store's order. Recents, alone. Actions:
// Choose File… and Open URL…. The paste row follows Open URL… only while the
// clipboard probably holds a web link. Adding a location is the bar's plus.
static inline NSArray<NSNumber *> *VibeBrowserRootRows(VibeBrowserRootSection section,
                                                       BOOL dropboxLinked,
                                                       NSUInteger locations,
                                                       BOOL clipboardHasLink) {
    if (section == VibeBrowserRootSectionLocations) {
        NSMutableArray<NSNumber *> *rows = [NSMutableArray arrayWithObject:@(VibeBrowserRootRowDevice)];
        if (dropboxLinked) {
            [rows addObject:@(VibeBrowserRootRowDropbox)];
        }
        for (NSUInteger i = 0; i < locations; i++) {
            [rows addObject:@(VibeBrowserRootRowLocation)];
        }
        return rows;
    }
    if (section == VibeBrowserRootSectionRecents) {
        return @[@(VibeBrowserRootRowRecents)];
    }
    if (section != VibeBrowserRootSectionActions) {
        return @[];
    }
    return clipboardHasLink
            ? @[@(VibeBrowserRootRowChooseFile), @(VibeBrowserRootRowOpenURL), @(VibeBrowserRootRowPasteURL)]
            : @[@(VibeBrowserRootRowChooseFile), @(VibeBrowserRootRowOpenURL)];
}

// A Location row's index in SearchFolderStore, or NSNotFound for any other
// row. The folders follow the device and, once linked, Dropbox.
static inline NSUInteger VibeBrowserRootLocationIndex(VibeBrowserRootSection section,
                                                      NSUInteger row,
                                                      BOOL dropboxLinked,
                                                      NSUInteger locations) {
    NSUInteger first = dropboxLinked ? 2 : 1;
    if (section != VibeBrowserRootSectionLocations || row < first || row - first >= locations) {
        return NSNotFound;
    }
    return row - first;
}

#pragma mark - Recents

// The recents' file URLs, from the paths they recorded. A launch's pruning
// keeps every link these name.
// TRAP: never fileURLWithPath: alone. It stats the path, and a recent on an
// unreachable SMB share then holds main for the connect's 30 s timeout.
static inline NSArray<NSURL *> *VibeRecentItemURLs(NSArray *items) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (id item in items) {
        NSDictionary *entry = [item isKindOfClass:NSDictionary.class] ? item : nil;
        id path = entry[@"path"];
        if ([path isKindOfClass:NSString.class] && [path length] > 0) {
            id folder = entry[@"folder"];
            BOOL isFolder = [folder isKindOfClass:NSNumber.class] && [folder boolValue];
            [urls addObject:[NSURL fileURLWithPath:path isDirectory:isFolder]];
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

// The base is the FIRST contributor, even a file, and an append never moves
// it. So a folder claims the base only as a replace's first contributor.
static inline BOOL VibeFolderSessionFolderClaimsBase(BOOL appending, NSUInteger contributorCount) {
    return !appending && contributorCount == 1;
}

// An open leaves the session bookmark alone when a URL lies strictly inside a
// hold only the session has, a one-off pick. A Location's grant or a favorite
// over it persists by itself, so the open is remembered.
static inline BOOL VibeFolderSessionKeepsSessionBookmark(BOOL insideSessionHold,
                                                         BOOL isSessionHoldRoot,
                                                         BOOL underSearchGrant,
                                                         BOOL underFavorite) {
    return insideSessionHold && !isSessionHoldRoot && !underSearchGrant && !underFavorite;
}

#pragma mark - The open intent

// A replace bumps openIntentGeneration and an Add captures it. The landed
// generation is the last settled replace's. It is zero while nothing has
// landed. FolderSession holds the state, and its TRAP: comments the sequences.

// Whether an Add may still land, from the token taken when the user asked. A
// token one below the live promoted generation is a promoted sibling's, so it
// is still the user's. A real replace or a clear bumps past it.
static inline BOOL VibeFolderSessionAddTokenIsCurrent(uint64_t token,
                                                      uint64_t openIntentGeneration,
                                                      uint64_t promotedOpenIntentGeneration) {
    if (token == openIntentGeneration) {
        return YES;
    }
    return promotedOpenIntentGeneration != 0
            && token + 1 == promotedOpenIntentGeneration
            && openIntentGeneration == promotedOpenIntentGeneration;
}

// An Add onto a session that has landed nothing is an open. Only the first
// such Add promotes. The rest park until that open settles.
static inline BOOL VibeFolderSessionAddPromotes(BOOL appending,
                                                uint64_t landedOpenIntentGeneration,
                                                BOOL promotedOpenInFlight) {
    return appending && landedOpenIntentGeneration == 0 && !promotedOpenInFlight;
}

static inline BOOL VibeFolderSessionAddParks(BOOL appending,
                                             uint64_t landedOpenIntentGeneration,
                                             BOOL promotedOpenInFlight) {
    return appending && landedOpenIntentGeneration == 0 && promotedOpenInFlight;
}

// An append lands only against the replace that settled last. An append
// captured during an open that never landed is dropped.
static inline BOOL VibeFolderSessionAppendIsStale(BOOL appending,
                                                  uint64_t openIntentGeneration,
                                                  uint64_t landedOpenIntentGeneration) {
    return appending && landedOpenIntentGeneration != openIntentGeneration;
}

// The landed generation once a current request settles. A replace that found
// tracks lands its own. An empty replace or a cancel still settles: the
// playlist left standing answers for it. Zero stays zero, so the next Add is
// still promoted. An append moves nothing.
static inline uint64_t VibeFolderSessionLandedOpenIntentGeneration(
        uint64_t landedOpenIntentGeneration,
        uint64_t openIntentGeneration,
        BOOL appending,
        BOOL foundTracks) {
    if (appending) {
        return landedOpenIntentGeneration;
    }
    if (foundTracks || landedOpenIntentGeneration != 0) {
        return openIntentGeneration;
    }
    return 0;
}

NS_ASSUME_NONNULL_END

#endif /* FileSearchRules_h */
