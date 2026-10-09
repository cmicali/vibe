//
//  RemotePlaceholderStoreInternal.h
//  Vibe
//
//  The hooks a subclass overrides, and what a subclass and the tests reach
//  past the public calls: the disk queue, the directory index, the downloads,
//  and the budget.
//

#import "RemotePlaceholderStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface RemotePlaceholderStore ()

// A sparse file of `size` bytes and mtime `modified` with no permissions,
// swapped in at url with one rename so no reader ever sees it half made. A
// directory standing at url is replaced.
+ (BOOL)writePlaceholderAtURL:(NSURL *)url size:(long long)size modified:(time_t)modified;

// Downloaded bytes in `part` take mtime `modified` (none when negative), then
// replace whatever stood at url in one rename. On failure the part is gone.
+ (BOOL)installPart:(NSURL *)part
              atURL:(NSURL *)url
           modified:(time_t)modified
              error:(NSError *__autoreleasing _Nullable *_Nullable)error;

// Serial: every change to the store's directories, so two changes to one
// directory never interleave. The downloads are counted, evicted, and removed
// on it too.
@property (nonatomic, readonly) dispatch_queue_t diskQueue;

// The index on a directory, read from its xattr once and cached. Nil for
// none. Any thread.
- (nullable NSDictionary *)indexOfDirectory:(NSURL *)directory;
// Writes the index unless it is unchanged. Any thread.
- (void)writeIndex:(NSDictionary *)index ofDirectory:(NSURL *)directory;
// Drops every cached index, to be read again from the xattrs: a removed
// directory takes its index with it, and the cache cannot name a subtree.
- (void)forgetCachedIndexes;

// Makes the root, once, and keeps it out of backups: the store is a cache of
// what the server holds. The disk queue, before the first directory under it.
- (void)prepareRoot;

// The download of target into url's part file, then the install at url with
// modificationTimeOfMetadata:forURL:'s mtime. Progress and completion on the
// client's queue. Returns the cancel.
- (dispatch_block_t)downloadTarget:(id)target
                   installingAtURL:(NSURL *)url
                          progress:(nullable void (^)(uint64_t bytesWritten, int64_t size,
                                                      NSString *_Nullable version))progress
                        completion:(void (^)(NSError *_Nullable error))completion;

// Whether a fetch of url runs now, from its start to its end. It covers the
// wait for the first response, before availabilityForURL: answers. Any thread.
- (BOOL)isFetchingURL:(NSURL *)url;

// Every downloaded song under root, oldest download first, each as {url,
// size, modified, downloaded}. A playlist file is not one. The disk queue.
- (NSArray<NSDictionary *> *)downloadsUnder:(NSURL *)root;
// Sends the oldest downloads back to placeholders until the rest fit the
// budget, never `keep`. Answers what the downloads take afterwards. The disk
// queue.
- (long long)enforceDownloadBudgetKeeping:(nullable NSURL *)keep;

#pragma mark Hooks

// The target the client fetches for the placeholder at url, nil with an
// error for a file the store cannot fetch. The default has none: every
// subclass overrides it.
- (nullable id)remoteTargetForURL:(NSURL *)url error:(NSError *__autoreleasing _Nullable *_Nullable)error;
// The client's download and ranged read of a target. The defaults call the
// client's downloadTarget:… and readTarget:….
- (dispatch_block_t)downloadTarget:(id)target
                             toURL:(NSURL *)destination
                          progress:(nullable void (^)(uint64_t bytesWritten, int64_t size,
                                                      NSString *_Nullable version))progress
                        completion:(void (^)(NSDictionary *_Nullable metadata, NSError *_Nullable error))completion;
- (dispatch_block_t)readTarget:(id)target
                        offset:(uint64_t)offset
                        length:(uint64_t)length
                    completion:(void (^)(NSData *_Nullable data, NSDictionary *_Nullable metadata,
                                         NSError *_Nullable error))completion;
// What names the bytes a transfer's metadata describes. The default is the
// client's versionOfMetadata:.
- (nullable NSString *)versionOfMetadata:(nullable NSDictionary *)metadata;
// The mtime downloaded bytes take at their install, negative for none. The
// default is the mtime the placeholder at url has now. The cache key is made
// from it, so it must not move across the install.
- (time_t)modificationTimeOfMetadata:(nullable NSDictionary *)metadata forURL:(NSURL *)url;
// Whether url's server answers a Range. NO means no tail read and no ranged
// read: the tags come once the file is local. The default is YES.
- (BOOL)readsByRangeAtURL:(NSURL *)url;
// Where the downloads the budget counts live, nil for none. The default is
// rootURL.
- (nullable NSURL *)budgetRootURL;
// The downloads now take `total` bytes: a fetch landed, the budget changed,
// or Remove Downloads settled. Any thread. The default does nothing.
- (void)downloadsDidChangeWithTotal:(long long)total;
// The log lines' prefix.
- (NSString *)logName;

@end

NS_ASSUME_NONNULL_END
