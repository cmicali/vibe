//
//  AppSettings.m
//  Vibe
//

#import "AppSettings.h"
#import "AppSettingsInternal.h"
#import "SettingsRules.h"
#import "PlatformColor.h"


#if !TARGET_OS_OSX
NSNotificationName const VibeDisplaySettingsDidChangeNotification =
        @"VibeDisplaySettingsDidChange";

void VibeNotifyDisplaySettingsChanged(void) {
    [NSNotificationCenter.defaultCenter
            postNotificationName:VibeDisplaySettingsDidChangeNotification object:nil];
}
#endif

@implementation AppSettings

#pragma mark - Both platforms

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
#if TARGET_OS_OSX
        // Before registerDefaults: the migration keys on "no stored value", and
        // objectForKey: consults the registration domain, so a registered
        // default would read as stored.
        [self migrateLooseAppearanceSettingsToTheme];
        [self migrateThemeRecordsToVersion2];
        [self migrateThemeDisplaySettings];
#else
        [AppSettings migrateLegacyWiggleMCInDefaults:NSUserDefaults.standardUserDefaults];
#endif
        [self registerDefaults];
    }
    return self;
}

- (NSDictionary<NSString *, id> *)registeredSettingDefaults {
    NSMutableDictionary *appDefaults = [@{
            SETTING_FOLDER_OPEN_SORT: SETTINGS_VALUE_FOLDER_OPEN_SORT_NAME,
            SETTING_CROSSFADE_MILLISECONDS: @(kVibeCrossfadeOffMilliseconds),
            SETTING_PAUSE_AT_TRACK_END: @(NO),
            SETTING_REPEAT_MODE: SETTINGS_VALUE_REPEAT_MODE_OFF,
            SETTING_SHUFFLE_ENABLED: @(NO),
            SETTING_AUDIO_FX_ENABLED: @(YES),
            SETTING_ANALYZE_BPM: @(YES),
            SETTING_SHOW_REMAINING_TIME: @(NO),
            SETTING_SHOW_FILE_INFO: @(YES),
            SETTING_SHOW_SHUFFLE_REPEAT: @(YES),
    } mutableCopy];
#if TARGET_OS_OSX
    [self registerMacDefaultsInto:appDefaults];
#else
    appDefaults[SETTING_WAVEFORM_STYLE] = SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT;
    appDefaults[SETTING_WAVEFORM_THEME] = SETTINGS_VALUE_WAVEFORM_THEME_MONO;
    appDefaults[SETTING_WIDGET_WAVEFORM_STYLE] = SETTINGS_VALUE_WIDGET_WAVEFORM_STYLE_DEFAULT;
    appDefaults[SETTING_WAVEFORM_CENTERED] = @(YES);
#endif
    return appDefaults;
}

// A stored Wiggle MC can only mean it, so the value itself makes this run
// once. The card's becomes Wiggle with Centered off; the widget's becomes
// Wiggle and follows the one Centered, which only the card's may turn off.
+ (void)migrateLegacyWiggleMCInDefaults:(NSUserDefaults *)defaults {
    if ([[defaults stringForKey:SETTING_WAVEFORM_STYLE] isEqualToString:SETTINGS_VALUE_WAVEFORM_STYLE_LEGACY_WIGGLE_MC]) {
        [defaults setObject:SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE forKey:SETTING_WAVEFORM_STYLE];
        [defaults setBool:NO forKey:SETTING_WAVEFORM_CENTERED];
    }
    if ([[defaults stringForKey:SETTING_WIDGET_WAVEFORM_STYLE]
            isEqualToString:SETTINGS_VALUE_WAVEFORM_STYLE_LEGACY_WIGGLE_MC]) {
        [defaults setObject:SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE forKey:SETTING_WIDGET_WAVEFORM_STYLE];
    }
}

- (void)registerDefaults {
    [[NSUserDefaults standardUserDefaults] registerDefaults:[self registeredSettingDefaults]];
}

#if !TARGET_OS_OSX
- (NSString *)waveformStyle {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_WAVEFORM_STYLE];
}

- (void)setWaveformStyle:(NSString *)identifier {
    [[NSUserDefaults standardUserDefaults] setObject:identifier forKey:SETTING_WAVEFORM_STYLE];
}

// Match app is the stored empty string: removing the key would read back the
// registered Wiggle.
- (NSString *)widgetWaveformStyle {
    NSString *identifier = [[NSUserDefaults standardUserDefaults]
            stringForKey:SETTING_WIDGET_WAVEFORM_STYLE];
    return identifier.length ? identifier : nil;
}

- (void)setWidgetWaveformStyle:(NSString *)identifier {
    [[NSUserDefaults standardUserDefaults] setObject:identifier ?: @""
                                              forKey:SETTING_WIDGET_WAVEFORM_STYLE];
}
#endif

#if !TARGET_OS_OSX
- (NSString *)waveformTheme {
    return VibeNormalizedWaveformTheme([[NSUserDefaults standardUserDefaults] stringForKey:SETTING_WAVEFORM_THEME]);
}

- (void)setWaveformTheme:(NSString *)identifier {
    [[NSUserDefaults standardUserDefaults] setObject:identifier forKey:SETTING_WAVEFORM_THEME];
}

- (VibeColor *)waveformCustomPlayedColorForDark:(BOOL)isDark {
    return VibeColorFromHexString([[NSUserDefaults standardUserDefaults] stringForKey:
            isDark ? SETTING_WAVEFORM_CUSTOM_PLAYED_DARK : SETTING_WAVEFORM_CUSTOM_PLAYED_LIGHT]);
}

- (void)setWaveformCustomPlayedColor:(VibeColor *)color forDark:(BOOL)isDark {
    [self setHexColor:color forKey:
            isDark ? SETTING_WAVEFORM_CUSTOM_PLAYED_DARK : SETTING_WAVEFORM_CUSTOM_PLAYED_LIGHT];
}

- (VibeColor *)waveformCustomUnplayedColorForDark:(BOOL)isDark {
    return VibeColorFromHexString([[NSUserDefaults standardUserDefaults] stringForKey:
            isDark ? SETTING_WAVEFORM_CUSTOM_UNPLAYED_DARK : SETTING_WAVEFORM_CUSTOM_UNPLAYED_LIGHT]);
}

- (void)setWaveformCustomUnplayedColor:(VibeColor *)color forDark:(BOOL)isDark {
    [self setHexColor:color forKey:
            isDark ? SETTING_WAVEFORM_CUSTOM_UNPLAYED_DARK : SETTING_WAVEFORM_CUSTOM_UNPLAYED_LIGHT];
}

- (NSNumber *)waveformPlayheadLine {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:SETTING_WAVEFORM_PLAYHEAD_LINE];
    return [stored isKindOfClass:NSNumber.class] ? stored : nil;
}

- (void)setWaveformPlayheadLine:(BOOL)line {
    [[NSUserDefaults standardUserDefaults] setBool:line forKey:SETTING_WAVEFORM_PLAYHEAD_LINE];
}

- (BOOL)waveformCentered {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_WAVEFORM_CENTERED];
}

- (void)setWaveformCentered:(BOOL)centered {
    [[NSUserDefaults standardUserDefaults] setBool:centered forKey:SETTING_WAVEFORM_CENTERED];
}
#endif  // !TARGET_OS_OSX


- (VibeFolderOpenSort)folderOpenSort {
    return VibeNormalizedFolderOpenSort(
            [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_FOLDER_OPEN_SORT]);
}

- (void)setFolderOpenSort:(VibeFolderOpenSort)sort {
    [[NSUserDefaults standardUserDefaults] setObject:VibeFolderOpenSortIdentifier(sort)
                                              forKey:SETTING_FOLDER_OPEN_SORT];
}

- (NSInteger)crossfadeMilliseconds {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_CROSSFADE_MILLISECONDS];
    return VibeNormalizedCrossfadeMilliseconds(stored);
}

- (void)setCrossfadeMilliseconds:(NSInteger)milliseconds {
    [[NSUserDefaults standardUserDefaults] setInteger:milliseconds forKey:SETTING_CROSSFADE_MILLISECONDS];
}

- (BOOL)pauseAtTrackEnd {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_PAUSE_AT_TRACK_END];
}

- (void)setPauseAtTrackEnd:(BOOL)pause {
    [[NSUserDefaults standardUserDefaults] setBool:pause forKey:SETTING_PAUSE_AT_TRACK_END];
}

- (VibeRepeatMode)repeatMode {
    return VibeNormalizedRepeatMode([[NSUserDefaults standardUserDefaults] stringForKey:SETTING_REPEAT_MODE]);
}

- (void)setRepeatMode:(VibeRepeatMode)mode {
    [[NSUserDefaults standardUserDefaults] setObject:VibeRepeatModeIdentifier(mode) forKey:SETTING_REPEAT_MODE];
}

- (BOOL)shuffleEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHUFFLE_ENABLED];
}

- (void)setShuffleEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:SETTING_SHUFFLE_ENABLED];
}

- (BOOL)audioFXEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_AUDIO_FX_ENABLED];
}

- (void)setAudioFXEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:SETTING_AUDIO_FX_ENABLED];
}

- (BOOL)analyzeBPM {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_ANALYZE_BPM];
}

- (void)setAnalyzeBPM:(BOOL)analyze {
    [[NSUserDefaults standardUserDefaults] setBool:analyze forKey:SETTING_ANALYZE_BPM];
}

- (BOOL)showRemainingTime {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHOW_REMAINING_TIME];
}

- (void)setShowRemainingTime:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_REMAINING_TIME];
}

- (BOOL)showFileInfo {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHOW_FILE_INFO];
}

- (void)setShowFileInfo:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_FILE_INFO];
}

- (BOOL)showShuffleRepeat {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHOW_SHUFFLE_REPEAT];
}

- (void)setShowShuffleRepeat:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_SHUFFLE_REPEAT];
}

#if !TARGET_OS_OSX
- (void)setHexColor:(VibeColor *)color forKey:(NSString *)key {
    NSString *hex = VibeHexStringFromColor(color);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (hex) {
        [defaults setObject:hex forKey:key];
    } else {
        [defaults removeObjectForKey:key];
    }
}
#endif

@end
