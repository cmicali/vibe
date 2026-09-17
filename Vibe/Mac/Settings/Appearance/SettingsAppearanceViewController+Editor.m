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
// The glyph an unset button image slot previews, at the transport row's
// own glyph size.
static const CGFloat kImagePreviewGlyphPointSize = 31;
// The two corner badges over an image preview — the clear ✕ and the
// missing-image (!) — sized as one pair. The box carries a little more than
// the glyph, which is the inset they sit at; scaling both by the same factor
// keeps that. SF Symbols quantize a point size to whole points, so the glyph
// lands near, not exactly on, the box's own ratio.
static const CGFloat kImageBadgeSize = 22.5;       // 18 * 1.25
static const CGFloat kImageBadgePointSize = 16.25; // NSFont.systemFontSize * 1.25
// Both badges sit fully INSIDE the preview, at this inset from its corners.
// They stay inside deliberately: a subview hanging past its superview's bounds
// is not hit-tested, which would cost the (!) its tooltip and the ✕ most of its
// click target.
static const CGFloat kImageBadgeInset = 1.5;

// A color well's binding to one side of its theme pair; see wellForDark:base:effect:.
static NSString *const kWellBase = @"base";
static NSString *const kWellEffect = @"effect";
static NSString *const kWellDark = @"dark";

// The transport buttons' glyph popups' last item: a custom image in place of
// any glyph. Not a symbol-name shape, so it can never reach a glyph field.
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

// A well bound to one side of a themed color pair, by the pair's base key: it
// reads its color through the theme's display accessor (the override, or the
// unset slot's constant), writes it through the base setter, and requests the
// effect. Alpha is part of the choice: a fill's strength, the solid
// background's opacity, a waveform side's resting level.
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
        // Pre-14 a well follows the shared panel, and nothing else in the app
        // opens it, so the global flag is safe.
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

// Both sides of one themed color pair as the Dark/Light row control.
- (NSStackView *)darkLightPairForBase:(NSString *)base effect:(VibeSettingsLiveEffect)effect {
    return [self darkLightPairWithDark:[self wellForDark:YES base:base effect:effect]
                                 light:[self wellForDark:NO base:base effect:effect]];
}

// A transport button's pairs — image previews, or its color wells — are
// art-keyed (see kVibeThemeColorPlaylistButton), so they are captioned like
// every pair but never registered with the single-mode collapse.
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

// A font row's trailing cluster: the current choice, then Select…, which
// opens the font panel onto that slot.
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

// One image field's picker: a preview of what the slot resolves to as the
// click target (click picks a custom image), with a hover-revealed clear
// badge over its corner while a custom image is set. The badge is a real
// button so the walker can address it by its undrawn title. System Settings
// appearance-picker shape. The field key rides both buttons' identifiers,
// which is how their shared actions find the slot.
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
    // The missing-image badge mirrors that clear badge across the preview, and
    // is NOT hover-gated: it reports a state rather than offering an action,
    // and a warning nobody can see without hovering the thing it warns about
    // is no warning. An image view, not a button — there is nothing to press,
    // and a button would promise one to VoiceOver.
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
        // Pinned to the glyph's size: the undrawn title still feeds the
        // button's intrinsic width, which stretched it across the preview.
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
    // The controller owns the hover tracking; userInfo names the field, since
    // every cluster shares one owner. ActiveInActiveApp, not ActiveInKeyWindow:
    // the font or color panel is often key while this page is edited, and the
    // badge must still appear. Posted debug events cannot fire it — the window
    // server drives tracking areas — so a scripted clear needs a real hover
    // (input.swift).
    [cluster addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
                    | NSTrackingInVisibleRect
            owner:self userInfo:@{@"imageField": key}]];
    _imagePreviews[key] = preview;
    _imageClearBadges[key] = clear;
    _imageMissingBadges[key] = missing;
    return cluster;
}

// One transport button's editor rows — the glyph popup, the color pair a
// glyph is drawn in, and the custom image pair(s) that replace the glyph —
// keyed by the button's dark image field, which its popup and rows are
// looked up by. The color and image rows swap on whether an image is set
// (resolveLayoutStateFromSettings): a glyph has a color, a picture has its
// own.
- (NSArray<SettingsRowView *> *)buttonRowsForImageKey:(NSString *)imageKey
                                                title:(NSString *)title
                                           colorTitle:(NSString *)colorTitle
                                            colorBase:(NSString *)colorBase
                                               glyphs:(NSArray<NSString *> *)glyphs
                                            imageRows:(NSArray<SettingsRowView *> *)imageRows {
    NSPopUpButton *popUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                               action:@selector(buttonGlyphChanged:)];
    popUp.identifier = imageKey;
    // The symbol names are identifiers — what SF Symbols calls them — shown
    // beside the glyph itself rather than given thirty display names apiece.
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

// What a slot's preview shows: the placeholder pair its resolved image (the
// factory record when unset), the app icon whatever the application holds —
// the composed custom icon or the bundle's, since the AppIcon effect has
// already landed by refresh time — and a button slot what draws over that
// side's art: its own picture, else the other side's, else the glyph, so an
// unset side is never a blank square.
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

- (NSStackView *)waveformBarControlWithSlider:(NSSlider *__strong *)outSlider
                                 valueLabel:(NSTextField *__strong *)outLabel {
    VibeDetentSlider *slider = [VibeDetentSlider sliderWithValue:kVibeThemeWaveformBarScaleDefault
            minValue:kVibeThemeWaveformBarScaleMin maxValue:kVibeThemeWaveformBarScaleMax
            target:self action:@selector(waveformBarSizingChanged:)];
    slider.detentValue = kVibeThemeWaveformBarScaleDefault;
    slider.continuous = YES;
    [slider.widthAnchor constraintEqualToConstant:kAppearancePopUpWidth].active = YES;
    NSTextField *label = [NSTextField labelWithString:@""];
    label.textColor = NSColor.secondaryLabelColor;
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
    _appIconShapeSwitch = [self switchWithAction:@selector(toggleAppIconShape:)];
    _customCornerRadiusSwitch = [self switchWithAction:@selector(toggleCustomCornerRadius:)];

    // Default artwork follows the color pairs: one preview per appearance
    // under Light & Dark Modes, collapsing to the dark-keyed one — the single
    // slot's home — under Single Mode.
    NSStackView *artPair = [self darkLightPairWithDark:
            [self imageClusterForKey:kVibeThemeImageDefaultArtworkDark]
            light:[self imageClusterForKey:kVibeThemeImageDefaultArtworkLight]];

    // The three transport buttons, each a glyph popup with a color pair, or
    // a custom image; the play button's picture is a play/pause pair, one
    // per state, captioned like the color pairs.
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
    _transportButtonsSwitch = [self switchWithAction:@selector(toggleThemeVisibility:)];
    _buttonGradientPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(buttonGradientChanged:)];
    [self addItem:STR_SETTINGS_THEME_BUTTON_GRADIENT_NONE value:SETTINGS_VALUE_BUTTON_GRADIENT_NONE to:_buttonGradientPopUp];
    [self addItem:STR_SETTINGS_THEME_BUTTON_GRADIENT_HOVER value:SETTINGS_VALUE_BUTTON_GRADIENT_HOVER to:_buttonGradientPopUp];
    [self addItem:STR_SETTINGS_THEME_BUTTON_GRADIENT_ARTWORK value:SETTINGS_VALUE_BUTTON_GRADIENT_ARTWORK to:_buttonGradientPopUp];
    [self addItem:STR_SETTINGS_THEME_BUTTON_GRADIENT_ALWAYS value:SETTINGS_VALUE_BUTTON_GRADIENT_ALWAYS to:_buttonGradientPopUp];

    _backgroundPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(backgroundStyleChanged:)];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_GLASS value:SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS to:_backgroundPopUp];
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

    VibeDetentSlider *radiusSlider = [VibeDetentSlider sliderWithValue:kVibeThemeCornerRadiusDefault
                                                              minValue:0 maxValue:kVibeThemeCornerRadiusMax
                                                                target:self action:@selector(cornerRadiusChanged:)];
    radiusSlider.detentValue = kVibeThemeCornerRadiusDefault;
    _cornerRadiusSlider = radiusSlider;
    _cornerRadiusSlider.continuous = YES;
    [_cornerRadiusSlider.widthAnchor constraintEqualToConstant:kAppearancePopUpWidth].active = YES;
    _cornerRadiusValue = [NSTextField labelWithString:@""];
    _cornerRadiusValue.textColor = NSColor.secondaryLabelColor;
    // Right-aligned at a fixed width, so the readout's changing digit count
    // never nudges the slider.
    _cornerRadiusValue.alignment = NSTextAlignmentRight;
    [_cornerRadiusValue.widthAnchor constraintEqualToConstant:50].active = YES;
    NSStackView *radiusCluster = [NSStackView stackViewWithViews:
            @[_cornerRadiusSlider, _cornerRadiusValue]];
    radiusCluster.spacing = 10;

    _playlistBackgroundPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                                   action:@selector(playlistBackgroundStyleChanged:)];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_GLASS value:SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS to:_playlistBackgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_SOLID value:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID to:_playlistBackgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_CLEAR value:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR to:_playlistBackgroundPopUp];

    _fileInfoSwitch = [self switchWithAction:@selector(toggleThemeVisibility:)];
    _statusIconsSwitch = [self switchWithAction:@selector(toggleThemeVisibility:)];
    _timeLabelsSwitch = [self switchWithAction:@selector(toggleThemeVisibility:)];
    _timeTotalRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_TOTAL
                                              target:self action:@selector(timeDisplayChanged:)];
    _timeRemainingRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_REMAINING
                                                  target:self action:@selector(timeDisplayChanged:)];
    NSStackView *timeRadios = [NSStackView stackViewWithViews:@[_timeTotalRadio, _timeRemainingRadio]];
    timeRadios.spacing = 12;
    _showBPMSwitch = [self switchWithAction:@selector(toggleShowBPM:)];
    _showKeySwitch = [self switchWithAction:@selector(toggleShowKey:)];
    _keyNotationPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(keyNotationChanged:)];
    [self addItem:STR_SETTINGS_KEY_NOTATION_CAMELOT value:SETTINGS_VALUE_KEY_NOTATION_CAMELOT to:_keyNotationPopUp];
    [self addItem:STR_SETTINGS_KEY_NOTATION_MUSICAL value:SETTINGS_VALUE_KEY_NOTATION_MUSICAL to:_keyNotationPopUp];
    _keyColorsSwitch = [self switchWithAction:@selector(toggleKeyColors:)];

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
    NSStackView *densityCluster = [self waveformBarControlWithSlider:&_waveformBarDensitySlider
            valueLabel:&_waveformBarDensityValue];
    NSStackView *widthCluster = [self waveformBarControlWithSlider:&_waveformBarWidthSlider
            valueLabel:&_waveformBarWidthValue];
    _waveformThemePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformThemeChanged:)];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_MONO value:SETTINGS_VALUE_WAVEFORM_THEME_MONO to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ORANGE value:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART value:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_CUSTOM value:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM to:_waveformThemePopUp];

    _waveformGradientSwitch = [self switchWithAction:@selector(toggleWaveformGradient:)];
    _playlistArtworkSwitch = [self switchWithAction:@selector(togglePlaylistArtwork:)];
    _playlistDurationSwitch = [self switchWithAction:@selector(togglePlaylistDuration:)];
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

    // The playlist background is one layer color the cells never read, and
    // the row fills are read per draw, so their drags take the lighter effects
    // rather than the full PlaylistAppearance rebuild.
    _playlistBackgroundColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_BACKGROUND_COLORS
            control:[self darkLightPairForBase:kVibeThemeColorPlaylistBackground
                                        effect:VibeSettingsLiveEffectPlaylistBackground]];

    // The playlist's tint mirrors the window's: the same three choices, the
    // same custom-color rows shown only under Custom.
    _playlistTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                             action:@selector(playlistTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_playlistTintPopUp];
    _playlistTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
            control:[self wellForDark:YES base:kVibeThemeColorPlaylistTint effect:VibeSettingsLiveEffectWindowTint]];
    _playlistTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
            control:[self wellForDark:NO base:kVibeThemeColorPlaylistTint effect:VibeSettingsLiveEffectWindowTint]];

    // A switch row per playlist column, each revealing its pair's row below
    // it — in column order, the number column first.
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
        NSSwitch *toggle = [self switchWithAction:@selector(togglePlaylistColor:)];
        toggle.identifier = base; // how the action finds the column, like the image buttons
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
        // The pair swaps visibility — exactly one shows — so the second row
        // must not keep the between-rows hairline the section stamps on it.
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
    scroll.drawsBackground = NO;
    // Without this, macOS 26 associates the scroll view with the titlebar
    // above it and builds a scroll pocket — a full-column blur band whose
    // hard bottom edge reads as a stray hairline over the editor page. The
    // scroll view starts below the toolbar, so there is nothing to inset.
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
        // The standard vertical-scroll pinning — top, leading and width, the
        // height left to the content. What keeps the resting position at the
        // top through a relayout is the document view being flipped, above.
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
    // A single-mode theme has one color per field, so every Dark/Light pair
    // collapses to one well — the dark-keyed well, the single slot's home —
    // with the captions hidden, and the per-side rows keep only that one.
    BOOL single = theme.isSingleMode;
    // The per-side rows lose their side with it: one color, so "Dark color"
    // names a half the theme does not have — and that title is what the
    // debug walker addresses the row by.
    [_windowTintDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
                                           : STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL];
    [_playlistTintDarkRow setRowTitle:single ? STR_SETTINGS_THEME_COLOR_LABEL
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
    _backgroundColorsRow.hidden = ![theme.windowBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    BOOL customPlaylistTint = [theme.playlistTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    _playlistTintDarkRow.hidden = !customPlaylistTint;
    _playlistTintLightRow.hidden = !customPlaylistTint || single;
    _playlistBackgroundColorsRow.hidden = ![theme.playlistBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    for (NSString *base in _playlistColorRows) {
        _playlistColorRows[base].hidden = ![theme playlistColorEnabledForBase:base];
    }
    // A button dressed in a picture has no glyph color to edit, and one
    // drawing a glyph has no picture to show.
    for (NSString *key in _glyphPopUps) {
        BOOL hasImage = [self buttonHasImageForKey:key];
        _buttonColorRows[key].hidden = hasImage;
        for (SettingsRowView *row in _buttonImageRows[key]) {
            row.hidden = !hasImage;
        }
    }
    [self applyEditorVisibility];
}

// One depth-first descendant walk; the leaf actions (enable, deactivate)
// ride it rather than re-rolling the recursion each time.
static void ForEachDescendantView(NSView *view, void (^block)(NSView *)) {
    for (NSView *subview in view.subviews) {
        block(subview);
        ForEachDescendantView(subview, block);
    }
}

static void SetDescendantControlsEnabled(NSView *view, BOOL enabled) {
    ForEachDescendantView(view, ^(NSView *subview) {
        if ([subview isKindOfClass:NSControl.class]) {
            [SettingsRowView setControl:(NSControl *)subview enabled:enabled];
            if (!enabled && [subview isKindOfClass:NSColorWell.class]) {
                [(NSColorWell *)subview deactivate];
            }
        }
    });
}

// The editor, from the working theme. (The name/built-in row swap lives in
// resolveLayoutStateFromSettings with the other conditional rows.)
- (void)refreshEditorFromSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;
    NSString *active = settings.activeThemeIdentifier;
    BOOL builtIn = [AppTheme isBuiltInIdentifier:active];
    // Skip while the field editor is open, or a refresh mid-type (a menu
    // open/close, the window regaining key) would silently discard the edit —
    // unless the active theme changed under it: then the edit belongs to a
    // theme this page no longer shows, and keeping it would commit onto the
    // wrong one, so it is dropped instead.
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

    [self refreshFontValueLabels];

    // Read-only built-ins: every editor control disables, honestly reported
    // by the debug walker; then the always-live sub-rules re-apply.
    SetDescendantControlsEnabled(_editorStack, !builtIn);
    // The built-in page's one live control sits inside the swept stack now
    // that the caption row is a card row: without this, a built-in could
    // never be duplicated from its own page. Observed, not hypothetical.
    [SettingsRowView setControl:_duplicateButton enabled:YES];
    if (!builtIn) {
        BOOL info = theme.showFileInfo;
        for (SettingsRowView *row in _fileInfoRows) {
            SetDescendantControlsEnabled(row, info);
        }
        // These readouts share one font, even when only one group is visible.
        SetDescendantControlsEnabled(_infoFontRow, info || theme.showStatusIcons || theme.showTimeLabels);
        SetDescendantControlsEnabled(_transportSection, theme.showTransportButtons);
        [SettingsRowView setControl:_transportButtonsSwitch enabled:YES];
        SetDescendantControlsEnabled(_timeSection, theme.showTimeLabels);
        [SettingsRowView setControl:_timeLabelsSwitch enabled:YES];
        // Key notation and key colors additionally require Show key.
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

// Which color slot every consumer reads moves with the mode, so the whole
// theme re-applies.
- (void)themeModeChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.mode =
            _modePopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings]; // ends in resolveLayoutStateFromSettings
}

// Writes each well's displayed color into its slot, so the surface
// immediately matches what the wells show when a popup reveals them. A set
// slot writes its own value back, unchanged; an unset one takes the
// display accessor's constant. Dark wells FIRST: under single mode both
// reads and writes canonicalize to the dark-keyed slot, so the dark pass
// seeds it and the light pass reads that back — the one slot takes the dark
// default with no special case.
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

// The one action every themed well sends: write the side, request the
// pair's effect.
- (void)colorWellChanged:(NSColorWell *)sender {
    NSDictionary *binding = [_wellBindings objectForKey:sender];
    [AppSettings.sharedInstance.currentTheme setColor:sender.color forBase:binding[kWellBase]
                                                 dark:[binding[kWellDark] boolValue]];
    [self themeFieldDidChange:(VibeSettingsLiveEffect)[binding[kWellEffect] unsignedIntegerValue]
                   continuous:YES];
}

// The one gesture behind every popup that reveals color rows — the two
// background styles, the two tints, the waveform theme: the choice that
// consumes the pair seeds its wells first, so the surface immediately matches
// what they show; then the field, the effect, and the row reveal.
- (void)chooseFromPopUp:(NSPopUpButton *)popUp revealing:(NSString *)revealing
                  wells:(NSArray<NSView *> *)rows effect:(VibeSettingsLiveEffect)effect
                  write:(void (^)(AppTheme *theme, NSString *identifier))write {
    NSString *identifier = popUp.selectedItem.representedObject;
    if ([identifier isEqualToString:revealing]) {
        [self seedWellsIn:rows];
    }
    write(AppSettings.sharedInstance.currentTheme, identifier);
    [self themeFieldDidChange:effect];
    [self resolveLayoutStateFromSettings];
}

#pragma mark - Editor: window

- (void)backgroundStyleChanged:(id)sender {
    [self chooseFromPopUp:_backgroundPopUp revealing:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID
                    wells:@[_backgroundColorsRow] effect:VibeSettingsLiveEffectWindowChrome
                    write:^(AppTheme *theme, NSString *identifier) { theme.windowBackgroundStyle = identifier; }];
}

- (void)windowTintChanged:(id)sender {
    [self chooseFromPopUp:_windowTintPopUp revealing:SETTINGS_VALUE_WINDOW_TINT_CUSTOM
                    wells:@[_windowTintDarkRow, _windowTintLightRow] effect:VibeSettingsLiveEffectWindowTint
                    write:^(AppTheme *theme, NSString *identifier) { theme.windowTint = identifier; }];
}

- (void)toggleAppIconShape:(id)sender {
    AppSettings.sharedInstance.currentTheme.appIconShape = (_appIconShapeSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectAppIcon];
}

- (void)dockIconChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.dockIcon = _dockIconPopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectAppIcon];
}

- (void)togglePlaylistColor:(NSSwitch *)sender {
    [AppSettings.sharedInstance.currentTheme
            setPlaylistColorEnabled:(sender.state == NSControlStateValueOn) forBase:sender.identifier];
    [self themeFieldDidChange:VibeSettingsLiveEffectPlaylistAppearance];
    [self resolveLayoutStateFromSettings]; // the pair's row reveals with it
}

- (void)toggleCustomCornerRadius:(id)sender {
    AppSettings.sharedInstance.currentTheme.customCornerRadius =
            (_customCornerRadiusSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowChrome];
    [self refreshFromSettings]; // the slider enables with it
}

- (void)cornerRadiusChanged:(id)sender {
    // A magnetic detent at the standard radius — the reset, without a button:
    // dragging near it snaps onto it. The sanitize gate rounds to whole
    // points; the knob re-syncs to what actually landed.
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

// The clear badge shows only while there is something to clear: a non-empty
// reference in the hovered slot, on an editable page. Read live — the value,
// the page and the enable state can all have changed since the last hover.
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
    [self refreshFromSettings]; // also hides the badge — the cursor is still over it
}

- (void)chooseImage:(NSButton *)sender {
    [self chooseImageForKey:sender.identifier];
}

- (void)chooseImageForKey:(NSString *)key {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[UTTypeJPEG, UTTypePNG];
    // The sheet blocks the window, not the menu bar — View > Theme can switch
    // the active theme underneath it, so bind the write to the theme that was
    // active when the panel opened (the async-delivery rule).
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

// A glyph pick retires the button's picture — the picture wins over the
// glyph while set, so leaving it would make the pick a no-op; Custom image…
// opens the panel for the button's (first) slot and, cancelled, refreshes
// the popup back to the glyph.
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

- (void)toggleThemeVisibility:(NSSwitch *)sender {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL show = sender.state == NSControlStateValueOn;
    VibeSettingsLiveEffect effect = VibeSettingsLiveEffectTrackDisplay;
    if (sender == _transportButtonsSwitch) {
        theme.showTransportButtons = show;
        effect = VibeSettingsLiveEffectTransportButtons;
    } else if (sender == _statusIconsSwitch) {
        theme.showStatusIcons = show;
    } else if (sender == _timeLabelsSwitch) {
        theme.showTimeLabels = show;
    } else {
        theme.showFileInfo = show;
    }
    [self themeFieldDidChange:effect];
    [self refreshFromSettings];
}

- (void)timeDisplayChanged:(NSButton *)sender {
    AppSettings.sharedInstance.currentTheme.showRemainingTime = (sender == _timeRemainingRadio);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
}

- (void)toggleShowBPM:(id)sender {
    AppSettings.sharedInstance.currentTheme.showBPM = (_showBPMSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
}

- (void)toggleShowKey:(id)sender {
    AppSettings.sharedInstance.currentTheme.showKey = (_showKeySwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
    // With Show key off the two rows below it have nothing to govern, so they
    // dim rather than pretending a write would change anything on screen.
    [self refreshFromSettings];
}

- (void)keyNotationChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.keyNotation = _keyNotationPopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
}

- (void)toggleKeyColors:(id)sender {
    AppSettings.sharedInstance.currentTheme.keyColorsEnabled = (_keyColorsSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
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

- (void)toggleWaveformGradient:(id)sender {
    AppSettings.sharedInstance.currentTheme.waveformGradient =
            (_waveformGradientSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectWaveformTheme];
}

- (void)waveformThemeChanged:(id)sender {
    [self chooseFromPopUp:_waveformThemePopUp revealing:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM
                    wells:@[_customDarkRow, _customLightRow] effect:VibeSettingsLiveEffectWaveformTheme
                    write:^(AppTheme *theme, NSString *identifier) { theme.waveformTheme = identifier; }];
}

#pragma mark - Editor: playlist

- (void)togglePlaylistArtwork:(id)sender {
    AppSettings.sharedInstance.currentTheme.showPlaylistArtworkColumn =
            (_playlistArtworkSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectPlaylistAppearance];
}

- (void)togglePlaylistDuration:(id)sender {
    AppSettings.sharedInstance.currentTheme.showPlaylistDurationColumn =
            (_playlistDurationSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectPlaylistAppearance];
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
// and would eat the font panel's sends to restyle the name. selectFont: parks
// first responder to open the panel clear of it; this is the same trap reached
// from the other side, once the panel is already up.
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
    // changeFont: and would eat the panel's sends to restyle the Name field —
    // park first responder on the pane's own view before opening the panel.
    [self.view.window makeFirstResponder:self.view];
    NSFontManager *manager = NSFontManager.sharedFontManager;
    [manager setSelectedFont:[Fonts fontForSlot:_fontEditingSlot bold:NO] isMultiple:NO];
    [manager orderFrontFontPanel:self];
}

- (NSFontPanelModeMask)validModesForFontPanel:(NSFontPanel *)fontPanel {
    return NSFontPanelModeMaskCollection | NSFontPanelModeMaskFace | NSFontPanelModeMaskSize;
}

// Continuous browsing in the panel lands here per pick — a live preview for
// free. The store clamps the size; face names resolve through Fonts'
// never-nil fallback at draw time.
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

// Editor teardown: close the font panel and deactivate every color well.
// A well stays bound to the shared NSColorPanel until deactivated — disabling
// or hiding it does not — so a well left active on a departed or now read-only
// page would take the panel's next pick. Every caller is a page leave or a
// switch to a built-in.
- (void)closeEditorPanels {
    _fontEditingSlot = VibeFontSlotNone;
    if (NSFontPanel.sharedFontPanelExists) {
        [NSFontPanel.sharedFontPanel orderOut:nil];
    }
    ForEachDescendantView(self.view, ^(NSView *subview) {
        if ([subview isKindOfClass:NSColorWell.class]) {
            [(NSColorWell *)subview deactivate];
        }
    });
}

@end
