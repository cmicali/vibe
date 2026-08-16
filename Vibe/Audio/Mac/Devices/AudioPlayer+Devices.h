//
//  AudioPlayer+Devices.h
//  Vibe
//
//  The internal surface of the output-device code: device switching,
//  config-change recovery and no-device parking. The public device API is
//  AudioPlayer.h's (Devices) category; AudioPlayer+Devices.m implements both.
//

#import "AudioPlayer.h"
#import "AudioDeviceManager.h"
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (DevicesInternal) <AudioDeviceManagerObserver>

// The AudioDeviceID the output unit is currently bound to.
- (AudioDeviceID)activeOutputDeviceID;

// A raw bind of the engine's output unit to deviceID, with no graph rebuild
// or restore. The async init uses it to apply the saved device before the
// engine ever starts.
- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID;

// Rebinds the engine to a new output device, restoring the current track, the
// position and the play or pause state. Runs on _queue.
- (BOOL)configureOutputDeviceOnQueue:(AudioDeviceID)deviceID;

// Parks a playing track as Paused when the last output device has vanished.
// Runs on _queue.
- (void)parkPlaybackForMissingOutputDeviceOnQueue;

// The AVAudioEngineConfigurationChangeNotification handler. The observer that
// AudioPlayer's init installs dispatches it onto _queue.
- (void)handleEngineConfigurationChange;

@end

NS_ASSUME_NONNULL_END
