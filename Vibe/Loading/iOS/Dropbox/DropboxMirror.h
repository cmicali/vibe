//
//  DropboxMirror.h
//  Vibe (iOS)
//
//  The linked Dropbox account as local files. What every account's mirror
//  shares is AccountMirror's, and the placeholders, their fetch, the ranged
//  read and the download budget are RemotePlaceholderStore's. This class
//  lists, names and searches Dropbox.
//
//  Paths are resolved component by component, case-insensitively, against
//  what is on disk, because Dropbox paths are case-insensitive and a
//  path_display is only trustworthy in its last component.
//

#import <Foundation/Foundation.h>

#import "AccountMirror.h"
#import "DropboxClient.h"

NS_ASSUME_NONNULL_BEGIN

@interface DropboxMirror : AccountMirror

- (instancetype)initWithClient:(HTTPTransferClient *)client
                       rootURL:(NSURL *)rootURL
                indexAttribute:(NSString *)indexAttribute
                downloadBudget:(long long)downloadBudget NS_UNAVAILABLE;

// The app's one Dropbox mirror over the one client.
@property (class, nonatomic, readonly) DropboxMirror *shared;

// rootURL holds one directory per account; the tests pass a temp directory.
// Past downloadBudget bytes of downloads, the oldest go back to placeholders.
- (instancetype)initWithClient:(DropboxClient *)client
                       rootURL:(NSURL *)rootURL
                downloadBudget:(long long)downloadBudget NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) DropboxClient *client;

// The Dropbox path ("" for the root, else "/Music/Album") a mirror URL stands
// for; nil outside the linked account's mirror. A folder below the root may
// read its listing's index, an xattr in the app's container, once per folder.
// Nothing outside the mirror is read.
- (nullable NSString *)dropboxPathForURL:(NSURL *)url;

// The same from the URL's spelling alone, with no index read. A folder whose
// local name gained a collision suffix answers that local spelling.
- (nullable NSString *)derivedDropboxPathForURL:(NSURL *)url;

// Lists the Dropbox folder and makes its directory here match
// (refreshDirectoryAtURL:, by path). Network results complete on main with
// the folder's local URL. An unlinked account fails inline.
- (void)refreshDropboxFolder:(NSString *)path
                  completion:(void (^)(NSURL *_Nullable folderURL, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
