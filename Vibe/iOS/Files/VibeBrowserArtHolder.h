//
//  VibeBrowserArtHolder.h
//  Vibe (iOS)
//
//  The holder a file row's art loads into when the host has none of its own
//  (artHolderForFileURL:). One whole file, with no window.
//

#import <Foundation/Foundation.h>

#import "AudioTrackMetadataHolder.h"

NS_ASSUME_NONNULL_BEGIN

@interface VibeBrowserArtHolder : NSObject <AudioTrackMetadataHolder>

- (instancetype)initWithURL:(NSURL *)url NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
