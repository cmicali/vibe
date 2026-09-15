//
//  AppSettingsInternal.h
//  Vibe
//
//  The private surface shared between AppSettings.m and Mac/AppSettings+Mac.m:
//  the stored keys both halves read, the ivars the macOS half keeps, and the
//  macOS halves of the shared store-wide entry points. Do not use it outside
//  the AppSettings implementation files and their tests; other callers use
//  AppSettings.h or AppSettings+Mac.h.
//

#import "AppSettings.h"

NS_ASSUME_NONNULL_BEGIN

#define SETTING_WAVEFORM_STYLE                      @"Settings.waveformStyle"
#define SETTING_WAVEFORM_THEME                      @"Settings.waveformTheme"
#define SETTING_WAVEFORM_CUSTOM_PLAYED_DARK         @"Settings.waveformCustomPlayedColorDark"
#define SETTING_WAVEFORM_CUSTOM_UNPLAYED_DARK       @"Settings.waveformCustomUnplayedColorDark"
#define SETTING_WAVEFORM_CUSTOM_PLAYED_LIGHT        @"Settings.waveformCustomPlayedColorLight"
#define SETTING_WAVEFORM_CUSTOM_UNPLAYED_LIGHT      @"Settings.waveformCustomUnplayedColorLight"
#define SETTING_WAVEFORM_NORMALIZE                  @"Appearance.waveformNormalize"
#define SETTING_WAVEFORM_GAIN_DB                    @"Appearance.waveformGainDB"
#define SETTING_FOLDER_OPEN_SORT                    @"Files.folderOpenSort"

#if TARGET_OS_OSX

@class AppTheme;

// A category cannot declare ivars, so the macOS half's state is declared here
// for AppSettings.m's @implementation to synthesize.
@interface AppSettings () {
    NSArray<NSDictionary *> *_storedUserThemesCache;
    AppTheme   *_currentTheme;
    // The theme editor's undo (AppSettings+Mac.h): the record each edit of a
    // user theme replaced, and what the last push moved, for coalescing.
    NSMutableArray<NSDictionary *> *_themeUndoStack;
    NSSet<NSString *> *_themeUndoChangedKeys;
    NSTimeInterval _themeUndoPushTime;
    BOOL _themeUndoRestoring;
    // The Settings window's temporary appearance preview: transient by
    // design, so a window left open on the Appearance page at quit reverts.
    NSString   *_windowAppearancePreviewStyle;
}
@end

// The macOS halves of the shared entry points — init, registerDefaults,
// nullableSettingKeys, resetToDefaults and applicationDidFinishLaunching —
// each called from AppSettings.m under TARGET_OS_OSX and implemented in
// Mac/AppSettings+Mac.m. A named category rather than the extension above:
// the compiler expects an extension's methods in the primary @implementation.
@interface AppSettings (MacInternal)
- (void)migrateLooseAppearanceSettingsToTheme;
- (void)registerMacDefaultsInto:(NSMutableDictionary *)defaults;
- (void)addMacNullableSettingKeysTo:(NSMutableArray<NSString *> *)keys;
- (void)resetMacThemeState;
- (void)macApplicationDidFinishLaunching;
// The production edit funnel with explicit time, so drag coalescing can be
// exercised without sleeping or replacing the defaults/theme machinery.
- (void)currentThemeDidChangeContinuous:(BOOL)continuous atTime:(NSTimeInterval)time;
@end

#endif  // TARGET_OS_OSX

NS_ASSUME_NONNULL_END
