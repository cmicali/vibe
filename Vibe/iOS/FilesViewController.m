//
//  FilesViewController.m
//  Vibe (iOS)
//
//  See FilesViewController.h.
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
    // Folders first, then the declared audio types, the same list the picker
    // takes — DocumentTypes reads it back out of Info.plist, so the browser's
    // filter and the app's registered types cannot drift.
    NSArray<UTType *> *types =
            [@[UTTypeFolder] arrayByAddingObjectsFromArray:DocumentTypes.declaredFileTypes];
    self = [super initForOpeningContentTypes:types];
    if (self) {
        _playback = playback;
        self.delegate = self;
        // Vibe opens what is already there; it authors nothing.
        self.allowsDocumentCreation = NO;
        // TRAP: multiple-item picking BREAKS the browser's Open button. With it
        // on, Open runs the browser's confirm-an-open flow, which replaces the
        // button with a progress indicator and holds it until the app presents
        // a document view controller for what was picked. Vibe presents none —
        // it switches to the Playlist tab and raises the card — so the open
        // lands and plays while the browser spins on that button forever, one
        // per Open, for the rest of the session. Off, the same press is a plain
        // pick: the button stays, and the Open button, folder opens and file
        // taps all behave. Tapping a file row never spun either way.
        //
        // It bought nothing on iPhone, where iOS 26's browser has no "Select"
        // mode; what it cost was Open. An iPad drag selection or a future OS
        // could have handed several items over, and now cannot — the delegate
        // below still takes a set, so restoring it is one line if a browser
        // ever both selects several items AND leaves Open alone.
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
        // Listing UTTypeFolder — what the browser itself filters on — hides
        // this action from every folder while the files still show it, which
        // looks like the action being unsupported on folders altogether.
        add.supportedContentTypes = [@[UTTypeDirectory.identifier]
                arrayByAddingObjectsFromArray:
                        [DocumentTypes.declaredFileTypes valueForKey:@"identifier"]];
        // Starring without opening. Until this existed the only road to a
        // favorite was to open the folder — replacing the playlist — and then
        // tap the star, so keeping a place for later cost you the place you
        // were. Menu availability only: the navigation-bar half needs rows the
        // user has selected, and this browser has no Select mode on iPhone.
        UIDocumentBrowserAction *favorite = [[UIDocumentBrowserAction alloc]
                initWithIdentifier:@"com.commonwealthrecordings.vibe.add-to-favorites"
                    localizedTitle:STR_MENU_CONTEXT_ADD_FAVORITE
                      availability:UIDocumentBrowserActionAvailabilityMenu
                           handler:^(NSArray<NSURL *> *urls) {
            for (NSURL *folder in urls) {
                // The mint needs the folder's scope open, which only
                // FolderSession promises; FavoritesStore refuses a row without
                // a bookmark, so a failed mint adds nothing rather than a row
                // that draws and cannot be opened.
                [weakPlayback bookmarkFolderURL:folder completion:^(NSData *bookmark) {
                    if (bookmark) {
                        [FavoritesStore.shared addFolderURL:folder bookmark:bookmark];
                    }
                }];
            }
        }];
        favorite.image = [UIImage systemImageNamed:@"star"];
        // Folders only — a favorite is a place to go back to, never a file.
        // TRAP: the same public.DIRECTORY rule as the action above; spelling it
        // UTTypeFolder hides the action from every folder, which is every row
        // this action has.
        favorite.supportedContentTypes = @[UTTypeDirectory.identifier];
        self.customActions = @[add, favorite];
        // The visible road to Add. iOS 26's browser has no "Select" mode on
        // iPhone, so the long-press menu above would otherwise be the only
        // one — and a context menu is never meant to be that.
        // TRAP: it must go on the LEADING side. The browser draws its own
        // overflow "•••" exactly where it lays a trailing additional item out,
        // so a trailing button renders nowhere and its touches reach the
        // browser's menu instead — a button that looks simply absent.
        UIBarButtonItem *addItem = [[UIBarButtonItem alloc]
                initWithImage:[UIImage systemImageNamed:@"text.badge.plus"]
                        style:UIBarButtonItemStylePlain
                       target:self
                       action:@selector(addTapped)];
        addItem.accessibilityLabel = STR_A11Y_FILES_ADD_TO_PLAYLIST;
        self.additionalLeadingNavigationBarButtonItems = @[addItem];
    }
    return self;
}

// The system picker, not this browser: a custom action needs rows the user has
// already selected, and there is no way to select any here.
- (void)addTapped {
    [_playback presentPickerFromViewController:self appending:YES];
}

#pragma mark - UIDocumentBrowserViewControllerDelegate

- (void)documentBrowser:(UIDocumentBrowserViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)documentURLs {
    if (documentURLs.count > 0) {
        // openInPlace:YES — the browser hands back the real files, never copies
        // in the inbox, so the security scopes FolderSession opens are the ones
        // that cover the folders they came from.
        [_playback openURLs:documentURLs openInPlace:YES];
    }
}

@end
