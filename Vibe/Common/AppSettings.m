//
//  AppSettings.m
//  Vibe
//

#import "AppSettings.h"
#import "AppSettingsInternal.h"
#import "SettingsRules.h"
#import "WaveformRendererRegistry.h"
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

#if !TARGET_OS_OSX
// The widget's copy of a card key: Settings.waveformX is stored for the widget
// as Settings.widgetWaveformX, which is SETTING_WIDGET_WAVEFORM_CENTERED's
// spelling.
static NSString *WaveformKey(NSString *key, BOOL widget) {
    return widget ? [key stringByReplacingOccurrencesOfString:@"Settings.waveform"
                                                   withString:@"Settings.widgetWaveform"]
                  : key;
}
#endif

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
    // The widget's default is Wiggle, which reads at a strip's height.
    appDefaults[SETTING_WIDGET_WAVEFORM_STYLE] = SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE;
    for (int widget = 0; widget <= 1; widget++) {
        appDefaults[WaveformKey(SETTING_WAVEFORM_THEME, widget)] = SETTINGS_VALUE_WAVEFORM_THEME_MONO;
        appDefaults[WaveformKey(SETTING_WAVEFORM_BAND_THEME, widget)] = SETTINGS_VALUE_WAVEFORM_BAND_THEME_REKORD_BIN;
        appDefaults[WaveformKey(SETTING_WAVEFORM_SPECTRUM_PALETTE, widget)] = SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_RGB;
        appDefaults[WaveformKey(SETTING_WAVEFORM_SPECTRUM_COLORING, widget)] =
                SETTINGS_VALUE_WAVEFORM_SPECTRUM_COLORING_SECTIONS;
        appDefaults[WaveformKey(SETTING_WAVEFORM_CENTERED, widget)] = @(YES);
    }
#endif
    return appDefaults;
}

// A stored Wiggle MC can only mean it, so the value itself makes this run
// once. Each becomes Wiggle with its own Centered off, so the card's and the
// widget's other styles keep the look they had.
+ (void)migrateLegacyWiggleMCInDefaults:(NSUserDefaults *)defaults {
    NSDictionary<NSString *, NSString *> *centeredForStyle = @{
        SETTING_WAVEFORM_STYLE: SETTING_WAVEFORM_CENTERED,
        SETTING_WIDGET_WAVEFORM_STYLE: SETTING_WIDGET_WAVEFORM_CENTERED,
    };
    for (NSString *style in centeredForStyle) {
        if ([[defaults stringForKey:style] isEqualToString:SETTINGS_VALUE_WAVEFORM_STYLE_LEGACY_WIGGLE_MC]) {
            [defaults setObject:SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE forKey:style];
            [defaults setBool:NO forKey:centeredForStyle[style]];
        }
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
// Under Match app the widget draws the card's, so a widget read is a card
// read. A write never redirects: the widget's copy waits for its own style.
- (BOOL)readsWidgetCopy:(BOOL)widget {
    return widget && self.widgetWaveformStyle != nil;
}

- (NSString *)waveformThemeForWidget:(BOOL)widget {
    return VibeNormalizedWaveformTheme([[NSUserDefaults standardUserDefaults]
            stringForKey:WaveformKey(SETTING_WAVEFORM_THEME, [self readsWidgetCopy:widget])]);
}

- (void)setWaveformTheme:(NSString *)identifier forWidget:(BOOL)widget {
    [[NSUserDefaults standardUserDefaults] setObject:identifier
                                              forKey:WaveformKey(SETTING_WAVEFORM_THEME, widget)];
}

- (VibeColor *)waveformCustomPlayedColorForDark:(BOOL)isDark widget:(BOOL)widget {
    return VibeColorFromHexString([[NSUserDefaults standardUserDefaults] stringForKey:WaveformKey(
            isDark ? SETTING_WAVEFORM_CUSTOM_PLAYED_DARK : SETTING_WAVEFORM_CUSTOM_PLAYED_LIGHT,
            [self readsWidgetCopy:widget])]);
}

- (void)setWaveformCustomPlayedColor:(VibeColor *)color forDark:(BOOL)isDark widget:(BOOL)widget {
    [self setHexColor:color forKey:WaveformKey(
            isDark ? SETTING_WAVEFORM_CUSTOM_PLAYED_DARK : SETTING_WAVEFORM_CUSTOM_PLAYED_LIGHT, widget)];
}

- (VibeColor *)waveformCustomUnplayedColorForDark:(BOOL)isDark widget:(BOOL)widget {
    return VibeColorFromHexString([[NSUserDefaults standardUserDefaults] stringForKey:WaveformKey(
            isDark ? SETTING_WAVEFORM_CUSTOM_UNPLAYED_DARK : SETTING_WAVEFORM_CUSTOM_UNPLAYED_LIGHT,
            [self readsWidgetCopy:widget])]);
}

- (void)setWaveformCustomUnplayedColor:(VibeColor *)color forDark:(BOOL)isDark widget:(BOOL)widget {
    [self setHexColor:color forKey:WaveformKey(
            isDark ? SETTING_WAVEFORM_CUSTOM_UNPLAYED_DARK : SETTING_WAVEFORM_CUSTOM_UNPLAYED_LIGHT, widget)];
}

- (NSString *)waveformBandThemeForWidget:(BOOL)widget {
    return VibeNormalizedWaveformBandTheme([[NSUserDefaults standardUserDefaults]
            stringForKey:WaveformKey(SETTING_WAVEFORM_BAND_THEME, [self readsWidgetCopy:widget])]);
}

- (void)setWaveformBandTheme:(NSString *)identifier forWidget:(BOOL)widget {
    [[NSUserDefaults standardUserDefaults] setObject:identifier
                                              forKey:WaveformKey(SETTING_WAVEFORM_BAND_THEME, widget)];
}

- (NSString *)waveformSpectrumPaletteForWidget:(BOOL)widget {
    return VibeNormalizedWaveformSpectrumPalette([[NSUserDefaults standardUserDefaults]
            stringForKey:WaveformKey(SETTING_WAVEFORM_SPECTRUM_PALETTE, [self readsWidgetCopy:widget])]);
}

- (void)setWaveformSpectrumPalette:(NSString *)identifier forWidget:(BOOL)widget {
    [[NSUserDefaults standardUserDefaults] setObject:identifier
                                              forKey:WaveformKey(SETTING_WAVEFORM_SPECTRUM_PALETTE, widget)];
}

- (NSString *)waveformSpectrumColoringForWidget:(BOOL)widget {
    return VibeNormalizedWaveformSpectrumColoring([[NSUserDefaults standardUserDefaults]
            stringForKey:WaveformKey(SETTING_WAVEFORM_SPECTRUM_COLORING, [self readsWidgetCopy:widget])]);
}

- (void)setWaveformSpectrumColoring:(NSString *)identifier forWidget:(BOOL)widget {
    [[NSUserDefaults standardUserDefaults] setObject:identifier
                                              forKey:WaveformKey(SETTING_WAVEFORM_SPECTRUM_COLORING, widget)];
}

static NSString *WaveformCustomBandKey(NSUInteger band, BOOL isDark, BOOL widget) {
    static NSString *const keys[2][3] = {
        {SETTING_WAVEFORM_CUSTOM_LOW_LIGHT, SETTING_WAVEFORM_CUSTOM_MID_LIGHT, SETTING_WAVEFORM_CUSTOM_HIGH_LIGHT},
        {SETTING_WAVEFORM_CUSTOM_LOW_DARK, SETTING_WAVEFORM_CUSTOM_MID_DARK, SETTING_WAVEFORM_CUSTOM_HIGH_DARK},
    };
    NSCParameterAssert(band < 3);
    return WaveformKey(keys[isDark ? 1 : 0][band], widget);
}

- (VibeColor *)waveformCustomBandColor:(NSUInteger)band forDark:(BOOL)isDark widget:(BOOL)widget {
    return VibeColorFromHexString([[NSUserDefaults standardUserDefaults]
            stringForKey:WaveformCustomBandKey(band, isDark, [self readsWidgetCopy:widget])]);
}

- (void)setWaveformCustomBandColor:(VibeColor *)color band:(NSUInteger)band
                           forDark:(BOOL)isDark widget:(BOOL)widget {
    [self setHexColor:[color colorWithAlphaComponent:1] forKey:WaveformCustomBandKey(band, isDark, widget)];
}

- (NSNumber *)waveformPlayheadLineForWidget:(BOOL)widget {
    id stored = [[NSUserDefaults standardUserDefaults]
            objectForKey:WaveformKey(SETTING_WAVEFORM_PLAYHEAD_LINE, [self readsWidgetCopy:widget])];
    return [stored isKindOfClass:NSNumber.class] ? stored : nil;
}

- (void)setWaveformPlayheadLine:(BOOL)line forWidget:(BOOL)widget {
    [[NSUserDefaults standardUserDefaults] setBool:line
                                            forKey:WaveformKey(SETTING_WAVEFORM_PLAYHEAD_LINE, widget)];
}

- (BOOL)waveformCenteredForWidget:(BOOL)widget {
    return [[NSUserDefaults standardUserDefaults]
            boolForKey:WaveformKey(SETTING_WAVEFORM_CENTERED, [self readsWidgetCopy:widget])];
}

- (void)setWaveformCentered:(BOOL)centered forWidget:(BOOL)widget {
    [[NSUserDefaults standardUserDefaults] setBool:centered
                                            forKey:WaveformKey(SETTING_WAVEFORM_CENTERED, widget)];
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

- (BOOL)welcomeTrackSpent {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_WELCOME_TRACK_SPENT];
}

- (void)setWelcomeTrackSpent:(BOOL)spent {
    [[NSUserDefaults standardUserDefaults] setBool:spent forKey:SETTING_WELCOME_TRACK_SPENT];
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
