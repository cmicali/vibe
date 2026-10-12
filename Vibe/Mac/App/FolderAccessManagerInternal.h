//
//  FolderAccessManagerInternal.h
//  Vibe
//

#import "FolderAccessManager.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSInteger VibeFolderAccessRestoreConcurrencyLimit;

@interface FolderAccessManager (Internal)

// Background thread. For the scheduler tests.
- (nullable NSDictionary *)resolveStoredEntry:(NSDictionary *)stored;

// Main thread. For the tests of reactivation racing launch restoration.
- (void)mergeAdditions:(NSArray<NSDictionary *> *)additions;

// The fallback of every wait for a grant. The scheduler tests replace it, so
// the fallback cannot settle a wait they assert real work settled.
- (NSTimeInterval)restoreDeadline;

@end

NS_ASSUME_NONNULL_END
