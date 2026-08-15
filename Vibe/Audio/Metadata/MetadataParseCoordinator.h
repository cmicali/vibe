//
//  MetadataParseCoordinator.h
//  Vibe
//
//  One parse holder per cache identity, with duplicate rows weakly waiting for
//  its result. Foundation-only so the contention contract has host-less tests.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MetadataParseClaimRole) {
    // This claim owns the parse and is the only one that may complete it.
    MetadataParseClaimRoleOwner,
    // Another participant holds it; this one joined the weak waiter list and
    // is handed back to the owner on completion.
    MetadataParseClaimRoleWaiter,
    // This participant already holds the claim from an earlier attempt, so it
    // has nothing to wait for — the in-flight parse publishes to it anyway.
    // Kept distinct from Waiter because the two mean opposite things, even
    // though a caller that only asks isOwner treats them alike.
    MetadataParseClaimRoleAlreadyOwner,
};

// A claim is confined to the thread that took it: it is built entirely inside
// the coordinator's monitor and handed to exactly one caller, so its own
// fields need no synchronization. Do not share one across threads.
@interface MetadataParseClaim : NSObject

@property (nonatomic, readonly) MetadataParseClaimRole role;
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

// Diagnostic: {holders, waiters}. Both should return to zero once parsing
// settles; a claim that is never completed strands its holder and that key's
// whole waiter table, which is far too small to show up in the process
// footprint but is exactly what an open storm can leave behind. Not debug-only
// — the contention tests assert on it, the way FolderArtResolver's
// recordedDirectoryCount is diagnostic surface for its own.
- (NSDictionary<NSString *, NSNumber *> *)pendingCounts;

@end

NS_ASSUME_NONNULL_END
