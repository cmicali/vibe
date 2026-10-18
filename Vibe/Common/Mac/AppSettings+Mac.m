//
//  AppSettings+Mac.m
//  Vibe
//

#import "AppSettings+Mac.h"
#import "AppSettingsInternal.h"
#import "SettingsRules.h"
#import "VibeStrings.h"
#import <AppKit/AppKit.h>

#define SETTING_WINDOW_APPEARANCE_STYLE             @"Settings.windowAppearance"
#define SETTING_AUDIO_PLAYER_DEVICE_NAME            @"AudioPlayer.deviceName"
#define SETTING_AUDIO_PLAYER_DEVICE_UID             @"AudioPlayer.deviceUID"
#define SETTING_AUDIO_PLAYER_DEVICE_MODEL_UID       @"AudioPlayer.deviceModelUID"
#define SETTING_PITCH_PANEL_SHOWN                   @"MainWindow.pitchPanelShown"
#define SETTING_PLAYLIST_SHOWN                      @"MainWindow.playlistShown"
#define SETTING_ALWAYS_ON_TOP                       @"MainWindow.alwaysOnTop"
#define SETTING_WINDOW_POSITION_LOCKED              @"MainWindow.positionLocked"
#define SETTING_SHOW_TRAFFIC_LIGHTS                 @"Appearance.showTrafficLights"
#define SETTING_PITCH_RANGE                         @"AudioPlayer.pitchRange"
#define SETTING_WAVEFORM_NORMALIZE                  @"Appearance.waveformNormalize"
#define SETTING_WAVEFORM_GAIN_DB                    @"Appearance.waveformGainDB"
#define SETTING_WAVEFORM_DRAG_BEHAVIOR              @"Settings.waveformDragBehavior"
#define SETTING_ARTWORK_DRAG_ACTION                 @"Settings.artworkDragAction"
#define SETTING_DELETE_ORIGINAL_AFTER_CONVERT       @"Convert.deleteOriginal"
#define SETTING_SKIP_BASE_BARS                      @"Transport.skipBaseBars"
#define SETTING_REOPEN_LAST_PLAYLIST                @"Playlist.reopenLast"
#define SETTING_UI_UPDATE_HZ_CAP                    @"UI.updateHzCap"
#define SETTING_ALLOW_BIT_PERFECT_ON_ANY_DEVICE      @"AudioPlayer.allowBitPerfectOnAnyDevice"
#if VIBE_DIRECT_DISTRIBUTION
#define SETTING_RECEIVE_BETA_UPDATES                @"Updates.receiveBetas"
// Sparkle's own keys, behind Settings > General's Check for updates.
#define SETTING_SPARKLE_AUTOMATIC_CHECKS            @"SUEnableAutomaticChecks"
#define SETTING_SPARKLE_CHECK_INTERVAL              @"SUScheduledCheckInterval"
#endif
// { device UID: { mode: YES } }, holding only the modes that are on.
#define SETTING_OUTPUT_MODES_BY_DEVICE_UID          @"AudioPlayer.outputModesByDeviceUID"
#define OUTPUT_MODE_BIT_PERFECT                     @"bitPerfect"
#define OUTPUT_MODE_EXCLUSIVE                       @"exclusive"
// { menu identifier: VibeShortcut }, only where a shortcut differs from its
// default (ShortcutRules.h).
#define SETTING_SHORTCUT_OVERRIDES                  @"Shortcuts.overrides"
#define SETTING_DECLICK                             @"AudioPlayer.declick"
#define SETTING_VOLUME_CONTROL                      @"AudioPlayer.volumeControl"
#define SETTING_VOLUME                              @"AudioPlayer.volume"
#define SETTING_ANALYZE_KEY                         @"Audio.analyzeKey"
#define SETTING_CONVERT_ASKS_WHERE_TO_SAVE          @"Convert.asksWhereToSave"
#define SETTING_CONVERT_ENABLED                     @"Convert.enabled"
// TRAP: a stored key never follows a rename of its macro — changing the
// string resets every user's setting. This one keeps "folderArtwork".
#define SETTING_FOLDER_ART                          @"Audio.folderArtwork"

const NSInteger kVibeSkipBasePresets[] = {4, 8, 16};
const size_t kVibeSkipBasePresetCount =
        sizeof(kVibeSkipBasePresets) / sizeof(kVibeSkipBasePresets[0]);
const NSInteger kVibeUIUpdateHzCapPresets[] = {3, 30, 60};
const size_t kVibeUIUpdateHzCapPresetCount =
        sizeof(kVibeUIUpdateHzCapPresets) / sizeof(kVibeUIUpdateHzCapPresets[0]);

@implementation AppSettings (Mac)

#pragma mark - macOS only

- (void)registerMacDefaultsInto:(NSMutableDictionary *)defaults {
    [defaults addEntriesFromDictionary:@{
            SETTING_AUDIO_PLAYER_DEVICE_NAME:       @"",
            SETTING_AUDIO_PLAYER_DEVICE_UID:        @"",
            SETTING_AUDIO_PLAYER_DEVICE_MODEL_UID:  @"",
            SETTING_WINDOW_APPEARANCE_STYLE:        SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT,
            SETTING_PITCH_PANEL_SHOWN:              @(NO),
            SETTING_PLAYLIST_SHOWN:                 @(NO),
            SETTING_ALWAYS_ON_TOP:                  @(NO),
            SETTING_WINDOW_POSITION_LOCKED:         @(NO),
            SETTING_SHOW_TRAFFIC_LIGHTS:            @(YES),
            SETTING_SHOW_TIME_LABELS:               @(YES),
            SETTING_SHOW_STATUS_ICONS:              @(YES),
            SETTING_SHOW_BPM:                       @(YES),
            SETTING_SHOW_KEY:                       @(YES),
            SETTING_KEY_NOTATION:                   SETTINGS_VALUE_KEY_NOTATION_CAMELOT,
            SETTING_KEY_COLORS:                     @(NO),
            SETTING_PLAYLIST_NUMBER_COLUMN:         @(YES),
            SETTING_PLAYLIST_ARTWORK_COLUMN:        @(YES),
            SETTING_PLAYLIST_DURATION_COLUMN:       @(YES),
            SETTING_DOCK_ICON:                      SETTINGS_VALUE_DOCK_ICON_ALBUM_ART,
            SETTING_PITCH_RANGE:                    @(8),
            SETTING_WAVEFORM_DRAG_BEHAVIOR:         SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW,
            SETTING_ARTWORK_DRAG_ACTION:            SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE,
            SETTING_DELETE_ORIGINAL_AFTER_CONVERT:  @(NO),
            SETTING_CONVERT_ENABLED:                @(NO),
            SETTING_SKIP_BASE_BARS:                 @(8),
            SETTING_REOPEN_LAST_PLAYLIST:           @(NO),
            SETTING_UI_UPDATE_HZ_CAP:               @(60),
            SETTING_ALLOW_BIT_PERFECT_ON_ANY_DEVICE: @(NO),
#if VIBE_DIRECT_DISTRIBUTION
            // A beta build keeps its tester on the beta train.
            SETTING_RECEIVE_BETA_UPDATES:           @((BOOL)VIBE_BETA_DEBUG),
#endif
            SETTING_DECLICK:                        @(YES),
            SETTING_VOLUME_CONTROL:                 @(NO),
            SETTING_VOLUME:                         @(1.0),
            SETTING_ANALYZE_KEY:                    @(NO),
            SETTING_CONVERT_ASKS_WHERE_TO_SAVE:     @(NO),
            SETTING_FOLDER_ART:                     @(YES),
            SETTING_ACTIVE_THEME:                   kVibeThemeIdentifierVibe,
            SETTING_WAVEFORM_NORMALIZE:             @(YES),
            SETTING_WAVEFORM_GAIN_DB:               @(0.0),
    }];
}

// Keys with no registered default, where absent IS the default. Sparkle's
// defaults are the Info.plist's, so a reset clears them here too.
- (NSArray<NSString *> *)nullableSettingKeys {
    return @[SETTING_CURRENT_THEME, SETTING_OUTPUT_MODES_BY_DEVICE_UID, SETTING_SHORTCUT_OVERRIDES,
#if VIBE_DIRECT_DISTRIBUTION
             SETTING_SPARKLE_AUTOMATIC_CHECKS, SETTING_SPARKLE_CHECK_INTERVAL,
#endif
    ];
}

// The persistent domain, not dictionaryRepresentation, which folds the
// registration domain back in and would make every default read as stored.
- (BOOL)allSettingsAtDefaults {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults]
            persistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    return VibeSettingsAreAtDefaults(stored, [self registeredSettingDefaults],
                                     [self nullableSettingKeys]);
}

- (BOOL)atFactoryDefaults {
    return self.allSettingsAtDefaults && !self.welcomeTrackSpent && self.userThemeIdentifiers.count == 0;
}

- (void)resetToDefaults {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in [self registeredSettingDefaults]) {
        [defaults removeObjectForKey:key];
    }
    for (NSString *key in [self nullableSettingKeys]) {
        [defaults removeObjectForKey:key];
    }
    _storedUserThemesCache = nil;
    [_currentTheme replaceWithRecord:nil];
    [self clearThemeHistory];
    _windowAppearancePreviewStyle = nil;
    [self sweepUnreferencedThemeImages];
}

- (void)factoryReset {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SETTING_WELCOME_TRACK_SPENT];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SETTING_USER_THEMES];
    [self resetToDefaults];
}

- (void)applicationDidFinishLaunching {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"NSQuitAlwaysKeepsWindows"];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSFullScreenMenuItemEverywhere"];
    [NSApplication sharedApplication].automaticCustomizeTouchBarMenuItemEnabled = NO;
#if VIBE_DIRECT_DISTRIBUTION && VIBE_BETA_DEBUG
    // Stored, not just registered: a stable update registers it off, and would
    // otherwise take a tester off the beta train.
    [NSUserDefaults.standardUserDefaults setBool:self.receiveBetaUpdates forKey:SETTING_RECEIVE_BETA_UPDATES];
#endif
}

#pragma mark Output device

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

- (NSString *)audioOutputDeviceModelUID {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_AUDIO_PLAYER_DEVICE_MODEL_UID];
}

- (void)setAudioOutputDeviceModelUID:(NSString *)modelUID {
    [[NSUserDefaults standardUserDefaults] setObject:modelUID ?: @"" forKey:SETTING_AUDIO_PLAYER_DEVICE_MODEL_UID];
}

#pragma mark Window

- (NSString *)windowAppearanceStyle {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_WINDOW_APPEARANCE_STYLE];
}

- (void)setWindowAppearanceStyle:(NSString *)name {
    // An explicit choice ends any preview, or it would read as ignored.
    _windowAppearancePreviewStyle = nil;
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:SETTING_WINDOW_APPEARANCE_STYLE];
}

- (NSString *)windowAppearancePreviewStyle {
    return _windowAppearancePreviewStyle;
}

- (void)setWindowAppearancePreviewStyle:(NSString *)name {
    _windowAppearancePreviewStyle = [name copy];
}

- (NSAppearance *)windowAppearance {
    NSAppearance *required = self.currentTheme.requiredWindowAppearance;
    if (required) {
        return required;
    }
    NSString *value = _windowAppearancePreviewStyle ?: self.windowAppearanceStyle;
    if ([value isEqualToString:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT]) {
        return [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    }
    if ([value isEqualToString:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK]) {
        return [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    }
    return nil;
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

- (BOOL)windowPositionLocked {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_WINDOW_POSITION_LOCKED];
}

- (void)setWindowPositionLocked:(BOOL)locked {
    [[NSUserDefaults standardUserDefaults] setBool:locked forKey:SETTING_WINDOW_POSITION_LOCKED];
}

- (BOOL)showTrafficLights {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHOW_TRAFFIC_LIGHTS];
}

- (void)setShowTrafficLights:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_TRAFFIC_LIGHTS];
}

#pragma mark Player display

- (BOOL)showTimeLabels {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHOW_TIME_LABELS];
}

- (void)setShowTimeLabels:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_TIME_LABELS];
}

- (BOOL)showStatusIcons {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHOW_STATUS_ICONS];
}

- (void)setShowStatusIcons:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_STATUS_ICONS];
}

- (BOOL)showBPM {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHOW_BPM];
}

- (void)setShowBPM:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_BPM];
}

- (BOOL)showKey {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHOW_KEY];
}

- (void)setShowKey:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_KEY];
}

- (NSString *)keyNotation {
    return VibeNormalizedKeyNotation([[NSUserDefaults standardUserDefaults] stringForKey:SETTING_KEY_NOTATION]);
}

- (void)setKeyNotation:(NSString *)notation {
    [[NSUserDefaults standardUserDefaults] setObject:VibeNormalizedKeyNotation(notation)
                                              forKey:SETTING_KEY_NOTATION];
}

- (BOOL)keyColorsEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_KEY_COLORS];
}

- (void)setKeyColorsEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:SETTING_KEY_COLORS];
}

- (BOOL)showPlaylistNumberColumn {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_PLAYLIST_NUMBER_COLUMN];
}

- (void)setShowPlaylistNumberColumn:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_PLAYLIST_NUMBER_COLUMN];
}

- (BOOL)showPlaylistArtworkColumn {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_PLAYLIST_ARTWORK_COLUMN];
}

- (void)setShowPlaylistArtworkColumn:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_PLAYLIST_ARTWORK_COLUMN];
}

- (BOOL)showPlaylistDurationColumn {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_PLAYLIST_DURATION_COLUMN];
}

- (void)setShowPlaylistDurationColumn:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_PLAYLIST_DURATION_COLUMN];
}

- (NSString *)dockIcon {
    return VibeNormalizedDockIcon([[NSUserDefaults standardUserDefaults] stringForKey:SETTING_DOCK_ICON]);
}

- (void)setDockIcon:(NSString *)dockIcon {
    [[NSUserDefaults standardUserDefaults] setObject:VibeNormalizedDockIcon(dockIcon) forKey:SETTING_DOCK_ICON];
}

#pragma mark Drag behavior

- (NSString *)waveformDragBehavior {
    return VibeNormalizedWaveformDragBehavior(
            [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_WAVEFORM_DRAG_BEHAVIOR]);
}

- (void)setWaveformDragBehavior:(NSString *)behavior {
    [[NSUserDefaults standardUserDefaults] setObject:behavior forKey:SETTING_WAVEFORM_DRAG_BEHAVIOR];
}

- (NSString *)artworkDragAction {
    return VibeNormalizedArtworkDragAction(
            [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_ARTWORK_DRAG_ACTION]);
}

- (void)setArtworkDragAction:(NSString *)action {
    [[NSUserDefaults standardUserDefaults] setObject:action forKey:SETTING_ARTWORK_DRAG_ACTION];
}

#pragma mark Playback

- (NSInteger)pitchRange {
    return VibeNormalizedPitchRange(
            [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_PITCH_RANGE]);
}

- (void)setPitchRange:(NSInteger)range {
    [[NSUserDefaults standardUserDefaults] setInteger:VibeNormalizedPitchRange(range)
                                              forKey:SETTING_PITCH_RANGE];
}

- (NSInteger)skipBaseBars {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_SKIP_BASE_BARS];
    return VibeNearestPreset(stored, kVibeSkipBasePresets, kVibeSkipBasePresetCount);
}

- (void)setSkipBaseBars:(NSInteger)bars {
    [[NSUserDefaults standardUserDefaults] setInteger:bars forKey:SETTING_SKIP_BASE_BARS];
}

- (BOOL)waveformNormalize {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_WAVEFORM_NORMALIZE];
}

- (void)setWaveformNormalize:(BOOL)normalize {
    [[NSUserDefaults standardUserDefaults] setBool:normalize forKey:SETTING_WAVEFORM_NORMALIZE];
}

- (double)waveformGainDB {
    return VibeNormalizedWaveformGainDB(
            [[NSUserDefaults standardUserDefaults] doubleForKey:SETTING_WAVEFORM_GAIN_DB]);
}

- (void)setWaveformGainDB:(double)gainDB {
    [[NSUserDefaults standardUserDefaults] setDouble:gainDB forKey:SETTING_WAVEFORM_GAIN_DB];
}

- (BOOL)reopenLastPlaylist {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_REOPEN_LAST_PLAYLIST];
}

- (void)setReopenLastPlaylist:(BOOL)reopen {
    [[NSUserDefaults standardUserDefaults] setBool:reopen forKey:SETTING_REOPEN_LAST_PLAYLIST];
}

- (NSInteger)uiUpdateHzCap {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_UI_UPDATE_HZ_CAP];
    return VibeNearestPreset(stored, kVibeUIUpdateHzCapPresets, kVibeUIUpdateHzCapPresetCount);
}

- (void)setUiUpdateHzCap:(NSInteger)hz {
    [[NSUserDefaults standardUserDefaults] setInteger:hz forKey:SETTING_UI_UPDATE_HZ_CAP];
}

- (BOOL)allowBitPerfectOnAnyDevice {
    return [NSUserDefaults.standardUserDefaults boolForKey:SETTING_ALLOW_BIT_PERFECT_ON_ANY_DEVICE];
}

- (void)setAllowBitPerfectOnAnyDevice:(BOOL)allowed {
    [NSUserDefaults.standardUserDefaults setBool:allowed forKey:SETTING_ALLOW_BIT_PERFECT_ON_ANY_DEVICE];
}

#if VIBE_DIRECT_DISTRIBUTION
- (BOOL)receiveBetaUpdates {
    return [NSUserDefaults.standardUserDefaults boolForKey:SETTING_RECEIVE_BETA_UPDATES];
}

- (void)setReceiveBetaUpdates:(BOOL)receive {
    [NSUserDefaults.standardUserDefaults setBool:receive forKey:SETTING_RECEIVE_BETA_UPDATES];
}
#endif

// Shape-checked only; which entries mean anything is ShortcutRules.h's.
- (NSDictionary<NSString *, NSNumber *> *)shortcutOverrides {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:SETTING_SHORTCUT_OVERRIDES] ?: @{};
}

- (void)setShortcutOverrides:(NSDictionary<NSString *, NSNumber *> *)overrides {
    if (overrides.count) {
        [NSUserDefaults.standardUserDefaults setObject:overrides forKey:SETTING_SHORTCUT_OVERRIDES];
    }
    else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SETTING_SHORTCUT_OVERRIDES];
    }
}

// Off is absence, so the store names only devices with a mode on. An entry
// outlives its device being unplugged.
- (BOOL)outputMode:(NSString *)mode forDeviceUID:(NSString *)deviceUID {
    if (deviceUID.length == 0) {
        return NO;
    }
    NSDictionary *modes = [[NSUserDefaults standardUserDefaults] dictionaryForKey:SETTING_OUTPUT_MODES_BY_DEVICE_UID][deviceUID];
    NSNumber *enabled = [modes isKindOfClass:NSDictionary.class] ? modes[mode] : nil;
    return [enabled isKindOfClass:NSNumber.class] && enabled.boolValue;
}

- (void)setOutputMode:(NSString *)mode enabled:(BOOL)enabled {
    NSString *deviceUID = self.audioOutputDeviceUID;
    if (deviceUID.length == 0) {
        return; // System Output names no device
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *devices = [[defaults dictionaryForKey:SETTING_OUTPUT_MODES_BY_DEVICE_UID] mutableCopy]
            ?: [NSMutableDictionary dictionary];
    NSDictionary *stored = devices[deviceUID];
    NSMutableDictionary *modes = [stored isKindOfClass:NSDictionary.class]
            ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    modes[mode] = enabled ? @YES : nil;
    devices[deviceUID] = modes.count ? modes : nil;
    if (devices.count) {
        [defaults setObject:devices forKey:SETTING_OUTPUT_MODES_BY_DEVICE_UID];
    }
    else {
        [defaults removeObjectForKey:SETTING_OUTPUT_MODES_BY_DEVICE_UID];
    }
}

// Main thread only: an unlocked read-modify-write. Copies rather than moves,
// so moving the device back finds its modes again.
- (void)carryOutputModesFromDeviceUID:(NSString *)fromUID toDeviceUID:(NSString *)toUID {
    if (fromUID.length == 0 || toUID.length == 0 || [fromUID isEqualToString:toUID]) {
        return;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *devices = [[defaults dictionaryForKey:SETTING_OUTPUT_MODES_BY_DEVICE_UID] mutableCopy];
    NSDictionary *modes = devices[fromUID];
    if (![modes isKindOfClass:NSDictionary.class] || modes.count == 0 || devices[toUID]) {
        return;
    }
    devices[toUID] = modes;
    [defaults setObject:devices forKey:SETTING_OUTPUT_MODES_BY_DEVICE_UID];
}

- (BOOL)bitPerfectOutputForDeviceUID:(NSString *)deviceUID {
    return [self outputMode:OUTPUT_MODE_BIT_PERFECT forDeviceUID:deviceUID];
}

- (BOOL)bitPerfectOutput {
    return [self bitPerfectOutputForDeviceUID:self.audioOutputDeviceUID];
}

- (void)setBitPerfectOutput:(BOOL)enabled {
    [self setOutputMode:OUTPUT_MODE_BIT_PERFECT enabled:enabled];
}

- (BOOL)exclusiveOutputForDeviceUID:(NSString *)deviceUID {
    return [self outputMode:OUTPUT_MODE_EXCLUSIVE forDeviceUID:deviceUID];
}

- (BOOL)exclusiveOutput {
    return [self exclusiveOutputForDeviceUID:self.audioOutputDeviceUID];
}

- (void)setExclusiveOutput:(BOOL)enabled {
    [self setOutputMode:OUTPUT_MODE_EXCLUSIVE enabled:enabled];
}

- (BOOL)declick {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_DECLICK];
}

- (void)setDeclick:(BOOL)declick {
    [[NSUserDefaults standardUserDefaults] setBool:declick forKey:SETTING_DECLICK];
}

- (BOOL)volumeControl {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_VOLUME_CONTROL];
}

- (void)setVolumeControl:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:SETTING_VOLUME_CONTROL];
}

- (double)volume {
    return clampRange([[NSUserDefaults standardUserDefaults] doubleForKey:SETTING_VOLUME], 0, 1);
}

- (void)setVolume:(double)volume {
    [[NSUserDefaults standardUserDefaults] setDouble:volume forKey:SETTING_VOLUME];
}

- (double)effectiveVolume {
    return self.volumeControl ? self.volume : 1.0;
}

- (BOOL)audioFXAllowed {
    return self.audioFXEnabled && !self.bitPerfectOutput;
}

- (BOOL)pitchControlAllowed {
    return !self.bitPerfectOutput;
}

- (NSInteger)effectiveCrossfadeMilliseconds {
    return self.bitPerfectOutput ? kVibeCrossfadeOffMilliseconds : self.crossfadeMilliseconds;
}

#pragma mark Analysis and the key label

- (BOOL)analyzeKey {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_ANALYZE_KEY];
}

- (void)setAnalyzeKey:(BOOL)analyze {
    [[NSUserDefaults standardUserDefaults] setBool:analyze forKey:SETTING_ANALYZE_KEY];
}


#pragma mark Files and conversion

- (BOOL)convertEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_CONVERT_ENABLED];
}

- (void)setConvertEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:SETTING_CONVERT_ENABLED];
}

- (BOOL)deleteOriginalAfterConvert {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_DELETE_ORIGINAL_AFTER_CONVERT];
}

- (void)setDeleteOriginalAfterConvert:(BOOL)deleteOriginal {
    [[NSUserDefaults standardUserDefaults] setBool:deleteOriginal forKey:SETTING_DELETE_ORIGINAL_AFTER_CONVERT];
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
