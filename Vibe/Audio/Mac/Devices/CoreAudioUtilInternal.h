//
//  CoreAudioUtilInternal.h
//  Vibe
//
//  The HAL helpers CoreAudioUtil.m shares with its +BitPerfect and
//  +Diagnostics categories.
//

#import "CoreAudioUtil.h"

// One fixed-size property read or write, with the answer separate from the
// success. CoreAudioUtil.m defines both.
BOOL VibeReadDeviceProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                            AudioObjectPropertyScope scope, void *value, UInt32 size);
BOOL VibeWriteDeviceProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                             const void *value, UInt32 size);

// The stream's first device channel, one-based. CoreAudioUtil+BitPerfect.m
// defines it.
BOOL VibeReadStartingChannel(AudioStreamID stream, UInt32 *firstChannel);
