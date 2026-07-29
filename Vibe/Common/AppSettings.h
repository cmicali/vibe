//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#define SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT               @"Oversampling Detailed x4"

#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT     @""
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT       @"light"
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK        @"dark"

@interface AppSettings : NSObject

+ (AppSettings*)sharedInstance;

- (void)applicationDidFinishLaunching;

- (NSString *)audioOutputDeviceName;
- (void)setAudioOutputDeviceName:(NSString *)deviceName;

// CoreAudio device UID — more robust than the name (survives duplicate
// device names); the name is kept as a fallback for older settings.
- (NSString *)audioOutputDeviceUID;
- (void)setAudioOutputDeviceUID:(NSString *)deviceUID;

- (NSString *)windowAppearanceStyle;
- (void)setWindowAppearanceStyle:(NSString *)name;

- (NSAppearance *)windowAppearance;

- (NSString *)waveformStyle;
- (void)setWaveformStyle:(NSString *)name;

- (BOOL)isPitchPanelShown;
- (void)setPitchPanelShown:(BOOL)shown;

- (BOOL)isPlaylistShown;
- (void)setPlaylistShown:(BOOL)shown;

// Right-hand time label mode: YES (default) shows minus-prefixed remaining
// time ("-1:50"), NO the total duration. Toggled by clicking the label.
- (BOOL)showRemainingTime;
- (void)setShowRemainingTime:(BOOL)show;

// Pitch fader range in percent (8 or 16, like the SL-1200MK5G's range button).
- (NSInteger)pitchRange;
- (void)setPitchRange:(NSInteger)range;

@end
