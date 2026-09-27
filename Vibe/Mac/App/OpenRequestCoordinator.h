//
//  OpenRequestCoordinator.h
//  Vibe
//
//  Orders the asynchronously expanded batches of every open funnel. A
//  replacing request supersedes every unfinished older one; appends in the
//  surviving burst deliver in submission order. ONE coordinator, because
//  there is one playlist: a drop must not be overwritten by an older, slower
//  open from another funnel. Main thread only.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class OpenRequestToken;

// Runs on main when this request's turn comes up.
typedef void (^OpenRequestDelivery)(NSArray<NSURL *> *files, NSUInteger folderCount, BOOL append);

@interface OpenRequestCoordinator : NSObject

// -init makes an independent one, for tests.
+ (instancetype)sharedCoordinator;

// Closing the playlist supersedes pending walks and buffered append results.
- (void)invalidate;

// append == NO starts a new generation and invalidates every older token.
- (OpenRequestToken *)beginRequestAppending:(BOOL)append
                                   delivery:(OpenRequestDelivery)delivery;

// YES until a later replacing request supersedes the token.
- (BOOL)isRequestCurrent:(OpenRequestToken *)token;

// May arrive out of order. Results buffer until every earlier one in their
// generation has arrived, or the straggler deadline gives up on it.
- (void)finishRequest:(OpenRequestToken *)token
                files:(NSArray<NSURL *> *)files
          folderCount:(NSUInteger)folderCount;

// Gives up on the one request the buffered results wait behind (a walk on a
// mount that never answers) and delivers what that frees. Only that one, so a
// merely slow walk behind it still delivers; each stalled request costs one
// deadline. Armed automatically; exposed for the tests.
- (void)abandonStalledRequests;

// How long a finished result waits behind an earlier one.
@property (nonatomic) NSTimeInterval stragglerDeadline;

@end

NS_ASSUME_NONNULL_END
