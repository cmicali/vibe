//
//  NSURL+FileIdentity.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSURL (FileIdentity)

// Same standardized or symlink-resolved path, or the same inode. NO for nil,
// non-file or unstattable pairs. May block: call it off main.
- (BOOL)vibeRefersToSameFileAsURL:(nullable NSURL *)otherURL;

@end

NS_ASSUME_NONNULL_END
