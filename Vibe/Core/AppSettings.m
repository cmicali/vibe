//
// Created by Christopher Micali on 12/30/19.
// Copyright (c) 2019 Christopher Micali. All rights reserved.
//

#import "AppSettings.h"
#import "SettingsRules.h"

#define SETTING_WINDOW_APPEARANCE_STYLE             @"Settings.windowAppearance"
#define SETTING_WAVEFORM_STYLE                      @"Settings.waveformStyle"
#define SETTING_AUDIO_PLAYER_DEVICE_NAME            @"AudioPlayer.deviceName"
#define SETTING_AUDIO_PLAYER_DEVICE_UID             @"AudioPlayer.deviceUID"
#define SETTING_PITCH_PANEL_SHOWN                   @"MainWindow.pitchPanelShown"
#define SETTING_PLAYLIST_SHOWN                      @"MainWindow.playlistShown"
#define SETTING_ALWAYS_ON_TOP                       @"MainWindow.alwaysOnTop"
#define SETTING_PITCH_RANGE                         @"AudioPlayer.pitchRange"
#define SETTING_SHOW_REMAINING_TIME                 @"MainWindow.showRemainingTime"
#define SETTING_SHOW_FILE_INFO                      @"MainWindow.showFileInfo"
#define SETTING_DELETE_ORIGINAL_AFTER_CONVERT       @"Convert.deleteOriginal"
#define SETTING_SKIP_BASE_BARS                      @"Transport.skipBaseBars"
#define SETTING_CROSSFADE_MILLISECONDS              @"AudioPlayer.crossfadeMilliseconds"
#define SETTING_UI_UPDATE_HZ_CAP                    @"UI.updateHzCap"
#define SETTING_ANALYZE_BPM                         @"Audio.analyzeBPM"
#define SETTING_ANALYZE_KEY                         @"Audio.analyzeKey"
#define SETTING_KEY_NOTATION                        @"Audio.keyNotation"
#define SETTING_KEY_COLORS                          @"Appearance.keyColors"
#define SETTING_CONVERT_ASKS_WHERE_TO_SAVE          @"Convert.asksWhereToSave"
// TRAP: the stored key is not the macro's name and must never follow a rename —
// it is a persisted NSUserDefaults key, so changing the string silently resets
// every existing user's setting to the default. It predates the folder-artwork
// → folder-art vocabulary and stays as written.
#define SETTING_FOLDER_ART                           @"Audio.folderArtwork"

@implementation AppSettings {
    // ---- The hot-path cache, which lives for ONE turn of the main run loop.
    //
    // Five settings are read far more often than the rest: the right time
    // label's mode on every playback tick, the file-info, key-notation and
    // key-color flags several times per updateUI pass, and the refresh cap on
    // every live-resize frame. Every other accessor here is a CFPreferences
    // lookup apiece, which is what FolderArtResolver caches its own setting to
    // avoid.
    //
    // TRAP: the obvious invalidation, NSUserDefaultsDidChangeNotification,
    // does NOT fire for a write from another process — and the debug channel's
    // prefs verbs (set_key_display, set_analysis, set_folder_art) are exactly
    // that, writing from the CLI client while the app runs, as is a plain
    // `defaults write`. Caching on that notification left the app reporting
    // the old value for good; observed, not hypothetical.
    //
    // So the lifetime is a run-loop turn instead: an observer drops the cache
    // before the loop sleeps, and the setters drop it immediately. Every read
    // inside one updateUI pass or one tick is then served from the cache — all
    // of the cost, since that is where the repetition is — while a value can
    // never be more than one turn stale, which is the same freshness an
    // uncached read gave. No writer has to remember anything, which is the
    // difference from the resolver's cache and its one call to forget.
    //
    // Main thread only, which every reader of these five is: the header
    // labels, the updateUI funnel, the Settings panes and the debug channel.
    // The analysis flags are deliberately NOT cached — the waveform loader
    // reads them off-main, and once per decode is not a hot path.
    BOOL        _hotCacheValid;
    BOOL        _hotShowRemainingTime;
    BOOL        _hotShowFileInfo;
    BOOL        _hotKeyColorsEnabled;
    NSInteger   _hotUIUpdateHzCap;
    NSString   *_hotKeyNotation;
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
        [self installHotCacheInvalidator];
    }
    return self;
}

#pragma mark - The hot-path cache

- (void)primeHotCache {
    NSAssert(NSThread.isMainThread, @"AppSettings' hot-path cache is main-thread only");
    if (_hotCacheValid) {
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _hotShowRemainingTime = [defaults boolForKey:SETTING_SHOW_REMAINING_TIME];
    _hotShowFileInfo = [defaults boolForKey:SETTING_SHOW_FILE_INFO];
    _hotKeyColorsEnabled = [defaults boolForKey:SETTING_KEY_COLORS];
    _hotUIUpdateHzCap = [self storedUIUpdateHzCap];
    _hotKeyNotation = [self storedKeyNotation];
    _hotCacheValid = YES;
}

- (void)invalidateHotCache {
    _hotCacheValid = NO;
}

// Drops the cache before the main run loop sleeps, and on the exit of any
// nested loop (menu tracking, a live resize), which is what bounds a cached
// value to the turn that read it. Common modes, so tracking loops are covered.
// The singleton lives for the process, so the observer is never removed.
- (void)installHotCacheInvalidator {
    if (!NSThread.isMainThread) {
        // The singleton can, in principle, be created by an off-main first
        // touch. The invalidator belongs to the main loop either way.
        run_on_main_thread({ [self installHotCacheInvalidator]; });
        return;
    }
    __weak AppSettings *weakSelf = self;
    CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, YES, 0,
            ^(CFRunLoopObserverRef o, CFRunLoopActivity activity) {
                [weakSelf invalidateHotCache];
            });
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    CFRelease(observer);
}

- (void)registerDefaults {
    NSDictionary *appDefaults = @{
            SETTING_AUDIO_PLAYER_DEVICE_NAME:       @"",
            SETTING_AUDIO_PLAYER_DEVICE_UID:        @"",
            SETTING_WINDOW_APPEARANCE_STYLE:        SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK,
            SETTING_WAVEFORM_STYLE:                 SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT,
            SETTING_PITCH_PANEL_SHOWN:              @(NO),
            SETTING_PLAYLIST_SHOWN:                 @(NO),
            SETTING_ALWAYS_ON_TOP:                  @(NO),
            SETTING_PITCH_RANGE:                    @(8),
            SETTING_SHOW_REMAINING_TIME:            @(NO),
            SETTING_SHOW_FILE_INFO:                 @(YES),
            SETTING_DELETE_ORIGINAL_AFTER_CONVERT:  @(NO),
            SETTING_SKIP_BASE_BARS:                 @(8),
            SETTING_CROSSFADE_MILLISECONDS:         @(10),
            SETTING_UI_UPDATE_HZ_CAP:               @(30),
            SETTING_ANALYZE_BPM:                    @(YES),
            SETTING_ANALYZE_KEY:                    @(NO),
            SETTING_KEY_NOTATION:                   SETTINGS_VALUE_KEY_NOTATION_CAMELOT,
            SETTING_KEY_COLORS:                     @(NO),
            SETTING_CONVERT_ASKS_WHERE_TO_SAVE:     @(NO),
            SETTING_FOLDER_ART:                 @(YES),
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

- (BOOL)alwaysOnTop {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_ALWAYS_ON_TOP];
}

- (void)setAlwaysOnTop:(BOOL)onTop {
    [[NSUserDefaults standardUserDefaults] setBool:onTop forKey:SETTING_ALWAYS_ON_TOP];
}

// Cached; see primeHotCache. Read on every playback tick.
- (BOOL)showRemainingTime {
    [self primeHotCache];
    return _hotShowRemainingTime;
}

- (void)setShowRemainingTime:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_REMAINING_TIME];
    [self invalidateHotCache];
}

// Cached; read twice per updateUI pass, by the codec and BPM lines.
- (BOOL)showFileInfo {
    [self primeHotCache];
    return _hotShowFileInfo;
}

- (void)setShowFileInfo:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_FILE_INFO];
    [self invalidateHotCache];
}

- (NSInteger)pitchRange {
    return VibeNormalizedPitchRange(
            [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_PITCH_RANGE]);
}

- (void)setPitchRange:(NSInteger)range {
    [[NSUserDefaults standardUserDefaults] setInteger:VibeNormalizedPitchRange(range)
                                              forKey:SETTING_PITCH_RANGE];
}

- (BOOL)deleteOriginalAfterConvert {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_DELETE_ORIGINAL_AFTER_CONVERT];
}

- (void)setDeleteOriginalAfterConvert:(BOOL)deleteOriginal {
    [[NSUserDefaults standardUserDefaults] setBool:deleteOriginal forKey:SETTING_DELETE_ORIGINAL_AFTER_CONVERT];
}

// See the preset declarations in the header: an out-of-list persisted value
// reads as the nearest preset, so display and behavior cannot disagree.
static NSInteger VibeNearestPreset(NSInteger value, const NSInteger *presets, size_t count) {
    NSInteger best = presets[0];
    for (size_t i = 1; i < count; i++) {
        if (llabs((long long)(value - presets[i])) < llabs((long long)(value - best))) {
            best = presets[i];
        }
    }
    return best;
}

- (NSInteger)skipBaseBars {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_SKIP_BASE_BARS];
    return VibeNearestPreset(stored, kVibeSkipBasePresets,
                             sizeof(kVibeSkipBasePresets) / sizeof(kVibeSkipBasePresets[0]));
}

- (void)setSkipBaseBars:(NSInteger)bars {
    [[NSUserDefaults standardUserDefaults] setInteger:bars forKey:SETTING_SKIP_BASE_BARS];
}

- (NSInteger)crossfadeMilliseconds {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_CROSSFADE_MILLISECONDS];
    return VibeNearestPreset(stored, kVibeCrossfadePresets,
                             sizeof(kVibeCrossfadePresets) / sizeof(kVibeCrossfadePresets[0]));
}

- (void)setCrossfadeMilliseconds:(NSInteger)milliseconds {
    [[NSUserDefaults standardUserDefaults] setInteger:milliseconds forKey:SETTING_CROSSFADE_MILLISECONDS];
}

- (NSInteger)storedUIUpdateHzCap {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_UI_UPDATE_HZ_CAP];
    return VibeNearestPreset(stored, kVibeUIUpdateHzCapPresets,
                             sizeof(kVibeUIUpdateHzCapPresets) / sizeof(kVibeUIUpdateHzCapPresets[0]));
}

// Cached; read on every live-resize frame through syncUITimerRate.
- (NSInteger)uiUpdateHzCap {
    [self primeHotCache];
    return _hotUIUpdateHzCap;
}

- (void)setUiUpdateHzCap:(NSInteger)hz {
    [[NSUserDefaults standardUserDefaults] setInteger:hz forKey:SETTING_UI_UPDATE_HZ_CAP];
    [self invalidateHotCache];
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

- (NSString *)storedKeyNotation {
    NSString *notation = [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_KEY_NOTATION];
    // An unrecognized persisted value renders as Camelot rather than nothing.
    if (![notation isEqualToString:SETTINGS_VALUE_KEY_NOTATION_MUSICAL]) {
        return SETTINGS_VALUE_KEY_NOTATION_CAMELOT;
    }
    return notation;
}

// Cached; read on every updateUI pass and every fader tick, through
// effectiveTempoDidChange.
- (NSString *)keyNotation {
    [self primeHotCache];
    return _hotKeyNotation;
}

- (void)setKeyNotation:(NSString *)notation {
    [[NSUserDefaults standardUserDefaults] setObject:notation forKey:SETTING_KEY_NOTATION];
    [self invalidateHotCache];
}

// Cached; read alongside keyNotation on the same pass.
- (BOOL)keyColorsEnabled {
    [self primeHotCache];
    return _hotKeyColorsEnabled;
}

- (void)setKeyColorsEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:SETTING_KEY_COLORS];
    [self invalidateHotCache];
}

- (BOOL)convertAsksWhereToSave {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_CONVERT_ASKS_WHERE_TO_SAVE];
}

- (void)setConvertAsksWhereToSave:(BOOL)ask {
    [[NSUserDefaults standardUserDefaults] setBool:ask forKey:SETTING_CONVERT_ASKS_WHERE_TO_SAVE];
}

- (BOOL)useFolderArt {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_FOLDER_ART];
}

- (void)setUseFolderArt:(BOOL)use {
    [[NSUserDefaults standardUserDefaults] setBool:use forKey:SETTING_FOLDER_ART];
}

@end
