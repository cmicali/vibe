//
//  AppSettings.m
//  Vibe
//

#import "AppSettings.h"
#import "AppSettingsInternal.h"
#import "SettingsRules.h"
#import "PlatformColor.h"

const NSInteger kVibeCrossfadePresets[] = {10, 500, 2000};
const size_t kVibeCrossfadePresetCount =
        sizeof(kVibeCrossfadePresets) / sizeof(kVibeCrossfadePresets[0]);

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
        // Migrations run before registerDefaults: the theme migration keys on
        // "no stored value", and objectForKey: consults the registration
        // domain, so a registered default would read as stored.
        [self migrateLegacyWaveformStyle];
#if TARGET_OS_OSX
        [self migrateLooseAppearanceSettingsToTheme];
#endif
        [self registerDefaults];
    }
    return self;
}

- (NSDictionary<NSString *, id> *)registeredSettingDefaults {
    NSMutableDictionary *appDefaults = [@{
            SETTING_WAVEFORM_STYLE: SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT,
            SETTING_WAVEFORM_THEME: SETTINGS_VALUE_WAVEFORM_THEME_MONO,
            SETTING_FOLDER_OPEN_SORT: SETTINGS_VALUE_FOLDER_OPEN_SORT_NAME,
            SETTING_CROSSFADE_MILLISECONDS: @(10),
            SETTING_PAUSE_AT_TRACK_END: @(NO),
            SETTING_AUDIO_FX_ENABLED: @(YES),
            SETTING_ANALYZE_BPM: @(YES),
    } mutableCopy];
#if TARGET_OS_OSX
    [self registerMacDefaultsInto:appDefaults];
#else
    appDefaults[SETTING_WIDGET_WAVEFORM_STYLE] = SETTINGS_VALUE_WIDGET_WAVEFORM_STYLE_DEFAULT;
#endif
    return appDefaults;
}

- (void)registerDefaults {
    [[NSUserDefaults standardUserDefaults] registerDefaults:[self registeredSettingDefaults]];
}

// Keys with no registered default, where absent IS the default: the nullable
// custom colors.
- (NSArray<NSString *> *)nullableSettingKeys {
    NSMutableArray<NSString *> *keys = [@[
            SETTING_WAVEFORM_CUSTOM_PLAYED_DARK,
            SETTING_WAVEFORM_CUSTOM_UNPLAYED_DARK,
            SETTING_WAVEFORM_CUSTOM_PLAYED_LIGHT,
            SETTING_WAVEFORM_CUSTOM_UNPLAYED_LIGHT,
    ] mutableCopy];
#if TARGET_OS_OSX
    [self addMacNullableSettingKeysTo:keys];
#endif
    return keys;
}

// The persistent domain, not dictionaryRepresentation, which folds the
// registration domain back in and would make every default read as stored.
- (BOOL)allSettingsAtDefaults {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults]
            persistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    return VibeSettingsAreAtDefaults(stored, [self registeredSettingDefaults],
                                     [self nullableSettingKeys]);
}

- (void)resetToDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in [self registeredSettingDefaults]) {
        [defaults removeObjectForKey:key];
    }
    for (NSString *key in [self nullableSettingKeys]) {
        [defaults removeObjectForKey:key];
    }
#if TARGET_OS_OSX
    [self resetMacThemeState];
#endif
}

- (void)applicationDidFinishLaunching {
#if TARGET_OS_OSX
    [self macApplicationDidFinishLaunching];
#endif
}

// Old builds stored the renderer's English display name. Frozen: every value
// ever written.
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

- (void)migrateLegacyWaveformStyle {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *stored = [defaults stringForKey:SETTING_WAVEFORM_STYLE];
    NSString *normalized = NormalizedWaveformStyle(stored);
    if (stored && ![normalized isEqualToString:stored]) {
        [defaults setObject:normalized forKey:SETTING_WAVEFORM_STYLE];
    }
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
    return VibeNearestPreset(stored, kVibeCrossfadePresets, kVibeCrossfadePresetCount);
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
