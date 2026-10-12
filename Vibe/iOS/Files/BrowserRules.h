//
//  BrowserRules.h
//  Vibe (iOS)
//
//  The Files tab's decisions: the root's rows, and the URLs Recents names.
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
