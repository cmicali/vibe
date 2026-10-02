//
//  DropboxMirror.h
//  Vibe (iOS)
//
//  The linked Dropbox account as local files, so everything that plays,
//  tags, waveforms and caches a file works on Dropbox unchanged. Lazy: a
//  Dropbox folder exists here only once something listed it, as a directory
//  holding a placeholder per audio file (NSURLUtil's remote placeholders: the
//  real size and mtime, no readable bytes) and the CUE sheets beside them.
//  Playing a placeholder downloads it through CloudFileMaterializer's remote
//  fetch, which is fetchPlaceholderAtURL:… here, and the bytes replace it.
//
//  Paths are resolved component by component, case-insensitively, against
//  what is on disk, because Dropbox paths are case-insensitive and a
//  path_display is only trustworthy in its last component.
//

#import <Foundation/Foundation.h>

#import "DropboxClient.h"

NS_ASSUME_NONNULL_BEGIN

@interface DropboxMirror : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

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

// Inside the mirror of any account, a signed-out one's included.
- (BOOL)containsURL:(NSURL *)url;

// The Dropbox path ("" for the root, else "/Music/Album") a mirror URL stands
// for; nil outside the linked account's mirror.
- (nullable NSString *)dropboxPathForURL:(NSURL *)url;

// Lists the Dropbox folder and makes its directory here match: placeholders
// for new or changed audio, CUE sheets downloaded, departed entries removed.
// Completion on main with the folder's local URL.
- (void)refreshDropboxFolder:(NSString *)path
                  completion:(void (^)(NSURL *_Nullable folderURL, NSError *_Nullable error))completion;

// The same, for a directory already in the mirror.
- (void)refreshFolderAtURL:(NSURL *)folderURL
                completion:(void (^)(NSError *_Nullable error))completion;

// files/search_v2 over the whole account: folders and playable files, as
// entries. Completion on main.
- (void)searchQuery:(NSString *)query
         completion:(void (^)(NSArray<NSDictionary *> *_Nullable entries, NSError *_Nullable error))completion;

// Where an entry (a listing's or a search's) lives here, listing its folder
// first so the file or folder exists: a folder entry answers itself, a file
// its placeholder. Completion on main, nil when Dropbox could not be listed.
- (void)localURLForEntry:(NSDictionary *)entry
              completion:(void (^)(NSURL *_Nullable url, NSError *_Nullable error))completion;

// What the downloaded songs take on disk, counted on the mirror's queue.
// Completion on main.
- (void)measureDownloadsWithCompletion:(void (^)(long long bytes))completion;

// Turns every downloaded song back into its placeholder; a player still
// reading one keeps its open file. Completion on main.
- (void)removeDownloadsWithCompletion:(dispatch_block_t)completion;

// CloudFileMaterializer's remote fetch: blocks until url's bytes have
// replaced its placeholder. Background threads only.
- (BOOL)fetchPlaceholderAtURL:(NSURL *)url
                     onCancel:(void (^)(dispatch_block_t cancel))onCancel
                        error:(NSError *__autoreleasing _Nullable *_Nullable)error;

// CloudFileMaterializer's remote read: bytes of the file a placeholder stands
// for, by range, blocking, for a tag parse. Background threads only.
- (nullable NSData *)readPlaceholderAtURL:(NSURL *)url
                                   offset:(uint64_t)offset
                                   length:(uint64_t)length
                                    error:(NSError *__autoreleasing _Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
