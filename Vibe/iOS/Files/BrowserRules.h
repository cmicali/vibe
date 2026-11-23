//
//  BrowserRules.h
//  Vibe (iOS)
//
//  The browser's decisions: a Locations row's folder, which root covers a
//  path, a folder's empty state, and a row's tile. Header-only and Foundation-only so the macOS
//  suite can test it. The Files tab's own are FilesTabRules.h.
//

#ifndef BrowserRules_h
#define BrowserRules_h

#import <Foundation/Foundation.h>

#import "VibePlaylistFile.h"

NS_ASSUME_NONNULL_BEGIN

// A CUE sheet or an M3U by its name, which takes the playlist tile.
static inline BOOL VibeBrowserIsPlaylistName(NSString *_Nullable name) {
    return [VibePlaylistFile isPlaylistExtension:name.pathExtension.lowercaseString];
}

#pragma mark - The root's Locations

// A Locations row's index among the granted folders, or NSNotFound for a
// source's row. The sources the root last reloaded with come first.
static inline NSUInteger VibeBrowserLocationIndex(NSUInteger row, NSUInteger sources, NSUInteger locations) {
    if (row < sources || row - sources >= locations) {
        return NSNotFound;
    }
    return row - sources;
}

#pragma mark - The Locations' roots

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

// LocationStore's merge keeps roots minimal: an existing ancestor absorbs a
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

#pragma mark - A folder

typedef NS_ENUM(NSInteger, VibeBrowserFolderEmptyState) {
    VibeBrowserFolderEmptyStateNone,         // rows to show
    VibeBrowserFolderEmptyStateNoMatches,    // a filter that matches nothing: a search with no results
    VibeBrowserFolderEmptyStateLoading,      // nothing listed yet, and a relist running
    VibeBrowserFolderEmptyStateUnavailable,  // nothing listed, and its source could not be reached
    VibeBrowserFolderEmptyStateEmpty,        // the folder holds nothing that plays
};

// listedRows: the folder's listing. shownRows: what the filter leaves of it.
static inline VibeBrowserFolderEmptyState VibeBrowserFolderEmptyStateFor(NSUInteger listedRows,
                                                                         NSUInteger shownRows,
                                                                         BOOL refreshing,
                                                                         BOOL refreshFailed) {
    if (listedRows > 0) {
        return shownRows == 0 ? VibeBrowserFolderEmptyStateNoMatches : VibeBrowserFolderEmptyStateNone;
    }
    if (refreshing) {
        return VibeBrowserFolderEmptyStateLoading;
    }
    return refreshFailed ? VibeBrowserFolderEmptyStateUnavailable : VibeBrowserFolderEmptyStateEmpty;
}

NS_ASSUME_NONNULL_END

#endif /* BrowserRules_h */
