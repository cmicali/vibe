//
//  MetadataParseCoordinator.m
//  Vibe
//

#import "MetadataParseCoordinator.h"

// All nonatomic: a claim never leaves the thread that took it (see the
// header), so atomic accessors would buy nothing and cost a lock per read.
// They are written only inside the coordinator's monitor, before the claim is
// returned, which is what publishes them safely to that one thread.
@interface MetadataParseClaim ()
@property (nonatomic, copy, nullable) NSString *key;
@property (nonatomic, strong) id participant;
@property (nonatomic, getter=isOwner) BOOL owner;
@end

@implementation MetadataParseClaim
@end

@implementation MetadataParseCoordinator {
    // The owning claim per key. It holds its participant strongly: the owner
    // has to survive to complete its own parse.
    NSMutableDictionary<NSString *, MetadataParseClaim *> *_holders;
    // Duplicate participants per key, held WEAKLY — a row discarded while a
    // provider-backed parse blocks for minutes has nothing left to publish to, and
    // pinning it would keep the whole discarded playlist alive.
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
            // Pointer personality, not isEqual:, because two distinct rows for
            // the same file are distinct participants and both want serving.
            waiters = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory
                    | NSPointerFunctionsObjectPointerPersonality];
            _waiters[claim.key] = waiters;
        }
        [waiters addObject:participant]; // a set: a repeat waiter is absorbed
        return claim;
    }
}

- (NSArray *)completeClaim:(MetadataParseClaim *)claim {
    // Read outside the monitor deliberately: both are claim-confined fields
    // (see the header), and neither can change once the claim was returned.
    if (!claim.isOwner || !claim.key) {
        return @[];
    }
    @synchronized (self) {
        // Identity, not key presence: a claim whose key has since been claimed
        // again by someone else must not complete that newer generation, and a
        // non-owner claim must never free the true holder.
        if (_holders[claim.key] != claim) {
            return @[];
        }
        [_holders removeObjectForKey:claim.key];
        // Cleared with the holder, in the same critical section, so the next
        // generation of this key starts with no inherited waiters.
        NSArray *waiters = _waiters[claim.key].allObjects ?: @[];
        [_waiters removeObjectForKey:claim.key];
        return waiters;
    }
}

- (NSArray *)drainWaitersForSuccessfulClaim:(MetadataParseClaim *)claim
                                   completed:(BOOL *)completed {
    NSParameterAssert(completed);
    // Uncoordinated and stale claims have no waiter table to drain.
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
            // Keep the holder while the caller adopts this batch. Any waiter
            // arriving in that interval joins a fresh table for the next drain.
            *completed = NO;
        }
        return waiters;
    }
}

- (NSDictionary<NSString *, NSNumber *> *)pendingCounts {
    @synchronized (self) {
        NSUInteger waiters = 0;
        for (NSHashTable *table in _waiters.objectEnumerator) {
            // count, not allObjects.count: the waiters are weak, so this
            // includes entries whose participant has already been discarded —
            // which is the honest measure of what the table is still holding.
            waiters += table.count;
        }
        // This class's own vocabulary. The debug channel namespaces them into
        // its health schema; naming them for that schema here would be the
        // schema leaking into a class that knows nothing about it.
        return @{@"holders": @(_holders.count), @"waiters": @(waiters)};
    }
}

@end
