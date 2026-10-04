//
//  AppSettingsInternal.h
//  Vibe
//
//  The seam between AppSettings.m and Mac/AppSettings+Mac.m. Only those files
//  and their tests import it.
//

#import "AppSettings.h"

NS_ASSUME_NONNULL_BEGIN

#define SETTING_WAVEFORM_STYLE                      @"Settings.waveformStyle"
#define SETTING_WIDGET_WAVEFORM_STYLE               @"Settings.widgetWaveformStyle"
#define SETTING_WAVEFORM_THEME                      @"Settings.waveformTheme"
#define SETTING_WAVEFORM_CUSTOM_PLAYED_DARK         @"Settings.waveformCustomPlayedColorDark"
#define SETTING_WAVEFORM_CUSTOM_UNPLAYED_DARK       @"Settings.waveformCustomUnplayedColorDark"
#define SETTING_WAVEFORM_CUSTOM_PLAYED_LIGHT        @"Settings.waveformCustomPlayedColorLight"
#define SETTING_WAVEFORM_CUSTOM_UNPLAYED_LIGHT      @"Settings.waveformCustomUnplayedColorLight"
#define SETTING_WAVEFORM_PLAYHEAD_LINE              @"Settings.waveformPlayheadLine"
#define SETTING_FOLDER_OPEN_SORT                    @"Files.folderOpenSort"
#define SETTING_CROSSFADE_MILLISECONDS              @"AudioPlayer.crossfadeMilliseconds"
#define SETTING_PAUSE_AT_TRACK_END                  @"Transport.pauseAtTrackEnd"
#define SETTING_REPEAT_MODE                         @"Transport.repeatMode"
#define SETTING_SHUFFLE_ENABLED                     @"Transport.shuffleEnabled"
#define SETTING_AUDIO_FX_ENABLED                    @"AudioPlayer.fxEnabled"
#define SETTING_ANALYZE_BPM                         @"Audio.analyzeBPM"
// The player display keys both platforms shipped under their own names.
#if TARGET_OS_OSX
#define SETTING_SHOW_REMAINING_TIME                 @"MainWindow.showRemainingTime"
#define SETTING_SHOW_FILE_INFO                      @"MainWindow.showFileInfo"
#define SETTING_SHOW_SHUFFLE_REPEAT                 @"MainWindow.showShuffleRepeat"
#else
#define SETTING_SHOW_REMAINING_TIME                 @"VibeiOSShowRemainingTime"
#define SETTING_SHOW_FILE_INFO                      @"VibeiOSShowFileInfo"
#define SETTING_SHOW_SHUFFLE_REPEAT                 @"VibeiOSShowShuffleRepeat"
#endif

#if TARGET_OS_OSX

@class AppTheme;

// The macOS half's ivars, which its category cannot declare.
@interface AppSettings () {
    NSArray<NSDictionary *> *_storedUserThemesCache;
    AppTheme   *_currentTheme;
    // Theme undo history, with the last changed keys for coalescing.
    NSMutableArray<NSDictionary *> *_themeHistory;
    NSUInteger _themeHistoryIndex;
    NSSet<NSString *> *_themeHistoryChangedKeys;
    NSTimeInterval _themeHistoryPushTime;
    BOOL _themeHistoryRestoring;
    // In memory only, so a preview left open at quit reverts.
    NSString   *_windowAppearancePreviewStyle;
}
@end

// The seam both ways: the macOS halves of the shared entry points, implemented
// in Mac/AppSettings+Mac.m, and what registerDefaults registers, in
// AppSettings.m. A named category, since an extension's methods must be in the
// primary @implementation.
@interface AppSettings (MacInternal)
- (void)migrateLooseAppearanceSettingsToTheme;
- (void)migrateThemeDisplaySettings;
- (void)registerMacDefaultsInto:(NSMutableDictionary *)defaults;
- (NSDictionary<NSString *, id> *)registeredSettingDefaults;
// The edit funnel with an explicit time, so tests exercise coalescing without
// sleeping.
- (void)currentThemeDidChangeContinuous:(BOOL)continuous atTime:(NSTimeInterval)time;
@end

#endif  // TARGET_OS_OSX

NS_ASSUME_NONNULL_END
