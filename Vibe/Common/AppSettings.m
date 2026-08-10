//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AppSettings.h"

#define SETTING_WINDOW_APPEARANCE_STYLE             @"Settings.windowAppearance"
#define SETTING_WAVEFORM_STYLE                      @"Settings.waveformStyle"
#define SETTING_AUDIO_PLAYER_DEVICE_NAME            @"AudioPlayer.deviceName"
#define SETTING_AUDIO_PLAYER_DEVICE_UID             @"AudioPlayer.deviceUID"
#define SETTING_PITCH_PANEL_SHOWN                   @"MainWindow.pitchPanelShown"
#define SETTING_PLAYLIST_SHOWN                      @"MainWindow.playlistShown"
#define SETTING_PITCH_RANGE                         @"AudioPlayer.pitchRange"
#define SETTING_SHOW_REMAINING_TIME                 @"MainWindow.showRemainingTime"
#define SETTING_DELETE_ORIGINAL_AFTER_CONVERT       @"Convert.deleteOriginal"

@implementation AppSettings

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
    NSDictionary *appDefaults = @{
            SETTING_AUDIO_PLAYER_DEVICE_NAME:       @"",
            SETTING_AUDIO_PLAYER_DEVICE_UID:        @"",
            SETTING_WINDOW_APPEARANCE_STYLE:        SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK,
            SETTING_WAVEFORM_STYLE:                 SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT,
            SETTING_PITCH_PANEL_SHOWN:              @(NO),
            SETTING_PLAYLIST_SHOWN:                 @(NO),
            SETTING_PITCH_RANGE:                    @(8),
            SETTING_SHOW_REMAINING_TIME:            @(NO),
            SETTING_DELETE_ORIGINAL_AFTER_CONVERT:  @(NO),
    };
    [[NSUserDefaults standardUserDefaults] registerDefaults:appDefaults];
}

- (NSString *)audioOutputDeviceName {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_AUDIO_PLAYER_DEVICE_NAME];
}

-(void)setAudioOutputDeviceName:(NSString*)deviceName {
    [[NSUserDefaults standardUserDefaults] setObject:deviceName forKey:SETTING_AUDIO_PLAYER_DEVICE_NAME];
}

- (NSString *)audioOutputDeviceUID {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_AUDIO_PLAYER_DEVICE_UID];
}

- (void)setAudioOutputDeviceUID:(NSString *)deviceUID {
    [[NSUserDefaults standardUserDefaults] setObject:deviceUID forKey:SETTING_AUDIO_PLAYER_DEVICE_UID];
}

- (void)applicationDidFinishLaunching {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"NSQuitAlwaysKeepsWindows"];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSFullScreenMenuItemEverywhere"];
    [NSApplication sharedApplication].automaticCustomizeTouchBarMenuItemEnabled = NO;
}

- (NSString *)windowAppearanceStyle {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_WINDOW_APPEARANCE_STYLE];
}

- (void)setWindowAppearanceStyle:(NSString *)name {
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:SETTING_WINDOW_APPEARANCE_STYLE];
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
    // System default: a nil window appearance tracks the OS light/dark setting.
    return nil;
}

// Versions before the styleIdentifier/displayName split stored the renderer's
// English display name in this setting. Frozen list of every value ever written.
static NSString *NormalizedWaveformStyle(NSString *stored) {
    static NSDictionary<NSString *, NSString *> *legacy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        legacy = @{
            @"Basic":                    @"basic",
            @"Detailed":                 @"detailed",
            @"Sonic Cirrus":             @"sonic_cirrus",
            @"Oversampling Detailed x2": @"oversampling_detailed_x2",
            @"Oversampling Detailed x4": @"oversampling_detailed_x4",
            @"Oversampling Detailed x8": @"oversampling_detailed_x8",
        };
    });
    return stored ? (legacy[stored] ?: stored) : nil;
}

- (NSString *)waveformStyle {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *stored = [defaults stringForKey:SETTING_WAVEFORM_STYLE];
    NSString *normalized = NormalizedWaveformStyle(stored);
    // Migrate a legacy value in place on first read.
    if (stored && ![normalized isEqualToString:stored]) {
        [defaults setObject:normalized forKey:SETTING_WAVEFORM_STYLE];
    }
    return normalized;
}

- (void)setWaveformStyle:(NSString *)identifier {
    [[NSUserDefaults standardUserDefaults] setObject:identifier forKey:SETTING_WAVEFORM_STYLE];
}

- (BOOL)isPitchPanelShown {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_PITCH_PANEL_SHOWN];
}

- (void)setPitchPanelShown:(BOOL)shown {
    [[NSUserDefaults standardUserDefaults] setBool:shown forKey:SETTING_PITCH_PANEL_SHOWN];
}

- (BOOL)isPlaylistShown {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_PLAYLIST_SHOWN];
}

- (void)setPlaylistShown:(BOOL)shown {
    [[NSUserDefaults standardUserDefaults] setBool:shown forKey:SETTING_PLAYLIST_SHOWN];
}

- (BOOL)showRemainingTime {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHOW_REMAINING_TIME];
}

- (void)setShowRemainingTime:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_REMAINING_TIME];
}

- (NSInteger)pitchRange {
    return [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_PITCH_RANGE];
}

- (void)setPitchRange:(NSInteger)range {
    [[NSUserDefaults standardUserDefaults] setInteger:range forKey:SETTING_PITCH_RANGE];
}

- (BOOL)deleteOriginalAfterConvert {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_DELETE_ORIGINAL_AFTER_CONVERT];
}

- (void)setDeleteOriginalAfterConvert:(BOOL)deleteOriginal {
    [[NSUserDefaults standardUserDefaults] setBool:deleteOriginal forKey:SETTING_DELETE_ORIGINAL_AFTER_CONVERT];
}

@end
