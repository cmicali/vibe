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

// YES when CoreAudio's header parse refuses this file. Subsumes
// isEmptyOrDirectory, then probes with AudioFileOpenWithCallbacks over a
// descriptor this process owns and closes, so the probe itself can never
// strand one. Ask before every AVAudioFile open: a FAILED AVAudioFile init
// leaks its descriptor unrecoverably, so refusal has to be established
// beforehand or not at all — see the implementation.
@property (nonatomic, readonly) BOOL failsAudioOpenPreflight;

@end

NS_ASSUME_NONNULL_END
