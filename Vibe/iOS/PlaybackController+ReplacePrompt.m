//
//  PlaybackController+ReplacePrompt.m
//  Vibe (iOS)
//

#import "PlaybackController+ReplacePrompt.h"

#import "AccountMirror.h"
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

- (dispatch_block_t)resolveLinkString:(NSString *)string completion:(void (^)(NSURL *, NSError *))completion {
    NSURL *link = VibeLinkFolderURL(VibeLinkURLFromString(string));
    AccountMirror *mirror = nil;
    for (AccountMirror *each in AccountMirror.mirrors) {
        if (link && each.client.isLinked && [each opensSharedFolderLink:link]) {
            mirror = each;
            break;
        }
    }
    if (!mirror) {
        return [LinkStore.shared resolveURLString:string completion:completion];
    }
    // Main only, as LinkStore's resolve is.
    __block BOOL settled = NO;
    __block dispatch_block_t cancelFallback = nil;
    void (^settle)(NSURL *, NSError *) = ^(NSURL *file, NSError *error) {
        if (!settled) {
            settled = YES;
            completion(file, error);
        }
    };
    [mirror openSharedFolderLink:link completion:^(NSURL *folderURL, NSError *error) {
        if (settled) {
            return;
        }
        if (folderURL) {
            settle(folderURL, nil);
            return;
        }
        // A Dropbox grant from before sharing.read, among other refusals.
        // The folder may still open with no account.
        LogInfo(@"Links: the %@ account could not open a shared folder (%@); opening it without the account",
                mirror.serviceName, error.localizedDescription);
        cancelFallback = [LinkStore.shared resolveURLString:string completion:settle];
    }];
    return ^{
        if (cancelFallback) {
            cancelFallback();
            return;
        }
        settle(nil, VibeLinkMakeError(VibeLinkErrorCancelled, nil));
    };
}

- (dispatch_block_t)openLinkString:(NSString *)string
             replacingPlaylistFrom:(UIViewController *)anchor
                        completion:(void (^)(NSURL *, NSError *))completion {
    uint64_t token = [self replaceRequestTokenOpening:nil];
    __weak UIWindow *window = anchor.viewIfLoaded.window;
    __weak UIViewController *weakAnchor = anchor;
    return [self resolveLinkString:string completion:^(NSURL *file, NSError *error) {
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
