//
//  PlaybackBrowserHost.m
//  Vibe (iOS)
//

#import "PlaybackBrowserHost.h"

#import "AppSettings.h"
#import "AudioTrack.h"
#import "VibeBrowserRootViewController.h"
#import "DropboxBrowserSource.h"
#import "DropboxMirror+Shared.h"
#import "FavoritesStore.h"
#import "FilePaths.h"
#import "FilesTabRows.h"
#import "FilesTabRules.h"
#import "VibeLocationStore.h"
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
@synthesize sources = _sources;
@synthesize tabRows = _tabRows;

- (instancetype)initWithPlayback:(PlaybackController *)playback appending:(BOOL)appending {
    self = [super init];
    if (self) {
        _playback = playback;
        _appending = appending;
        _observers = [NSHashTable weakObjectsHashTable];
        _tabRows = [[FilesTabRows alloc] initWithPlayback:playback appending:appending host:self];
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
        // The device first, then Dropbox once linked.
        NSURL *documents = VibeLocationStore.containerDocumentsURL;
        UIImage *device = [UIImage systemImageNamed:
                UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"ipad" : @"iphone"];
        _sources = @[[VibeBrowserFolderSource sourceWithRootURL:documents
                                                          title:[VibeLocationStore displayNameForFolderURL:documents]
                                                          image:device],
                     [[DropboxBrowserSource alloc] init]];
        [playback addObserver:self];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(dropboxAccountDidChange:)
                                                   name:VibeDropboxAccountDidChangeNotification
                                                 object:DropboxMirror.shared.client];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(dropboxDownloadsDidChange:)
                                                   name:VibeDropboxDownloadsDidChangeNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)dropboxAccountDidChange:(NSNotification *)notification {
    [self notifyObservers:@selector(browserHostSourcesDidChange)];
}

// A download landed, or the downloads were removed: the mark and the art
// follow the file.
- (void)dropboxDownloadsDidChange:(NSNotification *)notification {
    [self notifyObservers:@selector(browserHostSourceFilesDidChange)];
}

+ (VibeBrowserRootViewController *)rootWithPlayback:(PlaybackController *)playback appending:(BOOL)appending {
    VibeBrowserRootViewController *root = [[VibeBrowserRootViewController alloc]
            initWithHost:[[PlaybackBrowserHost alloc] initWithPlayback:playback appending:appending]];
    // The add sheet says what a tap in it does: it is the Files tab's twin,
    // and there a tap plays.
    root.navigationItem.title = appending ? STR_MENU_CONTEXT_ADD_TO_PLAYLIST : STR_TAB_FILES;
    return root;
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
        case VibeBrowserLabelLocations:     return STR_BROWSER_LOCATIONS;
        case VibeBrowserLabelAddLocation:   return STR_BROWSER_ADD_LOCATION;
        case VibeBrowserLabelAddFolder:     return STR_SETTINGS_ADD_FOLDER;
        case VibeBrowserLabelAddFolderCaption: return STR_BROWSER_ADD_FOLDER_CAPTION;
        case VibeBrowserLabelLocationCovered: return STR_SETTINGS_SEARCH_FOLDERS_COVERED;
        case VibeBrowserLabelRemoveLocation: return STR_BROWSER_REMOVE_LOCATION;
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

- (void)addBrowserObserver:(id<VibeBrowserHostObserver>)observer {
    [_observers addObject:observer];
}

- (NSArray<NSArray<VibeBrowserRootRow *> *> *)rootSections {
    return _tabRows.sections;
}

- (void)rootWillAppear:(UIViewController *)root {
    [_tabRows rootWillAppear:root];
}

- (void)rootSectionDidChange:(NSUInteger)section animated:(BOOL)animated {
    for (id<VibeBrowserHostObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(browserHostRootSectionDidChange:animated:)]) {
            [observer browserHostRootSectionDidChange:section animated:animated];
        }
    }
}

// Only the observers that answer it: the source events are optional.
- (void)notifyObservers:(SEL)selector {
    NSPredicate *answers = [NSPredicate predicateWithBlock:^BOOL(id observer, NSDictionary *bindings) {
        return [observer respondsToSelector:selector];
    }];
    [[_observers.allObjects filteredArrayUsingPredicate:answers] makeObjectsPerformSelector:selector];
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
- (void (^)(NSArray<NSURL *> *folders))subfoldersHandlerForFolder:(NSURL *)folder
                                                       fromScreen:(UIViewController *)screen {
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
    VibeFilesTabRowActions rowActions = VibeFilesTabRowActionsFor(
            isFolder, _appending, [VibePlaylistFile isM3UExtension:url.pathExtension.lowercaseString], YES);
    if (rowActions & VibeFilesTabRowActionPlay) {
        // Outside the add sheet, the folder action is Play.
        [actions addObject:_folderAction];
    }
    if (rowActions & VibeFilesTabRowActionPlayInFolder) {
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
