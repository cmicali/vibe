//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AppSettings.h"

#define SETTING_HAS_LAUNCHED                        @"Settings.hasLaunched"
#define SETTING_WINDOW_APPEARANCE_STYLE             @"Settings.windowAppearance"
#define SETTING_WAVEFORM_STYLE                      @"Settings.waveformStyle"
#define SETTING_AUDIO_PLAYER_DEVICE_NAME            @"AudioPlayer.deviceName"
#define SETTING_AUDIO_PLAYER_LOCK_SAMPLE_RATE       @"AudioPlayer.lockSampleRate"

@implementation AppSettings {
    BOOL _firstLaunch;
}

+ (AppSettings*)sharedInstance {
    static AppSettings *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AppSettings alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self registerDefaults];
    }
    return self;
}

- (void)registerDefaults {
    _firstLaunch = NO;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:SETTING_HAS_LAUNCHED]) {
        _firstLaunch = YES;
    }
    NSDictionary *appDefaults = @{
            SETTING_AUDIO_PLAYER_DEVICE_NAME:       @"",
            SETTING_AUDIO_PLAYER_LOCK_SAMPLE_RATE:  @(NO),
            SETTING_WINDOW_APPEARANCE_STYLE:        SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK,
            SETTING_WAVEFORM_STYLE:                 SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT
    };
    [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:SETTING_HAS_LAUNCHED];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSString *)audioOutputDeviceName {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_AUDIO_PLAYER_DEVICE_NAME];
}

-(void)setAudioOutputDeviceName:(NSString*)deviceName {
    [[NSUserDefaults standardUserDefaults] setObject:deviceName forKey:SETTING_AUDIO_PLAYER_DEVICE_NAME];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL) audioPlayerLockSampleRate {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_AUDIO_PLAYER_LOCK_SAMPLE_RATE];
}

-(void) setAudioPlayerLockSampleRate:(BOOL)lockSampleRate {
    [[NSUserDefaults standardUserDefaults] setBool:lockSampleRate forKey:SETTING_AUDIO_PLAYER_LOCK_SAMPLE_RATE];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)applicationDidFinishLaunching {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"NSQuitAlwaysKeepsWindows"];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSFullScreenMenuItemEverywhere"];
    [NSApplication sharedApplication].automaticCustomizeTouchBarMenuItemEnabled = NO;
}

- (BOOL)isFirstLaunch {
    return _firstLaunch;
}

- (NSString *)windowAppearanceStyle {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_WINDOW_APPEARANCE_STYLE];
}

- (void)setWindowAppearanceStyle:(NSString *)name {
    [[NSUserDefaults standardUserDefaults] setValue:name forKey:SETTING_WINDOW_APPEARANCE_STYLE];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSAppearance *)windowAppearance {
    return [self appearanceForSettingValue:self.windowAppearanceStyle];
}

- (NSAppearance *)appearanceForSettingValue:(NSString *)value {
    if ([value isEqualToString:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT]) {
        return [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    }
    else if ([value isEqualToString:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK]) {
        return [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    }
    return [NSAppearance currentAppearance];
}

- (NSString *)waveformStyle {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_WAVEFORM_STYLE];
}

- (void)setWaveformStyle:(NSString *)name {
    [[NSUserDefaults standardUserDefaults] setValue:name forKey:SETTING_WAVEFORM_STYLE];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
