//
//  DropboxBrowserSource.h
//  Vibe (iOS)
//
//  Vibe's shared Dropbox mirror as a browser source. Its root is the linked
//  account's mirror folder. Each folder in it is drawn from disk, then
//  listed from Dropbox. Until an account is linked, the plus offers Connect
//  to Dropbox.
//

#import "VibeBrowserHost.h"

NS_ASSUME_NONNULL_BEGIN

@interface DropboxBrowserSource : NSObject <VibeBrowserSource>
@end

NS_ASSUME_NONNULL_END
