//
//  MetadataParseRunner.m
//  Vibe
//

#import "MetadataParseRunner.h"
#import "MetadataParseCoordinator.h"

@implementation MetadataParseRunner {
    MetadataParseCoordinator *_coordinator;
    __weak id<MetadataParseRunnerDelegate> _delegate;
}

- (instancetype)initWithCoordinator:(MetadataParseCoordinator *)coordinator
                           delegate:(id<MetadataParseRunnerDelegate>)delegate {
    self = [super init];
    if (self) {
        _coordinator = coordinator;
        _delegate = delegate;
    }
    return self;
}

- (void)runForParticipant:(id)participant key:(id<NSCopying>)key {
    // Held for the whole attempt: a delegate released mid-attempt would otherwise
    // strand the claim it already took, and the key's next generation would
    // wait on a holder that can never complete.
    id<MetadataParseRunnerDelegate> delegate = _delegate;
    if (!delegate || [delegate parseRunnerIsResolved:participant]) {
        return;
    }
    MetadataParseClaim *claim = [_coordinator claimParseForKey:key participant:participant];
    // A waiter's answer arrives through the holder's fan-out below, and a
    // repeat of this participant's own claim through the parse already in
    // flight. Either way there is nothing to do here.
    if (!claim.isOwner) {
        return;
    }
    // Re-checked under the claim. The other lane may have finished this exact
    // participant since the check above — and the entry may have been written
    // by a DIFFERENT participant for the same key that finished while this
    // attempt sat queued, which the claim cannot cover, since that one
    // released its claim before this one took it. One cache read beats
    // re-running the parse.
    if ([delegate parseRunnerIsResolved:participant]
            || [delegate parseRunnerServeFromCache:participant]) {
        [self serveWaiters:[_coordinator completeClaim:claim] delegate:delegate];
        return;
    }
    [delegate parseRunnerReadAndCache:participant];
    // Released before either publish; see the delegate protocol.
    NSArray *waiters = [_coordinator completeClaim:claim];
    [delegate parseRunnerPublish:participant];
    [self serveWaiters:waiters delegate:delegate];
}

// Each waiter is served from the entry the parse just wrote, never handed the
// holder's own result: two participants for one key must own separate
// metadata. A failed parse wrote nothing, so the reads miss and every waiter
// keeps the fallback the holder is showing — one answer for the whole key, and
// no retry storm from participants re-queueing each other.
- (void)serveWaiters:(NSArray *)waiters delegate:(id<MetadataParseRunnerDelegate>)delegate {
    for (id waiter in waiters) {
        // A concurrent sweep can serve a waiter while the parse it waited on
        // still blocks. Replacing that with an equivalent instance buys
        // nothing and costs the receiver a second delivery.
        if ([delegate parseRunnerIsResolved:waiter]) {
            continue;
        }
        [delegate parseRunnerServeFromCache:waiter];
    }
}

@end
