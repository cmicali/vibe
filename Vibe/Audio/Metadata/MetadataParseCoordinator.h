//
//  MetadataParseCoordinator.h
//  Vibe
//
//  One parse holder per URL, with duplicate rows weakly waiting for
//  its result. Foundation-only for host-less contention tests.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A claim is confined to the thread that took it: it is built entirely inside
// the coordinator's monitor and handed to exactly one caller, so its own
// fields need no synchronization. Do not share one across threads.
@interface MetadataParseClaim : NSObject

@property (nonatomic, readonly, getter=isOwner) BOOL owner;

@end

@interface MetadataParseCoordinator<__covariant ParticipantType> : NSObject

// Captures the key and participant for one parse attempt. A different
// participant joins the owner's waiter list; a repeated owner is a no-op. The
// key is copied here, so a participant that mutates its own key afterwards
// cannot strand the claim or its waiters. A nil key is uncoordinated: every
// such claim owns itself and has no waiters.
- (MetadataParseClaim *)claimParseForKey:(nullable id<NSCopying>)key
                             participant:(ParticipantType)participant;

// Only this exact owner claim may complete, and its waiters are returned
// exactly once. Waiters are held weakly, so one whose row was discarded during
// the parse is simply absent — there is nothing left to publish to. A waiter
// registering concurrently with this call either lands in the returned array
// or finds no holder and becomes the next owner; it is never lost.
- (NSArray<ParticipantType> *)completeClaim:(MetadataParseClaim *)claim;

// Successful-result handoff. Drains the waiters currently registered without
// releasing the holder; the caller installs its result on that batch, then
// repeats. Once a drain finds no waiters, it releases the holder atomically and
// sets completed to YES. This closes the last gap in which an uncached waiter
// could become a new owner after completion but before result adoption, while
// still letting the caller release the parse claim before any publication.
- (NSArray<ParticipantType> *)drainWaitersForSuccessfulClaim:
        (MetadataParseClaim *)claim
                                             completed:(BOOL *)completed;

// Diagnostic: {holders, waiters}. Both should return to zero once parsing
// settles; a claim that is never completed strands its holder and that key's
// whole waiter table, which is far too small to show up in the process
// footprint but is exactly what an open storm can leave behind. Not debug-only
// — the contention tests assert on it, the way FolderArtResolver's
// recordedDirectoryCount is diagnostic surface for its own.
- (NSDictionary<NSString *, NSNumber *> *)pendingCounts;

@end

NS_ASSUME_NONNULL_END
