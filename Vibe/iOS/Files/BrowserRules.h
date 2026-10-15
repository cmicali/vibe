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
    // A linked account, one row each, in AccountMirror.mirrors order.
    VibeBrowserRootRowAccount,
    VibeBrowserRootRowLocation,
    VibeBrowserRootRowRecents,
    VibeBrowserRootRowChooseFile,
    VibeBrowserRootRowOpenURL,
    VibeBrowserRootRowPasteURL,
};

// The rows of one root section. Locations: the device, each linked account,
// then the granted folders in the store's order. Recents, alone. Actions:
// Choose File… and Open URL…. The paste row follows Open URL… only while the
// clipboard probably holds a web link. Adding a location is the bar's plus.
static inline NSArray<NSNumber *> *VibeBrowserRootRows(VibeBrowserRootSection section,
                                                       NSUInteger linkedAccounts,
                                                       NSUInteger locations,
                                                       BOOL clipboardHasLink) {
    if (section == VibeBrowserRootSectionLocations) {
        NSMutableArray<NSNumber *> *rows = [NSMutableArray arrayWithObject:@(VibeBrowserRootRowDevice)];
        for (NSUInteger i = 0; i < linkedAccounts; i++) {
            [rows addObject:@(VibeBrowserRootRowAccount)];
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
// row. The folders follow the device and the linked accounts.
static inline NSUInteger VibeBrowserRootLocationIndex(VibeBrowserRootSection section,
                                                      NSUInteger row,
                                                      NSUInteger linkedAccounts,
                                                      NSUInteger locations) {
    NSUInteger first = 1 + linkedAccounts;
    if (section != VibeBrowserRootSectionLocations || row < first || row - first >= locations) {
        return NSNotFound;
    }
    return row - first;
}

// An account row's index among the linked accounts, or NSNotFound for any
// other row.
static inline NSUInteger VibeBrowserRootAccountIndex(VibeBrowserRootSection section,
                                                     NSUInteger row,
                                                     NSUInteger linkedAccounts) {
    if (section != VibeBrowserRootSectionLocations || row < 1 || row - 1 >= linkedAccounts) {
        return NSNotFound;
    }
    return row - 1;
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
