//
//  FilesViewController.m
//  Vibe (iOS)
//
//  See FilesViewController.h.
//

#import "FilesViewController.h"

#import "DocumentTypes.h"
#import "PlaybackController.h"

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
        self.allowsPickingMultipleItems = NO;
    }
    return self;
}

#pragma mark - UIDocumentBrowserViewControllerDelegate

- (void)documentBrowser:(UIDocumentBrowserViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)documentURLs {
    NSURL *url = documentURLs.firstObject;
    if (url) {
        // openInPlace:YES — the browser hands back the real file, never a copy
        // in the inbox, so the security scope FolderSession opens is the one
        // that covers the folder this file came from.
        [_playback openExternalURL:url openInPlace:YES];
    }
}

@end
