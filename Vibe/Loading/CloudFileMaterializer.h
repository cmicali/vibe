//
//  CloudFileMaterializer.h
//  Vibe
//
//  Downloads a file provider's placeholder as an abortable step. Opening a
//  dataless file blocks in the kernel until the provider finishes, and
//  NSFileCoordinator's -cancel is the one documented way out, so the download
//  is coordinated here rather than left inside whatever opens the file.
//
//  TRAP: cancelling stops us waiting. Whether the provider abandons the
//  transfer is its business (a replicated extension's NSProgress may be
//  cancelled, nothing promises it), so it frees the lane and the thread at
//  once, not the bandwidth.
//

#import <Foundation/Foundation.h>
#import "CloudFileAvailability.h"

NS_ASSUME_NONNULL_BEGIN

// Created before the caller dispatches its worker, so -cancel reaches a call
// that has not yet entered materializeURL:. A token, not a claim:
// each caller owns its materializer, and a later preparation supersedes it.
@interface CloudFileMaterializationToken : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// A remote placeholder's backend (PlaceholderFiles' setRemotePlaceholderRoots:;
// iOS: the Dropbox mirror). Blocks the worker until url holds its bytes.
// onCancel hands over the block -cancel runs, from any thread; a cancel that
// came first runs it at once. Unlike the provider path, this cancel stops the
// transfer, not just the wait. onReadable, when given, is called at most
// once, from the transfer's own thread and so must return at once, when the
// file can be opened before it is complete: availabilityForURL: answers it
// and enough of its head is written. A file that completes first never calls
// it, and the return still says whether the transfer completed.
typedef BOOL (^CloudFileRemoteFetch)(NSURL *url,
                                     dispatch_block_t _Nullable onReadable,
                                     void (^onCancel)(dispatch_block_t cancel),
                                     NSError *__autoreleasing _Nullable *_Nullable error);

// The same backend's ranged read: `length` bytes at `offset` of the remote
// file a placeholder stands for, blocking, so a tag parse reads the few
// hundred KB it needs instead of materializing the file. Nil on failure.
typedef NSData *_Nullable (^CloudFileRemoteRead)(NSURL *url, uint64_t offset, uint64_t length,
                                                 NSError *__autoreleasing _Nullable *_Nullable error);

// The same backend's streaming lookup: the availability of a file whose
// transfer is writing it now, nil when none is, and then the file is whole.
// It may answer nil only once that availability has finished, since a reader
// that looked it up earlier may be waiting on it.
typedef CloudFileAvailability *_Nullable (^CloudFileRemoteAvailability)(NSURL *url);

@interface CloudFileMaterializer : NSObject

// A remote backend for the files under root, at launch before anything opens
// one. It replaces any backend root had. Fetch and read come all or none, and
// availability only with them, nil while the backend streams nothing. A root
// with no blocks removes its backend, and a nil root removes every backend.
// Several roots may be installed. A file goes to the backend of the longest
// root holding it. The roots scope PlaceholderFiles' remote placeholder
// rule. While a file is a remote placeholder, its backend's blocks are there
// to serve it.
+ (void)setRemoteRoot:(nullable NSURL *)root
                fetch:(nullable CloudFileRemoteFetch)fetch
                 read:(nullable CloudFileRemoteRead)read
         availability:(nullable CloudFileRemoteAvailability)availability;

// The read of the backend holding url, nil under no root. AudioTrackMetadata's
// parse reads a remote placeholder through it.
+ (nullable CloudFileRemoteRead)remoteReadForURL:(NSURL *)url;

// AudioFileHandle opens a file being streamed through it; nil, and nothing
// asked, when no backend streams.
+ (nullable CloudFileAvailability *)availabilityForURL:(NSURL *)url;

// The caller's role in the debug transfer trace; set once at creation.
@property (nonatomic, copy, nullable) NSString *label;

// Registers one call before dispatch, cancelling any earlier one.
- (CloudFileMaterializationToken *)prepareMaterialization;

// Blocks until url's data is on disk; a local file costs only the probe.
// Background only: it blocks for a download, and coordinating on main is how
// an app deadlocks against its own presenters. onReadable is handed to the
// remote fetch as it is (CloudFileRemoteFetch); no other backend calls it.
- (BOOL)materializeURL:(NSURL *)url
                 token:(CloudFileMaterializationToken *)token
            onReadable:(nullable dispatch_block_t)onReadable
                 error:(NSError *__autoreleasing _Nullable *_Nullable)error;

// Any thread, returns at once; the call returns NO with NSUserCancelledError.
// Per-token, not a latch: the next preparation is independent work.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
