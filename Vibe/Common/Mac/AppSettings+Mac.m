//
//  AppSettings+Mac.m
//  Vibe
//
//  The macOS half of the store: the mac-only keys and preset ladders, the
//  theme store, and the macOS halves of the shared entry points AppSettings.m
//  calls under TARGET_OS_OSX (AppSettingsInternal.h).
//

#import "AppSettings+Mac.h"
#import "AppSettingsInternal.h"
#import "SettingsRules.h"
#import "VibeStrings.h"
#import <AppKit/AppKit.h>

#define SETTING_WINDOW_APPEARANCE_STYLE             @"Settings.windowAppearance"
#define SETTING_AUDIO_PLAYER_DEVICE_NAME            @"AudioPlayer.deviceName"
#define SETTING_AUDIO_PLAYER_DEVICE_UID             @"AudioPlayer.deviceUID"
#define SETTING_PITCH_PANEL_SHOWN                   @"MainWindow.pitchPanelShown"
#define SETTING_PLAYLIST_SHOWN                      @"MainWindow.playlistShown"
#define SETTING_ALWAYS_ON_TOP                       @"MainWindow.alwaysOnTop"
#define SETTING_SHOW_TRAFFIC_LIGHTS                 @"Appearance.showTrafficLights"
#define SETTING_PITCH_RANGE                         @"AudioPlayer.pitchRange"
#define SETTING_SHOW_REMAINING_TIME                 @"MainWindow.showRemainingTime"
#define SETTING_SHOW_FILE_INFO                      @"MainWindow.showFileInfo"
#define SETTING_WAVEFORM_DRAG_BEHAVIOR              @"Settings.waveformDragBehavior"
#define SETTING_ARTWORK_DRAG_ACTION                 @"Settings.artworkDragAction"
#define SETTING_DELETE_ORIGINAL_AFTER_CONVERT       @"Convert.deleteOriginal"
#define SETTING_SKIP_BASE_BARS                      @"Transport.skipBaseBars"
#define SETTING_CROSSFADE_MILLISECONDS              @"AudioPlayer.crossfadeMilliseconds"
#define SETTING_PAUSE_AT_TRACK_END                  @"Transport.pauseAtTrackEnd"
#define SETTING_REOPEN_LAST_PLAYLIST                @"Playlist.reopenLast"
#define SETTING_UI_UPDATE_HZ_CAP                    @"UI.updateHzCap"
#define SETTING_AUDIO_FX_ENABLED                    @"AudioPlayer.fxEnabled"
#define SETTING_ANALYZE_BPM                         @"Audio.analyzeBPM"
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
// TRAP: the stored key is not the macro's name and must never follow a rename —
// it is a persisted NSUserDefaults key, so changing the string silently resets
// every existing user's setting to the default. It predates the folder-artwork
// → folder-art vocabulary and stays as written.
#define SETTING_FOLDER_ART                          @"Audio.folderArtwork"
#define SETTING_ACTIVE_THEME                        @"Appearance.activeTheme"
#define SETTING_USER_THEMES                         @"Appearance.userThemes"
#define SETTING_CURRENT_THEME                       @"Appearance.currentTheme"

const NSInteger kVibeSkipBasePresets[] = {4, 8, 16};
const size_t kVibeSkipBasePresetCount =
        sizeof(kVibeSkipBasePresets) / sizeof(kVibeSkipBasePresets[0]);
const NSInteger kVibeCrossfadePresets[] = {10, 500, 2000};
const size_t kVibeCrossfadePresetCount =
        sizeof(kVibeCrossfadePresets) / sizeof(kVibeCrossfadePresets[0]);
const NSInteger kVibeUIUpdateHzCapPresets[] = {3, 30, 60};
const size_t kVibeUIUpdateHzCapPresetCount =
        sizeof(kVibeUIUpdateHzCapPresets) / sizeof(kVibeUIUpdateHzCapPresets[0]);

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

@implementation AppSettings (Mac)

#pragma mark - macOS only

- (void)registerMacDefaultsInto:(NSMutableDictionary *)defaults {
    [defaults addEntriesFromDictionary:@{
            SETTING_AUDIO_PLAYER_DEVICE_NAME:       @"",
            SETTING_AUDIO_PLAYER_DEVICE_UID:        @"",
            SETTING_WINDOW_APPEARANCE_STYLE:        SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT,
            SETTING_PITCH_PANEL_SHOWN:              @(NO),
            SETTING_PLAYLIST_SHOWN:                 @(NO),
            SETTING_ALWAYS_ON_TOP:                  @(NO),
            SETTING_SHOW_TRAFFIC_LIGHTS:            @(YES),
            SETTING_PITCH_RANGE:                    @(8),
            SETTING_WAVEFORM_DRAG_BEHAVIOR:         SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW,
            SETTING_ARTWORK_DRAG_ACTION:            SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE,
            SETTING_DELETE_ORIGINAL_AFTER_CONVERT:  @(NO),
            SETTING_CONVERT_ENABLED:                @(YES),
            SETTING_SKIP_BASE_BARS:                 @(8),
            SETTING_CROSSFADE_MILLISECONDS:         @(10),
            SETTING_PAUSE_AT_TRACK_END:             @(NO),
            SETTING_REOPEN_LAST_PLAYLIST:           @(NO),
            SETTING_UI_UPDATE_HZ_CAP:               @(30),
            SETTING_AUDIO_FX_ENABLED:               @(YES),
            SETTING_ANALYZE_BPM:                    @(YES),
            SETTING_ANALYZE_KEY:                    @(NO),
            SETTING_CONVERT_ASKS_WHERE_TO_SAVE:     @(NO),
            SETTING_FOLDER_ART:                     @(YES),
            SETTING_ACTIVE_THEME:                   kVibeThemeIdentifierVibe,
    }];
}

- (void)addMacNullableSettingKeysTo:(NSMutableArray<NSString *> *)keys {
    [keys addObjectsFromArray:@[SETTING_USER_THEMES, SETTING_CURRENT_THEME]];
}

- (void)resetMacThemeState {
    _storedUserThemesCache = nil; // the disk keys were just removed
    [_currentTheme replaceWithRecord:nil];
    [self sweepUnreferencedThemeArtwork];
}

- (void)macApplicationDidFinishLaunching {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"NSQuitAlwaysKeepsWindows"];
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSFullScreenMenuItemEverywhere"];
    [NSApplication sharedApplication].automaticCustomizeTouchBarMenuItemEnabled = NO;
}

#pragma mark Themes

// The pre-theme loose appearance settings, keyed by their AppTheme field
// names. One-time: any stored active-theme key means it already ran, and a
// successful run writes one. Runs before registerDefaults — the decision
// keys on "no stored value" — and consumes the loose keys it migrates,
// shared-named waveform keys included: this is the Mac store, and iOS is a
// separate app over a separate one.
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

// A stored user-theme entry is its sparse record plus id and name, flat —
// the same shape a theme JSON carries, minus the version.
static NSDictionary *UserThemeEntry(NSDictionary *record, NSString *identifier, NSString *name) {
    NSMutableDictionary *entry = [record mutableCopy];
    entry[kVibeThemeRecordIdentifierKey] = identifier;
    entry[kVibeThemeRecordNameKey] = name;
    return entry;
}

// Sanitized on read: an entry without a usable id and name is dropped, and
// every entry's fields go back through AppTheme's gate, so an external
// defaults write cannot smuggle in what an import would refuse. Memoized —
// the sanitize pass costs a full record walk per theme and every identity
// query funnels here. persistUserThemes: — the one RUNTIME writer; the
// one-time migration above writes the key directly, before this memo can
// have populated — installs what it wrote rather than dropping it: every
// caller hands it entries built from this list and AppTheme's own output, so
// they are already through the gate (no CLI-side verb writes this key, so
// the cross-process prefs trap in Common/CLAUDE.md does not reach it).
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

// An identifier naming no built-in and no stored user theme — a deleted
// theme, an external write — snaps to vibe.
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
    // A built-in's English name travels in its bundled JSON; the hand-managed
    // ThemeNames catalog (keyed by identifier) overlays a translation where
    // one exists, so a theme added by pull request needs no code and no
    // catalog entry to ship.
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
    // One store fetch for every user name, not one per identifier.
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
        // Already through the gate in storedUserThemes; strip the entry keys.
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

- (void)applyThemeWithIdentifier:(NSString *)identifier {
    NSString *resolved = [self resolvedThemeIdentifier:identifier];
    [self.currentTheme replaceWithRecord:[self recordForThemeIdentifier:resolved]];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:resolved forKey:SETTING_ACTIVE_THEME];
    [defaults removeObjectForKey:SETTING_CURRENT_THEME];
    // Dropping the divergence record can drop the last reference to a custom
    // image picked while a built-in was active.
    [self sweepUnreferencedThemeArtwork];
}

- (void)currentThemeDidChange {
    if (!_currentTheme) {
        return;
    }
    NSDictionary *record = _currentTheme.dictionaryRepresentation;
    NSString *active = self.activeThemeIdentifier;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // What this write replaces: the divergence record or the entry. Its
    // artwork references against the new record's decide the sweep below,
    // so a replaced or cleared placeholder image cannot strand its file —
    // and a color drag, which changes no reference, never lists the
    // container.
    NSDictionary *previous = [defaults dictionaryForKey:SETTING_CURRENT_THEME];
    if ([AppTheme isBuiltInIdentifier:active]) {
        previous = previous ?: [AppTheme builtInRecordForIdentifier:active];
        // A built-in stays pristine; the working record carries the
        // divergence, and only while there is one.
        if ([record isEqualToDictionary:[AppTheme builtInRecordForIdentifier:active]]) {
            [defaults removeObjectForKey:SETTING_CURRENT_THEME];
        } else {
            [defaults setObject:record forKey:SETTING_CURRENT_THEME];
        }
    } else {
        // A user theme IS its working state: the record lands in the entry,
        // from the same dictionary, so the two cannot drift.
        NSMutableArray<NSDictionary *> *themes = [[self storedUserThemes] mutableCopy];
        for (NSUInteger i = 0; i < themes.count; i++) {
            if ([themes[i][kVibeThemeRecordIdentifierKey] isEqualToString:active]) {
                previous = previous ?: themes[i];
                themes[i] = UserThemeEntry(record, active, themes[i][kVibeThemeRecordNameKey]);
                break;
            }
        }
        [self persistUserThemes:themes];
        [defaults removeObjectForKey:SETTING_CURRENT_THEME];
    }
    if (![[AppTheme customArtworkFilesInRecord:previous]
            isEqualToSet:[AppTheme customArtworkFilesInRecord:record]]) {
        [self sweepUnreferencedThemeArtwork];
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
    return identifier;
}

- (NSString *)duplicateThemeWithIdentifier:(NSString *)identifier {
    NSString *name = [self displayNameForThemeIdentifier:identifier];
    if (!name) {
        return nil;
    }
    return [self addUserThemeWithRecord:[self recordForThemeIdentifier:identifier] name:name];
}

- (void)removeUserThemeWithIdentifier:(NSString *)identifier
                        fallingBackTo:(NSString *)successor {
    if ([AppTheme isBuiltInIdentifier:identifier]) {
        return;
    }
    BOOL wasActive = [[self activeThemeIdentifier] isEqualToString:identifier];
    NSMutableArray<NSDictionary *> *themes = [NSMutableArray array];
    for (NSDictionary *entry in [self storedUserThemes]) {
        if (![entry[kVibeThemeRecordIdentifierKey] isEqualToString:identifier]) {
            [themes addObject:entry];
        }
    }
    [self persistUserThemes:themes];
    if (wasActive) {
        // The apply sweeps; the successor resolves to vibe when it names
        // nothing, the removed theme itself included.
        [self applyThemeWithIdentifier:successor ?: kVibeThemeIdentifierVibe];
    } else {
        [self sweepUnreferencedThemeArtwork];
    }
}

// Deletes every stored custom placeholder image no record names any more.
// The files are content-hash-named and shared by reference
// (AppTheme.storeCustomArtworkData:), so each store write that can drop the
// last reference — the field funnel when its artwork keys move, a theme
// removal, a theme apply (it drops the divergence record), a factory reset —
// runs this after its write.
- (void)sweepUnreferencedThemeArtwork {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSString *identifier in [self orderedThemeIdentifiers]) {
        [records addObject:[self recordForThemeIdentifier:identifier]];
    }
    // The persisted divergence record can name an image no theme's own record
    // holds. The in-memory working record needs no read of its own: every
    // caller sweeps after its store write, by which point that record has
    // landed in a theme entry or the divergence key.
    NSDictionary *diverged =
            [[NSUserDefaults standardUserDefaults] dictionaryForKey:SETTING_CURRENT_THEME];
    if (diverged) {
        [records addObject:diverged];
    }
    [AppTheme removeCustomArtworkFilesUnreferencedByRecords:records];
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
        NSMutableDictionary *entry = [themes[i] mutableCopy];
        entry[kVibeThemeRecordNameKey] = deduped;
        themes[i] = entry;
        [self persistUserThemes:themes];
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

#pragma mark Window

// The default is Auto — the window follows the OS. The pre-theme app pinned
// dark by default; themes made the adaptive factory look the product's
// default instead.
- (NSString *)windowAppearanceStyle {
    return [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_WINDOW_APPEARANCE_STYLE];
}

- (void)setWindowAppearanceStyle:(NSString *)name {
    // An explicit choice ends any preview, so it cannot land under one and
    // read as ignored.
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
    // A single-mode theme's one look outranks both the stored style and the
    // preview; folded in here so every reader of the answer gets the pin.
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
    // Auto: a nil window appearance tracks the OS light/dark setting.
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

- (BOOL)showTrafficLights {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_SHOW_TRAFFIC_LIGHTS];
}

- (void)setShowTrafficLights:(BOOL)show {
    [[NSUserDefaults standardUserDefaults] setBool:show forKey:SETTING_SHOW_TRAFFIC_LIGHTS];
}

#pragma mark Header labels


// Not cached: read once per mouse-down on the waveform, not per frame.
- (NSString *)waveformDragBehavior {
    return VibeNormalizedWaveformDragBehavior(
            [[NSUserDefaults standardUserDefaults] stringForKey:SETTING_WAVEFORM_DRAG_BEHAVIOR]);
}

- (void)setWaveformDragBehavior:(NSString *)behavior {
    [[NSUserDefaults standardUserDefaults] setObject:behavior forKey:SETTING_WAVEFORM_DRAG_BEHAVIOR];
}

// Not cached: read once per drag start on the artwork, not per frame.
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

- (BOOL)reopenLastPlaylist {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_REOPEN_LAST_PLAYLIST];
}

- (void)setReopenLastPlaylist:(BOOL)reopen {
    [[NSUserDefaults standardUserDefaults] setBool:reopen forKey:SETTING_REOPEN_LAST_PLAYLIST];
}

// Read on every live-resize frame through syncUITimerRate; a CFPreferences
// lookup is cheap enough uncached.
- (NSInteger)uiUpdateHzCap {
    NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:SETTING_UI_UPDATE_HZ_CAP];
    return VibeNearestPreset(stored, kVibeUIUpdateHzCapPresets, kVibeUIUpdateHzCapPresetCount);
}

- (void)setUiUpdateHzCap:(NSInteger)hz {
    [[NSUserDefaults standardUserDefaults] setInteger:hz forKey:SETTING_UI_UPDATE_HZ_CAP];
}

- (BOOL)audioFXEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:SETTING_AUDIO_FX_ENABLED];
}

- (void)setAudioFXEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:SETTING_AUDIO_FX_ENABLED];
}

#pragma mark Analysis and the key label

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
