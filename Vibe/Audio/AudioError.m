//
//  AudioError.m
//  Vibe
//
//  Definitions only, in a file of their own so the host-less test suite can
//  link the error rules without compiling the player.
//

#import "AudioError.h"

NSString *const kVibeAudioErrorDomain = @"com.commonwealthrecordings.Vibe";
NSString *const kVibeAudioErrorTrackURLKey = @"VibeAudioErrorTrackURL";
NSString *const kVibeAudioErrorOpenMadeProgressKey = @"VibeAudioErrorOpenMadeProgress";
