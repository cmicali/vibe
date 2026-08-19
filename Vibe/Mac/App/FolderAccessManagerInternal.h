//
//  FolderAccessManagerInternal.h
//  Vibe
//

#import "FolderAccessManager.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const NSInteger VibeFolderAccessRestoreConcurrencyLimit;

@interface FolderAccessManager (Internal)

// Background thread. The declaration is shared with the host-less scheduler
// coverage test; production callers use restoreGrantedAccessWithCompletion:.
- (nullable NSDictionary *)resolveStoredEntry:(NSDictionary *)stored;

// Main thread. Shared only with the coverage tests that exercise reactivation
// racing launch restoration.
- (void)mergeAdditions:(NSArray<NSDictionary *> *)additions;

@end

NS_ASSUME_NONNULL_END
