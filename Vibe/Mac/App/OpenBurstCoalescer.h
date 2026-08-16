//
//  OpenBurstCoalescer.h
//  Vibe
//
//  Coalesces system open events into one logical playlist action. Launch
//  Services can split a single multi-file open into several events, and a
//  burst can straddle app launch, so: the first batch replaces and plays
//  immediately, with no coalescing delay, and later batches inside the quiet
//  period append. A deliberate open (the open panel, Open Recent) ends any
//  burst and always replaces. Foundation-only; the owner supplies what to do
//  with each drained batch through the sink.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Receives each drained batch, unexpanded: folders still need walking and
// unsupported files filtering. append is NO for a replacing play.
typedef void (^OpenBurstSink)(NSArray<NSURL *> *urls, BOOL append);

// Test seam for the quiet-period timer; the default schedules on the main
// queue. A superseded block must become a no-op — the coalescer handles that
// internally, so a scheduler only ever runs what it is given.
typedef void (^OpenBurstScheduler)(NSTimeInterval delay, dispatch_block_t block);

@interface OpenBurstCoalescer : NSObject

- (instancetype)initWithQuietPeriod:(NSTimeInterval)quietPeriod sink:(OpenBurstSink)sink;
- (instancetype)initWithQuietPeriod:(NSTimeInterval)quietPeriod
                          scheduler:(OpenBurstScheduler)scheduler
                               sink:(OpenBurstSink)sink;

// The app finished launching: drains anything queued as the first batch of a
// burst — the post-launch remainder of an open that straddled launch must
// append rather than replace. Returns YES when a batch drained, so the caller
// knows whether the empty state may render.
- (BOOL)startAndDrainQueue;

// A system open event: part of the current burst, or the start of a new one.
- (void)openBurstURLs:(NSArray<NSURL *> *)urls;

// A deliberate open — the open panel, Open Recent, a window drop: ends any
// burst rather than joining it. append is the caller's own decision, not the
// burst's: a drop onto the empty-state add well appends, everything else
// replaces. Before start it only queues, exactly like enqueueURLs, and the
// launch drain picks it up.
- (void)openDeliberateURLs:(NSArray<NSURL *> *)urls appending:(BOOL)append;

@end

NS_ASSUME_NONNULL_END
