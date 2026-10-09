//
//  RemotePlaceholderStore.h
//  Vibe
//
//  Remote files kept as local placeholders under one root, so everything
//  that plays, tags, waveforms and caches a file works on them unchanged. A
//  placeholder is NSURLUtil's remote placeholder: the real size and mtime,
//  no readable bytes. Playing one downloads it through CloudFileMaterializer's
//  remote fetch, which is fetchPlaceholderAtURL:… here, and the bytes replace
//  it. The part file they stream into is readable meanwhile. Tags are read by
//  range. Past the download budget the oldest downloads go back to
//  placeholders.
//
//  A subclass says which remote file a placeholder stands for, and how its
//  client reads the answers, through the hooks in
//  RemotePlaceholderStoreInternal.h (DropboxMirror).
//

#import <Foundation/Foundation.h>

@class CloudFileAvailability;
@class HTTPTransferClient;

NS_ASSUME_NONNULL_BEGIN

@interface RemotePlaceholderStore : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// rootURL holds every placeholder. indexAttribute names the xattr each
// directory's index is kept in. Past downloadBudget bytes of downloads, the
// oldest go back to placeholders.
- (instancetype)initWithClient:(HTTPTransferClient *)client
                       rootURL:(NSURL *)rootURL
                indexAttribute:(NSString *)indexAttribute
                downloadBudget:(long long)downloadBudget NS_DESIGNATED_INITIALIZER;

@property (nonatomic, readonly) HTTPTransferClient *client;

// The remote placeholder root.
@property (nonatomic, readonly) NSURL *rootURL;

// Main thread; applied, not saved. A smaller one sends the oldest downloads
// back to placeholders at once, reporting the new total.
@property (nonatomic) long long downloadBudget;

// Installs this store as CloudFileMaterializer's backend for rootURL: the
// fetch, the ranged read and the streaming lookup below. Before anything
// opens a file under the root.
- (void)installAsRemoteBackend;

// What the downloaded songs take on disk, counted on the store's queue.
// Completion on main.
- (void)measureDownloadsWithCompletion:(void (^)(long long bytes))completion;

// Turns every downloaded song back into its placeholder. A player still
// reading one keeps its open file. Completion on main.
- (void)removeDownloadsWithCompletion:(dispatch_block_t)completion;

// CloudFileMaterializer's remote fetch: blocks until url's bytes have
// replaced its placeholder, the part file they stream into readable through
// availabilityForURL: meanwhile. onReadable as CloudFileRemoteFetch says, on
// the client's delivery queue. Background threads only.
- (BOOL)fetchPlaceholderAtURL:(NSURL *)url
                   onReadable:(nullable dispatch_block_t)onReadable
                     onCancel:(void (^)(dispatch_block_t cancel))onCancel
                        error:(NSError *__autoreleasing _Nullable *_Nullable)error;

// CloudFileMaterializer's streaming lookup: the availability of url's fetch
// from its first response until it has finished, after the install or the
// failure. Nil otherwise, and for a response naming no size. Any thread.
- (nullable CloudFileAvailability *)availabilityForURL:(NSURL *)url;

// CloudFileMaterializer's remote read: bytes of the file a placeholder stands
// for, by range, blocking, for a tag parse. Background threads only.
- (nullable NSData *)readPlaceholderAtURL:(NSURL *)url
                                   offset:(uint64_t)offset
                                   length:(uint64_t)length
                                    error:(NSError *__autoreleasing _Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
