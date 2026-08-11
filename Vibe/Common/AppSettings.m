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
#define SETTING_SKIP_BASE_BARS                      @"Transport.skipBaseBars"
#define SETTING_CROSSFADE_MILLISECONDS              @"AudioPlayer.crossfadeMilliseconds"
#define SETTING_ANALYZE_BPM                         @"Audio.analyzeBPM"
#define SETTING_ANALYZE_KEY                         @"Audio.analyzeKey"
#define SETTING_KEY_NOTATION                        @"Audio.keyNotation"
#define SETTING_KEY_COLORS                          @"Appearance.keyColors"
#define SETTING_CONVERT_ASKS_WHERE_TO_SAVE          @"Convert.asksWhereToSave"

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
            SETTING_SKIP_BASE_BARS:                 @(8),
            SETTING_CROSSFADE_MILLISECONDS:         @(10),
            SETTING_ANALYZE_BPM:                    @(YES),
            SETTING_ANALYZE_KEY:                    @(NO),
            SETTING_KEY_NOTATION:                   SETTINGS_VALUE_KEY_NOTATION_CAMELOT,
            SETTING_KEY_COLORS:                     @(NO),
            SETTING_CONVERT_ASKS_WHERE_TO_SAVE:     @(NO),
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
#if TARGET_OS_OSX
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"NSQuitAlwaysKeepsWindows"];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSFullScreenMenuItemEverywhere"];
    [NSApplication sharedApplication].automaticCustomizeTouchBarMenuItemEnabled = NO;
#endif
}

- (NSString *)windowAppearanceStyle {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_WINDOW_APPEARANCE_STYLE];
}

- (void)setWindowAppearanceStyle:(NSString *)name {
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:SETTING_WINDOW_APPEARANCE_STYLE];
}

#if TARGET_OS_OSX
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
#endif

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

- (NSInteger)skipBaseBars {
    return [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_SKIP_BASE_BARS];
}

- (void)setSkipBaseBars:(NSInteger)bars {
    [[NSUserDefaults standardUserDefaults] setInteger:bars forKey:SETTING_SKIP_BASE_BARS];
}

- (NSInteger)crossfadeMilliseconds {
    return [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_CROSSFADE_MILLISECONDS];
}

- (void)setCrossfadeMilliseconds:(NSInteger)milliseconds {
    [[NSUserDefaults standardUserDefaults] setInteger:milliseconds forKey:SETTING_CROSSFADE_MILLISECONDS];
}

- (BOOL)analyzeBPM {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_ANALYZE_BPM];
}

- (void)setAnalyzeBPM:(BOOL)analyze {
    [[NSUserDefaults standardUserDefaults] setBool:analyze forKey:SETTING_ANALYZE_BPM];
}

- (BOOL)analyzeKey {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_ANALYZE_KEY];
}

- (void)setAnalyzeKey:(BOOL)analyze {
    [[NSUserDefaults standardUserDefaults] setBool:analyze forKey:SETTING_ANALYZE_KEY];
}

- (NSString *)keyNotation {
    NSString *notation = [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_KEY_NOTATION];
    // An unrecognized persisted value renders as Camelot rather than nothing.
    if (![notation isEqualToString:SETTINGS_VALUE_KEY_NOTATION_MUSICAL]) {
        return SETTINGS_VALUE_KEY_NOTATION_CAMELOT;
    }
    return notation;
}

- (void)setKeyNotation:(NSString *)notation {
    [[NSUserDefaults standardUserDefaults] setObject:notation forKey:SETTING_KEY_NOTATION];
}

- (BOOL)keyColorsEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_KEY_COLORS];
}

- (void)setKeyColorsEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:SETTING_KEY_COLORS];
}

- (BOOL)convertAsksWhereToSave {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_CONVERT_ASKS_WHERE_TO_SAVE];
}

- (void)setConvertAsksWhereToSave:(BOOL)ask {
    [[NSUserDefaults standardUserDefaults] setBool:ask forKey:SETTING_CONVERT_ASKS_WHERE_TO_SAVE];
}

@end
