//
//  AccountMirror.h
//  Vibe (iOS)
//
//  A linked account as local files, so everything that plays, tags,
//  waveforms and caches a file works on it unchanged. Lazy: a remote folder
//  exists here only once something listed it, as a directory holding a
//  placeholder per audio file (PlaceholderFiles' remote placeholders: the
//  real size and mtime, no readable bytes) and the playlist files beside
//  them. The placeholders, their fetch, the ranged read and the download
//  budget are RemotePlaceholderStore's.
//
//  This class is what every account's mirror shares, and the one face the
//  shell sees: the account's directory, the pruning of other accounts, the
//  playlist files' download claim, the sweep of what left the service, the
//  downloads notification, and the calls the browser, Search and Settings
//  make. Each service's mirror lists, names and searches (DropboxMirror,
//  GoogleDriveMirror).
//

#import <Foundation/Foundation.h>

#import "OAuthAccountClient.h"
#import "RemotePlaceholderStore.h"

NS_ASSUME_NONNULL_BEGIN

// A fetch landed, or the budget changed, with whatever the budget then
// evicted. Posted on main with the mirror as its object and the downloads'
// total bytes, already counted, under VibeAccountDownloadsBytesKey. Posted
// when a fetch lands, when the budget changes, when Remove Downloads settles,
// and when a relist discards downloaded bytes.
extern NSNotificationName const VibeAccountDownloadsDidChangeNotification;
extern NSString *const VibeAccountDownloadsBytesKey;

@interface AccountMirror : RemotePlaceholderStore

// Every account's mirror, in the order the shell lists them: Dropbox, then
// Google Drive once the app has its client id. Singletons, because the
// remote fetch, installed at launch, must reach the same instance every
// screen does.
@property (class, nonatomic, readonly) NSArray<AccountMirror *> *mirrors;
// The mirror whose linked account's directory holds url, nil for none. From
// the spelling alone.
+ (nullable AccountMirror *)mirrorOfURL:(NSURL *)url;

// The store's client, typed as the account it is.
@property (nonatomic, readonly) OAuthAccountClient *client;

// The service's name, a product name shown as is in every language.
@property (nonatomic, readonly, copy) NSString *serviceName;
// The service's glyph in the asset catalog.
@property (nonatomic, readonly, copy) NSString *glyphName;
// The saved download budget, an iOS-owned key: the mirror starts from it
// (VibeAccountDownloadBudgetIndex), and Settings writes it, then sets
// downloadBudget.
@property (nonatomic, readonly, copy) NSString *downloadBudgetKey;

// The linked account's directory under the root, nil while unlinked.
@property (nonatomic, readonly, nullable) NSURL *accountURL;
// Beside accountURL: the shared folder links the account opened. Each link
// has a directory named by its URL's hash, which holds the folder under its
// own name. Nil while unlinked.
@property (nonatomic, readonly, nullable) NSURL *linksURL;
// Whether url lies in the linked account's directory or in linksURL, either
// directory included. From the spelling alone.
- (BOOL)isMirroredURL:(NSURL *)url;
// Whether url lies in linksURL, that directory included. From the spelling
// alone.
- (BOOL)isSharedLinkURL:(NSURL *)url;
// Whether url is the linked account's directory itself.
- (BOOL)isAccountRootURL:(NSURL *)url;

// Whether anything has listed this mirror directory: one never listed is
// empty on disk whatever the service holds.
- (BOOL)hasListedDirectory:(NSURL *)url;

// Lists the remote folder a mirror directory stands for and makes the
// directory match: placeholders for new or changed audio, playlist files
// downloaded, departed entries removed. Network results complete on main
// with the folder's local URL. A URL outside the linked account fails
// inline.
- (void)refreshDirectoryAtURL:(NSURL *)url
                   completion:(void (^)(NSURL *_Nullable folderURL, NSError *_Nullable error))completion;

// Whether a folder link (VibeLinkFolderURL) is this service's.
- (BOOL)opensSharedFolderLink:(NSURL *)link;

// A folder link of this service, listed through the account into linksURL:
// the folder and every folder below it. Its files download through the
// account. Completion on main with the folder's local URL. An unlinked
// account, or another service's link, fails inline.
- (void)openSharedFolderLink:(NSURL *)link
                  completion:(void (^)(NSURL *_Nullable folderURL, NSError *_Nullable error))completion;

// The service's search over the whole account: folders and playable files,
// as entries. Completion on main.
- (void)searchQuery:(NSString *)query
         completion:(void (^)(NSArray<NSDictionary *> *_Nullable entries, NSError *_Nullable error))completion;

// Where a search entry lives here, listing its folder first so the file or
// folder exists: a folder entry answers itself, a file its placeholder.
// Listing results complete on main. An unusable entry or an unlinked account
// fails inline.
- (void)localURLForEntry:(NSDictionary *)entry
              completion:(void (^)(NSURL *_Nullable url, NSError *_Nullable error))completion;

// What a search entry shows: its name, whether it is a folder, and the name
// of the folder holding it (nil for the account's root).
- (NSString *)nameOfEntry:(NSDictionary *)entry;
- (BOOL)entryIsFolder:(NSDictionary *)entry;
- (nullable NSString *)parentNameOfEntry:(NSDictionary *)entry;
// What names an entry across listings and searches, and the same for a
// mirror file, so Search leaves out what the playlist already lists. Nil
// for none. identityOfURL: may read its folder's index, once per folder.
- (nullable NSString *)identityOfEntry:(NSDictionary *)entry;
- (nullable NSString *)identityOfURL:(NSURL *)url;
// Of the entries' files, the identities of those the mirror holds bytes
// for. Off main; completion on main. A file the mirror cannot place reads
// as not downloaded, which errs safe.
- (void)downloadedIdentitiesOfEntries:(NSArray<NSDictionary *> *)entries
                           completion:(void (^)(NSSet<NSString *> *identities))completion;

@end

NS_ASSUME_NONNULL_END
