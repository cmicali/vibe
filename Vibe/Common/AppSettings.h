//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import <Foundation/Foundation.h>

#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT     @""
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT       @"light"
#define SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK        @"dark"

@interface AppSettings : NSObject

+ (AppSettings*)sharedInstance;

- (BOOL)audioPlayerLockSampleRate;

- (void)setAudioPlayerLockSampleRate:(BOOL)lockSampleRate;

- (void)applicationDidFinishLaunching;

- (BOOL)isFirstLaunch;

- (NSInteger)audioPlayerCurrentDevice;
- (void)setAudioPlayerCurrentDevice:(NSInteger)deviceIndex;

- (NSString *)windowAppearanceStyle;
- (void)setWindowAppearanceStyle:(NSString *)name;

- (NSAppearance *)windowAppearance;
- (NSAppearance *)appearanceForSettingValue:(NSString *)value;

@end
