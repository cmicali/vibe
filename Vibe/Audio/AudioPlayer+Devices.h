//
//  AudioPlayer+Devices.h
//  Vibe
//
//  Internal surface of the output-device management code — device switching,
//  config-change recovery, no-device parking — split from AudioPlayer.m
//  purely for file size. The public device API lives in AudioPlayer.h's
//  (Devices) category; both categories are implemented in
//  AudioPlayer+Devices.m.
//
//  AudioDeviceManagerObserver conformance is declared on this category (not
//  the class extension) so the compiler checks its implementation in that
//  file — same pattern as MainPlayerController+Menus.
//

#import "AudioPlayer.h"
#import "AudioDeviceManager.h"
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

@interface AudioPlayer (DevicesInternal) <AudioDeviceManagerObserver>

// The AudioDeviceID the output unit is currently bound to.
- (AudioDeviceID)activeOutputDeviceID;

// Raw bind of the engine's output unit to deviceID (no graph rebuild or
// restore) — the async init uses this to apply the saved device before the
// engine ever starts.
- (BOOL)setOutputUnitDevice:(AudioDeviceID)deviceID;

// Rebinds the engine to a new output device, restoring the current track,
// position, and play/pause state. Runs on _queue.
- (BOOL)configureOutputDeviceOnQueue:(AudioDeviceID)deviceID;

// Parks a playing track as Paused when the last output device vanished.
// Runs on _queue.
- (void)parkPlaybackForMissingOutputDeviceOnQueue;

// AVAudioEngineConfigurationChangeNotification handler; dispatched onto
// _queue by the observer AudioPlayer's init installs.
- (void)handleEngineConfigurationChange;

@end

NS_ASSUME_NONNULL_END
