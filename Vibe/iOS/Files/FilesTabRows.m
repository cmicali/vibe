//
//  FilesTabRows.m
//  Vibe (iOS)
//

#import "FilesTabRows.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "DocumentTypes.h"
#import "LinkDropRules.h"
#import "LinkStore.h"
#import "StringRules.h"
#import "OpenURLSheetController.h"
#if DEBUG
#import "OpenURLSheetController+Debug.h"
#endif
#import "PlaybackBrowserHost.h"
#import "PlaybackController.h"
#import "PlaybackController+ReplacePrompt.h"
#import "RecentsViewController.h"
#import "UIViewController+Alert.h"
#import "VibeStrings.h"

// The second group: Choose File…, Open URL…, and the paste row.
static const NSUInteger kActionsSection = 1;

@interface FilesTabRows () <UIDocumentPickerDelegate>
@end

// Each pasted item's URL and text, by the pasteboard types a drop is read
// for (VibeDropURLsOfItems). The providers load off main. Completes on main.
static void VibeLoadPastedItems(NSArray<NSItemProvider *> *providers,
                                void (^completion)(NSArray<NSDictionary<NSString *, NSString *> *> *items)) {
    NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *items = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    for (NSItemProvider *provider in providers) {
        NSMutableDictionary<NSString *, NSString *> *item = [NSMutableDictionary dictionary];
        [items addObject:item];
        if ([provider canLoadObjectOfClass:NSURL.class]) {
            dispatch_group_enter(group);
            [provider loadObjectOfClass:NSURL.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
                NSURL *url = [(NSObject *)object isKindOfClass:NSURL.class] ? (NSURL *)object : nil;
                @synchronized (item) {
                    if (url) {
                        item[url.isFileURL ? kVibeDropTypeFileURL : kVibeDropTypeURL] = url.absoluteString;
                    }
                }
                dispatch_group_leave(group);
            }];
        }
        if ([provider canLoadObjectOfClass:NSString.class]) {
            dispatch_group_enter(group);
            [provider loadObjectOfClass:NSString.class completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
                NSString *text = [(NSObject *)object isKindOfClass:NSString.class] ? (NSString *)object : nil;
                @synchronized (item) {
                    if (text) {
                        item[kVibeDropTypeText] = text;
                    }
                }
                dispatch_group_leave(group);
            }];
        }
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(items);
    });
}

@implementation FilesTabRows {
    PlaybackController *_playback;
    BOOL _appending;
    __weak PlaybackBrowserHost *_host;
    // Choose File…'s picker while it is up, and the root it came from.
    __weak UIDocumentPickerViewController *_filePicker;
    __weak UIViewController *_filePickerScreen;
    // Cancels the link Open URL's sheet or the paste row is resolving. The
    // paste row spins while it is set and no sheet is up.
    dispatch_block_t _cancelLinkResolve;
    // The clipboard's change count when it was last checked, and whether it
    // then probably held a web link. The paste row shows only while it does.
    NSInteger _clipboardChangeCount;
    BOOL _clipboardHasLink;
    OpenURLSheetController *_linkSheet;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback
                       appending:(BOOL)appending
                            host:(PlaybackBrowserHost *)host {
    self = [super init];
    if (self) {
        _playback = playback;
        _appending = appending;
        _host = host;
        _clipboardChangeCount = NSIntegerMin;
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(clipboardMayHaveChanged:)
                                                   name:UIPasteboardChangedNotification
                                                 object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(clipboardMayHaveChanged:)
                                                   name:UISceneDidActivateNotification
                                                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)rootWillAppear:(UIViewController *)root {
    [self refreshClipboardLink];
}

#pragma mark - Vibe's groups

// Recents, alone: a place to go back to, not a place files live. Then
// Choose File…, Open URL…, and the paste row while the clipboard probably
// holds a web link.
- (NSArray<NSArray<VibeBrowserRootRow *> *> *)sections {
    __weak FilesTabRows *weakSelf = self;
    VibeBrowserRootRow *recents = [VibeBrowserRootRow rowWithTitle:STR_BROWSER_RECENTS
                                                             image:[UIImage systemImageNamed:@"clock"]
                                                           handler:^(UIViewController *screen) {
        [weakSelf showRecentsFromScreen:screen];
    }];
    NSMutableArray<VibeBrowserRootRow *> *actions = [NSMutableArray arrayWithObjects:
            [VibeBrowserRootRow rowWithTitle:STR_BROWSER_CHOOSE_FILE
                                       image:[UIImage systemImageNamed:@"doc.badge.ellipsis"]
                                     handler:^(UIViewController *screen) {
        [weakSelf presentFilePickerFromScreen:screen];
    }],
            [VibeBrowserRootRow rowWithTitle:STR_BROWSER_OPEN_URL
                                       image:[UIImage systemImageNamed:@"link"]
                                     handler:^(UIViewController *screen) {
        [weakSelf openURLRowTappedFromScreen:screen];
    }], nil];
    if (_clipboardHasLink) {
        VibeBrowserRootRow *paste = [VibeBrowserRootRow rowWithTitle:_appending ? STR_BROWSER_ADD_CLIPBOARD_LINK
                                                                                : STR_BROWSER_OPEN_CLIPBOARD_LINK
                                                               image:[UIImage systemImageNamed:@"doc.on.clipboard"]
                                                             handler:^(UIViewController *screen) {
            [weakSelf pasteClipboardLinkFromScreen:screen];
        }];
        // It spins while its link resolves. Open URL's sheet shows its own.
        paste.spinning = _cancelLinkResolve != nil && _linkSheet == nil;
        [actions addObject:paste];
    }
    for (VibeBrowserRootRow *row in actions) {
        row.isAction = YES;
    }
    return @[@[recents], actions];
}

- (void)showRecentsFromScreen:(UIViewController *)screen {
    [screen.navigationController pushViewController:[[RecentsViewController alloc] initWithPlayback:_playback
                                                                                        appending:_appending]
                                         animated:YES];
}

// A newer link supersedes the pasted one still resolving.
- (void)openURLRowTappedFromScreen:(UIViewController *)screen {
    if (_cancelLinkResolve) {
        _cancelLinkResolve();
    }
    [self presentLinkSheetFromScreen:screen];
}

#pragma mark - Open URL

// The sheet stays up while the link resolves. Every way it closes cancels
// that.
- (void)presentLinkSheetFromScreen:(UIViewController *)screen {
    __weak FilesTabRows *weakSelf = self;
    __weak UIViewController *weakScreen = screen;
    OpenURLSheetController *sheet = [[OpenURLSheetController alloc] initWithOpen:^(NSString *text) {
        UIViewController *strongScreen = weakScreen;
        if (strongScreen) {
            [weakSelf openLinkText:text fromScreen:strongScreen];
        }
    } cancel:^{
        [weakSelf cancelLinkSheet];
    }];
    _linkSheet = sheet;
    sheet.resolving = _cancelLinkResolve != nil; // a paste-row resolve still running
    [sheet presentFrom:screen];
}

- (void)cancelLinkSheet {
    dispatch_block_t cancel = _cancelLinkResolve;
    [self closeLinkSheetThen:nil];
    if (cancel) {
        cancel();
    }
}

// Closes the sheet, then runs then. With no sheet up, then runs at once.
- (void)closeLinkSheetThen:(nullable dispatch_block_t)then {
    OpenURLSheetController *sheet = _linkSheet;
    _linkSheet = nil;
    if (sheet) {
        [sheet dismissThen:then];
    }
    else if (then) {
        then();
    }
}

// The sheet's Open and the paste row both come here, and only while no link
// resolves. The add sheet takes the Add token before the resolve, as
// Favorites does, and closes once the link is added. A failure closes Open
// URL's sheet first, then shows its alert. Never the inbox road: it does not
// persist.
- (void)openLinkText:(NSString *)text fromScreen:(UIViewController *)screen {
    if (VibeLinkTextIsBlank(text) || _cancelLinkResolve) {
        return;
    }
    // Found when the failure lands: the add sheet may be gone by then, and
    // the card may be up.
    __weak UIWindow *window = screen.view.window;
    __weak UIViewController *weakScreen = screen;
    __weak FilesTabRows *weakSelf = self;
    void (^settled)(NSURL *, NSError *) = ^(NSURL *file, NSError *error) {
        NSString *message = error ? VibeLinkMessageForError(error, NO) : nil;
        dispatch_block_t alert = ^{
            UIViewController *root = window.rootViewController;
            if (message && root) {
                [root.vibeTopmostPresenter vibePresentAlertWithTitle:STR_LINK_ERROR_TITLE message:message];
            }
        };
        FilesTabRows *strongSelf = weakSelf;
        if (!strongSelf) {
            alert();
            return;
        }
        strongSelf->_cancelLinkResolve = nil;
        [strongSelf reloadPasteRow];
        if (file && strongSelf->_appending) {
            // The add sheet takes Open URL's sheet with it.
            strongSelf->_linkSheet = nil;
            [weakScreen.navigationController.presentingViewController dismissViewControllerAnimated:YES
                                                                                       completion:nil];
            return;
        }
        [strongSelf closeLinkSheetThen:alert];
    };
    if (!_appending) {
        _cancelLinkResolve = [_playback openLinkString:text replacingPlaylistFrom:screen completion:settled];
    }
    else {
        PlaybackController *playback = _playback;
        uint64_t token = [playback addRequestToken];
        _cancelLinkResolve = [LinkStore.shared resolveURLString:text completion:^(NSURL *file, NSError *error) {
            if (file) {
                [playback addURLs:@[file] token:token];
            }
            settled(file, error);
        }];
    }
    [self reloadPasteRow];
    _linkSheet.resolving = _cancelLinkResolve != nil;
}

#pragma mark - The paste row

// Neither question reads the clipboard, so neither raises the paste prompt:
// pattern detection, and whether it holds a URL at all. A change count
// already checked asks nothing.
- (void)refreshClipboardLink {
    UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
    NSInteger changeCount = pasteboard.changeCount;
    if (changeCount == _clipboardChangeCount) {
        return;
    }
    _clipboardChangeCount = changeCount;
    BOOL hasURLs = pasteboard.hasURLs;
    __weak FilesTabRows *weakSelf = self;
    [pasteboard detectPatternsForPatterns:[NSSet setWithObject:UIPasteboardDetectionPatternProbableWebURL]
                        completionHandler:^(NSSet<UIPasteboardDetectionPattern> *patterns, NSError *error) {
        BOOL hasLink = hasURLs || [patterns containsObject:UIPasteboardDetectionPatternProbableWebURL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf clipboardHasLink:hasLink changeCount:changeCount];
        });
    }];
}

- (void)clipboardMayHaveChanged:(NSNotification *)notification {
    [self refreshClipboardLink];
}

- (void)clipboardHasLink:(BOOL)hasLink changeCount:(NSInteger)changeCount {
    if (changeCount != _clipboardChangeCount || hasLink == _clipboardHasLink) {
        return;
    }
    _clipboardHasLink = hasLink;
    [_host rootSectionDidChange:kActionsSection animated:YES];
}

// The paste row's tap. Listing the clipboard's providers asks nothing. Loading
// one raises the system's Allow Paste prompt, unless the user set Paste from
// Other Apps to Allow.
- (void)pasteClipboardLinkFromScreen:(UIViewController *)screen {
    [self pasteItemProviders:UIPasteboard.generalPasteboard.itemProviders fromScreen:screen];
}

// The paste row's items. The first web link opens as the sheet's Open does.
// Other text fails as an address that is no link. A paste while a link
// resolves gives that link up and loads nothing, as a second tap on a
// spinning row does.
- (void)pasteItemProviders:(NSArray<NSItemProvider *> *)itemProviders fromScreen:(UIViewController *)screen {
    dispatch_block_t cancel = _cancelLinkResolve;
    if (cancel) {
        cancel();
        return;
    }
    __weak FilesTabRows *weakSelf = self;
    __weak UIViewController *weakScreen = screen;
    VibeLoadPastedItems(itemProviders, ^(NSArray<NSDictionary<NSString *, NSString *> *> *items) {
        FilesTabRows *strongSelf = weakSelf;
        UIViewController *strongScreen = weakScreen;
        NSURL *link = VibePasteLinkOfItems(items);
        // TRAP: a denied paste still lists its items, with their types. Only
        // the loads fail (PBErrorDomain 13). Nothing was read, so nothing is
        // said.
        BOOL read = NO;
        for (NSDictionary<NSString *, NSString *> *item in items) {
            read = read || item.count > 0;
        }
        if (link) {
            if (strongScreen) {
                [strongSelf openLinkText:link.absoluteString fromScreen:strongScreen];
            }
        }
        else if (read && strongScreen.viewIfLoaded.window) {
            NSError *invalid = [NSError errorWithDomain:VibeLinkErrorDomain code:VibeLinkErrorInvalid userInfo:nil];
            [strongScreen.vibeTopmostPresenter vibePresentAlertWithTitle:STR_LINK_ERROR_TITLE
                                                               message:VibeLinkMessageForError(invalid, NO)];
        }
    });
}

- (void)reloadPasteRow {
    if (_clipboardHasLink) {
        [_host rootSectionDidChange:kActionsSection animated:NO];
    }
}

#pragma mark - Choose File…

// Files and folders from anywhere, for one open. asCopy:NO: the grant must be
// to the real items.
- (void)presentFilePickerFromScreen:(UIViewController *)screen {
    NSArray<UTType *> *types = [@[UTTypeFolder] arrayByAddingObjectsFromArray:DocumentTypes.declaredFileTypes];
    UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    _filePicker = picker;
    _filePickerScreen = screen;
    [screen presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    UIViewController *screen = _filePickerScreen;
    if (controller != _filePicker || !screen) {
        return;
    }
    // One picked file expands to its folder.
    [_host openURLs:urls inFolder:YES fromScreen:screen];
}

#if DEBUG
- (NSDictionary *)debugLinkState {
    NSDictionary *sheet = _linkSheet ? @{
        @"shown": @YES,
        @"text": _linkSheet.debugField.text ?: @"",
        @"resolving": @((BOOL)(_cancelLinkResolve != nil)),
        @"openEnabled": @(_linkSheet.debugOpenEnabled),
    } : @{@"shown": @NO};
    return @{
        @"pasteRowShown": @(_clipboardHasLink),
        @"pasteRowResolving": @((BOOL)(_cancelLinkResolve != nil && _linkSheet == nil)),
        @"linkSheet": sheet,
    };
}

- (OpenURLSheetController *)debugLinkSheet {
    return _linkSheet;
}
#endif

@end
