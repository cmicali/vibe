//
//  DropboxMirror.h
//  Vibe (iOS)
//
//  The linked Dropbox account as local files, so everything that plays,
//  tags, waveforms and caches a file works on Dropbox unchanged. Lazy: a
//  Dropbox folder exists here only once something listed it, as a directory
//  holding a placeholder per audio file (PlaceholderFiles' remote placeholders: the
//  real size and mtime, no readable bytes) and the playlist files beside them.
//  The placeholders, their fetch, the ranged read, and the download budget
//  are RemotePlaceholderStore's. This class lists, names, and searches.
//
//  Paths are resolved component by component, case-insensitively, against
//  what is on disk, because Dropbox paths are case-insensitive and a
//  path_display is only trustworthy in its last component.
//

#import <Foundation/Foundation.h>

#import "DropboxClient.h"
#import "RemotePlaceholderStore.h"

NS_ASSUME_NONNULL_BEGIN

// A fetch landed, or the budget changed, with whatever the budget then
// evicted. Posted on main with the mirror as its object and the downloads'
// total bytes, already counted, under VibeDropboxDownloadsBytesKey. Posted when
// a fetch lands, when the budget changes, when Remove Downloads settles, and
// when a relist discards downloaded bytes.
extern NSNotificationName const VibeDropboxDownloadsDidChangeNotification;
extern NSString *const VibeDropboxDownloadsBytesKey;
// The saved download budget, an iOS-owned key: the shared mirror starts from
// it (VibeDropboxDownloadBudgetIndex), and Settings writes it, then sets
// downloadBudget.
extern NSString *const VibeDropboxDownloadBudgetKey;

@interface DropboxMirror : RemotePlaceholderStore

- (instancetype)initWithClient:(HTTPTransferClient *)client
                       rootURL:(NSURL *)rootURL
                indexAttribute:(NSString *)indexAttribute
                downloadBudget:(long long)downloadBudget NS_UNAVAILABLE;

// The app's one mirror over the one client. A singleton because the remote
// fetch, installed at launch, must reach the same instance every screen does.
@property (class, nonatomic, readonly) DropboxMirror *shared;

// rootURL holds one directory per account; the tests pass a temp directory.
// Past downloadBudget bytes of downloads, the oldest go back to placeholders.
- (instancetype)initWithClient:(DropboxClient *)client
                       rootURL:(NSURL *)rootURL
                downloadBudget:(long long)downloadBudget NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) DropboxClient *client;

// The linked account's Dropbox root, nil while unlinked.
@property (nonatomic, readonly, nullable) NSURL *accountURL;

// The Dropbox path ("" for the root, else "/Music/Album") a mirror URL stands
// for; nil outside the linked account's mirror. A folder below the root may
// read its listing's index, an xattr in the app's container, once per folder.
// Nothing outside the mirror is read.
- (nullable NSString *)dropboxPathForURL:(NSURL *)url;

// The same from the URL's spelling alone, with no index read. A folder whose
// local name gained a collision suffix answers that local spelling.
- (nullable NSString *)derivedDropboxPathForURL:(NSURL *)url;

// Whether anything has listed this mirror directory: one never listed is
// empty on disk whatever Dropbox holds.
- (BOOL)hasListedDirectory:(NSURL *)url;

// Lists the Dropbox folder and makes its directory here match: placeholders
// for new or changed audio, playlist files downloaded, departed entries removed.
// Network results complete on main with the folder's local URL. An unlinked
// account fails inline. A directory already here
// is relisted by its dropboxPathForURL:.
- (void)refreshDropboxFolder:(NSString *)path
                  completion:(void (^)(NSURL *_Nullable folderURL, NSError *_Nullable error))completion;

// files/search_v2 over the whole account: folders and playable files, as
// entries. Completion on main.
- (void)searchQuery:(NSString *)query
         completion:(void (^)(NSArray<NSDictionary *> *_Nullable entries, NSError *_Nullable error))completion;

// Where an entry (a listing's or a search's) lives here, listing its folder
// first so the file or folder exists: a folder entry answers itself, a file
// its placeholder. Listing results complete on main. A missing path or unlinked
// account fails inline. The URL is nil when Dropbox could not be listed.
- (void)localURLForEntry:(NSDictionary *)entry
              completion:(void (^)(NSURL *_Nullable url, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
