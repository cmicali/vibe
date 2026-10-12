//
//  CloudFileAvailability.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CloudFileAvailabilityWait) {
    CloudFileAvailabilityReady,
    CloudFileAvailabilityFailed,       // the writer failed: every wait answers its error
    CloudFileAvailabilityInterrupted,  // the reader's own interrupt: neither the end nor a failure
};

// How much of a file is readable while a writer fetches it. A reader waits
// for the bytes it is about to read. Worker threads only: a wait blocks, and
// nothing here is reachable from the render.
//
// Two writers. A transfer writes a part file from byte 0, its size known
// before the first byte. It notes the bytes written after writing them, and
// may also install one tail window past them. A writer with no part file
// fetches the file by range into blocks held in memory. It notes the size
// once it knows it, and a wait waits for the blocks. Each writer finishes once.
//
// Blocks are offset-ordered and never overlap. A range held by contiguous
// blocks is copied out of them across their boundaries.
@interface CloudFileAvailability : NSObject

- (instancetype)initWithPartURL:(NSURL *)partURL size:(uint64_t)size;
// A writer with no part file. The size is unknown (UINT64_MAX) until noteSize:.
- (instancetype)initWithoutPartFile NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// Nil for a writer with no part file.
@property (nonatomic, readonly, nullable) NSURL *partURL;
// UINT64_MAX while unknown. Read under the lock, since a writer with no part
// file sets it and may lower it.
@property (nonatomic, readonly) uint64_t size;

// Once: sets an unknown size. Ignored once the size is known.
- (void)noteSize:(uint64_t)size;
// The file ends at `end`, short of the size: a read there found nothing. It
// lowers a known size and never raises it. A wait at or past it is then the
// end, Ready with nothing copied.
- (void)noteShortenedEnd:(uint64_t)end;
// [0, bytes) is on disk. A count below one already noted is ignored.
- (void)noteWrittenBytes:(uint64_t)bytes;
// The count noted so far: the transfer's progress (DownloadProgressMonitor),
// and what tells a reader a stalled transfer from a slow one.
@property (nonatomic, readonly) uint64_t writtenBytes;
// The bytes noted plus every block byte ever installed. It only grows. Any
// rise is movement, whichever writer it is.
@property (nonatomic, readonly) uint64_t progressBytes;
// Once. Nil is complete, after which every range is ready on disk. An error
// fails every wait, since nothing already read can be trusted. Either drops
// every block. A writer with no part file always finishes with an error,
// since complete sends readers to a disk it never wrote. It is asserted.
- (void)finishWithError:(nullable NSError *)error;
// The transfer's tail window: the file's bytes at offset, read ahead of the
// download and held until the download reaches offset. Ignored once
// finished, when the download is already there, when any block is held, or
// past the size.
- (void)installWindow:(NSData *)bytes atOffset:(uint64_t)offset;
// A writer with no part file: the file's bytes at offset, held until dropped.
// The writer hands the bytes over and never touches them again. Ignored once
// finished, past the size, or when blocks already hold the whole range.
// Otherwise it replaces every block it overlaps.
- (void)installBlock:(NSData *)bytes atOffset:(uint64_t)offset;
// Drops every block wholly outside [offset, offset + length). Three are
// always kept: the block at byte 0, the block that ends at the size, and any
// block the range a blocked wait wants overlaps.
- (void)dropBlocksOutsideRangeAt:(uint64_t)offset length:(uint64_t)length;
// The bytes all blocks hold now; 0 when none is held.
@property (nonatomic, readonly) uint64_t windowLength;
// Where the bytes held contiguously from offset end: on disk below the bytes
// written, then in blocks. Offset itself when none is held. It never waits
// and records nothing. The writer asks it rather than a wait.
- (uint64_t)heldEndAt:(uint64_t)offset;

// Blocks until [offset, offset + length) is held, the writer finished,
// `interrupted` answers YES, or `deadline` passes (Interrupted for both).
// `interrupted` is asked each time the wait would block. It is asked under
// the lock wakeWaiters takes, and must not call into this object. A range is
// clipped to the size, and one at or past it is the end, never a wait.
// A range already readable is Ready even when interrupted: an interrupt ends
// waits, not reads.
//
// Below the bytes written, a range is Ready to read from the disk, and
// *copied is 0. A range held by blocks is Ready too. With a buffer, up to
// `capacity` bytes from offset are copied out of the blocks into it, their
// count in *copied. Without one, readyBytesAt: hands them over. A transfer's
// range straddling its window's start waits for the disk.
//
// With no part file, every Ready range below the size comes from blocks. A
// wait before noteSize: waits, since nothing is known to be the end. Either
// writer's wait sleeps until woken or until `deadline`.
- (CloudFileAvailabilityWait)waitForBytesAt:(uint64_t)offset
                                     length:(uint64_t)length
                                 windowInto:(void *_Nullable)buffer
                                   capacity:(uint64_t)capacity
                                     copied:(uint64_t *_Nullable)copied
                                interrupted:(BOOL (NS_NOESCAPE ^_Nullable)(void))interrupted
                                   deadline:(nullable NSDate *)deadline
                                      error:(NSError *__autoreleasing _Nullable *_Nullable)error;
// Never waits: the longest prefix of [offset, offset + length) readable now.
// It is copied out of the blocks, or read from the part file below the bytes
// noted. It is never a byte not yet written. Nil when none, and once
// finished, when the part is renamed or deleted. Any thread. The disk read is outside
// the lock. A tag parse during a play reads what the stream holds this way.
- (nullable NSData *)readyBytesAt:(uint64_t)offset length:(uint64_t)length;
// Any thread: every wait asks its `interrupted` again. Call it after making
// one answer YES.
- (void)wakeWaiters;

// The writer's wait for work, for a writer with no part file. A transfer
// never calls it. It returns at once on news since its last call: a wait
// began to block, the reader entered another block, or readAheadPaused was
// cleared. Otherwise it returns at the deadline. It reports the range a
// blocked wait wants, length 0 when none is blocked, and the reader's
// position, the offset of the most recent wait. These are reported on every
// return. A writer that has just installed a block reads them afresh.
// NO once finished, at once.
- (BOOL)waitForWorkUntil:(NSDate *)deadline
                  wanted:(uint64_t *)offset
                  length:(uint64_t *)length
          readerPosition:(uint64_t *)position;
// Moves the reader's position and wakes the writer. A transfer ignores it.
- (void)noteReaderPosition:(uint64_t)offset;
// Set while the reader's reads are interrupted. The writer then fetches only
// a range a wait wants. Clearing it wakes the writer's wait for work. A
// transfer ignores it.
@property (nonatomic) BOOL readAheadPaused;

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

NS_ASSUME_NONNULL_END
