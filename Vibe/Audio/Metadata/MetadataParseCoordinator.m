//
//  MetadataParseCoordinator.m
//  Vibe
//

#import "MetadataParseCoordinator.h"

// Nonatomic: written inside the monitor before the claim reaches its one
// thread.
@interface MetadataParseClaim ()
@property (nonatomic, copy, nullable) NSString *key;
@property (nonatomic, strong) id participant;
@property (nonatomic, getter=isOwner) BOOL owner;
@end

@implementation MetadataParseClaim
@end

@implementation MetadataParseCoordinator {
    // Strong: the holder must survive to complete its parse.
    NSMutableDictionary<NSString *, MetadataParseClaim *> *_holders;
    // Weak: a row discarded during a minutes-long cloud parse must not pin its
    // playlist.
    NSMutableDictionary<NSString *, NSHashTable *> *_waiters;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _holders = [NSMutableDictionary dictionary];
        _waiters = [NSMutableDictionary dictionary];
    }
    return self;
}

- (MetadataParseClaim *)claimParseForKey:(NSString *)key participant:(id)participant {
    @synchronized (self) {
        MetadataParseClaim *claim = [MetadataParseClaim new];
        claim.key = [key copy];
        claim.participant = participant;
        if (!claim.key) {
            claim.owner = YES;
            return claim;
        }
        MetadataParseClaim *currentHolder = _holders[claim.key];
        if (!currentHolder) {
            claim.owner = YES;
            _holders[claim.key] = claim;
            return claim;
        }
        if (currentHolder.participant == participant) {
            return claim;
        }
        NSHashTable *waiters = _waiters[claim.key];
        if (!waiters) {
            // Pointer personality: two rows for one file both want serving.
            waiters = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory
                    | NSPointerFunctionsObjectPointerPersonality];
            _waiters[claim.key] = waiters;
        }
        [waiters addObject:participant];
        return claim;
    }
}

- (NSArray *)completeClaim:(MetadataParseClaim *)claim {
    // Outside the monitor: claim-confined, immutable once returned.
    if (!claim.isOwner || !claim.key) {
        return @[];
    }
    @synchronized (self) {
        // Identity, not key presence: never complete a newer holder.
        if (_holders[claim.key] != claim) {
            return @[];
        }
        [_holders removeObjectForKey:claim.key];
        // With the holder, so the next holder inherits no waiters.
        NSArray *waiters = _waiters[claim.key].allObjects ?: @[];
        [_waiters removeObjectForKey:claim.key];
        return waiters;
    }
}

- (NSArray *)drainWaitersForSuccessfulClaim:(MetadataParseClaim *)claim
                                   completed:(BOOL *)completed {
    NSParameterAssert(completed);
    if (!claim.isOwner || !claim.key) {
        *completed = YES;
        return @[];
    }
    @synchronized (self) {
        if (_holders[claim.key] != claim) {
            *completed = YES;
            return @[];
        }
        NSArray *waiters = _waiters[claim.key].allObjects ?: @[];
        [_waiters removeObjectForKey:claim.key];
        if (waiters.count == 0) {
            [_holders removeObjectForKey:claim.key];
            *completed = YES;
        }
        else {
            // Keep the holder; a waiter arriving now joins the next drain.
            *completed = NO;
        }
        return waiters;
    }
}

- (NSDictionary<NSString *, NSNumber *> *)pendingCounts {
    @synchronized (self) {
        NSUInteger waiters = 0;
        for (NSHashTable *table in _waiters.objectEnumerator) {
            // count includes discarded weak entries: what the table holds.
            waiters += table.count;
        }
        return @{@"holders": @(_holders.count), @"waiters": @(waiters)};
    }
}

@end
