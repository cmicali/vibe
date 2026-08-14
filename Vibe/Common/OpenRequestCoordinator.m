//
//  OpenRequestCoordinator.m
//  Vibe
//

#import "OpenRequestCoordinator.h"

// How long a finished result waits behind an earlier one that has not arrived.
// It is not a bound on expansion — nothing is armed until a LATER batch has
// already finished, so by then the straggler is the odd one out.
static const NSTimeInterval kStragglerDeadline = 10.0;

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
    NSUInteger _generation;
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
        _generation = 1;
        _completed = [NSMutableDictionary dictionary];
    }
    return self;
}

- (OpenRequestToken *)beginRequestAppending:(BOOL)append
                                   delivery:(OpenRequestDelivery)delivery {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    if (!append) {
        _generation++;
        _nextSequence = 0;
        _nextDeliverySequence = 0;
        [_completed removeAllObjects];
    }
    OpenRequestToken *token = [OpenRequestToken new];
    token.generation = _generation;
    token.sequence = _nextSequence++;
    token.append = append;
    token.delivery = delivery;
    return token;
}

- (BOOL)isRequestCurrent:(OpenRequestToken *)token {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    return token && token.generation == _generation;
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
    NSUInteger earliestReady = NSUIntegerMax;
    for (NSNumber *sequence in _completed) {
        earliestReady = MIN(earliestReady, sequence.unsignedIntegerValue);
    }
    // Skip past the gap. Whatever those requests eventually deliver is dropped
    // by the sequence check in finishRequest:, so a walk that answers hours
    // later cannot reorder the playlist behind the user.
    _nextDeliverySequence = earliestReady;
    [self deliverReadyResults];
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
    NSUInteger generation = _generation;
    __weak OpenRequestCoordinator *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStragglerDeadline * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        OpenRequestCoordinator *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_stragglerDeadlineArmed = NO;
        // A replacement since cleared the buffer; its own results re-arm.
        if (strongSelf->_generation != generation) {
            return;
        }
        [strongSelf abandonStalledRequests];
    });
}

@end
