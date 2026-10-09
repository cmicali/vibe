//
//  FilesTabRules.h
//  Vibe (iOS)
//
//  The decisions behind the Files tab that need no UIKit and no disk: the
//  root's rows, what Recents names and offers for an item, which open the
//  next launch restores, and which links a launch keeps. Header-only and
//  Foundation-only so the macOS suite can test it.
//

#ifndef FilesTabRules_h
#define FilesTabRules_h

#import <Foundation/Foundation.h>

#import "FileSearchRules.h"

NS_ASSUME_NONNULL_BEGIN

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
// linked, Add Folder…, Browse Files… and Open URL….
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

// A file is a link when its path lies under the Links root. Both paths are
// comparable spellings. No disk.
static inline BOOL VibePathIsLink(NSString *_Nullable path, NSString *_Nullable linksRootPath) {
    return path.length > 0 && linksRootPath.length > 0 && VibeSearchRootCoversPath(linksRootPath, path);
}

// Play in Folder and Open Folder, for a recent. A link's folder is the
// store's, named by a hash and holding the one file, so it offers neither.
static inline BOOL VibeRecentOffersFolderActions(NSString *_Nullable path, NSString *_Nullable linksRootPath) {
    return !VibePathIsLink(path, linksRootPath);
}

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

#endif
