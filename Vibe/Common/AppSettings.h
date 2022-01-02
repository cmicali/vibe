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

- (BOOL)isFirstLaunch;

- (NSString *)audioOutputDeviceName;
- (void)setAudioOutputDeviceName:(NSString *)deviceName;

- (BOOL)audioPlayerLockSampleRate;
- (void)setAudioPlayerLockSampleRate:(BOOL)lockSampleRate;

- (NSString *)windowAppearanceStyle;
- (void)setWindowAppearanceStyle:(NSString *)name;

- (NSAppearance *)windowAppearance;

- (NSString *)waveformStyle;
- (void)setWaveformStyle:(NSString *)name;

@end
