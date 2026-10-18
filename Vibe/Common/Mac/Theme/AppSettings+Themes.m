//
//  AppSettings+Themes.m
//  Vibe
//

#import "AppSettings+Themes.h"
#import "AppSettingsInternal.h"
#import "SettingsRules.h"
#import "VibeStrings.h"

// The pre-theme window tint. Only migrateLooseAppearanceSettingsToTheme reads it.
#define SETTING_WINDOW_TINT                         @"Appearance.windowTint"
#define SETTING_WINDOW_TINT_CUSTOM_DARK             @"Appearance.windowTintCustomColorDark"
#define SETTING_WINDOW_TINT_CUSTOM_LIGHT            @"Appearance.windowTintCustomColorLight"
// What makes migrateThemeRecordsToVersion2 run once.
#define SETTING_THEME_RECORD_VERSION                @"Appearance.themeRecordVersion"
// What makes migrateThemeDisplaySettings read the built-ins' volume labels
// once. Unregistered, so a reset keeps it.
#define SETTING_BUILT_IN_VOLUME_LABELS_READ         @"Appearance.builtInVolumeLabelsRead"

@implementation AppSettings (Themes)

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

// The divergence key exists only while a built-in's working record differs
// from the built-in.
static void StoreBuiltInWorkingRecord(NSDictionary *record, NSString *builtIn) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([record isEqualToDictionary:[AppTheme builtInRecordForIdentifier:builtIn]]) {
        [defaults removeObjectForKey:SETTING_CURRENT_THEME];
    } else {
        [defaults setObject:record forKey:SETTING_CURRENT_THEME];
    }
}

// A record stored before 1.15 meant today's "frosted" by a window "solid"
// (recordUpgradedFromVersion1:). The stored version makes this run once, so a
// Solid picked since stays Solid. Raw records, so the display migration after
// it still finds their 1.14 fields.
- (void)migrateThemeRecordsToVersion2 {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults integerForKey:SETTING_THEME_RECORD_VERSION] >= kVibeThemeRecordVersion) {
        return;
    }
    NSArray *stored = [defaults arrayForKey:SETTING_USER_THEMES];
    if (stored) {
        NSMutableArray *upgraded = [NSMutableArray arrayWithCapacity:stored.count];
        for (id record in stored) {
            [upgraded addObject:[record isKindOfClass:NSDictionary.class]
                    ? [AppTheme recordUpgradedFromVersion1:record] : record];
        }
        [defaults setObject:upgraded forKey:SETTING_USER_THEMES];
    }
    NSDictionary *diverged = [defaults dictionaryForKey:SETTING_CURRENT_THEME];
    if (diverged) {
        StoreBuiltInWorkingRecord([AppTheme recordUpgradedFromVersion1:diverged], self.activeThemeIdentifier);
    }
    [defaults setInteger:kVibeThemeRecordVersion forKey:SETTING_THEME_RECORD_VERSION];
}

// The active theme's display choices become the app-wide settings, so the
// window shows what it showed before; storing every record back through the
// gate, which drops them as unknown keys, makes this run once.
- (void)migrateThemeDisplaySettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // The fields a theme record carried, and the key each became: the display
    // choices through 1.14, the volume slider's layout through 1.16.
    NSDictionary<NSString *, NSString *> *keys = @{
        @"showTimeLabels":             SETTING_SHOW_TIME_LABELS,
        @"showRemainingTime":          SETTING_SHOW_REMAINING_TIME,
        @"showStatusIcons":            SETTING_SHOW_STATUS_ICONS,
        @"showFileInfo":               SETTING_SHOW_FILE_INFO,
        @"showBPM":                    SETTING_SHOW_BPM,
        @"showKey":                    SETTING_SHOW_KEY,
        @"keyNotation":                SETTING_KEY_NOTATION,
        @"keyColorsEnabled":           SETTING_KEY_COLORS,
        @"showPlaylistNumberColumn":   SETTING_PLAYLIST_NUMBER_COLUMN,
        @"showPlaylistArtworkColumn":  SETTING_PLAYLIST_ARTWORK_COLUMN,
        @"showPlaylistDurationColumn": SETTING_PLAYLIST_DURATION_COLUMN,
        @"dockIcon":                   SETTING_DOCK_ICON,
        @"volumeLocation":             SETTING_VOLUME_LOCATION,
        @"volumeVisibility":           SETTING_VOLUME_VISIBILITY,
        @"showVolumeLabels":           SETTING_SHOW_VOLUME_LABELS,
    };
    // Every launch asks, so the common answer, nothing to carry, allocates nothing.
    NSDictionary *diverged = [defaults dictionaryForKey:SETTING_CURRENT_THEME];
    NSArray *stored = [defaults arrayForKey:SETTING_USER_THEMES];
    BOOL (^carries)(id) = ^BOOL(id record) {
        if (![record isKindOfClass:NSDictionary.class]) {
            return NO;
        }
        for (NSString *field in keys) {
            if (record[field]) {
                return YES;
            }
        }
        return NO;
    };
    BOOL carried = carries(diverged);
    for (id record in stored) {
        carried = carried || carries(record);
    }
    // Kinda Blue and Dark Wolf shipped their volume labels off through 1.16,
    // so an unedited one carries that too, once. Either picked since keeps
    // them on.
    BOOL builtInsUnread = ![defaults boolForKey:SETTING_BUILT_IN_VOLUME_LABELS_READ];
    if (!carried && !builtInsUnread) {
        return;
    }
    // The raw records: the sanitized ones have lost the fields being carried.
    NSString *active = self.activeThemeIdentifier;
    NSDictionary *working = diverged;
    for (id record in stored) {
        if (!working && [record isKindOfClass:NSDictionary.class]
                && [record[kVibeThemeRecordIdentifierKey] isEqual:active]) {
            working = record;
        }
    }
    if (!working && builtInsUnread
            && ([active isEqualToString:@"kinda_blue"] || [active isEqualToString:@"dark_wolf"])) {
        working = @{@"showVolumeLabels": @NO};
    }
    for (NSString *field in keys) {
        id value = working[field];
        if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) {
            [defaults setObject:value forKey:keys[field]];
        }
    }
    [defaults setBool:YES forKey:SETTING_BUILT_IN_VOLUME_LABELS_READ];
    if (!carried) {
        return;
    }
    [self persistUserThemes:[self storedUserThemes]];
    if (diverged) {
        StoreBuiltInWorkingRecord([AppTheme sanitizedRecord:diverged], active);
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
    return [[AppTheme builtInThemeIdentifiers] arrayByAddingObjectsFromArray:[self userThemeIdentifiers]];
}

- (NSArray<NSString *> *)userThemeIdentifiers {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
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
        StoreBuiltInWorkingRecord(record, active);
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

- (BOOL)setCurrentThemeImageForKey:(NSString *)key
                 themeIdentifier:(NSString *)identifier
                            data:(NSData *)data
                           error:(NSError **)error {
    if (error) *error = nil;
    if (![self.activeThemeIdentifier isEqualToString:identifier]
            || [AppTheme isBuiltInIdentifier:identifier]) return NO;
    NSString *reference = [AppTheme storeCustomImageData:data error:error];
    if (!reference) return NO;
    [self.currentTheme setImageReference:reference forKey:key];
    return YES;
}

@end
