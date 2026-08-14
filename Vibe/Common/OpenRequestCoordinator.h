//
//  OpenRequestCoordinator.h
//  Vibe
//
//  Orders the asynchronously expanded batches of every open funnel — Launch
//  Services bursts, the ⌘O panel, Open Recent and window drops — against one
//  another. A replacing request supersedes every unfinished older request;
//  append batches in the surviving burst still deliver in submission order.
//
//  There is ONE coordinator (sharedCoordinator), because there is one
//  playlist: two of them would each enforce ordering only within their own
//  funnel, and a drop could still be overwritten by an older, slower open.
//  Main thread only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class OpenRequestToken;

// Runs on the main thread when this request's turn comes up. Each request
// carries its own sink, so unrelated funnels can share the coordinator.
typedef void (^OpenRequestDelivery)(NSArray<NSURL *> *files, NSUInteger folderCount, BOOL append);

@interface OpenRequestCoordinator : NSObject

// The app's coordinator. -init makes an independent one, for tests.
+ (instancetype)sharedCoordinator;

// append == NO starts a new generation and invalidates every older token.
- (OpenRequestToken *)beginRequestAppending:(BOOL)append
                                   delivery:(OpenRequestDelivery)delivery;

// YES until a later replacing request supersedes the token.
- (BOOL)isRequestCurrent:(OpenRequestToken *)token;

// May arrive out of order. Surviving append results are buffered until every
// earlier result in their generation has arrived — or until the straggler
// deadline gives up on it; see abandonStalledRequests.
- (void)finishRequest:(OpenRequestToken *)token
                files:(NSArray<NSURL *> *)files
          folderCount:(NSUInteger)folderCount;

// Gives up on the earliest request that finished results are queued behind and
// delivers them. An expansion can block forever — a folder walk on a mount
// that never answers — and without this every later batch in the burst would
// buffer unseen. Armed automatically whenever a result cannot deliver in
// order; exposed because it is the seam the tests drive.
- (void)abandonStalledRequests;

@end

NS_ASSUME_NONNULL_END
