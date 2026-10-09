//
//  AudioFileHandle+Debug.h
//  Vibe
//
//  The read-ahead's test seam: which files read ahead, and what each of its
//  reads does. Both are process-wide, so a test sets them for its own URLs
//  and clears them in tearDown. Declaration-only, like AudioPlayer+Debug.h.
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
// it, or -1 to read nothing, which is the file's end.
+ (void)debugSetBeforeRead:(nullable int (^)(NSURL *url, uint64_t offset, uint64_t length))beforeRead;

// Read-ahead threads alive now, and those whose handle is gone while they are
// still inside a read. Both are process-wide.
@property (class, nonatomic, readonly) NSInteger debugLiveReadAheads;
@property (class, nonatomic, readonly) NSInteger debugOrphanedReadAheads;

@end

NS_ASSUME_NONNULL_END

#endif
