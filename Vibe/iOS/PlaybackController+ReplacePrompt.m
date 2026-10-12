//
//  PlaybackController+ReplacePrompt.m
//  Vibe (iOS)
//

#import "PlaybackController+ReplacePrompt.h"

#import "LinkStore.h"
#import "UIViewController+Alert.h"
#import "VibeStrings.h"

@implementation PlaybackController (ReplacePrompt)

- (void)confirmReplacingPlaylistFrom:(UIViewController *)presenter
                         openingURLs:(NSArray<NSURL *> *)urls
                            inFolder:(BOOL)inFolder
                               token:(uint64_t)token {
    if (urls.count == 0 || ![self isCurrentReplaceRequest:token]) {
        return;
    }
    dispatch_block_t replace = ^{
        if (urls.count == 1) {
            [self openFileURL:urls.firstObject inFolder:inFolder];
        }
        else {
            [self openURLs:urls openInPlace:YES];
        }
    };
    if (!self.playlistHasAdditions) {
        replace();
        return;
    }
    // The question waits on the user, not the disk: its row stops spinning, so
    // the give-up timeout cannot fire over the alert. Replace opens anew.
    [self endOpeningForReplaceRequest:token];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:STR_PLAYLIST_REPLACE_TITLE
                                                                   message:STR_PLAYLIST_REPLACE_MESSAGE
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:STR_PLAYLIST_REPLACE_CONFIRM
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) { replace(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:STR_PLAYLIST_REPLACE_ADD
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self addURLs:urls];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:STR_BUTTON_CANCEL style:UIAlertActionStyleCancel
                                            handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (dispatch_block_t)openLinkString:(NSString *)string
             replacingPlaylistFrom:(UIViewController *)anchor
                        completion:(void (^)(NSURL *, NSError *))completion {
    uint64_t token = [self replaceRequestTokenOpening:nil];
    __weak UIWindow *window = anchor.viewIfLoaded.window;
    __weak UIViewController *weakAnchor = anchor;
    return [LinkStore.shared resolveURLString:string completion:^(NSURL *file, NSError *error) {
        // First, so the caller can close what it showed before the replace
        // question goes over the top.
        if (completion) {
            completion(file, error);
        }
        UIViewController *root = window.rootViewController ?: weakAnchor;
        if (file && root) {
            [self confirmReplacingPlaylistFrom:root.vibeTopmostPresenter openingURLs:@[file] inFolder:NO
                                         token:token];
        }
    }];
}

@end
