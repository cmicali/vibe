//
//  NSURL+FileIdentity.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSURL (FileIdentity)

// Whether two file URLs name the same standardized or symlink-resolved file
// location, or currently resolve to the same filesystem object. Nil, non-file
// and unestablishable pairs answer NO. This may block; call it off main.
- (BOOL)vibeRefersToSameFileAsURL:(nullable NSURL *)otherURL;

@end

NS_ASSUME_NONNULL_END
