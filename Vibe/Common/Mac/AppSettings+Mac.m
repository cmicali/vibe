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
#define SETTING_SHOW_REMAINING_TIME                 @"MainWindow.showRemainingTime"
#define SETTING_SHOW_FILE_INFO                      @"MainWindow.showFileInfo"
#define SETTING_WAVEFORM_NORMALIZE                  @"Appearance.waveformNormalize"
#define SETTING_WAVEFORM_GAIN_DB                    @"Appearance.waveformGainDB"
#define SETTING_WAVEFORM_DRAG_BEHAVIOR              @"Settings.waveformDragBehavior"
#define SETTING_ARTWORK_DRAG_ACTION                 @"Settings.artworkDragAction"
#define SETTING_DELETE_ORIGINAL_AFTER_CONVERT       @"Convert.deleteOriginal"
#define SETTING_SKIP_BASE_BARS                      @"Transport.skipBaseBars"
#define SETTING_REOPEN_LAST_PLAYLIST                @"Playlist.reopenLast"
#define SETTING_UI_UPDATE_HZ_CAP                    @"UI.updateHzCap"
#define SETTING_ALLOW_BIT_PERFECT_ON_ANY_DEVICE      @"AudioPlayer.allowBitPerfectOnAnyDevice"
#define SETTING_APPLE_MPEG_DECODER                  @"AudioPlayer.appleMPEGDecoder"
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
#define SETTING_KEY_NOTATION                        @"Audio.keyNotation"
#define SETTING_KEY_COLORS                          @"Appearance.keyColors"
#define SETTING_SHOW_BPM                            @"Appearance.showBPM"
#define SETTING_SHOW_KEY                            @"Appearance.showKey"
#define SETTING_WINDOW_TINT                         @"Appearance.windowTint"
#define SETTING_WINDOW_TINT_CUSTOM_DARK             @"Appearance.windowTintCustomColorDark"
#define SETTING_WINDOW_TINT_CUSTOM_LIGHT            @"Appearance.windowTintCustomColorLight"
#define SETTING_CONVERT_ASKS_WHERE_TO_SAVE          @"Convert.asksWhereToSave"
#define SETTING_CONVERT_ENABLED                     @"Convert.enabled"
// TRAP: a stored key never follows a rename of its macro — changing the
// string resets every user's setting. This one keeps "folderArtwork".
#define SETTING_FOLDER_ART                          @"Audio.folderArtwork"
#define SETTING_ACTIVE_THEME                        @"Appearance.activeTheme"
#define SETTING_USER_THEMES                         @"Appearance.userThemes"
#define SETTING_CURRENT_THEME                       @"Appearance.currentTheme"

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
            SETTING_PITCH_RANGE:                    @(8),
            SETTING_WAVEFORM_DRAG_BEHAVIOR:         SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW,
            SETTING_ARTWORK_DRAG_ACTION:            SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE,
            SETTING_DELETE_ORIGINAL_AFTER_CONVERT:  @(NO),
            SETTING_CONVERT_ENABLED:                @(YES),
            SETTING_SKIP_BASE_BARS:                 @(8),
            SETTING_REOPEN_LAST_PLAYLIST:           @(NO),
            SETTING_UI_UPDATE_HZ_CAP:               @(60),
            SETTING_ALLOW_BIT_PERFECT_ON_ANY_DEVICE: @(NO),
            SETTING_APPLE_MPEG_DECODER:             @(NO),
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

// Keys with no registered default, where absent IS the default.
- (NSArray<NSString *> *)nullableSettingKeys {
    return @[SETTING_CURRENT_THEME, SETTING_OUTPUT_MODES_BY_DEVICE_UID, SETTING_SHORTCUT_OVERRIDES];
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
    _storedUserThemesCache = nil;
    [_currentTheme replaceWithRecord:nil];
    [self clearThemeHistory];
    _windowAppearancePreviewStyle = nil;
    [self sweepUnreferencedThemeImages];
}

- (void)factoryReset {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SETTING_USER_THEMES];
    [self resetToDefaults];
}

- (void)applicationDidFinishLaunching {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"NSQuitAlwaysKeepsWindows"];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSFullScreenMenuItemEverywhere"];
    [NSApplication sharedApplication].automaticCustomizeTouchBarMenuItemEnabled = NO;
}

#pragma mark Themes

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

// The pre-theme loose keys, by AppTheme field name. Runs once, before
// registerDefaults (it keys on "no stored active theme"), and consumes every
// key it reads, the shared-named waveform keys included: iOS has its own store.
- (void)migrateLooseAppearanceSettingsToTheme {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:SETTING_ACTIVE_THEME]) {
        return;
    }
    NSDictionary<NSString *, NSString *> *legacyKeys = @{
        @"waveformStyle":              SETTING_WAVEFORM_STYLE,
        @"waveformTheme":              SETTING_WAVEFORM_THEME,
        @"waveformPlayedColorDark":    SETTING_WAVEFORM_CUSTOM_PLAYED_DARK,
        @"waveformUnplayedColorDark":  SETTING_WAVEFORM_CUSTOM_UNPLAYED_DARK,
        @"waveformPlayedColorLight":   SETTING_WAVEFORM_CUSTOM_PLAYED_LIGHT,
        @"waveformUnplayedColorLight": SETTING_WAVEFORM_CUSTOM_UNPLAYED_LIGHT,
        @"windowTint":                 SETTING_WINDOW_TINT,
        @"windowTintColorDark":        SETTING_WINDOW_TINT_CUSTOM_DARK,
        @"windowTintColorLight":       SETTING_WINDOW_TINT_CUSTOM_LIGHT,
        @"showFileInfo":               SETTING_SHOW_FILE_INFO,
        @"showRemainingTime":          SETTING_SHOW_REMAINING_TIME,
        @"showBPM":                    SETTING_SHOW_BPM,
        @"showKey":                    SETTING_SHOW_KEY,
        @"keyColorsEnabled":           SETTING_KEY_COLORS,
        @"keyNotation":                SETTING_KEY_NOTATION,
    };
    NSMutableDictionary *legacyValues = [NSMutableDictionary dictionary];
    for (NSString *field in legacyKeys) {
        id value = [defaults objectForKey:legacyKeys[field]];
        if (value) {
            legacyValues[field] = value;
        }
    }
    NSString *waveformStyle = NormalizedWaveformStyle([defaults stringForKey:SETTING_WAVEFORM_STYLE]);
    if (waveformStyle) {
        legacyValues[@"waveformStyle"] = waveformStyle;
    }
    NSString *waveformTheme = VibeMigratedWaveformTheme([defaults stringForKey:SETTING_WAVEFORM_THEME],
                                                        waveformStyle);
    if (waveformTheme) {
        legacyValues[@"waveformTheme"] = waveformTheme;
    }
    NSDictionary *record = [AppTheme migratedRecordFromLegacyValues:legacyValues];
    if (record) {
        NSString *identifier = NSUUID.UUID.UUIDString;
        [defaults setObject:@[UserThemeEntry(record, identifier, STR_THEME_NAME_CUSTOM)]
                     forKey:SETTING_USER_THEMES];
        [defaults setObject:identifier forKey:SETTING_ACTIVE_THEME];
    }
    for (NSString *field in legacyKeys) {
        [defaults removeObjectForKey:legacyKeys[field]];
    }
}

// A stored user-theme entry: its sparse record plus id and name, flat.
static NSDictionary *UserThemeEntry(NSDictionary *record, NSString *identifier, NSString *name) {
    NSMutableDictionary *entry = [record mutableCopy];
    entry[kVibeThemeRecordIdentifierKey] = identifier;
    entry[kVibeThemeRecordNameKey] = name;
    return entry;
}

// One side of a history entry. An edit, a rename and a removal each move some
// of the three, so there is one entry kind and one restore.
static NSDictionary *ThemeStoreSnapshot(NSArray<NSDictionary *> *themes, NSString *active,
                                        NSDictionary *working) {
    return @{@"themes": [themes copy], @"active": active, @"working": [working copy]};
}

// Every record a history entry can put back, for the image sweep.
static NSArray<NSDictionary *> *ThemeHistoryRecords(NSDictionary *change) {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSDictionary *snapshot in change.allValues) {
        [records addObjectsFromArray:snapshot[@"themes"]];
        [records addObject:snapshot[@"working"]];
    }
    return records;
}

static BOOL ThemeHistoryChangeRemovesTheme(NSDictionary *change) {
    return [change[@"before"][@"themes"] count] > [change[@"after"][@"themes"] count];
}

// Sanitized on read, so an external defaults write cannot smuggle in what an
// import would refuse; an entry without a usable id and name is dropped.
// Memoized: persistUserThemes: is the only runtime writer and installs what it
// wrote, entries already through the gate. No CLI verb writes this key.
- (NSArray<NSDictionary *> *)storedUserThemes {
    if (_storedUserThemesCache) {
        return _storedUserThemesCache;
    }
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:SETTING_USER_THEMES];
    NSMutableArray<NSDictionary *> *themes = [NSMutableArray array];
    for (id entry in stored) {
        if (![entry isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *identifier = entry[kVibeThemeRecordIdentifierKey];
        NSString *name = entry[kVibeThemeRecordNameKey];
        if (![identifier isKindOfClass:NSString.class] || identifier.length == 0 ||
            [AppTheme isBuiltInIdentifier:identifier] ||
            ![name isKindOfClass:NSString.class] || name.length == 0) {
            continue;
        }
        [themes addObject:UserThemeEntry([AppTheme sanitizedRecord:entry], identifier, name)];
    }
    _storedUserThemesCache = [themes copy];
    return _storedUserThemesCache;
}

- (void)persistUserThemes:(NSArray<NSDictionary *> *)themes {
    _storedUserThemesCache = [themes copy];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (themes.count) {
        [defaults setObject:themes forKey:SETTING_USER_THEMES];
    } else {
        [defaults removeObjectForKey:SETTING_USER_THEMES];
    }
}

- (NSDictionary *)storedUserThemeWithIdentifier:(NSString *)identifier {
    for (NSDictionary *entry in [self storedUserThemes]) {
        if ([entry[kVibeThemeRecordIdentifierKey] isEqualToString:identifier]) {
            return entry;
        }
    }
    return nil;
}

- (NSString *)activeThemeIdentifier {
    return [self resolvedThemeIdentifier:
            [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_ACTIVE_THEME]];
}

// An identifier naming no theme snaps to vibe.
- (NSString *)resolvedThemeIdentifier:(NSString *)identifier {
    if ([AppTheme isBuiltInIdentifier:identifier] ||
        (identifier && [self storedUserThemeWithIdentifier:identifier])) {
        return identifier;
    }
    return kVibeThemeIdentifierVibe;
}

- (NSArray<NSString *> *)orderedThemeIdentifiers {
    NSMutableArray<NSString *> *identifiers = [[AppTheme builtInThemeIdentifiers] mutableCopy];
    for (NSDictionary *entry in [self storedUserThemes]) {
        [identifiers addObject:entry[kVibeThemeRecordIdentifierKey]];
    }
    return identifiers;
}

- (NSString *)displayNameForThemeIdentifier:(NSString *)identifier {
    // The ThemeNames catalog overlays a translation on the JSON's English
    // name, so a new built-in ships with no catalog entry.
    NSString *builtInName = [AppTheme builtInNameForIdentifier:identifier];
    if (builtInName) {
        return [NSBundle.mainBundle localizedStringForKey:identifier
                                                    value:builtInName
                                                    table:@"ThemeNames"];
    }
    return [self storedUserThemeWithIdentifier:identifier][kVibeThemeRecordNameKey];
}

- (NSArray<NSString *> *)allThemeDisplayNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *identifier in [AppTheme builtInThemeIdentifiers]) {
        [names addObject:[self displayNameForThemeIdentifier:identifier]];
    }
    for (NSDictionary *entry in [self storedUserThemes]) {
        [names addObject:entry[kVibeThemeRecordNameKey]];
    }
    return names;
}

- (NSDictionary<NSString *, id> *)recordForThemeIdentifier:(NSString *)identifier {
    if ([AppTheme isBuiltInIdentifier:identifier]) {
        return [AppTheme builtInRecordForIdentifier:identifier];
    }
    NSDictionary *entry = [self storedUserThemeWithIdentifier:identifier];
    if (entry) {
        NSMutableDictionary *record = [entry mutableCopy];
        [record removeObjectsForKeys:@[kVibeThemeRecordIdentifierKey,
                                       kVibeThemeRecordNameKey]];
        return [record copy];
    }
    return [AppTheme builtInRecordForIdentifier:kVibeThemeIdentifierVibe];
}

- (AppTheme *)currentTheme {
    NSAssert(NSThread.isMainThread, @"AppSettings.currentTheme is main-thread only");
    if (!_currentTheme) {
        NSDictionary *diverged =
                [[NSUserDefaults standardUserDefaults] dictionaryForKey:SETTING_CURRENT_THEME];
        _currentTheme = [[AppTheme alloc] initWithRecord:
                diverged ?: [self recordForThemeIdentifier:self.activeThemeIdentifier]];
    }
    return _currentTheme;
}

// Activation that keeps history, for a restore and a removal's fallback;
// applyThemeWithIdentifier: also clears it.
- (void)activateThemeWithIdentifier:(NSString *)identifier {
    NSString *resolved = [self resolvedThemeIdentifier:identifier];
    [self.currentTheme replaceWithRecord:[self recordForThemeIdentifier:resolved]];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:resolved forKey:SETTING_ACTIVE_THEME];
    [defaults removeObjectForKey:SETTING_CURRENT_THEME];
}

- (void)applyThemeWithIdentifier:(NSString *)identifier {
    [self activateThemeWithIdentifier:identifier];
    [self clearThemeHistory];
    // Dropping the history orphans any image only an undo was keeping. A
    // divergence record never names one: built-ins refuse custom images.
    [self sweepUnreferencedThemeImages];
}

- (void)currentThemeDidChange {
    [self currentThemeDidChangeContinuous:NO];
}

- (void)currentThemeDidChangeContinuous:(BOOL)continuous {
    [self currentThemeDidChangeContinuous:continuous atTime:NSDate.timeIntervalSinceReferenceDate];
}

- (void)currentThemeDidChangeContinuous:(BOOL)continuous atTime:(NSTimeInterval)time {
    if (!_currentTheme) {
        return;
    }
    NSDictionary *record = _currentTheme.dictionaryRepresentation;
    NSString *active = self.activeThemeIdentifier;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Its image references against the new record's decide the sweep, so a
    // color drag, which changes none, never lists the container.
    NSDictionary *previous = [defaults dictionaryForKey:SETTING_CURRENT_THEME]
            ?: [self recordForThemeIdentifier:active];
    NSDictionary *before = ThemeStoreSnapshot([self storedUserThemes], active, previous);
    if ([AppTheme isBuiltInIdentifier:active]) {
        // A built-in stays pristine; the divergence key exists only while
        // there is one.
        if ([record isEqualToDictionary:[AppTheme builtInRecordForIdentifier:active]]) {
            [defaults removeObjectForKey:SETTING_CURRENT_THEME];
        } else {
            [defaults setObject:record forKey:SETTING_CURRENT_THEME];
        }
    } else {
        // From the same dictionary, so the entry and working state cannot
        // drift.
        NSMutableArray<NSDictionary *> *themes = [[self storedUserThemes] mutableCopy];
        for (NSUInteger i = 0; i < themes.count; i++) {
            if ([themes[i][kVibeThemeRecordIdentifierKey] isEqualToString:active]) {
                themes[i] = UserThemeEntry(record, active, themes[i][kVibeThemeRecordNameKey]);
                break;
            }
        }
        [self persistUserThemes:themes];
        [defaults removeObjectForKey:SETTING_CURRENT_THEME];
    }
    BOOL retiredHistoryImages = !_themeHistoryRestoring
            && [self recordThemeChange:before
                            replacedBy:ThemeStoreSnapshot([self storedUserThemes], active, record)
                            continuous:continuous atTime:time];
    if (retiredHistoryImages || ![[AppTheme customImageFilesInRecord:previous]
            isEqualToSet:[AppTheme customImageFilesInRecord:record]]) {
        [self sweepUnreferencedThemeImages];
    }
}

- (NSString *)addUserThemeWithRecord:(NSDictionary<NSString *, id> *)record
                                name:(NSString *)name {
    NSString *deduped = [AppTheme dedupedThemeName:name
                                          fallback:STR_THEME_NAME_CUSTOM
                                     existingNames:[self allThemeDisplayNames]];
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSMutableArray *themes = [[self storedUserThemes] mutableCopy];
    [themes addObject:UserThemeEntry([AppTheme sanitizedRecord:record], identifier, deduped)];
    [self persistUserThemes:themes];
    // An older snapshot would erase this unrecorded addition.
    [self clearThemeHistory];
    [self sweepUnreferencedThemeImages];
    return identifier;
}

- (NSString *)duplicateThemeWithIdentifier:(NSString *)identifier {
    NSString *name = [self displayNameForThemeIdentifier:identifier];
    if (!name) {
        return nil;
    }
    NSDictionary *record = [identifier isEqualToString:self.activeThemeIdentifier]
            ? self.currentTheme.dictionaryRepresentation : [self recordForThemeIdentifier:identifier];
    return [self addUserThemeWithRecord:record name:name];
}

- (void)removeUserThemeWithIdentifier:(NSString *)identifier
                        fallingBackTo:(NSString *)successor {
    NSArray<NSDictionary *> *stored = [self storedUserThemes];
    NSUInteger index = [stored indexOfObjectPassingTest:^BOOL(NSDictionary *entry, NSUInteger i, BOOL *stop) {
        return [entry[kVibeThemeRecordIdentifierKey] isEqualToString:identifier];
    }];
    if (index == NSNotFound) return;
    NSString *active = self.activeThemeIdentifier;
    NSDictionary *before = ThemeStoreSnapshot(stored, active, self.currentTheme.dictionaryRepresentation);
    NSMutableArray<NSDictionary *> *themes = [stored mutableCopy];
    [themes removeObjectAtIndex:index];
    [self persistUserThemes:themes];
    if ([active isEqualToString:identifier]) {
        [self activateThemeWithIdentifier:successor ?: kVibeThemeIdentifierVibe];
    }
    // The entry holds everything the removal dropped, so only an eviction at
    // the cap can orphan an image.
    if ([self recordThemeChange:before
                     replacedBy:ThemeStoreSnapshot(themes, self.activeThemeIdentifier,
                                                   self.currentTheme.dictionaryRepresentation)
                     continuous:NO atTime:NSDate.timeIntervalSinceReferenceDate]) {
        [self sweepUnreferencedThemeImages];
    }
}

- (BOOL)currentThemeIsModified {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:SETTING_CURRENT_THEME] != nil;
}

- (BOOL)themeUndoRemovesTheme {
    return self.canUndoThemeEdit && ThemeHistoryChangeRemovesTheme(_themeHistory[_themeHistoryIndex - 1]);
}

- (BOOL)themeRedoRemovesTheme {
    return self.canRedoThemeEdit && ThemeHistoryChangeRemovesTheme(_themeHistory[_themeHistoryIndex]);
}

// Deletes every custom image no stored record or history entry names. Files
// are content-addressed and shared, so run it after any write that can drop a
// last reference.
- (void)sweepUnreferencedThemeImages {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSString *identifier in [self orderedThemeIdentifiers]) {
        [records addObject:[self recordForThemeIdentifier:identifier]];
    }
    // The in-memory working record needs no read: every caller sweeps after
    // its store write, so it is already in a theme entry or the divergence key.
    NSDictionary *diverged =
            [[NSUserDefaults standardUserDefaults] dictionaryForKey:SETTING_CURRENT_THEME];
    if (diverged) {
        [records addObject:diverged];
    }
    for (NSDictionary *change in _themeHistory) {
        [records addObjectsFromArray:ThemeHistoryRecords(change)];
    }
    [AppTheme removeCustomImageFilesUnreferencedByRecords:records];
}

- (void)clearThemeHistory {
    [_themeHistory removeAllObjects];
    _themeHistoryIndex = 0;
    _themeHistoryChangedKeys = nil;
}

- (BOOL)themeHistoryChangeUsesImages:(NSDictionary *)change {
    for (NSDictionary *record in ThemeHistoryRecords(change)) {
        if ([AppTheme customImageFilesInRecord:record].count > 0) return YES;
    }
    return NO;
}

// Returns whether discarded history held images, so callers sweep only then.
- (BOOL)recordThemeChange:(NSDictionary *)before replacedBy:(NSDictionary *)after
                continuous:(BOOL)continuous atTime:(NSTimeInterval)now {
    if ([before isEqualToDictionary:after]) return NO;
    BOOL retiredImages = NO;
    while (_themeHistory.count > _themeHistoryIndex) {
        retiredImages |= [self themeHistoryChangeUsesImages:_themeHistory.lastObject];
        [_themeHistory removeLastObject];
    }
    // The theme list counts as one key, so a rename or removal never folds
    // into the drag after it.
    NSDictionary *from = before[@"working"], *to = after[@"working"];
    NSMutableSet<NSString *> *changed = [NSMutableSet set];
    for (NSString *key in [[NSSet setWithArray:from.allKeys] setByAddingObjectsFromArray:to.allKeys]) {
        if (![from[key] isEqual:to[key]]) [changed addObject:key];
    }
    if (![before[@"themes"] isEqual:after[@"themes"]]) [changed addObject:@"themes"];
    if (continuous && _themeHistoryChangedKeys && [changed isEqualToSet:_themeHistoryChangedKeys]
            && now - _themeHistoryPushTime < 2) {
        _themeHistory[_themeHistoryIndex - 1] = @{@"before": _themeHistory.lastObject[@"before"],
                                                 @"after": after};
        _themeHistoryPushTime = now;
        return retiredImages;
    }
    if (!_themeHistory) _themeHistory = [NSMutableArray array];
    [_themeHistory addObject:@{@"before": before, @"after": after}];
    if (_themeHistory.count > 50) {
        retiredImages |= [self themeHistoryChangeUsesImages:_themeHistory.firstObject];
        [_themeHistory removeObjectAtIndex:0];
    }
    _themeHistoryIndex = _themeHistory.count;
    _themeHistoryChangedKeys = changed;
    _themeHistoryPushTime = now;
    return retiredImages;
}

- (BOOL)canUndoThemeEdit {
    return _themeHistoryIndex > 0;
}

- (BOOL)canRedoThemeEdit {
    return _themeHistoryIndex < _themeHistory.count;
}

- (void)undoThemeEdit {
    [self restoreThemeHistoryForward:NO];
}

- (void)redoThemeEdit {
    [self restoreThemeHistoryForward:YES];
}

- (void)restoreThemeHistoryForward:(BOOL)forward {
    if (forward ? !self.canRedoThemeEdit : !self.canUndoThemeEdit) return;
    NSUInteger index = forward ? _themeHistoryIndex : _themeHistoryIndex - 1;
    NSDictionary *snapshot = _themeHistory[index][forward ? @"after" : @"before"];
    _themeHistoryIndex = forward ? index + 1 : index;
    // Not an edit: the next edit starts a fresh entry. No sweep: the entry
    // still holds everything this puts back.
    _themeHistoryChangedKeys = nil;
    _themeHistoryRestoring = YES;
    [self persistUserThemes:snapshot[@"themes"]];
    [self activateThemeWithIdentifier:snapshot[@"active"]];
    [self.currentTheme replaceWithRecord:snapshot[@"working"]];
    [self currentThemeDidChange];
    _themeHistoryRestoring = NO;
}

- (void)renameUserThemeWithIdentifier:(NSString *)identifier toName:(NSString *)name {
    if ([AppTheme isBuiltInIdentifier:identifier]) {
        return;
    }
    NSMutableArray<NSDictionary *> *themes = [[self storedUserThemes] mutableCopy];
    for (NSUInteger i = 0; i < themes.count; i++) {
        if (![themes[i][kVibeThemeRecordIdentifierKey] isEqualToString:identifier]) {
            continue;
        }
        NSMutableArray *otherNames = [[self allThemeDisplayNames] mutableCopy];
        [otherNames removeObject:themes[i][kVibeThemeRecordNameKey]];
        NSString *deduped = [AppTheme dedupedThemeName:name
                                              fallback:STR_THEME_NAME_CUSTOM
                                         existingNames:otherNames];
        if ([deduped isEqualToString:themes[i][kVibeThemeRecordNameKey]]) return;
        NSDictionary *working = self.currentTheme.dictionaryRepresentation;
        NSDictionary *before = ThemeStoreSnapshot([self storedUserThemes], self.activeThemeIdentifier, working);
        NSMutableDictionary *entry = [themes[i] mutableCopy];
        entry[kVibeThemeRecordNameKey] = deduped;
        themes[i] = entry;
        [self persistUserThemes:themes];
        if ([identifier isEqualToString:self.activeThemeIdentifier]) {
            if ([self recordThemeChange:before replacedBy:ThemeStoreSnapshot(themes, identifier, working)
                             continuous:NO atTime:NSDate.timeIntervalSinceReferenceDate]) {
                [self sweepUnreferencedThemeImages];
            }
        } else {
            [self clearThemeHistory];
            [self sweepUnreferencedThemeImages];
        }
        return;
    }
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

- (BOOL)appleMPEGDecoder {
    return [NSUserDefaults.standardUserDefaults boolForKey:SETTING_APPLE_MPEG_DECODER];
}

- (void)setAppleMPEGDecoder:(BOOL)apple {
    [NSUserDefaults.standardUserDefaults setBool:apple forKey:SETTING_APPLE_MPEG_DECODER];
}

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

- (BOOL)setCurrentThemeImageForKey:(NSString *)key
                 themeIdentifier:(NSString *)identifier
                            data:(NSData * _Nullable (^)(void))data
                           error:(NSError **)error {
    if (error) *error = nil;
    if (![self.activeThemeIdentifier isEqualToString:identifier]
            || [AppTheme isBuiltInIdentifier:identifier]) return NO;
    NSString *reference = [AppTheme storeCustomImageData:data() error:error];
    if (!reference) return NO;
    [self.currentTheme setImageReference:reference forKey:key];
    return YES;
}

@end
