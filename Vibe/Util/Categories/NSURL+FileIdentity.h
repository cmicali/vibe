//
//  NSURL+FileIdentity.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSURL (FileIdentity)

// Same standardized or symlink-resolved path, or the same device and inode.
// Matching paths need no stat. Other pairs require two successful stats.
// NO for nil or non-file URLs. May block: call it off main.
- (BOOL)vibeRefersToSameFileAsURL:(nullable NSURL *)otherURL;

@end

NS_ASSUME_NONNULL_END
