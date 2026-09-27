//
//  NSURL+AudioOpen.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSURL (AudioOpen)

// A zero-length file or a directory. One stat, no open; NO when the stat
// fails, so the real open reports why.
@property (nonatomic, readonly) BOOL isEmptyOrDirectory;

@end

NS_ASSUME_NONNULL_END
