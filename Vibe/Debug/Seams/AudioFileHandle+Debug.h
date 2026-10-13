//
//  AudioFileHandle+Debug.h
//  Vibe
//
//  The read-ahead's test seam (NetworkReadAhead): which files read ahead, and
//  what each of its reads does. Both are process-wide. A test sets them for
//  its own URLs and clears them in tearDown. The category forwards to
//  NetworkReadAhead.m's functions below.
//

#if DEBUG

#import "AudioFileHandle.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioFileHandle (Debug)

// Decides the mount rule for each open that asks it: @YES reads ahead, @NO
// takes the direct road, and nil asks the real rule. Nil restores the real
// rule for every file.
+ (void)debugSetMountRule:(nullable NSNumber *_Nullable (^)(NSURL *url))rule;

// Called on the read-ahead thread before each pread, outside every lock, as
// the syscall would be. It may sleep, to throttle, or block, to stall until
// the test releases it. It answers 0 to read, an errno to fail the read with
// it, or -1 to read nothing. Nothing read is the file's end.
+ (void)debugSetBeforeRead:(nullable int (^)(NSURL *url, uint64_t offset, uint64_t length))beforeRead;

// Scales the pause before a failed read is tried again, 1 by default. A test
// that only waits the pause out shortens it. A test that races a deadline
// against the pause keeps 1.
+ (void)debugSetRetryScale:(double)scale;

// Read-ahead threads alive now, and those whose handle is gone while they are
// still inside a read. Both are process-wide.
@property (class, nonatomic, readonly) NSInteger debugLiveReadAheads;
@property (class, nonatomic, readonly) NSInteger debugOrphanedReadAheads;

@end

// NetworkReadAhead.m's side of the seam. The category forwards to these.
void VibeNetworkReadAheadDebugSetMountRule(NSNumber *_Nullable (^_Nullable rule)(NSURL *url));
void VibeNetworkReadAheadDebugSetBeforeRead(int (^_Nullable beforeRead)(NSURL *url, uint64_t offset, uint64_t length));
void VibeNetworkReadAheadDebugSetRetryScale(double scale);
NSInteger VibeNetworkReadAheadDebugLive(void);
NSInteger VibeNetworkReadAheadDebugOrphaned(void);

NS_ASSUME_NONNULL_END

#endif
