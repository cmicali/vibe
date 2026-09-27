//
//  MetadataParseCoordinator.h
//  Vibe
//
//  One parse holder per standardized path, with duplicate rows weakly waiting
//  for its result. Foundation-only for host-less contention tests.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Confined to the thread that took it; do not share one across threads.
@interface MetadataParseClaim : NSObject

@property (nonatomic, readonly, getter=isOwner) BOOL owner;

@end

@interface MetadataParseCoordinator<__covariant ParticipantType> : NSObject

// key is the standardized path (VibeStandardizedAudioOpenPath), copied. A
// different participant joins the holder's waiters; a repeated holder is a
// no-op. A nil key is uncoordinated: the claim owns itself, with no waiters.
- (MetadataParseClaim *)claimParseForKey:(nullable NSString *)key
                             participant:(ParticipantType)participant;

// Only the exact holder completes; its weak waiters are returned once. A
// waiter registering concurrently lands here or becomes the next holder.
- (NSArray<ParticipantType> *)completeClaim:(MetadataParseClaim *)claim;

// Successful-result handoff: drains the current waiters but keeps the holder
// while the caller installs on them; repeat until a drain finds none, which
// releases the holder and sets completed. No waiter can become a new holder
// before adopting the result, and the claim is released before publication.
- (NSArray<ParticipantType> *)drainWaitersForSuccessfulClaim:
        (MetadataParseClaim *)claim
                                             completed:(BOOL *)completed;

// {holders, waiters}; both return to zero once parsing settles. Not
// debug-only: the contention tests assert on it.
- (NSDictionary<NSString *, NSNumber *> *)pendingCounts;

@end

NS_ASSUME_NONNULL_END
