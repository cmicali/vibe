//
//  SettingsThemesViewController+EditorActions.m
//  Vibe
//
//  The editor page's state and actions: the layout and the refresh from the
//  active theme, and the targets of its rows. +Editor.m builds the rows.
//

#import "SettingsThemesViewController+Editor.h"
#import "SettingsThemesViewControllerInternal.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "Fonts.h"
#import "NSImage+Util.h"
#import "SettingsRules.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"

// An unset button image slot's glyph, at the transport row's glyph size.
static const CGFloat kImagePreviewGlyphPointSize = 31;

static BOOL IsEitherSide(NSString *key, NSString *dark, NSString *light) {
    return [key isEqualToString:dark] || [key isEqualToString:light];
}

@implementation SettingsThemesViewController (EditorActions)

#pragma mark - Transport buttons: the theme's fields by button

- (BOOL)buttonHasImageForKey:(NSString *)key {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    for (NSString *imageKey in [AppTheme imageKeysForButton:key]) {
        if ([theme imageReferenceForKey:imageKey].length) {
            return YES;
        }
    }
    return NO;
}

// The glyph an image slot stands in for: the pause state's for the pause
// slots, its button's for every other.
- (NSString *)glyphForImageKey:(NSString *)key {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if (IsEitherSide(key, kVibeThemeImagePauseButtonDark, kVibeThemeImagePauseButtonLight)) {
        return theme.pauseButtonGlyph;
    }
    if (IsEitherSide(key, kVibeThemeImagePlayButtonDark, kVibeThemeImagePlayButtonLight)) {
        return theme.playButtonGlyph;
    }
    if (IsEitherSide(key, kVibeThemeImageNextButtonDark, kVibeThemeImageNextButtonLight)) {
        return theme.nextButtonGlyph;
    }
    return theme.playlistButtonGlyph;
}

// The popup's selection from the theme: Custom image while the button has
// one, else its glyph.
- (void)selectGlyphChoiceForButtonImageKey:(NSString *)key {
    NSPopUpButton *popUp = _glyphPopUps[key];
    if ([self buttonHasImageForKey:key]) {
        popUp.itemArray.firstObject.hidden = YES;
        [self selectValue:kGlyphChoiceCustomImage in:popUp];
        return;
    }
    [self selectGlyph:[self glyphForImageKey:key] in:popUp];
}

// Item 0 is dressed as a stored glyph the menu does not list, a
// JSON-authored one, so the popup never shows nothing.
- (void)selectGlyph:(NSString *)glyph in:(NSPopUpButton *)popUp {
    NSMenuItem *unlisted = popUp.itemArray.firstObject;
    unlisted.hidden = YES;
    [self selectValue:glyph in:popUp];
    if (popUp.indexOfSelectedItem < 0) {
        unlisted.title = @"";
        unlisted.toolTip = VibeNotLocalized(glyph);
        unlisted.representedObject = glyph;
        unlisted.image = [NSImage imageWithSystemSymbolName:glyph accessibilityDescription:nil];
        [popUp selectItem:unlisted];
    }
    unlisted.hidden = popUp.selectedItem != unlisted;
}

// The glyph a slot previews when neither side of its pair has a picture,
// built once per name: the palette is a constant and refresh runs often.
static NSImage *PreviewGlyphImage(NSString *glyph) {
    static NSMutableDictionary<NSString *, NSImage *> *images;
    if (!images) {
        images = [NSMutableDictionary dictionary];
    }
    NSImage *image = images[glyph];
    if (!image) {
        image = [NSImage symbolNamed:glyph pointSize:kImagePreviewGlyphPointSize
                              weight:NSFontWeightRegular palette:@[NSColor.secondaryLabelColor]
            accessibilityDescription:nil];
        images[glyph] = image;
    }
    return image;
}

// The app icon is whatever the application holds, since the AppIcon effect
// has landed by refresh time. A button slot shows its picture, else the other
// side's, else the glyph.
- (NSImage *)previewImageForKey:(NSString *)key {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if ([key isEqualToString:kVibeThemeImageAppIcon]) {
        return NSApp.applicationIconImage;
    }
    if ([key isEqualToString:kVibeThemeImageDefaultArtworkDark]
            || [key isEqualToString:kVibeThemeImageDefaultArtworkLight]) {
        return [AppTheme imageForReference:[theme imageReferenceForKey:key]];
    }
    return [theme buttonImageForKey:key] ?: PreviewGlyphImage([self glyphForImageKey:key]);
}

#pragma mark - State

- (void)resolveLayoutStateFromSettings {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL builtIn = [AppTheme isBuiltInIdentifier:
            AppSettings.sharedInstance.activeThemeIdentifier];
    [_nameRow setCaption:builtIn ? STR_SETTINGS_THEME_BUILT_IN_COPY_CAPTION : nil];
    BOOL single = theme.isSingleMode;
    [_windowTintDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                           : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_defaultArtworkDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                               : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_defaultArtworkGlyphDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                                    : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_playlistTintDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                             : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_volumeBarDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                           : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_volumeKnobDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                           : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_customDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLORS_LABEL
                                       : STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL];
    [_bandsDarkRow setRowTitle:single ? STR_SETTINGS_THEME_WAVEFORM_COLOR
                                      : STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL];
    for (NSStackView *pair in _darkLightPairs) {
        NSArray<NSView *> *views = pair.arrangedSubviews; // well, caption, well, caption
        views[1].hidden = single;
        views[2].hidden = single;
        views[3].hidden = single;
    }
    _waveformTypeRow.hidden = [WaveformRendererRegistry typeIdentifiersForIdentifier:
            [WaveformRendererRegistry resolveStyleIdentifier:theme.waveformStyle]].count == 0;
    VibeWaveformPaletteKind kind = [WaveformRendererRegistry paletteKindForIdentifier:theme.waveformStyle];
    BOOL bandWells = kind == VibeWaveformPaletteKindBands ||
            (kind == VibeWaveformPaletteKindSpectrum &&
             [theme.waveformSpectrumPalette isEqualToString:SETTINGS_VALUE_WAVEFORM_SPECTRUM_PALETTE_CUSTOM]);
    BOOL customTheme = kind == VibeWaveformPaletteKindTheme &&
            [theme.waveformTheme isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    _waveformThemeRow.hidden = kind != VibeWaveformPaletteKindTheme;
    _spectrumPaletteRow.hidden = kind != VibeWaveformPaletteKindSpectrum;
    _customDarkRow.hidden = !customTheme;
    _customLightRow.hidden = !customTheme || single;
    _bandsDarkRow.hidden = !bandWells;
    _bandsLightRow.hidden = !bandWells || single;
    _shadeOverlapsRow.hidden = kind != VibeWaveformPaletteKindBands;
    _playheadColorsRow.hidden = !theme.waveformPlayheadLine;
    BOOL customTint = [theme.windowTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    _windowTintDarkRow.hidden = !customTint;
    _windowTintLightRow.hidden = !customTint || single;
    BOOL customArt = [theme.defaultArtwork isEqualToString:SETTINGS_VALUE_DEFAULT_ARTWORK_CUSTOM];
    BOOL glyphArt = [theme.defaultArtwork isEqualToString:SETTINGS_VALUE_DEFAULT_ARTWORK_GLYPH];
    _defaultArtworkImageRow.hidden = ![theme.defaultArtwork isEqualToString:SETTINGS_VALUE_DEFAULT_ARTWORK_ARTWORK];
    _defaultArtworkDarkRow.hidden = !customArt;
    _defaultArtworkLightRow.hidden = !customArt || single;
    _defaultArtworkGlyphRow.hidden = !glyphArt;
    _defaultArtworkGlyphSizeRow.hidden = !glyphArt;
    _defaultArtworkGlyphDarkRow.hidden = !glyphArt;
    _defaultArtworkGlyphLightRow.hidden = !glyphArt || single;
    _backgroundColorsRow.hidden = !VibeWindowBackgroundTakesColor(theme.windowBackgroundStyle);
    BOOL customPlaylistTint = [theme.playlistTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    _playlistTintDarkRow.hidden = !customPlaylistTint;
    _playlistTintLightRow.hidden = !customPlaylistTint || single;
    _playlistBackgroundColorsRow.hidden = ![theme.playlistBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    BOOL customVolumeBar = [theme.volumeBar isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    _volumeBarDarkRow.hidden = !customVolumeBar;
    _volumeBarLightRow.hidden = !customVolumeBar || single;
    BOOL customVolumeKnob = [theme.volumeKnob isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    _volumeKnobDarkRow.hidden = !customVolumeKnob;
    _volumeKnobLightRow.hidden = !customVolumeKnob || single;
    for (NSString *base in _playlistColorPairs) {
        _playlistColorPairs[base].hidden = ![theme playlistColorEnabledForBase:base];
    }
    _cornerRadiusCluster.hidden = !theme.customCornerRadius;
    for (NSString *key in _glyphPopUps) {
        BOOL hasImage = [self buttonHasImageForKey:key];
        _buttonColorRows[key].hidden = hasImage;
        for (SettingsRowView *row in _buttonImageRows[key]) {
            row.hidden = !hasImage;
        }
    }
    [self applyEditorVisibility];
}

static void ForEachDescendantView(NSView *view, void (^block)(NSView *)) {
    for (NSView *subview in view.subviews) {
        block(subview);
        ForEachDescendantView(subview, block);
    }
}

- (void)refreshEditorFromSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;
    NSString *active = settings.activeThemeIdentifier;
    // A refresh mid-type (menu tracking, regaining key) must not discard the
    // edit, unless the active theme changed under it: then drop it rather
    // than commit it onto the wrong theme.
    if (_nameField.currentEditor != nil &&
        ![active isEqualToString:_nameFieldThemeIdentifier]) {
        [_nameField abortEditing];
    }
    if (_nameField.currentEditor == nil) {
        _nameField.stringValue = [settings displayNameForThemeIdentifier:active] ?: @"";
        _nameFieldThemeIdentifier = active;
    }

    [self selectValue:theme.mode in:_modePopUp];
    _appIconShapeSwitch.state = StateForBOOL(theme.appIconShape);
    [self selectValue:theme.windowBackgroundStyle in:_backgroundPopUp];
    [self selectValue:theme.windowTint in:_windowTintPopUp];
    [self selectValue:theme.defaultArtwork in:_defaultArtworkPopUp];
    [self selectGlyph:theme.defaultArtworkGlyph in:_defaultArtworkGlyphPopUp];
    [self refreshDefaultArtworkGlyphSize];
    for (NSColorWell *well in _wellBindings) {
        NSDictionary *binding = [_wellBindings objectForKey:well];
        well.color = [theme displayColorForBase:binding[kWellBase] dark:[binding[kWellDark] boolValue]];
    }
    [self selectValue:(theme.customCornerRadius ? SETTINGS_VALUE_WINDOW_TINT_CUSTOM : kChoiceStandard) in:_cornerRadiusPopUp];
    _cornerRadiusSlider.doubleValue = theme.windowCornerRadius;
    [self refreshCornerRadiusValue];
    for (NSString *key in _glyphPopUps) {
        [self selectGlyphChoiceForButtonImageKey:key];
    }
    [self selectValue:theme.buttonGradient in:_buttonGradientPopUp];

    _transportButtonsSwitch.state = StateForBOOL(theme.showTransportButtons);

    [self selectWaveformStyle:theme.waveformStyle in:_waveformPopUp];
    NSString *style = [WaveformRendererRegistry resolveStyleIdentifier:theme.waveformStyle];
    [_waveformTypePopUp removeAllItems];
    for (NSString *type in [WaveformRendererRegistry typeIdentifiersForIdentifier:style]) {
        [self addItem:[WaveformRendererRegistry typeDisplayNameForIdentifier:type] value:type to:_waveformTypePopUp];
    }
    [self selectValue:style in:_waveformTypePopUp];
    [self refreshWaveformBarSizing];
    [self selectValue:theme.waveformTheme in:_waveformThemePopUp];
    [self selectValue:theme.waveformSpectrumPalette in:_spectrumPalettePopUp];
    _waveformShadeOverlapsSwitch.state = StateForBOOL(theme.waveformShadeOverlaps);
    _waveformGradientSwitch.state = StateForBOOL(theme.waveformGradient);
    _waveformCenteredSwitch.state = StateForBOOL(theme.waveformCentered);
    _waveformPlayheadSwitch.state = StateForBOOL(theme.waveformPlayheadLine);
    for (NSString *key in AppTheme.imageFieldKeys) {
        _imagePreviews[key].image = [self previewImageForKey:key];
        _imageClearBadges[key].hidden = YES;
        _imageMissingBadges[key].hidden =
                ![AppTheme referenceIsMissing:[theme imageReferenceForKey:key]];
    }
    for (NSString *base in _playlistColorPopUps) {
        [self selectValue:([theme playlistColorEnabledForBase:base] ? SETTINGS_VALUE_WINDOW_TINT_CUSTOM : kChoiceStandard)
                       in:_playlistColorPopUps[base]];
    }
    [self selectValue:theme.playlistBackgroundStyle in:_playlistBackgroundPopUp];
    [self selectValue:theme.playlistTint in:_playlistTintPopUp];
    [self selectValue:theme.volumeBar in:_volumeBarPopUp];
    [self selectValue:theme.volumeKnob in:_volumeKnobPopUp];
    _volumeLabelsSwitch.state = StateForBOOL(theme.showVolumeLabels);
    [self selectValue:theme.volumeLocation in:_volumeLocationPopUp];
    [self selectValue:theme.volumeVisibility in:_volumeVisibilityPopUp];

    [self refreshFontValueLabels];

    [SettingsRowView setControlsInView:_transportSection enabled:theme.showTransportButtons];
    [SettingsRowView setControl:_transportButtonsSwitch enabled:YES];
    [SettingsRowView setControl:_waveformBarDensitySlider
            enabled:[WaveformRendererRegistry supportsBarDensityForIdentifier:style]];
    [SettingsRowView setControl:_waveformBarWidthSlider
            enabled:[WaveformRendererRegistry supportsBarWidthForIdentifier:style]];
    [SettingsRowView setControl:_waveformCenteredSwitch
            enabled:[WaveformRendererRegistry supportsCenteringForIdentifier:style]];
    [SettingsRowView setControl:_waveformGradientSwitch
            enabled:[WaveformRendererRegistry supportsGradientForIdentifier:style]];
}

- (void)refreshFontValueLabels {
    NSDictionary<NSNumber *, NSTextField *> *labels = @{
        @(VibeFontSlotTitle): _titleFontValue,
        @(VibeFontSlotArtist): _artistFontValue,
        @(VibeFontSlotInfo): _infoFontValue,
        @(VibeFontSlotPlaylist): _playlistFontValue,
        @(VibeFontSlotPlaylistDuration): _playlistDurationFontValue,
    };
    for (NSNumber *slot in labels) {
        NSFont *font = [Fonts fontForSlot:slot.integerValue bold:NO];
        labels[slot].stringValue = [NSString stringWithFormat:STR_SETTINGS_THEME_FONT_VALUE,
                font.displayName, (long)lround(font.pointSize)];
    }
}

#pragma mark - Editor: mode and color wells

// Every consumer's color slot moves with the mode, so the whole theme re-applies.
- (void)themeModeChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.mode =
            _modePopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings]; // ends in resolveLayoutStateFromSettings
}

// Writes each well's displayed color into its slot, so a revealed pair
// matches the surface at once. Dark FIRST: under single mode both sides
// canonicalize to the dark-keyed slot, which must take the dark default.
- (void)seedWellsIn:(NSArray<NSView *> *)containers {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    NSMutableArray<NSDictionary *> *bindings = [NSMutableArray array];
    for (NSView *container in containers) {
        ForEachDescendantView(container, ^(NSView *subview) {
            NSDictionary *binding = [subview isKindOfClass:NSColorWell.class]
                    ? [self->_wellBindings objectForKey:(NSColorWell *)subview] : nil;
            if (binding) {
                [bindings addObject:binding];
            }
        });
    }
    for (int darkPass = 1; darkPass >= 0; darkPass--) {
        for (NSDictionary *binding in bindings) {
            BOOL isDark = [binding[kWellDark] boolValue];
            if (isDark == (darkPass == 1)) {
                NSString *base = binding[kWellBase];
                [theme setColor:[theme displayColorForBase:base dark:isDark] forBase:base dark:isDark];
            }
        }
    }
}

- (void)colorWellChanged:(NSColorWell *)sender {
    NSDictionary *binding = [_wellBindings objectForKey:sender];
    [AppSettings.sharedInstance.currentTheme setColor:sender.color forBase:binding[kWellBase]
                                                 dark:[binding[kWellDark] boolValue]];
    [self themeFieldDidChange:(VibeSettingsLiveEffect)[binding[kWellEffect] unsignedIntegerValue]
                   continuous:YES];
}

// Every popup that reveals color rows: the revealing choice seeds its wells
// first, so the surface matches what they show. nil reveals nothing.
- (void)chooseFromPopUp:(NSPopUpButton *)popUp revealing:(NSString *)revealing
                  wells:(NSArray<NSView *> *)rows effect:(VibeSettingsLiveEffect)effect
                  write:(void (^)(AppTheme *theme, NSString *identifier))write {
    NSString *identifier = popUp.selectedItem.representedObject;
    if (revealing && [identifier isEqualToString:revealing]) {
        [self seedWellsIn:rows];
    }
    write(AppSettings.sharedInstance.currentTheme, identifier);
    [self themeFieldDidChange:effect];
    [self resolveLayoutStateFromSettings];
}

#pragma mark - Editor: window

- (void)backgroundStyleChanged:(id)sender {
    // Frosted and solid share the color pair, so either reveals it.
    NSString *chosen = _backgroundPopUp.selectedItem.representedObject;
    [self chooseFromPopUp:_backgroundPopUp revealing:VibeWindowBackgroundTakesColor(chosen) ? chosen : nil
                    wells:@[_backgroundColorsRow] effect:VibeSettingsLiveEffectWindowChrome
                    write:^(AppTheme *theme, NSString *identifier) { theme.windowBackgroundStyle = identifier; }];
}

- (void)windowTintChanged:(id)sender {
    [self chooseFromPopUp:_windowTintPopUp revealing:SETTINGS_VALUE_WINDOW_TINT_CUSTOM
                    wells:@[_windowTintDarkRow, _windowTintLightRow] effect:VibeSettingsLiveEffectWindowTint
                    write:^(AppTheme *theme, NSString *identifier) { theme.windowTint = identifier; }];
}

// Window moves the header's panel under the art, which is chrome.
- (void)defaultArtworkChanged:(id)sender {
    [self chooseFromPopUp:_defaultArtworkPopUp revealing:SETTINGS_VALUE_DEFAULT_ARTWORK_CUSTOM
                    wells:@[_defaultArtworkDarkRow, _defaultArtworkLightRow]
                   effect:VibeThemeImageEditEffect(kVibeThemeImageDefaultArtworkDark) | VibeSettingsLiveEffectWindowChrome
                    write:^(AppTheme *theme, NSString *identifier) { theme.defaultArtwork = identifier; }];
}

- (void)defaultArtworkGlyphChanged:(NSPopUpButton *)sender {
    AppSettings.sharedInstance.currentTheme.defaultArtworkGlyph = sender.selectedItem.representedObject;
    [self themeFieldDidChange:VibeThemeImageEditEffect(kVibeThemeImageDefaultArtworkDark)];
    [self refreshFromSettings];
}

- (void)defaultArtworkGlyphSizeChanged:(NSSlider *)sender {
    double size = round(sender.doubleValue * 100) / 100;
    if (fabs(size - kVibeThemeDefaultArtworkGlyphSizeDefault) < 0.04) {
        size = kVibeThemeDefaultArtworkGlyphSizeDefault;
    }
    AppSettings.sharedInstance.currentTheme.defaultArtworkGlyphSize = size;
    [self refreshDefaultArtworkGlyphSize];
    [self themeFieldDidChange:VibeThemeImageEditEffect(kVibeThemeImageDefaultArtworkDark) continuous:YES];
}

- (void)refreshDefaultArtworkGlyphSize {
    double size = AppSettings.sharedInstance.currentTheme.defaultArtworkGlyphSize;
    _defaultArtworkGlyphSizeSlider.doubleValue = size;
    _defaultArtworkGlyphSizeValue.stringValue = [NSNumberFormatter
            localizedStringFromNumber:@(size) numberStyle:NSNumberFormatterPercentStyle];
}

- (void)cornerRadiusModeChanged:(NSPopUpButton *)sender {
    [self chooseFromPopUp:sender revealing:nil wells:@[] effect:VibeSettingsLiveEffectWindowChrome
                    write:^(AppTheme *theme, NSString *identifier) {
        theme.customCornerRadius = [identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    }];
}

- (void)cornerRadiusChanged:(id)sender {
    // The sanitize gate rounds to whole points; the knob re-syncs to it.
    double radius = _cornerRadiusSlider.doubleValue;
    if (fabs(radius - kVibeThemeCornerRadiusDefault) < 1.5) {
        radius = kVibeThemeCornerRadiusDefault;
    }
    AppSettings.sharedInstance.currentTheme.windowCornerRadius = radius;
    _cornerRadiusSlider.doubleValue = AppSettings.sharedInstance.currentTheme.windowCornerRadius;
    [self refreshCornerRadiusValue];
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowChrome continuous:YES];
}

- (void)refreshCornerRadiusValue {
    _cornerRadiusValue.stringValue = [NSString stringWithFormat:STR_SETTINGS_THEME_CORNER_RADIUS_VALUE,
            (long)lround(AppSettings.sharedInstance.currentTheme.windowCornerRadius)];
}

#pragma mark - Editor: images

// Read live: the value, the page and the enable state may have changed.
- (void)mouseEntered:(NSEvent *)event {
    NSString *key = event.trackingArea.userInfo[@"imageField"];
    if (!key) {
        return;
    }
    _imageClearBadges[key].hidden = !_imagePreviews[key].enabled
            || [AppSettings.sharedInstance.currentTheme imageReferenceForKey:key].length == 0;
}

- (void)mouseExited:(NSEvent *)event {
    NSString *key = event.trackingArea.userInfo[@"imageField"];
    if (key) {
        _imageClearBadges[key].hidden = YES;
    }
}

- (void)clearCustomImage:(NSButton *)sender {
    NSString *key = sender.identifier;
    [_imagePickTokens removeObjectForKey:key];
    [AppSettings.sharedInstance.currentTheme setImageReference:@"" forKey:key];
    [self themeFieldDidChange:VibeThemeImageEditEffect(key)];
    [self refreshFromSettings]; // hides the badge, though the cursor is still over it
}

- (void)chooseImage:(NSButton *)sender {
    [self chooseImageForKey:sender.identifier];
}

- (void)chooseImageForKey:(NSString *)key {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[UTTypeJPEG, UTTypePNG];
    // View > Theme can switch the active theme under the sheet.
    NSString *target = AppSettings.sharedInstance.activeThemeIdentifier;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result != NSModalResponseOK || !panel.URL) {
            // A glyph popup left on Custom image… re-selects its glyph.
            [self refreshFromSettings];
            return;
        }
        // Read off main: the picked file can sit on a share or in iCloud.
        NSURL *url = panel.URL;
        id token = [NSObject new];
        self->_imagePickTokens[key] = token;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:NULL];
            run_on_main_thread({
                [self storePickedImageData:data forKey:key target:target token:token];
            });
        });
    }];
}

// `target` is the theme active when the panel opened. TRAP: the slot can
// change while the file reads. A pick, a clear or a glyph made since then
// wins, and this one stores nothing.
- (void)storePickedImageData:(NSData *)data forKey:(NSString *)key target:(NSString *)target token:(id)token {
    if (_imagePickTokens[key] != token) {
        return;
    }
    [_imagePickTokens removeObjectForKey:key];
    NSError *error = nil;
    NSString *destination = target;
    if ([destination isEqualToString:AppSettings.sharedInstance.activeThemeIdentifier]
            && [self forkBuiltInForEdit]) {
        destination = AppSettings.sharedInstance.activeThemeIdentifier;
    }
    BOOL stored = [AppSettings.sharedInstance setCurrentThemeImageForKey:key
            themeIdentifier:destination data:data error:&error];
    if (!stored) {
        [self refreshFromSettings];
        if (!error) return; // a theme switch superseded the picker
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = STR_SETTINGS_THEME_ALBUM_ART_INVALID;
        alert.informativeText = STR_SETTINGS_THEME_ALBUM_ART_REQUIREMENTS;
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
        return;
    }
    [self themeFieldDidChange:VibeThemeImageEditEffect(key)];
    [self refreshFromSettings];
}

#pragma mark - Editor: transport buttons

// A glyph pick retires the button's picture, which would otherwise win.
- (void)buttonGlyphChanged:(NSPopUpButton *)sender {
    NSString *key = sender.identifier;
    NSString *choice = sender.selectedItem.representedObject;
    if ([choice isEqualToString:kGlyphChoiceCustomImage]) {
        [self chooseImageForKey:key];
        return;
    }
    // The glyph retires the button's pictures, picks still reading included.
    [_imagePickTokens removeObjectsForKeys:[AppTheme imageKeysForButton:key]];
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    [theme setGlyph:choice forButtonImageKey:key];
    [self themeFieldDidChange:VibeSettingsLiveEffectTransportButtons];
    [self refreshFromSettings];
}

- (void)buttonGradientChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.buttonGradient =
            _buttonGradientPopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectTransportButtons];
}

#pragma mark - Editor: volume slider

- (void)volumeBarChanged:(id)sender {
    [self chooseFromPopUp:_volumeBarPopUp revealing:SETTINGS_VALUE_WINDOW_TINT_CUSTOM
                    wells:@[_volumeBarDarkRow, _volumeBarLightRow] effect:VibeSettingsLiveEffectVolume
                    write:^(AppTheme *theme, NSString *identifier) { theme.volumeBar = identifier; }];
}

- (void)volumeKnobChanged:(id)sender {
    [self chooseFromPopUp:_volumeKnobPopUp revealing:SETTINGS_VALUE_WINDOW_TINT_CUSTOM
                    wells:@[_volumeKnobDarkRow, _volumeKnobLightRow] effect:VibeSettingsLiveEffectVolume
                    write:^(AppTheme *theme, NSString *identifier) { theme.volumeKnob = identifier; }];
}

- (void)volumeLocationChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.volumeLocation = _volumeLocationPopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectVolume];
}

- (void)volumeVisibilityChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.volumeVisibility = _volumeVisibilityPopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectVolume];
}

#pragma mark - Editor: waveform

- (void)waveformBarSizingChanged:(NSSlider *)sender {
    double scale = round(sender.doubleValue * 100) / 100;
    if (fabs(scale - kVibeThemeWaveformBarScaleDefault) < 0.08) {
        scale = kVibeThemeWaveformBarScaleDefault;
    }
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if (sender == _waveformBarWidthSlider) theme.waveformBarWidth = scale;
    else theme.waveformBarDensity = scale;
    [self refreshWaveformBarSizing];
    [self themeFieldDidChange:VibeSettingsLiveEffectWaveformStyle continuous:YES];
}

- (void)refreshWaveformBarSizing {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    _waveformBarDensitySlider.doubleValue = theme.waveformBarDensity;
    _waveformBarWidthSlider.doubleValue = theme.waveformBarWidth;
    _waveformBarDensityValue.stringValue = [NSNumberFormatter
            localizedStringFromNumber:@(theme.waveformBarDensity)
            numberStyle:NSNumberFormatterPercentStyle];
    _waveformBarWidthValue.stringValue = [NSNumberFormatter
            localizedStringFromNumber:@(theme.waveformBarWidth)
            numberStyle:NSNumberFormatterPercentStyle];
}

- (void)waveformTypeChanged:(id)sender {
    [self chooseFromPopUp:_waveformTypePopUp revealing:nil wells:@[] effect:VibeSettingsLiveEffectWaveformStyle
                    write:^(AppTheme *theme, NSString *identifier) { theme.waveformStyle = identifier; }];
}

- (void)waveformThemeChanged:(id)sender {
    [self chooseFromPopUp:_waveformThemePopUp revealing:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM
                    wells:@[_customDarkRow, _customLightRow] effect:VibeSettingsLiveEffectWaveformTheme
                    write:^(AppTheme *theme, NSString *identifier) { theme.waveformTheme = identifier; }];
}

// Unset Custom wells use Rekord Bin's bands without writing them.
- (void)spectrumPaletteChanged:(id)sender {
    [self chooseFromPopUp:_spectrumPalettePopUp revealing:nil wells:@[] effect:VibeSettingsLiveEffectWaveformTheme
                    write:^(AppTheme *theme, NSString *identifier) { theme.waveformSpectrumPalette = identifier; }];
}

#pragma mark - Editor: playlist

- (void)playlistColorModeChanged:(NSPopUpButton *)sender {
    NSString *base = sender.identifier;
    [self chooseFromPopUp:sender revealing:SETTINGS_VALUE_WINDOW_TINT_CUSTOM wells:@[_playlistColorPairs[base]]
                   effect:VibeThemePlaylistColorEditEffect(base)
                    write:^(AppTheme *theme, NSString *identifier) {
        [theme setPlaylistColorEnabled:[identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM] forBase:base];
    }];
}

- (void)playlistBackgroundStyleChanged:(id)sender {
    [self chooseFromPopUp:_playlistBackgroundPopUp revealing:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID
                    wells:@[_playlistBackgroundColorsRow] effect:VibeSettingsLiveEffectPlaylistAppearance
                    write:^(AppTheme *theme, NSString *identifier) { theme.playlistBackgroundStyle = identifier; }];
}

- (void)playlistTintChanged:(id)sender {
    [self chooseFromPopUp:_playlistTintPopUp revealing:SETTINGS_VALUE_WINDOW_TINT_CUSTOM
                    wells:@[_playlistTintDarkRow, _playlistTintLightRow] effect:VibeSettingsLiveEffectWindowTint
                    write:^(AppTheme *theme, NSString *identifier) { theme.playlistTint = identifier; }];
}

#pragma mark - Editor: name

// TRAP: the Name field's editor is an NSTextView, which implements changeFont:
// and would eat the font panel's sends; editing the name closes the panel
// (selectFont: guards the other direction).
- (void)controlTextDidBeginEditing:(NSNotification *)notification {
    if (notification.object != _nameField) {
        return;
    }
    [(NSTextView *)_nameField.currentEditor setAllowsUndo:YES];
    _fontEditingSlot = VibeFontSlotNone;
    if (NSFontPanel.sharedFontPanelExists) {
        [NSFontPanel.sharedFontPanel orderOut:nil];
    }
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _nameField) {
        [self applyEditorTitle];
    }
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object != _nameField) {
        return;
    }
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *active = settings.activeThemeIdentifier;
    // An edit that outlived a theme switch is dropped, never committed onto
    // the theme that is now active (see _nameFieldThemeIdentifier).
    if (![active isEqualToString:_nameFieldThemeIdentifier]) {
        [self refreshFromSettings];
        return;
    }
    if ([AppTheme isBuiltInIdentifier:active]) {
        if ([_nameField.stringValue isEqualToString:[settings displayNameForThemeIdentifier:active]]
                || ![self forkBuiltInForEdit]) {
            [self refreshFromSettings];
            return;
        }
        active = settings.activeThemeIdentifier;
    }
    [settings renameUserThemeWithIdentifier:active toName:_nameField.stringValue];
    // The stored name may have been deduped or fallback-named; show what
    // actually landed.
    [self refreshFromSettings];
}

#pragma mark - Editor: fonts

- (void)selectFont:(NSButton *)sender {
    _fontEditingSlot = (VibeFontSlot)sender.tag;
    // TRAP: a focused field editor is an NSTextView, which implements
    // changeFont: and would eat the panel's sends.
    [self.view.window makeFirstResponder:self.view];
    NSFontManager *manager = NSFontManager.sharedFontManager;
    [manager setSelectedFont:[Fonts fontForSlot:_fontEditingSlot bold:NO] isMultiple:NO];
    [manager orderFrontFontPanel:self];
}

- (NSFontPanelModeMask)validModesForFontPanel:(NSFontPanel *)fontPanel {
    return NSFontPanelModeMaskCollection | NSFontPanelModeMaskFace | NSFontPanelModeMaskSize;
}

// Called per pick while browsing. The store clamps the size.
- (void)changeFont:(NSFontManager *)sender {
    if (_fontEditingSlot == VibeFontSlotNone) {
        return;
    }
    NSFont *font = [sender convertFont:[Fonts fontForSlot:_fontEditingSlot bold:NO]];
    [AppSettings.sharedInstance.currentTheme setFontFace:font.fontName size:font.pointSize
                                                 forSlot:_fontEditingSlot];
    [self themeFieldDidChange:VibeSettingsLiveEffectFonts
            | VibeSettingsLiveEffectPlaylistAppearance
            | VibeSettingsLiveEffectTrackDisplay];
    [self refreshFontValueLabels];
}

// Hidden wells still receive color-panel picks until deactivated.
// TRAP: deactivate only active wells. It can otherwise create the panel and Metal resources.
- (void)closeEditorPanels {
    _fontEditingSlot = VibeFontSlotNone;
    if (NSFontPanel.sharedFontPanelExists) {
        [NSFontPanel.sharedFontPanel orderOut:nil];
    }
    ForEachDescendantView(self.view, ^(NSView *subview) {
        if ([subview isKindOfClass:NSColorWell.class] && ((NSColorWell *)subview).isActive) {
            [(NSColorWell *)subview deactivate];
        }
    });
}

@end
