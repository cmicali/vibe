//
//  SettingsAppearanceViewController+Editor.m
//  Vibe
//

#import "SettingsAppearanceViewController+Editor.h"
#import "SettingsAppearanceViewControllerInternal.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "Fonts.h"
#import "NSImage+Util.h"
#import "SettingsRules.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"

static const CGFloat kImagePreviewSize = 64;
// An unset button image slot's glyph, at the transport row's glyph size.
static const CGFloat kImagePreviewGlyphPointSize = 31;
// The clear ✕ and missing (!) badges, box and glyph scaled by one factor.
static const CGFloat kImageBadgeSize = 22.5;       // 18 * 1.25
static const CGFloat kImageBadgePointSize = 16.25; // NSFont.systemFontSize * 1.25
// Inside the preview: a subview past its superview's bounds is not
// hit-tested, costing the (!) its tooltip and the ✕ its click target.
static const CGFloat kImageBadgeInset = 1.5;

// A color well's binding to one side of its theme pair; see wellForDark:base:effect:.
static NSString *const kWellBase = @"base";
static NSString *const kWellEffect = @"effect";
static NSString *const kWellDark = @"dark";

// Not a symbol-name shape, so it can never reach a glyph field.
static NSString *const kGlyphChoiceCustomImage = @"custom-image";

static BOOL IsEitherSide(NSString *key, NSString *dark, NSString *light) {
    return [key isEqualToString:dark] || [key isEqualToString:light];
}



@implementation VibeDetentSlider

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.maxValue <= self.minValue) {
        return;
    }
    CGFloat knob = ((NSSliderCell *)self.cell).knobThickness;
    CGFloat fraction = (self.detentValue - self.minValue) / (self.maxValue - self.minValue);
    CGFloat x = round(knob / 2 + fraction * (NSWidth(self.bounds) - knob));
    CGFloat midY = NSMidY(self.bounds);
    [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.6] setFill];
    NSRectFillUsingOperation(NSMakeRect(x - 0.5, midY + 5, 1, 4), NSCompositingOperationSourceOver);
    NSRectFillUsingOperation(NSMakeRect(x - 0.5, midY - 9, 1, 4), NSCompositingOperationSourceOver);
}

@end

@implementation SettingsAppearanceViewController (Editor)

#pragma mark - Construction

- (VibeSwitch *)themeSwitchWithEffect:(VibeSettingsLiveEffect)effect
                              write:(void (^)(AppTheme *, BOOL))write {
    VibeSwitch *toggle = [self switchWithAction:@selector(themeSwitchChanged:)];
    toggle.tag = effect;
    if (!_themeSwitchWrites) _themeSwitchWrites = [NSMapTable strongToStrongObjectsMapTable];
    [_themeSwitchWrites setObject:[write copy] forKey:toggle];
    return toggle;
}

- (void)themeSwitchChanged:(VibeSwitch *)sender {
    void (^write)(AppTheme *, BOOL) = [_themeSwitchWrites objectForKey:sender];
    write(AppSettings.sharedInstance.currentTheme, sender.state == NSControlStateValueOn);
    [self themeFieldDidChange:(VibeSettingsLiveEffect)sender.tag];
    [self refreshFromSettings];
}

// Bound to one side of the pair at base. Alpha is part of every choice: a
// fill's strength, a background's opacity, a waveform side's resting level.
- (NSColorWell *)wellForDark:(BOOL)isDark base:(NSString *)base effect:(VibeSettingsLiveEffect)effect {
    NSColorWell *well = [[NSColorWell alloc] init];
    well.target = self;
    well.action = @selector(colorWellChanged:);
    if (!_wellBindings) {
        _wellBindings = [NSMapTable strongToStrongObjectsMapTable];
    }
    [_wellBindings setObject:@{kWellBase: base, kWellEffect: @(effect), kWellDark: @(isDark)}
                      forKey:well];
    if (@available(macOS 14.0, *)) {
        well.supportsAlpha = YES;
    } else {
        // Pre-14 wells follow the shared panel, which nothing else opens.
        NSColorPanel.sharedColorPanel.showsAlpha = YES;
    }
    [well.widthAnchor constraintEqualToConstant:44].active = YES;
    [well.heightAnchor constraintEqualToConstant:24].active = YES;
    return well;
}

// [well caption] [well caption] — one row per themed color pair, Dark/Light
// or the waveform's Played/Unplayed.
- (NSStackView *)wellPair:(NSView *)first caption:(NSString *)firstCaption
                     well:(NSView *)second caption:(NSString *)secondCaption {
    NSTextField *firstLabel = [NSTextField labelWithString:firstCaption];
    NSTextField *secondLabel = [NSTextField labelWithString:secondCaption];
    firstLabel.textColor = NSColor.secondaryLabelColor;
    secondLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *pair = [NSStackView stackViewWithViews:
            @[first, firstLabel, second, secondLabel]];
    pair.spacing = 6;
    [pair setCustomSpacing:16 afterView:firstLabel];
    return pair;
}

- (NSStackView *)captionedPairWithDark:(NSView *)dark light:(NSView *)light {
    return [self wellPair:dark caption:STR_SETTINGS_THEME_DARK
                     well:light caption:STR_SETTINGS_THEME_LIGHT];
}

// An appearance-keyed pair: registered with the single-mode collapse.
- (NSStackView *)darkLightPairWithDark:(NSView *)dark light:(NSView *)light {
    NSStackView *pair = [self captionedPairWithDark:dark light:light];
    if (!_darkLightPairs) {
        _darkLightPairs = [NSMutableArray array];
    }
    [_darkLightPairs addObject:pair];
    return pair;
}

- (NSStackView *)darkLightPairForBase:(NSString *)base effect:(VibeSettingsLiveEffect)effect {
    return [self darkLightPairWithDark:[self wellForDark:YES base:base effect:effect]
                                 light:[self wellForDark:NO base:base effect:effect]];
}

// A transport button's pairs are art-keyed (kVibeThemeColorPlaylistButton),
// so they never join the single-mode collapse.
- (NSStackView *)artKeyedImagePairForDarkKey:(NSString *)darkKey lightKey:(NSString *)lightKey {
    return [self wellPair:[self imageClusterForKey:darkKey] caption:STR_SETTINGS_THEME_ON_DARK_ART
                    well:[self imageClusterForKey:lightKey] caption:STR_SETTINGS_THEME_ON_LIGHT_ART];
}

- (NSStackView *)artKeyedColorPairForBase:(NSString *)base {
    return [self wellPair:[self wellForDark:YES base:base effect:VibeSettingsLiveEffectTransportButtons]
                 caption:STR_SETTINGS_THEME_ON_DARK_ART
                    well:[self wellForDark:NO base:base effect:VibeSettingsLiveEffectTransportButtons]
                 caption:STR_SETTINGS_THEME_ON_LIGHT_ART];
}

- (NSStackView *)fontClusterForSlot:(VibeFontSlot)slot valueLabel:(NSTextField **)outLabel {
    NSTextField *value = [NSTextField labelWithString:@""];
    value.textColor = NSColor.secondaryLabelColor;
    NSButton *select = [NSButton buttonWithTitle:STR_SETTINGS_THEME_FONT_SELECT
                                          target:self action:@selector(selectFont:)];
    select.tag = slot;
    *outLabel = value;
    NSStackView *cluster = [NSStackView stackViewWithViews:@[value, select]];
    cluster.spacing = 10;
    return cluster;
}

// The field key rides both buttons' identifiers, which is how their shared
// actions find the slot. The clear badge is a real button so the walker can
// address it by its undrawn title.
- (NSView *)imageClusterForKey:(NSString *)key {
    NSButton *preview = [NSButton buttonWithImage:[AppTheme imageForReference:@""]
                                           target:self action:@selector(chooseImage:)];
    preview.bordered = NO;
    preview.title = @""; // the factory's "Button" would name it in the walker
    preview.identifier = key;
    preview.wantsLayer = YES;
    preview.layer.cornerRadius = 6;
    preview.layer.masksToBounds = YES;
    ((NSButtonCell *)preview.cell).imageScaling = NSImageScaleProportionallyUpOrDown;
    NSButton *clear = [NSButton buttonWithImage:[NSImage symbolNamed:@"xmark.circle.fill"
            pointSize:kImageBadgePointSize weight:NSFontWeightRegular
              palette:@[NSColor.whiteColor, [NSColor colorWithWhite:0 alpha:0.6]]
            accessibilityDescription:STR_SETTINGS_THEME_IMAGE_CLEAR]
                                         target:self action:@selector(clearCustomImage:)];
    clear.bordered = NO;
    clear.title = STR_SETTINGS_THEME_IMAGE_CLEAR; // image-only: named, never drawn
    clear.identifier = key;
    clear.imagePosition = NSImageOnly;
    clear.hidden = YES;
    // Not hover-gated: it reports a state. An image view, since a button
    // would promise VoiceOver an action.
    NSImageView *missing = [NSImageView imageViewWithImage:[NSImage
            symbolNamed:@"exclamationmark.circle.fill"
              pointSize:kImageBadgePointSize weight:NSFontWeightRegular
                palette:@[NSColor.whiteColor, NSColor.systemRedColor]
            accessibilityDescription:STR_SETTINGS_THEME_IMAGE_MISSING]];
    missing.toolTip = STR_SETTINGS_THEME_IMAGE_MISSING;
    missing.accessibilityLabel = STR_SETTINGS_THEME_IMAGE_MISSING;
    missing.hidden = YES;
    NSView *cluster = [[NSView alloc] initWithFrame:NSZeroRect];
    cluster.translatesAutoresizingMaskIntoConstraints = NO;
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    clear.translatesAutoresizingMaskIntoConstraints = NO;
    missing.translatesAutoresizingMaskIntoConstraints = NO;
    [cluster addSubview:preview];
    [cluster addSubview:clear];
    [cluster addSubview:missing];
    [NSLayoutConstraint activateConstraints:@[
        [cluster.widthAnchor constraintEqualToConstant:kImagePreviewSize],
        [cluster.heightAnchor constraintEqualToConstant:kImagePreviewSize],
        [preview.leadingAnchor constraintEqualToAnchor:cluster.leadingAnchor],
        [preview.trailingAnchor constraintEqualToAnchor:cluster.trailingAnchor],
        [preview.topAnchor constraintEqualToAnchor:cluster.topAnchor],
        [preview.bottomAnchor constraintEqualToAnchor:cluster.bottomAnchor],
        // The undrawn title still feeds the intrinsic width.
        [clear.widthAnchor constraintEqualToConstant:kImageBadgeSize],
        [clear.heightAnchor constraintEqualToConstant:kImageBadgeSize],
        [clear.topAnchor constraintEqualToAnchor:cluster.topAnchor
                                        constant:kImageBadgeInset],
        [clear.trailingAnchor constraintEqualToAnchor:cluster.trailingAnchor
                                             constant:-kImageBadgeInset],
        [missing.widthAnchor constraintEqualToConstant:kImageBadgeSize],
        [missing.heightAnchor constraintEqualToConstant:kImageBadgeSize],
        [missing.topAnchor constraintEqualToAnchor:cluster.topAnchor
                                          constant:kImageBadgeInset],
        [missing.leadingAnchor constraintEqualToAnchor:cluster.leadingAnchor
                                              constant:kImageBadgeInset],
    ]];
    // ActiveInActiveApp: the font or color panel is often key. Posted debug
    // events cannot fire tracking areas; a scripted clear needs a real hover.
    [cluster addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
                    | NSTrackingInVisibleRect
            owner:self userInfo:@{@"imageField": key}]];
    _imagePreviews[key] = preview;
    _imageClearBadges[key] = clear;
    _imageMissingBadges[key] = missing;
    return cluster;
}

// Keyed by the button's dark image field. The color and image rows swap on
// whether an image is set (resolveLayoutStateFromSettings).
- (NSArray<SettingsRowView *> *)buttonRowsForImageKey:(NSString *)imageKey
                                                title:(NSString *)title
                                           colorTitle:(NSString *)colorTitle
                                            colorBase:(NSString *)colorBase
                                               glyphs:(NSArray<NSString *> *)glyphs
                                            imageRows:(NSArray<SettingsRowView *> *)imageRows {
    NSPopUpButton *popUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                               action:@selector(buttonGlyphChanged:)];
    popUp.identifier = imageKey;
    // Symbol names are identifiers, deliberately not given display names.
    for (NSString *glyph in glyphs) {
        [self addItem:VibeNotLocalized(glyph) value:glyph to:popUp];
        popUp.lastItem.image = [NSImage imageWithSystemSymbolName:glyph accessibilityDescription:nil];
    }
    [popUp.menu addItem:NSMenuItem.separatorItem];
    [self addItem:STR_SETTINGS_THEME_BUTTON_CUSTOM_IMAGE value:kGlyphChoiceCustomImage to:popUp];
    // Item 0 stands in for a stored glyph the menu does not list — a
    // JSON-authored one — shown only while that is the selection
    // (selectGlyphChoiceForButtonImageKey:).
    NSMenuItem *unlisted = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
    unlisted.hidden = YES;
    [popUp.menu insertItem:unlisted atIndex:0];
    SettingsRowView *colorRow = [SettingsRowView rowWithTitle:colorTitle
                                                      control:[self artKeyedColorPairForBase:colorBase]];
    _glyphPopUps[imageKey] = popUp;
    _buttonColorRows[imageKey] = colorRow;
    _buttonImageRows[imageKey] = imageRows;
    return [@[[SettingsRowView rowWithTitle:title control:popUp], colorRow]
            arrayByAddingObjectsFromArray:imageRows];
}

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
// one, else its glyph — item 0 dressed as a stored glyph the menu does not
// list, a JSON-authored one, so the popup never shows nothing.
- (void)selectGlyphChoiceForButtonImageKey:(NSString *)key {
    NSPopUpButton *popUp = _glyphPopUps[key];
    NSMenuItem *unlisted = popUp.itemArray.firstObject;
    unlisted.hidden = YES;
    if ([self buttonHasImageForKey:key]) {
        [self selectValue:kGlyphChoiceCustomImage in:popUp];
        return;
    }
    NSString *glyph = [self glyphForImageKey:key];
    [self selectValue:glyph in:popUp];
    if (popUp.indexOfSelectedItem < 0) {
        unlisted.title = VibeNotLocalized(glyph);
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

- (NSStackView *)detentSliderClusterWithDetent:(double)detent min:(double)min max:(double)max
                                        action:(SEL)action slider:(NSSlider *__strong *)outSlider
                                    valueLabel:(NSTextField *__strong *)outLabel {
    VibeDetentSlider *slider = [VibeDetentSlider sliderWithValue:detent minValue:min maxValue:max
                                                          target:self action:action];
    slider.detentValue = detent;
    slider.continuous = YES;
    [slider.widthAnchor constraintEqualToConstant:kAppearancePopUpWidth].active = YES;
    NSTextField *label = [NSTextField labelWithString:@""];
    label.textColor = NSColor.secondaryLabelColor;
    // Fixed width, so a changing digit count never nudges the slider.
    label.alignment = NSTextAlignmentRight;
    [label.widthAnchor constraintEqualToConstant:50].active = YES;
    *outSlider = slider;
    *outLabel = label;
    NSStackView *cluster = [NSStackView stackViewWithViews:@[slider, label]];
    cluster.spacing = 10;
    return cluster;
}

- (void)buildEditorPage {
    _imagePreviews = [NSMutableDictionary dictionary];
    _imageClearBadges = [NSMutableDictionary dictionary];
    _imageMissingBadges = [NSMutableDictionary dictionary];
    _glyphPopUps = [NSMutableDictionary dictionary];
    _buttonColorRows = [NSMutableDictionary dictionary];
    _buttonImageRows = [NSMutableDictionary dictionary];
    _nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _nameField.delegate = self;
    [_nameField.widthAnchor constraintEqualToConstant:kAppearancePopUpWidth].active = YES;
    _nameRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_NAME_LABEL control:_nameField];
    _duplicateButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_DUPLICATE
                                          target:self action:@selector(duplicateTheme:)];
    _builtInRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BUILT_IN_CAPTION
                                        control:_duplicateButton];

    _modePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                     action:@selector(themeModeChanged:)];
    [self addItem:STR_SETTINGS_THEME_MODE_DUAL value:SETTINGS_VALUE_THEME_MODE_DUAL to:_modePopUp];
    [self addItem:STR_SETTINGS_THEME_MODE_SINGLE value:SETTINGS_VALUE_THEME_MODE_SINGLE to:_modePopUp];

    NSView *appIconCluster = [self imageClusterForKey:kVibeThemeImageAppIcon];
    _dockIconPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(dockIconChanged:)];
    [self addItem:STR_SETTINGS_THEME_DOCK_ICON_ALBUM_ART value:SETTINGS_VALUE_DOCK_ICON_ALBUM_ART to:_dockIconPopUp];
    [self addItem:STR_SETTINGS_THEME_APP_ICON value:SETTINGS_VALUE_DOCK_ICON_APP_ICON to:_dockIconPopUp];
    _appIconShapeSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectAppIcon
            write:^(AppTheme *theme, BOOL on) { theme.appIconShape = on; }];
    _customCornerRadiusSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectWindowChrome
            write:^(AppTheme *theme, BOOL on) { theme.customCornerRadius = on; }];

    // Appearance-keyed, so it joins the single-mode collapse.
    NSStackView *artPair = [self darkLightPairWithDark:
            [self imageClusterForKey:kVibeThemeImageDefaultArtworkDark]
            light:[self imageClusterForKey:kVibeThemeImageDefaultArtworkLight]];

    NSArray<SettingsRowView *> *playlistButtonRows = [self
            buttonRowsForImageKey:kVibeThemeImagePlaylistButtonDark
                            title:STR_SETTINGS_THEME_BUTTON_PLAYLIST
                       colorTitle:STR_SETTINGS_THEME_BUTTON_PLAYLIST_COLOR
                        colorBase:kVibeThemeColorPlaylistButton
                           glyphs:VibePlaylistButtonGlyphs()
                        imageRows:@[[SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BUTTON_PLAYLIST_IMAGE
                            control:[self artKeyedImagePairForDarkKey:kVibeThemeImagePlaylistButtonDark
                                                             lightKey:kVibeThemeImagePlaylistButtonLight]]]];
    NSArray<SettingsRowView *> *playButtonRows = [self
            buttonRowsForImageKey:kVibeThemeImagePlayButtonDark
                            title:STR_SETTINGS_THEME_BUTTON_PLAY
                       colorTitle:STR_SETTINGS_THEME_BUTTON_PLAY_COLOR
                        colorBase:kVibeThemeColorPlayButton
                           glyphs:VibePlayButtonGlyphs()
                        imageRows:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BUTTON_PLAY_IMAGE
                              control:[self artKeyedImagePairForDarkKey:kVibeThemeImagePlayButtonDark
                                                               lightKey:kVibeThemeImagePlayButtonLight]],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BUTTON_PAUSE_IMAGE
                              control:[self artKeyedImagePairForDarkKey:kVibeThemeImagePauseButtonDark
                                                               lightKey:kVibeThemeImagePauseButtonLight]],
    ]];
    NSArray<SettingsRowView *> *nextButtonRows = [self
            buttonRowsForImageKey:kVibeThemeImageNextButtonDark
                            title:STR_SETTINGS_THEME_BUTTON_NEXT
                       colorTitle:STR_SETTINGS_THEME_BUTTON_NEXT_COLOR
                        colorBase:kVibeThemeColorNextButton
                           glyphs:VibeNextButtonGlyphs()
                        imageRows:@[[SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BUTTON_NEXT_IMAGE
                            control:[self artKeyedImagePairForDarkKey:kVibeThemeImageNextButtonDark
                                                             lightKey:kVibeThemeImageNextButtonLight]]]];
    _transportButtonsSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectTransportButtons
            write:^(AppTheme *theme, BOOL on) { theme.showTransportButtons = on; }];
    _buttonGradientPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(buttonGradientChanged:)];
    [self addItem:STR_SETTINGS_THEME_BUTTON_GRADIENT_NONE value:SETTINGS_VALUE_BUTTON_GRADIENT_NONE to:_buttonGradientPopUp];
    [self addItem:STR_SETTINGS_THEME_BUTTON_GRADIENT_HOVER value:SETTINGS_VALUE_BUTTON_GRADIENT_HOVER to:_buttonGradientPopUp];
    [self addItem:STR_SETTINGS_THEME_BUTTON_GRADIENT_ARTWORK value:SETTINGS_VALUE_BUTTON_GRADIENT_ARTWORK to:_buttonGradientPopUp];
    [self addItem:STR_SETTINGS_THEME_BUTTON_GRADIENT_ALWAYS value:SETTINGS_VALUE_BUTTON_GRADIENT_ALWAYS to:_buttonGradientPopUp];

    _backgroundPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(backgroundStyleChanged:)];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_GLASS value:SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS to:_backgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_FROSTED value:SETTINGS_VALUE_WINDOW_BACKGROUND_FROSTED to:_backgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_SOLID value:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID to:_backgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_CLEAR value:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR to:_backgroundPopUp];
    _backgroundColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BACKGROUND_COLORS
            control:[self darkLightPairForBase:kVibeThemeColorWindowBackground
                                        effect:VibeSettingsLiveEffectWindowChrome]];

    _windowTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(windowTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_windowTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_windowTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_windowTintPopUp];
    _windowTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
            control:[self wellForDark:YES base:kVibeThemeColorWindowTint effect:VibeSettingsLiveEffectWindowTint]];
    _windowTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
            control:[self wellForDark:NO base:kVibeThemeColorWindowTint effect:VibeSettingsLiveEffectWindowTint]];

    NSStackView *radiusCluster = [self detentSliderClusterWithDetent:kVibeThemeCornerRadiusDefault
            min:0 max:kVibeThemeCornerRadiusMax action:@selector(cornerRadiusChanged:)
            slider:&_cornerRadiusSlider valueLabel:&_cornerRadiusValue];

    _playlistBackgroundPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                                   action:@selector(playlistBackgroundStyleChanged:)];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_GLASS value:SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS to:_playlistBackgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_SOLID value:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID to:_playlistBackgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_CLEAR value:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR to:_playlistBackgroundPopUp];

    _fileInfoSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectTrackDisplay
            write:^(AppTheme *theme, BOOL on) { theme.showFileInfo = on; }];
    _statusIconsSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectTrackDisplay
            write:^(AppTheme *theme, BOOL on) { theme.showStatusIcons = on; }];
    _timeLabelsSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectTrackDisplay
            write:^(AppTheme *theme, BOOL on) { theme.showTimeLabels = on; }];
    _timeTotalRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_TOTAL
                                              target:self action:@selector(timeDisplayChanged:)];
    _timeRemainingRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_REMAINING
                                                  target:self action:@selector(timeDisplayChanged:)];
    NSStackView *timeRadios = [NSStackView stackViewWithViews:@[_timeTotalRadio, _timeRemainingRadio]];
    timeRadios.spacing = 12;
    _showBPMSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectTrackDisplay
            write:^(AppTheme *theme, BOOL on) { theme.showBPM = on; }];
    _showKeySwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectTrackDisplay
            write:^(AppTheme *theme, BOOL on) { theme.showKey = on; }];
    _keyNotationPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(keyNotationChanged:)];
    [self addItem:STR_SETTINGS_KEY_NOTATION_CAMELOT value:SETTINGS_VALUE_KEY_NOTATION_CAMELOT to:_keyNotationPopUp];
    [self addItem:STR_SETTINGS_KEY_NOTATION_MUSICAL value:SETTINGS_VALUE_KEY_NOTATION_MUSICAL to:_keyNotationPopUp];
    _keyColorsSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectTrackDisplay
            write:^(AppTheme *theme, BOOL on) { theme.keyColorsEnabled = on; }];

    // Title and artist paint the playlist rows too; info and time appear only
    // in the header, so their drags skip the table reload.
    NSStackView *titleColors = [self darkLightPairForBase:kVibeThemeColorTitle
            effect:VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance];
    NSStackView *artistColors = [self darkLightPairForBase:kVibeThemeColorArtist
            effect:VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance];
    NSStackView *infoColors = [self darkLightPairForBase:kVibeThemeColorInfo
            effect:VibeSettingsLiveEffectTrackDisplay];
    NSStackView *timeColors = [self darkLightPairForBase:kVibeThemeColorTime
            effect:VibeSettingsLiveEffectTrackDisplay];

    _waveformPopUp = [self waveformStylePopUpButton];
    NSStackView *densityCluster = [self detentSliderClusterWithDetent:kVibeThemeWaveformBarScaleDefault
            min:kVibeThemeWaveformBarScaleMin max:kVibeThemeWaveformBarScaleMax
            action:@selector(waveformBarSizingChanged:)
            slider:&_waveformBarDensitySlider valueLabel:&_waveformBarDensityValue];
    NSStackView *widthCluster = [self detentSliderClusterWithDetent:kVibeThemeWaveformBarScaleDefault
            min:kVibeThemeWaveformBarScaleMin max:kVibeThemeWaveformBarScaleMax
            action:@selector(waveformBarSizingChanged:)
            slider:&_waveformBarWidthSlider valueLabel:&_waveformBarWidthValue];
    _waveformThemePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformThemeChanged:)];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_MONO value:SETTINGS_VALUE_WAVEFORM_THEME_MONO to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ORANGE value:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART value:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_CUSTOM value:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM to:_waveformThemePopUp];

    _waveformGradientSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectWaveformTheme
            write:^(AppTheme *theme, BOOL on) { theme.waveformGradient = on; }];
    _playlistNumberSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectPlaylistAppearance
            write:^(AppTheme *theme, BOOL on) { theme.showPlaylistNumberColumn = on; }];
    _playlistArtworkSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectPlaylistAppearance
            write:^(AppTheme *theme, BOOL on) { theme.showPlaylistArtworkColumn = on; }];
    _playlistDurationSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectPlaylistAppearance
            write:^(AppTheme *theme, BOOL on) { theme.showPlaylistDurationColumn = on; }];
    NSStackView *(^customWells)(BOOL) = ^(BOOL dark) {
        return [self wellPair:[self wellForDark:dark base:kVibeThemeColorWaveformPlayed
                                         effect:VibeSettingsLiveEffectWaveformTheme]
                      caption:STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED
                         well:[self wellForDark:dark base:kVibeThemeColorWaveformUnplayed
                                         effect:VibeSettingsLiveEffectWaveformTheme]
                      caption:STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED];
    };
    _customDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL
                                           control:customWells(YES)];
    _customLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_LIGHT_LABEL
                                            control:customWells(NO)];

    // The background is one layer color and the row fills are read per draw,
    // so their drags take lighter effects than PlaylistAppearance.
    _playlistBackgroundColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_BACKGROUND_COLORS
            control:[self darkLightPairForBase:kVibeThemeColorPlaylistBackground
                                        effect:VibeSettingsLiveEffectPlaylistBackground]];

    _playlistTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                             action:@selector(playlistTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_playlistTintPopUp];
    _playlistTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
            control:[self wellForDark:YES base:kVibeThemeColorPlaylistTint effect:VibeSettingsLiveEffectWindowTint]];
    _playlistTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
            control:[self wellForDark:NO base:kVibeThemeColorPlaylistTint effect:VibeSettingsLiveEffectWindowTint]];

    _volumeBarPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(volumeBarChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_volumeBarPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_volumeBarPopUp];
    [self addItem:STR_SETTINGS_THEME_VOLUME_WAVEFORM value:SETTINGS_VALUE_VOLUME_WAVEFORM to:_volumeBarPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_volumeBarPopUp];
    // Every waveform theme resolution re-resolves the slider's fill and knob,
    // so a well drag takes that effect rather than Volume's relayout.
    _volumeBarDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
            control:[self wellForDark:YES base:kVibeThemeColorVolumeBar effect:VibeSettingsLiveEffectWaveformTheme]];
    _volumeBarLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
            control:[self wellForDark:NO base:kVibeThemeColorVolumeBar effect:VibeSettingsLiveEffectWaveformTheme]];
    _volumeKnobPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(volumeKnobChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_volumeKnobPopUp];
    [self addItem:STR_SETTINGS_THEME_VOLUME_KNOB_BAR value:SETTINGS_VALUE_VOLUME_KNOB_BAR to:_volumeKnobPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_volumeKnobPopUp];
    [self addItem:STR_SETTINGS_THEME_VOLUME_WAVEFORM value:SETTINGS_VALUE_VOLUME_WAVEFORM to:_volumeKnobPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_volumeKnobPopUp];
    _volumeKnobDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
            control:[self wellForDark:YES base:kVibeThemeColorVolumeKnob effect:VibeSettingsLiveEffectWaveformTheme]];
    _volumeKnobLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
            control:[self wellForDark:NO base:kVibeThemeColorVolumeKnob effect:VibeSettingsLiveEffectWaveformTheme]];
    _volumeLabelsSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectVolume
            write:^(AppTheme *theme, BOOL on) { theme.showVolumeLabels = on; }];
    _volumeLocationPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(volumeLocationChanged:)];
    [self addItem:STR_SETTINGS_THEME_VOLUME_LOCATION_BOTTOM value:SETTINGS_VALUE_VOLUME_LOCATION_BOTTOM
               to:_volumeLocationPopUp];
    [self addItem:STR_SETTINGS_THEME_VOLUME_LOCATION_TOP_RIGHT value:SETTINGS_VALUE_VOLUME_LOCATION_TOP_RIGHT
               to:_volumeLocationPopUp];

    _playlistColorSwitches = [NSMutableDictionary dictionary];
    _playlistColorRows = [NSMutableDictionary dictionary];
    NSMutableArray<SettingsRowView *> *playlistColorRows = [NSMutableArray array];
    NSArray<NSArray *> *playlistColumns = @[
        @[kVibeThemeColorPlaylistNumber, STR_SETTINGS_THEME_PLAYLIST_NUMBER_COLOR_CUSTOM,
          STR_SETTINGS_THEME_PLAYLIST_NUMBER_COLOR],
        @[kVibeThemeColorPlaylistTitle, STR_SETTINGS_THEME_PLAYLIST_TITLE_COLOR_CUSTOM,
          STR_SETTINGS_THEME_PLAYLIST_TITLE_COLOR],
        @[kVibeThemeColorPlaylistArtist, STR_SETTINGS_THEME_PLAYLIST_ARTIST_COLOR_CUSTOM,
          STR_SETTINGS_THEME_PLAYLIST_ARTIST_COLOR],
        @[kVibeThemeColorPlaylistDuration, STR_SETTINGS_THEME_PLAYLIST_DURATION_COLOR_CUSTOM,
          STR_SETTINGS_THEME_PLAYLIST_DURATION_COLOR],
    ];
    for (NSArray *column in playlistColumns) {
        NSString *base = column[0];
        VibeSwitch *toggle = [self themeSwitchWithEffect:VibeSettingsLiveEffectPlaylistAppearance
                write:^(AppTheme *theme, BOOL on) { [theme setPlaylistColorEnabled:on forBase:base]; }];
        _playlistColorSwitches[base] = toggle;
        SettingsRowView *pairRow = [SettingsRowView rowWithTitle:column[2]
                control:[self darkLightPairForBase:base effect:VibeSettingsLiveEffectPlaylistAppearance]];
        _playlistColorRows[base] = pairRow;
        [playlistColorRows addObject:[SettingsRowView rowWithTitle:column[1] control:toggle]];
        [playlistColorRows addObject:pairRow];
    }

    NSStackView *playingRowColors = [self darkLightPairForBase:kVibeThemeColorPlaylistPlayingRow
                                                        effect:VibeSettingsLiveEffectPlaylistRowFills];
    NSStackView *selectedRowColors = [self darkLightPairForBase:kVibeThemeColorPlaylistSelectedRow
                                                         effect:VibeSettingsLiveEffectPlaylistRowFills];

    NSTextField *titleFontValue = nil, *infoFontValue = nil, *playlistFontValue = nil;
    NSStackView *titleFontCluster = [self fontClusterForSlot:VibeFontSlotTitle valueLabel:&titleFontValue];
    NSTextField *artistFontValue = nil;
    NSStackView *artistFontCluster = [self fontClusterForSlot:VibeFontSlotArtist valueLabel:&artistFontValue];
    NSStackView *infoFontCluster = [self fontClusterForSlot:VibeFontSlotInfo valueLabel:&infoFontValue];
    NSStackView *playlistFontCluster = [self fontClusterForSlot:VibeFontSlotPlaylist valueLabel:&playlistFontValue];
    NSTextField *playlistDurationFontValue = nil;
    NSStackView *playlistDurationFontCluster =
            [self fontClusterForSlot:VibeFontSlotPlaylistDuration
                          valueLabel:&playlistDurationFontValue];
    _titleFontValue = titleFontValue;
    _artistFontValue = artistFontValue;
    _infoFontValue = infoFontValue;
    _playlistFontValue = playlistFontValue;
    _playlistDurationFontValue = playlistDurationFontValue;

    _infoFontRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_INFO control:infoFontCluster];
    _fileInfoRows = @[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_INFO control:infoColors],
        [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_BPM control:_showBPMSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_KEY control:_showKeySwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_NOTATION_LABEL control:_keyNotationPopUp],
        [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_COLORS control:_keyColorsSwitch],
    ];
    NSMutableArray<SettingsRowView *> *infoRows = [NSMutableArray arrayWithArray:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SHOW_STATUS_ICONS control:_statusIconsSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_FILE_INFO control:_fileInfoSwitch],
        _infoFontRow,
    ]];
    [infoRows addObjectsFromArray:_fileInfoRows];
    _timeSection = [SettingsSectionView sectionWithHeader:STR_SETTINGS_SECTION_TIME rows:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SHOW_TIME_LABELS control:_timeLabelsSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TIMES control:timeColors],
        [SettingsRowView rowWithTitle:STR_SETTINGS_TIME_LABEL control:timeRadios],
    ]];

    NSMutableArray<SettingsRowView *> *playlistRows = [NSMutableArray arrayWithArray:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_BACKGROUND
                control:_playlistBackgroundPopUp],
        _playlistBackgroundColorsRow,
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_TINT
                control:_playlistTintPopUp],
        _playlistTintDarkRow,
        _playlistTintLightRow,
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_PLAYLIST control:playlistFontCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_PLAYLIST_DURATION
                control:playlistDurationFontCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_NUMBER_COLUMN
                control:_playlistNumberSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_ARTWORK
                control:_playlistArtworkSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_DURATION_COLUMN
                control:_playlistDurationSwitch],
    ]];
    [playlistRows addObjectsFromArray:playlistColorRows];
    [playlistRows addObject:[SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYING_ROW control:playingRowColors]];
    [playlistRows addObject:[SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SELECTED_ROW control:selectedRowColors]];

    NSMutableArray<SettingsRowView *> *transportRows =
        [NSMutableArray arrayWithObject:[SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SHOW_TRANSPORT_BUTTONS
                                                            control:_transportButtonsSwitch]];
    [transportRows addObjectsFromArray:playlistButtonRows];
    [transportRows addObjectsFromArray:playButtonRows];
    [transportRows addObjectsFromArray:nextButtonRows];
    [transportRows addObject:[SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BUTTON_GRADIENT control:_buttonGradientPopUp]];

    _transportSection = [SettingsSectionView sectionWithHeader:STR_SETTINGS_TRANSPORT_SECTION rows:transportRows];

    NSArray<NSView *> *sections = @[
        // Exactly one of the pair shows, so the second drops its hairline.
        [SettingsSectionView sectionWithRows:@[_builtInRow, _nameRow]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_ICON_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_APP_ICON control:appIconCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_DOCK_ICON control:_dockIconPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_APP_ICON_SHAPE control:_appIconShapeSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_APPEARANCE control:_modePopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BACKGROUND_LABEL control:_backgroundPopUp],
            _backgroundColorsRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_BACKGROUND_TINT_LABEL control:_windowTintPopUp],
            _windowTintDarkRow,
            _windowTintLightRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_CUSTOM_CORNER_RADIUS control:_customCornerRadiusSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_CORNER_RADIUS control:radiusCluster],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYER_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_ALBUM_ART control:artPair],
            [SettingsRowView rowWithContentView:[self waveformPreviewView]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_STYLE control:_waveformPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_BAR_DENSITY control:densityCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_BAR_WIDTH control:widthCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_COLOR control:_waveformThemePopUp],
            _customDarkRow,
            _customLightRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_GRADIENT control:_waveformGradientSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_MAIN control:titleFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TITLE control:titleColors],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_ARTIST control:artistFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_ARTIST control:artistColors],
        ]],
        _transportSection,
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_INFO_SECTION rows:infoRows],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_VOLUME_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_VOLUME_LOCATION
                                  caption:STR_SETTINGS_THEME_VOLUME_LOCATION_CAPTION
                                  control:_volumeLocationPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SHOW_VOLUME_LABELS control:_volumeLabelsSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_VOLUME_BAR control:_volumeBarPopUp],
            _volumeBarDarkRow,
            _volumeBarLightRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_VOLUME_KNOB control:_volumeKnobPopUp],
            _volumeKnobDarkRow,
            _volumeKnobLightRow,
        ]],
        _timeSection,
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYLIST_SECTION rows:playlistRows],
    ];

    _nameRow.showsTopSeparator = NO;
    SettingsStackView *editorStack =
            [[SettingsStackView alloc] initWithFrame:NSZeroRect];
    for (NSView *section in sections) {
        [editorStack addArrangedSubview:section];
    }
    _editorStack = editorStack;
    _editorStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _editorStack.alignment = NSLayoutAttributeLeading;
    _editorStack.spacing = 20;
    _editorStack.translatesAutoresizingMaskIntoConstraints = NO;
    _editorStack.wantsLayer = YES;
    for (NSView *section in sections) {
        [section.widthAnchor constraintEqualToAnchor:_editorStack.widthAnchor].active = YES;
    }

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    // Otherwise macOS 26 builds a titlebar scroll pocket whose hard edge
    // draws a stray hairline over the page.
    scroll.automaticallyAdjustsContentInsets = NO;
    scroll.documentView = _editorStack;

    NSView *container = [[NSView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.hidden = YES;
    [container addSubview:scroll];
    [self.view addSubview:container];
    _detailContainer = container;

    NSLayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:kPanePadding],
        [container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kPanePadding],
        [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kPanePadding],
        [container.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-kPanePadding],
        [scroll.topAnchor constraintEqualToAnchor:container.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        // The flipped document view keeps the top in place across relayout.
        [_editorStack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [_editorStack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [_editorStack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];
}

#pragma mark - State

- (void)resolveLayoutStateFromSettings {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL builtIn = [AppTheme isBuiltInIdentifier:
            AppSettings.sharedInstance.activeThemeIdentifier];
    _nameRow.hidden = builtIn;
    _builtInRow.hidden = !builtIn;
    // Single mode has one color per field: every pair collapses to its
    // dark-keyed well, and the per-side rows lose their side in the title the
    // debug walker addresses them by.
    BOOL single = theme.isSingleMode;
    [_windowTintDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                           : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_playlistTintDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                             : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_volumeBarDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                           : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_volumeKnobDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                           : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_customDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLORS_LABEL
                                       : STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL];
    for (NSStackView *pair in _darkLightPairs) {
        NSArray<NSView *> *views = pair.arrangedSubviews; // well, caption, well, caption
        views[1].hidden = single;
        views[2].hidden = single;
        views[3].hidden = single;
    }
    BOOL customTheme = [theme.waveformTheme isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    _customDarkRow.hidden = !customTheme;
    _customLightRow.hidden = !customTheme || single;
    BOOL customTint = [theme.windowTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    _windowTintDarkRow.hidden = !customTint;
    _windowTintLightRow.hidden = !customTint || single;
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
    for (NSString *base in _playlistColorRows) {
        _playlistColorRows[base].hidden = ![theme playlistColorEnabledForBase:base];
    }
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
    BOOL builtIn = [AppTheme isBuiltInIdentifier:active];
    // A refresh mid-type (menu tracking, regaining key) must not discard the
    // edit, unless the active theme changed under it: then drop it rather
    // than commit it onto the wrong theme.
    if (_nameField.currentEditor != nil &&
        ![active isEqualToString:_nameFieldThemeIdentifier]) {
        [_nameField abortEditing];
    }
    if (_nameField.currentEditor == nil) {
        _nameField.stringValue = builtIn ? @"" : ([settings displayNameForThemeIdentifier:active] ?: @"");
        _nameFieldThemeIdentifier = active;
    }

    [self selectValue:theme.mode in:_modePopUp];
    [self selectValue:theme.dockIcon in:_dockIconPopUp];
    _appIconShapeSwitch.state = StateForBOOL(theme.appIconShape);
    [self selectValue:theme.windowBackgroundStyle in:_backgroundPopUp];
    [self selectValue:theme.windowTint in:_windowTintPopUp];
    for (NSColorWell *well in _wellBindings) {
        NSDictionary *binding = [_wellBindings objectForKey:well];
        well.color = [theme displayColorForBase:binding[kWellBase] dark:[binding[kWellDark] boolValue]];
    }
    _customCornerRadiusSwitch.state = StateForBOOL(theme.customCornerRadius);
    _cornerRadiusSlider.doubleValue = theme.windowCornerRadius;
    [self refreshCornerRadiusValue];
    for (NSString *key in _glyphPopUps) {
        [self selectGlyphChoiceForButtonImageKey:key];
    }
    [self selectValue:theme.buttonGradient in:_buttonGradientPopUp];

    _transportButtonsSwitch.state = StateForBOOL(theme.showTransportButtons);
    _statusIconsSwitch.state = StateForBOOL(theme.showStatusIcons);
    _timeLabelsSwitch.state = StateForBOOL(theme.showTimeLabels);
    _fileInfoSwitch.state = StateForBOOL(theme.showFileInfo);
    BOOL remaining = theme.showRemainingTime;
    _timeTotalRadio.state = StateForBOOL(!remaining);
    _timeRemainingRadio.state = StateForBOOL(remaining);
    _showBPMSwitch.state = StateForBOOL(theme.showBPM);
    BOOL showKey = theme.showKey;
    _showKeySwitch.state = StateForBOOL(showKey);
    [self selectValue:theme.keyNotation in:_keyNotationPopUp];
    _keyColorsSwitch.state = StateForBOOL(theme.keyColorsEnabled);

    [self selectWaveformStyle:theme.waveformStyle in:_waveformPopUp];
    [self refreshWaveformBarSizing];
    [self selectValue:theme.waveformTheme in:_waveformThemePopUp];
    _waveformGradientSwitch.state = StateForBOOL(theme.waveformGradient);
    _playlistNumberSwitch.state = StateForBOOL(theme.showPlaylistNumberColumn);
    _playlistArtworkSwitch.state = StateForBOOL(theme.showPlaylistArtworkColumn);
    for (NSString *key in AppTheme.imageFieldKeys) {
        _imagePreviews[key].image = [self previewImageForKey:key];
        _imageClearBadges[key].hidden = YES;
        _imageMissingBadges[key].hidden =
                ![AppTheme referenceIsMissing:[theme imageReferenceForKey:key]];
    }
    _playlistDurationSwitch.state = StateForBOOL(theme.showPlaylistDurationColumn);
    for (NSString *base in _playlistColorSwitches) {
        _playlistColorSwitches[base].state = StateForBOOL([theme playlistColorEnabledForBase:base]);
    }
    [self selectValue:theme.playlistBackgroundStyle in:_playlistBackgroundPopUp];
    [self selectValue:theme.playlistTint in:_playlistTintPopUp];
    [self selectValue:theme.volumeBar in:_volumeBarPopUp];
    [self selectValue:theme.volumeKnob in:_volumeKnobPopUp];
    _volumeLabelsSwitch.state = StateForBOOL(theme.showVolumeLabels);
    [self selectValue:theme.volumeLocation in:_volumeLocationPopUp];

    [self refreshFontValueLabels];

    [SettingsRowView setControlsInView:_editorStack enabled:!builtIn];
    // The built-in page's one live control sits inside the swept stack.
    [SettingsRowView setControl:_duplicateButton enabled:YES];
    if (!builtIn) {
        BOOL info = theme.showFileInfo;
        for (SettingsRowView *row in _fileInfoRows) {
            [SettingsRowView setControlsInView:row enabled:info];
        }
        // One font shared by three readouts.
        [SettingsRowView setControlsInView:_infoFontRow
                                   enabled:info || theme.showStatusIcons || theme.showTimeLabels];
        [SettingsRowView setControlsInView:_transportSection enabled:theme.showTransportButtons];
        [SettingsRowView setControl:_transportButtonsSwitch enabled:YES];
        [SettingsRowView setControlsInView:_timeSection enabled:theme.showTimeLabels];
        [SettingsRowView setControl:_timeLabelsSwitch enabled:YES];
        [SettingsRowView setControl:_keyNotationPopUp enabled:info && showKey];
        [SettingsRowView setControl:_keyColorsSwitch enabled:info && showKey];
        // The slider governs nothing while the window draws the standard radius.
        [SettingsRowView setControl:_cornerRadiusSlider enabled:theme.customCornerRadius];
        NSString *style = [WaveformRendererRegistry resolveStyleIdentifier:theme.waveformStyle];
        [SettingsRowView setControl:_waveformBarDensitySlider
                enabled:[WaveformRendererRegistry supportsBarDensityForIdentifier:style]];
        [SettingsRowView setControl:_waveformBarWidthSlider
                enabled:[WaveformRendererRegistry supportsBarWidthForIdentifier:style]];
    }
    if (builtIn || (_fontEditingSlot == VibeFontSlotInfo
            && !(theme.showFileInfo || theme.showStatusIcons || theme.showTimeLabels))) {
        [self closeEditorPanels];
    }
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

- (void)dockIconChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.dockIcon = _dockIconPopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectAppIcon];
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
        NSError *error = nil;
        BOOL stored = [AppSettings.sharedInstance setCurrentThemeImageForKey:key
                themeIdentifier:target data:^{
            return [NSData dataWithContentsOfURL:panel.URL options:NSDataReadingMappedIfSafe error:NULL];
        } error:&error];
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
    }];
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

#pragma mark - Editor: info display

- (void)timeDisplayChanged:(NSButton *)sender {
    AppSettings.sharedInstance.currentTheme.showRemainingTime = (sender == _timeRemainingRadio);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
}

- (void)keyNotationChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.keyNotation = _keyNotationPopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
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

- (void)waveformThemeChanged:(id)sender {
    [self chooseFromPopUp:_waveformThemePopUp revealing:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM
                    wells:@[_customDarkRow, _customLightRow] effect:VibeSettingsLiveEffectWaveformTheme
                    write:^(AppTheme *theme, NSString *identifier) { theme.waveformTheme = identifier; }];
}

#pragma mark - Editor: playlist

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
    NSString *active = AppSettings.sharedInstance.activeThemeIdentifier;
    if ([AppTheme isBuiltInIdentifier:active]) {
        return;
    }
    // An edit that outlived a theme switch is dropped, never committed onto
    // the theme that is now active (see _nameFieldThemeIdentifier).
    if (![active isEqualToString:_nameFieldThemeIdentifier]) {
        [self refreshFromSettings];
        return;
    }
    [AppSettings.sharedInstance renameUserThemeWithIdentifier:active
                                                       toName:_nameField.stringValue];
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

// A well stays bound to the shared color panel until deactivated, even
// disabled or hidden, and would take the panel's next pick. TRAP: only an
// active well is deactivated: deactivate creates the shared color panel when
// none exists, and the panel's first layout brings up RenderBox's Metal
// device and the GPU driver's 256 MB texture heap.
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
