//
//  OpenRequestCoordinator.m
//  Vibe
//

#import "OpenRequestCoordinator.h"

// Not a bound on expansion: nothing is armed until a LATER batch has finished.
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
    // One armed deadline per missing head. 0 is none; generations start at 1
    // and only ever climb.
    NSUInteger _armedDeadlineGeneration;
    NSUInteger _armedDeadlineSequence;
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
        // 1, not 0: the armed-deadline state uses 0 as none.
        _openGeneration = 1;
        _completed = [NSMutableDictionary dictionary];
        _stragglerDeadline = kDefaultStragglerDeadline;
    }
    return self;
}

- (void)invalidate {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    _openGeneration++;
    _nextSequence = 0;
    _nextDeliverySequence = 0;
    [_completed removeAllObjects];
}

- (OpenRequestToken *)beginRequestAppending:(BOOL)append
                                   delivery:(OpenRequestDelivery)delivery {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    if (!append) {
        [self invalidate];
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
    // Still buffered: an earlier batch is outstanding.
    if (_completed.count > 0) {
        [self armStragglerDeadline];
    }
}

- (void)abandonStalledRequests {
    NSAssert(NSThread.isMainThread, @"OpenRequestCoordinator is main-thread only");
    if (_completed.count == 0) {
        return;
    }
    // Only the head: the ones behind it may be slow rather than wedged, and a
    // skipped request's late result is dropped by finishRequest:'s sequence
    // check. Every insertion drains first, so the head is the missing one.
    _nextDeliverySequence++;
    [self deliverReadyResults];
    // Nothing else re-arms for a gap still buffered.
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
    NSUInteger generation = _openGeneration;
    NSUInteger missingSequence = _nextDeliverySequence;
    if (_armedDeadlineGeneration == generation &&
            _armedDeadlineSequence == missingSequence) {
        return;
    }
    _armedDeadlineGeneration = generation;
    _armedDeadlineSequence = missingSequence;
    __weak OpenRequestCoordinator *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_stragglerDeadline * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        OpenRequestCoordinator *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        // TRAP: a replacement or a later gap may have armed its own deadline;
        // disarming here would strand that missing request.
        if (strongSelf->_armedDeadlineGeneration != generation ||
                strongSelf->_armedDeadlineSequence != missingSequence) {
            return;
        }
        strongSelf->_armedDeadlineGeneration = 0;
        if (strongSelf->_openGeneration != generation ||
                strongSelf->_nextDeliverySequence != missingSequence) {
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
