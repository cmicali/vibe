//
//  OpenRequestCoordinator.m
//  Vibe
//

#import "OpenRequestCoordinator.h"

// How long a finished result waits behind an earlier one that has not arrived.
// It is not a bound on expansion — nothing is armed until a LATER batch has
// already finished, so by then the straggler is the odd one out.
static const NSTimeInterval kDefaultStragglerDeadline = 10.0;

@interface OpenRequestToken : NSObject
@property NSUInteger generation;
@property NSUInteger sequence;
@property BOOL append;
@property (copy) OpenRequestDelivery delivery;
@end

@implementation OpenRequestToken
@end

@interface OpenRequestResult : NSObject
@property (strong) OpenRequestToken *token;
@property (copy) NSArray<NSURL *> *files;
@property NSUInteger folderCount;
@end

@implementation OpenRequestResult
@end

@implementation OpenRequestCoordinator {
    NSUInteger _openGeneration;
    NSUInteger _nextSequence;
    NSUInteger _nextDeliverySequence;
    NSMutableDictionary<NSNumber *, OpenRequestResult *> *_completed;
    // One armed deadline at a time; re-armed by the next stalled result.
    BOOL _stragglerDeadlineArmed;
}

+ (instancetype)sharedCoordinator {
    static OpenRequestCoordinator *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[OpenRequestCoordinator alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Generation 1, not 0, so the first request needs no special case: an
        // append arriving first is a genuine append, not a silently rewritten
        // replacement.
        _openGeneration = 1;
        _completed = [NSMutableDictionary dictionary];
        _stragglerDeadline = kDefaultStragglerDeadline;
    }
    return self;
}

- (OpenRequestToken *)beginRequestAppending:(BOOL)append
                                   delivery:(OpenRequestDelivery)delivery {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    if (!append) {
        _openGeneration++;
        _nextSequence = 0;
        _nextDeliverySequence = 0;
        [_completed removeAllObjects];
    }
    OpenRequestToken *token = [OpenRequestToken new];
    token.generation = _openGeneration;
    token.sequence = _nextSequence++;
    token.append = append;
    token.delivery = delivery;
    return token;
}

- (BOOL)isRequestCurrent:(OpenRequestToken *)token {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    return token && token.generation == _openGeneration;
}

- (void)finishRequest:(OpenRequestToken *)token
                files:(NSArray<NSURL *> *)files
          folderCount:(NSUInteger)folderCount {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    if (![self isRequestCurrent:token] || token.sequence < _nextDeliverySequence
            || _completed[@(token.sequence)]) {
        return;
    }
    OpenRequestResult *result = [OpenRequestResult new];
    result.token = token;
    result.files = files;
    result.folderCount = folderCount;
    _completed[@(token.sequence)] = result;

    [self deliverReadyResults];
    // Still buffered, so an earlier batch is outstanding. Give it a bounded
    // head start rather than holding these behind it for good.
    if (_completed.count > 0) {
        [self armStragglerDeadline];
    }
}

- (void)abandonStalledRequests {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    if (_completed.count == 0) {
        return;
    }
    // Give up on the request at the head of the queue and on nothing else:
    // the ones behind it may be slow rather than wedged, and skipping the
    // whole gap at once would drop a walk that is still coming — its result
    // is dropped by the sequence check in finishRequest:. Every insertion
    // drains first, so the head is always the missing one. Each stalled
    // request costs one more deadline this way, and buys the next one a full
    // window to answer in.
    _nextDeliverySequence++;
    [self deliverReadyResults];
    // Whatever is still buffered sits behind a gap of its own, and nothing
    // else re-arms a deadline for it.
    if (_completed.count > 0) {
        [self armStragglerDeadline];
    }
}

- (void)deliverReadyResults {
    while (YES) {
        NSNumber *key = @(_nextDeliverySequence);
        OpenRequestResult *next = _completed[key];
        if (!next) {
            break;
        }
        [_completed removeObjectForKey:key];
        _nextDeliverySequence++;
        next.token.delivery(next.files, next.folderCount, next.token.append);
    }
}

- (void)armStragglerDeadline {
    if (_stragglerDeadlineArmed) {
        return;
    }
    _stragglerDeadlineArmed = YES;
    NSUInteger generation = _openGeneration;
    __weak OpenRequestCoordinator *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_stragglerDeadline * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        OpenRequestCoordinator *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_stragglerDeadlineArmed = NO;
        // A replacement since cleared the buffer; its own results re-arm.
        if (strongSelf->_openGeneration != generation) {
            return;
        }
        [strongSelf abandonStalledRequests];
    });
}

#if DEBUG
- (NSUInteger)debugBufferedResultCount {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    return _completed.count;
}
#endif

@end
