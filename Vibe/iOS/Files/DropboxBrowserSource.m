//
//  DropboxBrowserSource.m
//  Vibe (iOS)
//

#import "DropboxBrowserSource.h"

#import "DropboxMirror+Shared.h"
#import "UIViewController+Alert.h"
#import "VibeStrings.h"

@implementation DropboxBrowserSource

// Linked is the account's state. The root shows the row, and a folder of the
// account stays up, only while it holds.
- (NSURL *)rootURL {
    return DropboxMirror.shared.client.isLinked ? DropboxMirror.shared.accountURL : nil;
}

- (NSString *)title {
    return VibeNotLocalized(@"Dropbox");
}

- (NSString *)subtitle {
    return DropboxMirror.shared.client.accountName;
}

- (UIImage *)image {
    return [UIImage imageNamed:@"dropbox-glyph"];
}

// Never touches the disk: a screen asks it in its initializer.
- (BOOL)refreshesDirectoryURL:(NSURL *)url {
    return [DropboxMirror.shared dropboxPathForURL:url] != nil;
}

- (void)refreshDirectoryURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    // The account can go between the browser's two questions.
    NSString *path = [DropboxMirror.shared dropboxPathForURL:url];
    if (!path) {
        completion(nil);
        return;
    }
    [DropboxMirror.shared refreshDropboxFolder:path completion:^(NSURL *folderURL, NSError *error) {
        completion(error);
    }];
}

- (NSString *)connectTitle {
    return STR_SETTINGS_DROPBOX_CONNECT;
}

- (void)connectFromScreen:(UIViewController *)screen connected:(dispatch_block_t)connected {
    __weak UIViewController *weakScreen = screen;
    [DropboxMirror.shared.client signInWithPresentationAnchor:screen.view.window completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *strongScreen = weakScreen;
            if (!strongScreen) {
                return;
            }
            if (error) {
                LogWarn(@"Dropbox: sign-in failed: %@", error.localizedDescription);
                [strongScreen vibePresentAlertWithTitle:self.title
                                                message:STR_SETTINGS_DROPBOX_CONNECT_FAILED];
                return;
            }
            connected();
        });
    }];
}

@end
