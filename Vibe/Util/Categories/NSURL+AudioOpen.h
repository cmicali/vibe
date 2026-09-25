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

// The FLAC conversion's strict positive check before a destructive handoff:
// YES only for a regular file this process can open, whose container
// CoreAudio accepts and which reports at least one decoded frame. One
// AudioFileHandle open, closed again; do not use it to gate playback opens,
// which open the handle they will read.
- (BOOL)validateAudioFileIsReadableAndHasContent;

@end

NS_ASSUME_NONNULL_END
