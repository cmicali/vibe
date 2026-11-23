//
//  BrowserRules.h
//  Vibe (iOS)
//
//  The browser's decisions: a Locations row's folder, a folder's empty
//  state, and a row's tile. Header-only and Foundation-only so the macOS
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
