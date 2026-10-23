//
//  OpenRequestCoordinator.h
//  Vibe
//
//  Orders the asynchronously expanded batches of every open funnel. A
//  replacing request supersedes every unfinished older one; appends in the
//  surviving burst deliver in submission order. Use one coordinator for each
//  list the opens land in, so a drop is not overwritten by an older, slower
//  open from another funnel. The rows are the caller's own objects, handed
//  back as they came. Main thread only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class OpenRequestToken;

// Runs on main when this request's turn comes up.
typedef void (^OpenRequestDelivery)(NSArray *rows, NSUInteger folderCount, BOOL append);

@interface OpenRequestCoordinator : NSObject

// The app's one coordinator. -init makes an independent one.
+ (instancetype)sharedCoordinator;

// Supersedes every pending request and buffered result. Call it before
// clearing the list the opens land in, so a late result cannot refill it.
- (void)invalidate;

// append == NO starts a new generation and invalidates every older token.
- (OpenRequestToken *)beginRequestAppending:(BOOL)append
                                   delivery:(OpenRequestDelivery)delivery;

// YES until a later replacing request supersedes the token.
- (BOOL)isRequestCurrent:(OpenRequestToken *)token;

// May arrive out of order. Results buffer until every earlier one in their
// generation has arrived, or the straggler deadline gives up on it.
- (void)finishRequest:(OpenRequestToken *)token
                 rows:(NSArray *)rows
          folderCount:(NSUInteger)folderCount;

// A held request is never given up on. Its owner is still deciding what it
// opens, in a wait that is bounded and can be cancelled: a dropped link
// resolving. Release starts the deadline again for what then buffers behind
// it. Either one on a superseded token does nothing.
- (void)holdRequest:(OpenRequestToken *)token;
- (void)releaseRequest:(OpenRequestToken *)token;

// Gives up on the one request the buffered results wait behind (a walk on a
// mount that never answers) and delivers what that frees. Only that one, so a
// merely slow walk behind it still delivers; each stalled request costs one
// deadline. A held request is not given up on. Armed automatically; exposed
// for the tests.
- (void)abandonStalledRequests;

// Test seam; the default schedules on the main queue. A block is a no-op
// once a newer deadline is armed, so firing a stale one is safe.
@property (nonatomic, copy) VibeScheduler deadlineScheduler;

@end

NS_ASSUME_NONNULL_END
