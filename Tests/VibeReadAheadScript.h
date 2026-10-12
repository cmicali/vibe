// What a read-ahead's reads do, as a test scripts them through
// AudioFileHandle+Debug.h's seam: each counted by file and offset, then
// slept, stalled until released, failed or cut short. A stalled read holds
// its thread as a dead mount's syscall does. Shared by VibeTests and
// VibeAudioTests.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// AudioFileHandle.m's read-ahead block, the unit a script's offsets count in.
static const uint64_t kReadAheadBlock = 256 * 1024;

@interface VibeReadAheadScript : NSObject

// Installs the process-wide mount rule and hook: every file whose path
// contains `marker` reads ahead, its reads as this script says. Every other
// file asks the real rule.
- (instancetype)initForPathsContaining:(NSString *)marker NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// For tearDown: restores the real mount rule, stops failing and releases
// every stall and held failure. The hook stays until removeHook, so a read
// released now still sees the script.
- (void)releaseEverything;
+ (void)removeHook;
// No read-ahead thread alive and none orphaned. The counts are process-wide.
@property (class, nonatomic, readonly) BOOL threadsGone;

// Signalled once per read that stalls, and per read that fails.
@property (nonatomic, readonly) dispatch_semaphore_t stalled;
@property (nonatomic, readonly) dispatch_semaphore_t failed;
@property (atomic) useconds_t throttle;
- (void)stallFrom:(uint64_t)offset;
// Lets one stalled read through. The rest stay stalled.
- (void)releaseOneStall;
// Releases every stalled read and every held failure.
- (void)releaseStalls;
// Reads at or past `offset` fail with `code`, once or every time.
- (void)fail:(int)code from:(uint64_t)offset always:(BOOL)always;
- (void)stopFailing;
// A failing read then waits after signalling `failed`, until releaseStalls.
// Its errno reaches the thread only then.
- (void)holdFailures;
// The next read at or past `offset` reads nothing, as a share can while it
// reconnects. The file on disk is unchanged.
- (void)cutOnceAt:(uint64_t)offset;

// Reads at `offset`, of any file or of the file named `name`.
- (NSUInteger)readsAt:(uint64_t)offset;
- (NSUInteger)readsOf:(NSString *)name at:(uint64_t)offset;
// Every read the hook was called for.
@property (atomic, readonly) NSUInteger reads;

@end

NS_ASSUME_NONNULL_END
