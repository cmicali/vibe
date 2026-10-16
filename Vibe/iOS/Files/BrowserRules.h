//
//  BrowserRules.h
//  Vibe (iOS)
//
//  The Files tab's decisions: the root's rows, a folder's empty state, a
//  row's long press, and the URLs Recents names.
//  Header-only and Foundation-only so the macOS suite can test it.
//

#ifndef BrowserRules_h
#define BrowserRules_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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

// A Location row's index in LocationStore, or NSNotFound for any other
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

#pragma mark - A folder

typedef NS_ENUM(NSInteger, VibeBrowserFolderEmptyState) {
    VibeBrowserFolderEmptyStateNone,         // rows to show
    VibeBrowserFolderEmptyStateNoMatches,    // a filter that matches nothing: a search with no results
    VibeBrowserFolderEmptyStateLoading,      // nothing listed yet, and a relist running
    VibeBrowserFolderEmptyStateUnavailable,  // nothing listed, and Dropbox could not be reached
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

#pragma mark - A row's long press

typedef NS_OPTIONS(NSUInteger, VibeBrowserRowActions) {
    VibeBrowserRowActionPlay = 1 << 0,
    VibeBrowserRowActionPlayInFolder = 1 << 1,
    VibeBrowserRowActionAddToPlaylist = 1 << 2,
    VibeBrowserRowActionOpenFolder = 1 << 3,
};

// The long press Recents and Search share: Play, Play in Folder for a file,
// Add to Playlist, and Open Folder. The add sheet only adds. A playlist file
// is never part of its folder's play. A link has neither folder action,
// since its folder is the Links store's, named by a hash (folderActions NO).
static inline VibeBrowserRowActions VibeBrowserRowActionsFor(BOOL isFolder, BOOL appendingSheet, BOOL isM3U,
                                                             BOOL folderActions) {
    VibeBrowserRowActions actions = VibeBrowserRowActionAddToPlaylist;
    if (!appendingSheet) {
        actions |= VibeBrowserRowActionPlay;
        if (!isFolder && folderActions && !isM3U) {
            actions |= VibeBrowserRowActionPlayInFolder;
        }
    }
    if (folderActions) {
        actions |= VibeBrowserRowActionOpenFolder;
    }
    return actions;
}

#pragma mark - Recents

// The recents' file URLs, from the paths they recorded. A launch's pruning
// keeps every link these name.
// TRAP: pass isDirectory: to avoid a blocking stat of an unreachable path on main.
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

NS_ASSUME_NONNULL_END

#endif /* BrowserRules_h */
