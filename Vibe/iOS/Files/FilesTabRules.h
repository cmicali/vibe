//
//  FilesTabRules.h
//  Vibe (iOS)
//
//  The Files tab's decisions beside the browser's (BrowserRules.h): the long
//  press Recents and Search share, and the URLs Recents names. Header-only and Foundation-only so the macOS suite can
//  test it.
//

#ifndef FilesTabRules_h
#define FilesTabRules_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - A row's long press

typedef NS_OPTIONS(NSUInteger, VibeFilesTabRowActions) {
    VibeFilesTabRowActionPlay = 1 << 0,
    VibeFilesTabRowActionPlayInFolder = 1 << 1,
    VibeFilesTabRowActionAddToPlaylist = 1 << 2,
    VibeFilesTabRowActionOpenFolder = 1 << 3,
};

// The long press Recents and Search share: Play, Play in Folder for a file,
// Add to Playlist, and Open Folder. The add sheet only adds. A playlist file
// is never part of its folder's play. A link has neither folder action,
// since its folder is the Links store's, named by a hash (folderActions NO).
static inline VibeFilesTabRowActions VibeFilesTabRowActionsFor(BOOL isFolder, BOOL appendingSheet, BOOL isM3U,
                                                             BOOL folderActions) {
    VibeFilesTabRowActions actions = VibeFilesTabRowActionAddToPlaylist;
    if (!appendingSheet) {
        actions |= VibeFilesTabRowActionPlay;
        if (!isFolder && folderActions && !isM3U) {
            actions |= VibeFilesTabRowActionPlayInFolder;
        }
    }
    if (folderActions) {
        actions |= VibeFilesTabRowActionOpenFolder;
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

#endif /* FilesTabRules_h */
