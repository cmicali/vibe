//
//  NSURL+AudioOpen.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSURL (AudioOpen)

// YES when the path holds no bytes for a decoder to read: a zero-length file
// or a directory. One stat, no opens — cheap enough for list filtering.
@property (nonatomic, readonly) BOOL isEmptyOrDirectory;

@end

NS_ASSUME_NONNULL_END
