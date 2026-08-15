//
//  NSURL+AudioOpen.h
//  Vibe
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSURL (AudioOpen)

// YES when the path holds no bytes for a decoder to read: a zero-length file
// or a directory. Ask before every AVAudioFile open; see the implementation.
@property (nonatomic, readonly) BOOL isEmptyOrDirectory;

@end

NS_ASSUME_NONNULL_END
