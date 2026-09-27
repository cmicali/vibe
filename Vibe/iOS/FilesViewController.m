//
//  FilesViewController.m
//  Vibe (iOS)
//

#import "FilesViewController.h"

#import "DocumentTypes.h"
#import "FavoritesStore.h"
#import "PlaybackController.h"
#import "VibeStrings.h"

@interface FilesViewController () <UIDocumentBrowserViewControllerDelegate>
@end

@implementation FilesViewController {
    __weak PlaybackController *_playback;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    // The picker's list; DocumentTypes reads Info.plist, so it cannot drift.
    NSArray<UTType *> *types =
            [@[UTTypeFolder] arrayByAddingObjectsFromArray:DocumentTypes.declaredFileTypes];
    self = [super initForOpeningContentTypes:types];
    if (self) {
        _playback = playback;
        self.delegate = self;
        self.allowsDocumentCreation = NO;
        // TRAP: multiple-item picking BREAKS the browser's Open button. On,
        // Open swaps the button for a progress indicator until the app presents
        // a document view controller, which Vibe never does, so it spins
        // forever after every Open. It buys nothing on iPhone, whose browser
        // has no Select mode.
        self.allowsPickingMultipleItems = NO;
        __weak PlaybackController *weakPlayback = playback;
        UIDocumentBrowserAction *add = [[UIDocumentBrowserAction alloc]
                initWithIdentifier:@"com.commonwealthrecordings.vibe.add-to-playlist"
                    localizedTitle:STR_MENU_CONTEXT_ADD_TO_PLAYLIST
                      availability:UIDocumentBrowserActionAvailabilityMenu
                                 | UIDocumentBrowserActionAvailabilityNavigationBar
                           handler:^(NSArray<NSURL *> *urls) {
            [weakPlayback addURLs:urls];
        }];
        add.image = [UIImage systemImageNamed:@"text.badge.plus"];
        add.supportsMultipleItems = YES;
        // TRAP: a folder row matches public.DIRECTORY, not public.folder.
        // UTTypeFolder, what the browser filters on, hides the action from
        // every folder.
        add.supportedContentTypes = [@[UTTypeDirectory.identifier]
                arrayByAddingObjectsFromArray:
                        [DocumentTypes.declaredFileTypes valueForKey:@"identifier"]];
        // Starring without opening, which would replace the playlist. Menu
        // only: the navigation bar half needs a Select mode iPhone lacks.
        UIDocumentBrowserAction *favorite = [[UIDocumentBrowserAction alloc]
                initWithIdentifier:@"com.commonwealthrecordings.vibe.add-to-favorites"
                    localizedTitle:[NSString stringWithFormat:STR_MENU_CONTEXT_ADD_FAVORITE,
                                                              VibeAppName()]
                      availability:UIDocumentBrowserActionAvailabilityMenu
                           handler:^(NSArray<NSURL *> *urls) {
            for (NSURL *folder in urls) {
                // A failed mint adds no row: one without a bookmark cannot
                // be opened.
                [weakPlayback bookmarkFolderURL:folder completion:^(NSData *bookmark) {
                    if (bookmark) {
                        [FavoritesStore.shared addFolderURL:folder bookmark:bookmark];
                    }
                }];
            }
        }];
        favorite.image = [UIImage systemImageNamed:@"star"];
        // Folders only. TRAP: the public.DIRECTORY rule above; UTTypeFolder
        // here hides the action from every row it has.
        favorite.supportedContentTypes = @[UTTypeDirectory.identifier];
        self.customActions = @[add, favorite];
    }
    return self;
}

#pragma mark - UIDocumentBrowserViewControllerDelegate

- (void)documentBrowser:(UIDocumentBrowserViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)documentURLs {
    if (documentURLs.count > 0) {
        // The browser hands back the real files, never inbox copies.
        [_playback openURLs:documentURLs openInPlace:YES];
    }
}

@end
