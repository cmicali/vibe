//
//  OpenBurstCoalescer.h
//  Vibe
//
//  Launch Services can split one multi-file open into several events, and a
//  burst can straddle launch. The first batch replaces and plays at once;
//  later batches inside the quiet period append. A deliberate open ends any
//  burst.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Receives each drained batch unexpanded.
typedef void (^OpenBurstSink)(NSArray<NSURL *> *urls, BOOL append);

// Test seam; the default schedules on the main queue. The coalescer makes a
// superseded block a no-op itself.
typedef void (^OpenBurstScheduler)(NSTimeInterval delay, dispatch_block_t block);

@interface OpenBurstCoalescer : NSObject

- (instancetype)initWithQuietPeriod:(NSTimeInterval)quietPeriod sink:(OpenBurstSink)sink;
- (instancetype)initWithQuietPeriod:(NSTimeInterval)quietPeriod
                          scheduler:(OpenBurstScheduler)scheduler
                               sink:(OpenBurstSink)sink;

// Drains the queue as a burst's first batch, so the rest of an open that
// straddled launch appends. YES when a batch drained.
- (BOOL)startAndDrainQueue;
// After grant restoration: an explicit queued open wins, then the saved
// session, then empty state. Restoration itself never arms an open burst.
- (void)finishLaunchRestoring:(BOOL (^)(void))restore revealEmpty:(dispatch_block_t)revealEmpty;
// exists runs on the caller's worker, never during the main-thread drain.
+ (NSArray<NSURL *> *)fileURLsInArguments:(NSArray<NSString *> *)arguments
                           existingPath:(BOOL (^)(NSString *path))exists;

// A system open event: part of the current burst, or the start of a new one.
- (void)openBurstURLs:(NSArray<NSURL *> *)urls;

// The open panel, Open Recent, a window drop: ends any burst rather than
// joining it; append is the caller's own. Before start it only queues.
- (void)openDeliberateURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append;

@end

NS_ASSUME_NONNULL_END
