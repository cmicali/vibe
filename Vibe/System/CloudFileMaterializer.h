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

NS_ASSUME_NONNULL_BEGIN

// Created before the caller dispatches its worker, so -cancel reaches a call
// that has not yet entered materializeURL:. A token, not a claim:
// each caller owns its materializer, and a later preparation supersedes it.
@interface CloudFileMaterializationToken : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

// A remote placeholder's backend (NSURLUtil's setRemotePlaceholderRoot:;
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

typedef NS_ENUM(NSInteger, CloudFileAvailabilityWait) {
    CloudFileAvailabilityReady,
    CloudFileAvailabilityFailed,       // the transfer failed: every wait answers its error
    CloudFileAvailabilityInterrupted,  // the waiter's own interrupt: neither the end nor a failure
};

// How much of a remote file is readable while its transfer writes it into a
// part file from byte 0, the final size known before the first byte, plus at
// most one window of bytes past the download's edge held in memory (the tail
// a stream reads ahead by range). The writer writes before it notes, and
// finishes once; a reader opens the part and waits for the bytes it is about
// to read. Worker threads only: a wait blocks, and nothing here is reachable
// from the render.
@interface CloudFileAvailability : NSObject

- (instancetype)initWithPartURL:(NSURL *)partURL size:(uint64_t)size NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly) NSURL *partURL;
@property (nonatomic, readonly) uint64_t size;

// [0, bytes) is on disk. A count below one already noted is ignored.
- (void)noteWrittenBytes:(uint64_t)bytes;
// The count noted so far: the transfer's progress (DownloadProgressMonitor),
// and what tells a reader a stalled transfer from a slow one.
@property (nonatomic, readonly) uint64_t writtenBytes;
// Once: nil is complete, after which every range is ready; an error fails
// every wait, since nothing already read can be trusted. Either drops the window.
- (void)finishWithError:(nullable NSError *)error;
// The file's bytes at [offset, offset + bytes.length), read ahead of the
// download, held until the download reaches offset. Ignored once finished,
// when the download is already there, when one is held, or past the size.
- (void)installWindow:(NSData *)bytes atOffset:(uint64_t)offset;
// The bytes the window holds now; 0 when none is.
@property (nonatomic, readonly) uint64_t windowLength;

// Blocks until [offset, offset + length) is held, the transfer finished,
// `interrupted` answers YES, or `deadline` passes (Interrupted for both);
// `interrupted` is asked each time the wait would block, under the lock
// wakeWaiters takes. A range is clipped to the size, and one at or past it is
// the end, never a wait. A range already readable is Ready even when
// interrupted: an interrupt ends waits, not reads. A range not on disk but
// wholly inside the window is Ready too, and with a buffer up to `capacity`
// bytes from offset are copied out of the window into it, their count in
// *copied (0: read the disk); without one, readyBytesAt: hands them over. A
// range straddling the window's start waits for the disk. The one range
// question, so a source of bytes changes what answers it, not who asks.
- (CloudFileAvailabilityWait)waitForBytesAt:(uint64_t)offset
                                     length:(uint64_t)length
                                 windowInto:(void *_Nullable)buffer
                                   capacity:(uint64_t)capacity
                                     copied:(uint64_t *_Nullable)copied
                                interrupted:(BOOL (NS_NOESCAPE ^_Nullable)(void))interrupted
                                   deadline:(nullable NSDate *)deadline
                                      error:(NSError *__autoreleasing _Nullable *_Nullable)error;
// Never waits: the longest prefix of [offset, offset + length) readable now,
// copied out of the window, or read from the part file below the bytes
// noted, so never a byte not yet written; nil when none, and once finished,
// when the part is renamed or deleted. Any thread; the disk read is outside
// the lock. A tag parse during a play reads what the stream holds this way.
- (nullable NSData *)readyBytesAt:(uint64_t)offset length:(uint64_t)length;
// Any thread: every wait asks its `interrupted` again. Call it after making
// one answer YES.
- (void)wakeWaiters;

// A holder: a reader, an AudioFileHandle open on the part file, counted from
// its open to its dealloc, or an open about to become one, so whoever runs the
// transfer can tell when nobody still wants it.
- (void)addReader;
- (void)removeReader;
@property (nonatomic, readonly) NSUInteger readerCount;
// Called after each removal that leaves no reader, on the removing thread and
// outside the lock, so it must return at once.
@property (nonatomic, copy, nullable) dispatch_block_t onLastReaderGone;

@end

// The same backend's streaming lookup: the availability of a file whose
// transfer is writing it now, nil when none is, and then the file is whole.
// It may answer nil only once that availability has finished, since a reader
// that looked it up earlier may be waiting on it.
typedef CloudFileAvailability *_Nullable (^CloudFileRemoteAvailability)(NSURL *url);

@interface CloudFileMaterializer : NSObject

// The remote backend, once at launch before anything opens a file: root,
// fetch and read all or none, availability only with them, nil while the
// backend streams nothing. The root scopes NSURLUtil's remote placeholder
// rule, so while a file is a remote placeholder the blocks are there to serve it.
+ (void)setRemoteRoot:(nullable NSURL *)root
                fetch:(nullable CloudFileRemoteFetch)fetch
                 read:(nullable CloudFileRemoteRead)read
         availability:(nullable CloudFileRemoteAvailability)availability;

// AudioTrackMetadata's parse reads a remote placeholder through it.
@property (class, nonatomic, readonly, copy, nullable) CloudFileRemoteRead remoteRead;

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

// materializeURL:'s answer for a file its caller has just probed as local,
// without probing it again: settles token, NO with NSUserCancelledError when
// it was cancelled or superseded.
- (BOOL)settleLocalToken:(CloudFileMaterializationToken *)token
                   error:(NSError *__autoreleasing _Nullable *_Nullable)error;

// Any thread, returns at once; the call returns NO with NSUserCancelledError.
// Per-token, not a latch: the next preparation is independent work.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
