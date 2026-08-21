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
// or restore.
- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID;

// Resolves the retained launch preference without blocking _queue. It only
// applies a found device while Stopped; playback winning the lookup race leaves
// the preference pending for the next Stopped transition or device/default
// refresh. Runs on _queue.
- (void)resolvePendingSavedOutputDeviceOnQueue;

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
