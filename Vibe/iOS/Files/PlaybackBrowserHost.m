//
//  PlaybackBrowserHost.m
//  Vibe (iOS)
//

#import "PlaybackBrowserHost.h"

#import "AppSettings.h"
#import "AudioTrack.h"
#import "BrowserRules.h"
#import "FavoritesStore.h"
#import "FilePaths.h"
#import "PlaybackController.h"
#import "PlaybackController+ReplacePrompt.h"
#import "SettingsRules.h"
#import "VibePlaylistFile.h"
#import "VibeStrings.h"

@interface PlaybackBrowserHost () <PlaybackObserver>
@end

@implementation PlaybackBrowserHost {
    PlaybackController *_playback;
    BOOL _appending;
    NSHashTable<id<VibeBrowserHostObserver>> *_observers;
}

@synthesize selectionAction = _selectionAction;
@synthesize folderAction = _folderAction;

- (instancetype)initWithPlayback:(PlaybackController *)playback appending:(BOOL)appending {
    self = [super init];
    if (self) {
        _playback = playback;
        _appending = appending;
        _observers = [NSHashTable weakObjectsHashTable];
        __weak PlaybackBrowserHost *weakSelf = self;
        _selectionAction = [VibeBrowserAction actionWithTitle:STR_MENU_CONTEXT_ADD_TO_PLAYLIST
                                                       symbol:@"text.badge.plus"
                                                      handler:^(NSArray<NSURL *> *urls, UIViewController *screen) {
            [weakSelf addURLs:urls fromScreen:screen];
        }];
        _selectionAction.liftsRows = YES;
        _folderAction = [VibeBrowserAction actionWithTitle:appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST
                                                                     : STR_MENU_CONTEXT_PLAY
                                                    symbol:appending ? @"text.badge.plus" : @"play.fill"
                                                   handler:^(NSArray<NSURL *> *urls, UIViewController *screen) {
            [weakSelf openURLs:urls inFolder:NO fromScreen:screen];
        }];
        [playback addObserver:self];
    }
    return self;
}

#pragma mark - How the screens look and read

- (NSString *)label:(VibeBrowserLabel)label {
    switch (label) {
        case VibeBrowserLabelSelect:        return STR_BROWSER_SELECT;
        case VibeBrowserLabelSelectAll:     return STR_MENU_EDIT_SELECT_ALL;
        case VibeBrowserLabelSort:          return STR_BROWSER_SORT;
        // The Settings row's string: the menu writes the one folder-open
        // setting, not this folder's view.
        case VibeBrowserLabelSortMenuTitle: return STR_SETTINGS_FOLDER_SORT_LABEL;
        case VibeBrowserLabelFilter:        return STR_BROWSER_FILTER;
        case VibeBrowserLabelEmptyFolder:   return STR_ERROR_FOLDER_EMPTY;
        case VibeBrowserLabelUnavailable:   return STR_BROWSER_DROPBOX_UNAVAILABLE;
        case VibeBrowserLabelOK:            return STR_BUTTON_OK;
    }
    return @"";
}

- (NSString *)selectionTitleForCount:(NSUInteger)count {
    return [NSString stringWithFormat:STR_BROWSER_SELECTED_COUNT, (unsigned long)count];
}

- (NSString *)subfoldersCappedMessageForLimit:(NSUInteger)limit {
    return [NSString stringWithFormat:STR_BROWSER_SUBFOLDERS_CAPPED, (unsigned long)limit];
}

// The add sheet says what a tap in it does, and it is modal.
- (NSString *)prompt {
    return _appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST : nil;
}

- (BOOL)showsCloseButton {
    return _appending;
}

// Not in the add sheet: with Close the bar has no room, and the order is a
// setting the Files tab changes.
- (BOOL)showsSortMenu {
    return !_appending;
}

- (VibeFolderOpenSort)folderSort {
    return AppSettings.sharedInstance.folderOpenSort;
}

- (void)setFolderSort:(VibeFolderOpenSort)folderSort {
    AppSettings.sharedInstance.folderOpenSort = folderSort;
}

- (NSString *)titleForSort:(VibeFolderOpenSort)sort {
    return VibeFolderOpenSortDisplayName(sort);
}

- (id<AudioTrackMetadataHolder>)artHolderForFileURL:(NSURL *)url {
    return [AudioTrack withURL:url];
}

#pragma mark - What the rows show

- (NSString *)playingPath {
    return VibeComparablePath(_playback.currentTrack.url.path);
}

- (NSString *)openingPath {
    return _playback.openingPath;
}

- (BOOL)audioOutputActive {
    return _playback.audioOutputActive;
}

- (id<EqualizerLevelSource>)levelSource {
    return _playback;
}

- (void)addObserver:(id<VibeBrowserHostObserver>)observer {
    [_observers addObject:observer];
}

- (void)notifyObservers:(SEL)selector {
    [_observers.allObjects makeObjectsPerformSelector:selector];
}

- (void)playbackDidMoveToCurrentTrack:(PlaybackController *)playback animated:(BOOL)animated {
    [self notifyObservers:@selector(browserHostPlayingFileDidChange)];
}

- (void)playbackDidChangePlayState:(PlaybackController *)playback {
    [self notifyObservers:@selector(browserHostPlayStateDidChange)];
}

- (void)playbackDidChangeOpening:(PlaybackController *)playback {
    [self notifyObservers:@selector(browserHostOpeningDidChange)];
}

#pragma mark - The actions

// A file plays alone, here as in Search and Recents. The long press has Play
// in Folder. A second tap on the row still opening gives it up.
- (void)screen:(UIViewController *)screen didTapFile:(NSURL *)url {
    if ([VibeComparablePath(url.path) isEqualToString:_playback.openingPath]) {
        [_playback cancelOpening];
        return;
    }
    [self openURLs:@[url] inFolder:NO fromScreen:screen];
}

- (NSString *)subfoldersTitle {
    return _appending ? STR_BROWSER_ADD_SUBFOLDERS : STR_BROWSER_PLAY_SUBFOLDERS;
}

// The token is the ask's, in the add sheet too: the walk's Dropbox listings
// come between the ask and the open, and a replace asked for meanwhile wins.
- (void (^)(NSArray<NSURL *> *folders))subfoldersHandlerFromScreen:(UIViewController *)screen {
    uint64_t token = [_playback replaceRequestTokenOpening:nil];
    BOOL appending = _appending;
    __weak PlaybackBrowserHost *weakSelf = self;
    __weak UIViewController *weakScreen = screen;
    return ^(NSArray<NSURL *> *folders) {
        UIViewController *strongScreen = weakScreen;
        if (!strongScreen) {
            return;
        }
        if (appending) {
            [weakSelf addURLs:folders fromScreen:strongScreen];
        }
        else {
            [weakSelf openURLs:folders inFolder:NO token:token fromScreen:strongScreen];
        }
    };
}

- (NSArray<VibeBrowserAction *> *)menuActionsForURL:(NSURL *)url isFolder:(BOOL)isFolder {
    __weak PlaybackBrowserHost *weakSelf = self;
    NSMutableArray<VibeBrowserAction *> *actions = [NSMutableArray array];
    // Recents' and Search's rule, without Open Folder: the row is already in
    // its folder.
    VibeBrowserRowActions rowActions = VibeBrowserRowActionsFor(
            isFolder, _appending, [VibePlaylistFile isM3UExtension:url.pathExtension.lowercaseString], YES);
    if (rowActions & VibeBrowserRowActionPlay) {
        // Outside the add sheet, the folder action is Play.
        [actions addObject:_folderAction];
    }
    if (rowActions & VibeBrowserRowActionPlayInFolder) {
        [actions addObject:[VibeBrowserAction actionWithTitle:STR_MENU_CONTEXT_PLAY_IN_FOLDER
                                                       symbol:@"play.square.stack"
                                                      handler:^(NSArray<NSURL *> *urls, UIViewController *screen) {
            [weakSelf openURLs:urls inFolder:YES fromScreen:screen];
        }]];
    }
    [actions addObject:_selectionAction];
    if (isFolder && !_appending && ![FavoritesStore.shared containsFolderURL:url]) {
        [actions addObject:[VibeBrowserAction actionWithTitle:[NSString stringWithFormat:STR_MENU_CONTEXT_ADD_FAVORITE,
                                                                                         VibeAppName()]
                                                       symbol:@"star"
                                                      handler:^(NSArray<NSURL *> *urls, UIViewController *screen) {
            [weakSelf favoriteFolder:urls.firstObject];
        }]];
    }
    return actions;
}

#pragma mark - Opening

- (void)openURLs:(NSArray<NSURL *> *)urls inFolder:(BOOL)inFolder fromScreen:(UIViewController *)screen {
    if (_appending) {
        [self addURLs:urls fromScreen:screen];
        return;
    }
    NSURL *row = urls.count == 1 ? urls.firstObject : nil;
    [self openURLs:urls inFolder:inFolder token:[_playback replaceRequestTokenOpening:row] fromScreen:screen];
}

- (void)openURLs:(NSArray<NSURL *> *)urls
        inFolder:(BOOL)inFolder
           token:(uint64_t)token
      fromScreen:(UIViewController *)screen {
    [_playback confirmReplacingPlaylistFrom:screen openingURLs:urls inFolder:inFolder token:token];
}

// The add sheet closes after an Add. By its presenter, so Open URL's sheet
// over it closes with it.
- (void)addURLs:(NSArray<NSURL *> *)urls fromScreen:(UIViewController *)screen {
    if (urls.count == 0) {
        return;
    }
    [_playback addURLs:urls];
    if (_appending) {
        [screen.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)favoriteFolder:(NSURL *)url {
    // A failed mint adds no row: one without a bookmark cannot be opened.
    [_playback bookmarkFolderURL:url completion:^(NSData *bookmark) {
        if (bookmark) {
            [FavoritesStore.shared addFolderURL:url bookmark:bookmark];
        }
    }];
}

@end
