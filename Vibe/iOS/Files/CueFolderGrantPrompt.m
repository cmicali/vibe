//
//  CueFolderGrantPrompt.m
//  Vibe (iOS)
//

#import "CueFolderGrantPrompt.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "PlaybackController.h"
#import "VibeStrings.h"

@interface CueFolderGrantPrompt () <UIDocumentPickerDelegate>
@end

@implementation CueFolderGrantPrompt {
    // What the folder picker on screen does with the folder picked.
    void (^_sheetFolderPicked)(NSURL *folder);
}

- (void)askForFolderOfSheetAtURL:(NSURL *)sheetURL
                       appending:(BOOL)appending
                        playback:(PlaybackController *)playback
                       presenter:(UIViewController *)presenter {
    NSString *message = [NSString stringWithFormat:STR_PLAYLIST_GRANT_MESSAGE, VibeAppName(),
                         sheetURL.lastPathComponent];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_CANCEL
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    UIAlertAction *grant = [UIAlertAction actionWithTitle:STR_PLAYLIST_GRANT_BUTTON
                                                    style:UIAlertActionStyleDefault
                                                  handler:^(UIAlertAction *action) {
        UIDocumentPickerViewController *picker =
                [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
        picker.directoryURL = sheetURL.URLByDeletingLastPathComponent;
        picker.delegate = self;
        self->_sheetFolderPicked = ^(NSURL *folder) {
            [playback openSheetURL:sheetURL inGrantedFolder:folder appending:appending];
        };
        [presenter presentViewController:picker animated:YES completion:nil];
    }];
    [alert addAction:grant];
    alert.preferredAction = grant;
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
        didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    void (^picked)(NSURL *) = _sheetFolderPicked;
    _sheetFolderPicked = nil;
    if (picked && urls.firstObject) {
        picked(urls.firstObject);
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    _sheetFolderPicked = nil;
}

@end
