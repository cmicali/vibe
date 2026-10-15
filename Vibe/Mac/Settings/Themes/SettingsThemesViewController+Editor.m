//
//  SettingsThemesViewController+Editor.m
//  Vibe
//

#import "SettingsThemesViewController+Editor.h"
#import "SettingsThemesViewControllerInternal.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "Fonts.h"
#import "NSImage+Util.h"
#import "SettingsRules.h"
#import "VibeStrings.h"

static const CGFloat kImagePreviewSize = 64;
// The clear ✕ and missing (!) badges, box and glyph scaled by one factor.
static const CGFloat kImageBadgeSize = 22.5;       // 18 * 1.25
static const CGFloat kImageBadgePointSize = 16.25; // NSFont.systemFontSize * 1.25
// Inside the preview: a subview past its superview's bounds is not
// hit-tested, costing the (!) its tooltip and the ✕ its click target.
static const CGFloat kImageBadgeInset = 1.5;

@implementation SettingsThemesViewController (Editor)

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

// Bound to one side of the pair at base. Alpha is part of every choice but an
// opaque pair's (3-Band's bands): a fill's strength, a background's opacity, a
// waveform side's resting level.
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
        well.supportsAlpha = ![AppTheme storesOpaqueColorBase:base];
    } else {
        // Pre-14 wells follow the shared panel, which nothing else opens; an
        // opaque pair stores its alpha opaque.
        NSColorPanel.sharedColorPanel.showsAlpha = YES;
    }
    [well.widthAnchor constraintEqualToConstant:44].active = YES;
    [well.heightAnchor constraintEqualToConstant:24].active = YES;
    return well;
}

// [well caption] [well caption] … — one row per themed color set: Dark/Light,
// the waveform's Played/Unplayed, or 3-Band's Low/Mid/High.
- (NSStackView *)wells:(NSArray<NSView *> *)wells captions:(NSArray<NSString *> *)captions {
    NSStackView *row = [NSStackView stackViewWithViews:@[]];
    row.spacing = 6;
    for (NSUInteger i = 0; i < wells.count; i++) {
        NSTextField *label = [NSTextField labelWithString:captions[i]];
        label.textColor = NSColor.secondaryLabelColor;
        [row addArrangedSubview:wells[i]];
        [row addArrangedSubview:label];
        [row setCustomSpacing:16 afterView:label];
    }
    return row;
}

- (NSStackView *)captionedPairWithDark:(NSView *)dark light:(NSView *)light {
    return [self wells:@[dark, light] captions:@[STR_SETTINGS_THEME_DARK, STR_SETTINGS_THEME_LIGHT]];
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
    return [self wells:@[[self imageClusterForKey:darkKey], [self imageClusterForKey:lightKey]]
              captions:@[STR_SETTINGS_THEME_ON_DARK_ART, STR_SETTINGS_THEME_ON_LIGHT_ART]];
}

- (NSStackView *)artKeyedColorPairForBase:(NSString *)base {
    return [self wells:@[[self wellForDark:YES base:base effect:VibeSettingsLiveEffectTransportButtons],
                         [self wellForDark:NO base:base effect:VibeSettingsLiveEffectTransportButtons]]
              captions:@[STR_SETTINGS_THEME_ON_DARK_ART, STR_SETTINGS_THEME_ON_LIGHT_ART]];
}

// A setting's own value or the theme's custom one, which reveals its controls.
- (NSPopUpButton *)standardOrCustomPopUpWithAction:(SEL)action standard:(NSString *)standardTitle {
    NSPopUpButton *popUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:action];
    [self addItem:standardTitle value:kChoiceStandard to:popUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:popUp];
    return popUp;
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

// A glyph menu: each item the symbol alone, since its name is an identifier,
// never shown, and the system symbol carries its own accessibility
// description. Item 0, hidden, stands in for a stored glyph the menu does
// not list — a JSON-authored one — shown only while that is the selection
// (selectGlyph:in:).
- (NSPopUpButton *)glyphPopUpWithGlyphs:(NSArray<NSString *> *)glyphs action:(SEL)action {
    NSPopUpButton *popUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:action];
    NSMenuItem *unlisted = [[NSMenuItem alloc] initWithTitle:@"" action:NULL keyEquivalent:@""];
    unlisted.hidden = YES;
    [popUp.menu addItem:unlisted];
    for (NSString *glyph in glyphs) {
        [self addItem:@"" value:glyph to:popUp];
        popUp.lastItem.image = [NSImage imageWithSystemSymbolName:glyph accessibilityDescription:nil];
        popUp.lastItem.toolTip = VibeNotLocalized(glyph);
    }
    return popUp;
}

// Keyed by the button's dark image field. The color and image rows swap on
// whether an image is set (resolveLayoutStateFromSettings).
- (NSArray<SettingsRowView *> *)buttonRowsForImageKey:(NSString *)imageKey
                                                title:(NSString *)title
                                           colorTitle:(NSString *)colorTitle
                                            colorBase:(NSString *)colorBase
                                               glyphs:(NSArray<NSString *> *)glyphs
                                            imageRows:(NSArray<SettingsRowView *> *)imageRows {
    NSPopUpButton *popUp = [self glyphPopUpWithGlyphs:glyphs action:@selector(buttonGlyphChanged:)];
    popUp.identifier = imageKey;
    [popUp.menu addItem:NSMenuItem.separatorItem];
    [self addItem:STR_SETTINGS_THEME_BUTTON_CUSTOM_IMAGE value:kGlyphChoiceCustomImage to:popUp];
    SettingsRowView *colorRow = [SettingsRowView rowWithTitle:colorTitle
                                                      control:[self artKeyedColorPairForBase:colorBase]];
    _glyphPopUps[imageKey] = popUp;
    _buttonColorRows[imageKey] = colorRow;
    _buttonImageRows[imageKey] = imageRows;
    return [@[[SettingsRowView rowWithTitle:title control:popUp], colorRow]
            arrayByAddingObjectsFromArray:imageRows];
}

#pragma mark - Sections

- (void)buildEditorPage {
    _imagePreviews = [NSMutableDictionary dictionary];
    _imageClearBadges = [NSMutableDictionary dictionary];
    _imageMissingBadges = [NSMutableDictionary dictionary];
    _imagePickTokens = [NSMutableDictionary dictionary];
    _glyphPopUps = [NSMutableDictionary dictionary];
    _buttonColorRows = [NSMutableDictionary dictionary];
    _buttonImageRows = [NSMutableDictionary dictionary];
    // Name first: the Theme segment is the way back to the top.
    _editorJumpSections = @[
        [self buildNameSection],
        [self buildAppIconSection],
        [self buildWindowSection],
        [self buildPlayerSection],
        [self buildTransportSection],
        [self buildInfoSection],
        [self buildVolumeSection],
        [self buildPlaylistSection],
    ];
    // Short labels, since eight must fit the pane's minimum width; the
    // tooltips carry the cards' full headers.
    NSArray<NSString *> *jumpLabels = @[STR_SETTINGS_THEME_JUMP_THEME, STR_SETTINGS_THEME_JUMP_ICON,
                                        STR_SETTINGS_WINDOW_SECTION,
                                        STR_SETTINGS_THEME_JUMP_PLAYER, STR_SETTINGS_THEME_JUMP_BUTTONS,
                                        STR_SETTINGS_THEME_JUMP_INFO, STR_SETTINGS_THEME_JUMP_VOLUME,
                                        STR_SETTINGS_PLAYLIST_SECTION];
    _editorJumpControl = [NSSegmentedControl segmentedControlWithLabels:jumpLabels
                                                           trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                 target:self action:@selector(jumpToSection:)];
    _editorJumpControl.segmentStyle = NSSegmentStyleCapsule;
    _editorJumpControl.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSUInteger i = 0; i < _editorJumpSections.count; i++) {
        [_editorJumpControl setToolTip:_editorJumpSections[i].headerLabel.stringValue ?: STR_SETTINGS_THEME_NAME_LABEL
                            forSegment:(NSInteger)i];
    }

    SettingsStackView *editorStack =
            [[SettingsStackView alloc] initWithFrame:NSZeroRect];
    for (NSView *section in _editorJumpSections) {
        [editorStack addArrangedSubview:section];
    }
    _editorStack = editorStack;
    _editorStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _editorStack.alignment = NSLayoutAttributeLeading;
    _editorStack.spacing = 20;
    _editorStack.translatesAutoresizingMaskIntoConstraints = NO;
    _editorStack.wantsLayer = YES;
    for (NSView *section in _editorJumpSections) {
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
    [container addSubview:_editorJumpControl];
    [container addSubview:scroll];
    [self.view addSubview:container];
    _detailContainer = container;
    // The selected segment follows every scroll: by hand, a click's animation,
    // a search reveal and settings_reveal.
    scroll.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(editorDidScroll:)
                                               name:NSViewBoundsDidChangeNotification
                                             object:scroll.contentView];

    NSLayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:kPanePadding],
        [container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kPanePadding],
        [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kPanePadding],
        [container.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-kPanePadding],
        [_editorJumpControl.topAnchor constraintEqualToAnchor:container.topAnchor],
        [_editorJumpControl.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [scroll.topAnchor constraintEqualToAnchor:_editorJumpControl.bottomAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        // The flipped document view keeps the top in place across relayout.
        [_editorStack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [_editorStack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [_editorStack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];
}

#pragma mark - The jump bar

- (void)jumpToSection:(NSSegmentedControl *)sender {
    [SettingsPaneViewController scrollCardToTop:_editorJumpSections[(NSUInteger)sender.selectedSegment]
                                       animated:YES];
}

- (void)editorDidScroll:(NSNotification *)notification {
    [self syncEditorJumpSelection];
}

// The selected segment is the last card whose header sits at the top, within
// twice the reveal inset, which is where a reveal and a hand scroll leave it.
// Also run when the page shows, since no scroll fires then.
- (void)syncEditorJumpSelection {
    NSClipView *clip = _editorStack.enclosingScrollView.contentView;
    CGFloat top = NSMinY(clip.bounds) + 2 * kSettingsCardRevealInset;
    NSInteger selected = 0;
    for (NSUInteger i = 0; i < _editorJumpSections.count; i++) {
        if (NSMinY(_editorJumpSections[i].frame) <= top) {
            selected = (NSInteger)i;
        }
    }
    if (_editorJumpControl.selectedSegment != selected) {
        _editorJumpControl.selectedSegment = selected;
    }
}

- (SettingsSectionView *)buildNameSection {
    _nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _nameField.delegate = self;
    [_nameField.widthAnchor constraintEqualToConstant:kAppearancePopUpWidth].active = YES;
    _nameRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_NAME_LABEL control:_nameField];
    return [SettingsSectionView sectionWithRows:@[_nameRow]];
}

- (SettingsSectionView *)buildAppIconSection {
    NSView *appIconCluster = [self imageClusterForKey:kVibeThemeImageAppIcon];
    _appIconShapeSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectAppIcon
            write:^(AppTheme *theme, BOOL on) { theme.appIconShape = on; }];
    return [SettingsSectionView sectionWithHeader:STR_SETTINGS_THEME_APP_ICON rows:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_APP_ICON control:appIconCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_APP_ICON_SHAPE
                              caption:STR_SETTINGS_THEME_APP_ICON_SHAPE_CAPTION control:_appIconShapeSwitch],
    ]];
}

- (SettingsSectionView *)buildWindowSection {
    _modePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                     action:@selector(themeModeChanged:)];
    [self addItem:STR_SETTINGS_THEME_MODE_DUAL value:SETTINGS_VALUE_THEME_MODE_DUAL to:_modePopUp];
    [self addItem:STR_SETTINGS_THEME_MODE_SINGLE value:SETTINGS_VALUE_THEME_MODE_SINGLE to:_modePopUp];

    _cornerRadiusPopUp = [self standardOrCustomPopUpWithAction:@selector(cornerRadiusModeChanged:)
                                                     standard:STR_SETTINGS_THEME_STANDARD];

    _backgroundPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(backgroundStyleChanged:)];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_GLASS value:SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS to:_backgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_FROSTED value:SETTINGS_VALUE_WINDOW_BACKGROUND_FROSTED to:_backgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_SOLID value:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID to:_backgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_CLEAR value:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR to:_backgroundPopUp];
    _backgroundColorsPair = [self darkLightPairForBase:kVibeThemeColorWindowBackground
                                                effect:VibeSettingsLiveEffectWindowChrome];

    _windowTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(windowTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_windowTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_windowTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_windowTintPopUp];
    _windowTintPair = [self darkLightPairForBase:kVibeThemeColorWindowTint
                                          effect:VibeSettingsLiveEffectWindowTint];

    _cornerRadiusCluster = [self detentSliderClusterWithDetent:kVibeThemeCornerRadiusDefault
            min:0 max:kVibeThemeCornerRadiusMax action:@selector(cornerRadiusChanged:)
            width:kAppearancePopUpWidth slider:&_cornerRadiusSlider valueLabel:&_cornerRadiusValue];

    return [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_APPEARANCE control:_modePopUp],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BACKGROUND_LABEL
                             controls:@[_backgroundColorsPair, _backgroundPopUp]],
        [SettingsRowView rowWithTitle:STR_SETTINGS_BACKGROUND_TINT_LABEL
                             controls:@[_windowTintPair, _windowTintPopUp]],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_CORNER_RADIUS
                             controls:@[_cornerRadiusCluster, _cornerRadiusPopUp]],
    ]];
}

- (SettingsSectionView *)buildPlayerSection {
    _defaultArtworkPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(defaultArtworkChanged:)];
    [self addItem:STR_SETTINGS_THEME_DEFAULT_ARTWORK_ARTWORK value:SETTINGS_VALUE_DEFAULT_ARTWORK_ARTWORK to:_defaultArtworkPopUp];
    [self addItem:STR_SETTINGS_THEME_DEFAULT_ARTWORK_CLEAR value:SETTINGS_VALUE_DEFAULT_ARTWORK_CLEAR to:_defaultArtworkPopUp];
    [self addItem:STR_SETTINGS_THEME_DEFAULT_ARTWORK_WINDOW value:SETTINGS_VALUE_DEFAULT_ARTWORK_WINDOW to:_defaultArtworkPopUp];
    [self addItem:STR_SETTINGS_THEME_DEFAULT_ARTWORK_GLYPH value:SETTINGS_VALUE_DEFAULT_ARTWORK_GLYPH to:_defaultArtworkPopUp];
    [self addItem:STR_SETTINGS_THEME_DEFAULT_ARTWORK_CUSTOM value:SETTINGS_VALUE_DEFAULT_ARTWORK_CUSTOM to:_defaultArtworkPopUp];
    NSStackView *artPair = [self darkLightPairWithDark:
            [self imageClusterForKey:kVibeThemeImageDefaultArtworkDark]
            light:[self imageClusterForKey:kVibeThemeImageDefaultArtworkLight]];
    _defaultArtworkImageRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_DEFAULT_ARTWORK_IMAGE control:artPair];
    _defaultArtworkColorsPair = [self darkLightPairForBase:kVibeThemeColorDefaultArtwork
                                                    effect:kVibeThemeDefaultArtworkEffect];
    _defaultArtworkGlyphPopUp = [self glyphPopUpWithGlyphs:VibeDefaultArtworkGlyphs()
                                                    action:@selector(defaultArtworkGlyphChanged:)];
    NSStackView *glyphColors = [self darkLightPairForBase:kVibeThemeColorDefaultArtworkGlyph
                                                   effect:kVibeThemeDefaultArtworkEffect];
    SettingsRowView *glyphRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_DEFAULT_ARTWORK_GLYPH
                                                     controls:@[glyphColors, _defaultArtworkGlyphPopUp]];
    _defaultArtworkGlyphNameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _defaultArtworkGlyphNameField.delegate = self;
    _defaultArtworkGlyphNameField.placeholderString = VibeNotLocalized(kVibeThemeDefaultArtworkGlyphDefault);
    [_defaultArtworkGlyphNameField.widthAnchor constraintEqualToConstant:kAppearancePopUpWidth].active = YES;
    _defaultArtworkGlyphNameRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_DEFAULT_ARTWORK_GLYPH_NAME
                                                        control:_defaultArtworkGlyphNameField];
    NSStackView *glyphSizeCluster = [self detentSliderClusterWithDetent:kVibeThemeDefaultArtworkGlyphSizeDefault
            min:kVibeThemeDefaultArtworkGlyphSizeMin max:kVibeThemeDefaultArtworkGlyphSizeMax
            action:@selector(defaultArtworkGlyphSizeChanged:)
            width:kAppearancePopUpWidth slider:&_defaultArtworkGlyphSizeSlider valueLabel:&_defaultArtworkGlyphSizeValue];
    _defaultArtworkGlyphRows = @[glyphRow, _defaultArtworkGlyphNameRow,
                                 [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_DEFAULT_ARTWORK_GLYPH_SIZE
                                                       control:glyphSizeCluster]];
    NSMutableArray<SettingsRowView *> *rows = [NSMutableArray arrayWithArray:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_ALBUM_ART
                             controls:@[_defaultArtworkColorsPair, _defaultArtworkPopUp]],
        _defaultArtworkImageRow,
    ]];
    [rows addObjectsFromArray:_defaultArtworkGlyphRows];
    [rows addObjectsFromArray:[self buildWaveformRows]];

    // Title and artist paint the playlist rows too.
    NSStackView *titleColors = [self darkLightPairForBase:kVibeThemeColorTitle
            effect:VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance];
    NSStackView *artistColors = [self darkLightPairForBase:kVibeThemeColorArtist
            effect:VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance];
    NSTextField *titleFontValue = nil;
    NSStackView *titleFontCluster = [self fontClusterForSlot:VibeFontSlotTitle valueLabel:&titleFontValue];
    NSTextField *artistFontValue = nil;
    NSStackView *artistFontCluster = [self fontClusterForSlot:VibeFontSlotArtist valueLabel:&artistFontValue];
    _titleFontValue = titleFontValue;
    _artistFontValue = artistFontValue;

    [rows addObjectsFromArray:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_MAIN control:titleFontCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TITLE control:titleColors],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_ARTIST control:artistFontCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_ARTIST control:artistColors],
    ]];
    return [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYER_SECTION rows:rows];
}

- (NSArray<SettingsRowView *> *)buildWaveformRows {
    _waveformPopUp = [self waveformStylePopUpButton];
    _waveformTypePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformTypeChanged:)];
    _waveformTypeRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_TYPE control:_waveformTypePopUp];
    NSStackView *densityCluster = [self detentSliderClusterWithDetent:kVibeThemeWaveformBarScaleDefault
            min:kVibeThemeWaveformBarScaleMin max:kVibeThemeWaveformBarScaleMax
            action:@selector(waveformBarSizingChanged:)
            width:kAppearancePopUpWidth slider:&_waveformBarDensitySlider valueLabel:&_waveformBarDensityValue];
    NSStackView *widthCluster = [self detentSliderClusterWithDetent:kVibeThemeWaveformBarScaleDefault
            min:kVibeThemeWaveformBarScaleMin max:kVibeThemeWaveformBarScaleMax
            action:@selector(waveformBarSizingChanged:)
            width:kAppearancePopUpWidth slider:&_waveformBarWidthSlider valueLabel:&_waveformBarWidthValue];
    _waveformThemePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformThemeChanged:)];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_MONO value:SETTINGS_VALUE_WAVEFORM_THEME_MONO to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ORANGE value:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART value:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_CUSTOM value:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM to:_waveformThemePopUp];
    _spectrumPalettePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(spectrumPaletteChanged:)];
    for (NSString *palette in VibeWaveformSpectrumPalettes()) {
        [self addItem:VibeWaveformSpectrumPaletteDisplayName(palette) value:palette to:_spectrumPalettePopUp];
    }

    _waveformGradientSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectWaveformTheme
            write:^(AppTheme *theme, BOOL on) { theme.waveformGradient = on; }];
    _waveformCenteredSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectWaveformStyle
            write:^(AppTheme *theme, BOOL on) { theme.waveformCentered = on; }];
    _waveformPlayheadSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectWaveformTheme
            write:^(AppTheme *theme, BOOL on) { theme.waveformPlayheadLine = on; }];
    _playheadColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_PLAYHEAD_COLOR
            control:[self darkLightPairForBase:kVibeThemeColorWaveformPlayhead
                                        effect:VibeSettingsLiveEffectWaveformTheme]];
    NSStackView *(^wellRow)(NSArray<NSString *> *, NSArray<NSString *> *, BOOL) =
            ^(NSArray<NSString *> *bases, NSArray<NSString *> *captions, BOOL dark) {
        NSMutableArray<NSColorWell *> *wells = [NSMutableArray array];
        for (NSString *base in bases) {
            [wells addObject:[self wellForDark:dark base:base effect:VibeSettingsLiveEffectWaveformTheme]];
        }
        return [self wells:wells captions:captions];
    };
    NSArray<NSString *> *sides = @[kVibeThemeColorWaveformPlayed, kVibeThemeColorWaveformUnplayed];
    NSArray<NSString *> *sideCaptions = @[STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED, STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED];
    _customDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL
                                           control:wellRow(sides, sideCaptions, YES)];
    _customLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_LIGHT_LABEL
                                            control:wellRow(sides, sideCaptions, NO)];
    _waveformThemeRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_COLOR control:_waveformThemePopUp];
    _spectrumPaletteRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_COLOR
                                                control:_spectrumPalettePopUp];
    NSArray<NSString *> *bands = @[kVibeThemeColorWaveformLow, kVibeThemeColorWaveformMid,
                                   kVibeThemeColorWaveformHigh];
    NSArray<NSString *> *bandCaptions = @[STR_SETTINGS_WAVEFORM_BAND_LOW, STR_SETTINGS_WAVEFORM_BAND_MID,
                                          STR_SETTINGS_WAVEFORM_BAND_HIGH];
    _bandsDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL
                                          control:wellRow(bands, bandCaptions, YES)];
    _bandsLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_LIGHT_LABEL
                                           control:wellRow(bands, bandCaptions, NO)];
    _waveformShadeOverlapsSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectWaveformTheme
            write:^(AppTheme *theme, BOOL on) { theme.waveformShadeOverlaps = on; }];
    _shadeOverlapsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_SHADE_OVERLAPS
                                              control:_waveformShadeOverlapsSwitch];

    return @[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_STYLE control:_waveformPopUp],
        _waveformTypeRow,
        [SettingsRowView rowWithContentView:[self waveformPreviewView]],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_BAR_DENSITY control:densityCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_BAR_WIDTH control:widthCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CENTERED control:_waveformCenteredSwitch],
        _waveformThemeRow,
        _spectrumPaletteRow,
        _customDarkRow,
        _customLightRow,
        _bandsDarkRow,
        _bandsLightRow,
        _shadeOverlapsRow,
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_GRADIENT control:_waveformGradientSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_PLAYHEAD_LINE control:_waveformPlayheadSwitch],
        _playheadColorsRow,
    ];
}

- (SettingsSectionView *)buildTransportSection {
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

    NSMutableArray<SettingsRowView *> *transportRows = [@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SHOW_TRANSPORT_BUTTONS control:_transportButtonsSwitch],
        // Said once here, so each well's caption can be two words.
        [SettingsRowView rowWithContentView:[self wrappingLabelWithString:STR_SETTINGS_TRANSPORT_ART_EXPLAIN]],
    ] mutableCopy];
    [transportRows addObjectsFromArray:playlistButtonRows];
    [transportRows addObjectsFromArray:playButtonRows];
    [transportRows addObjectsFromArray:nextButtonRows];
    [transportRows addObject:[SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BUTTON_GRADIENT control:_buttonGradientPopUp]];

    _transportSection = [SettingsSectionView sectionWithHeader:STR_SETTINGS_TRANSPORT_SECTION rows:transportRows];
    return _transportSection;
}

- (SettingsSectionView *)buildInfoSection {
    // Info and time appear only in the header, so their drags skip the table
    // reload.
    NSStackView *infoColors = [self darkLightPairForBase:kVibeThemeColorInfo
            effect:VibeSettingsLiveEffectTrackDisplay];
    NSStackView *timeColors = [self darkLightPairForBase:kVibeThemeColorTime
            effect:VibeSettingsLiveEffectTrackDisplay];
    NSTextField *infoFontValue = nil;
    NSStackView *infoFontCluster = [self fontClusterForSlot:VibeFontSlotInfo valueLabel:&infoFontValue];
    _infoFontValue = infoFontValue;

    return [SettingsSectionView sectionWithHeader:STR_SETTINGS_INFO_SECTION rows:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_INFO control:infoFontCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_INFO control:infoColors],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TIMES control:timeColors],
    ]];
}

- (SettingsSectionView *)buildVolumeSection {
    _volumeBarPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(volumeBarChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_volumeBarPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_volumeBarPopUp];
    [self addItem:STR_SETTINGS_THEME_VOLUME_WAVEFORM value:SETTINGS_VALUE_VOLUME_WAVEFORM to:_volumeBarPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_volumeBarPopUp];
    // Every waveform theme resolution re-resolves the slider's fill and knob,
    // so a well drag takes that effect rather than Volume's relayout.
    _volumeBarPair = [self darkLightPairForBase:kVibeThemeColorVolumeBar
                                         effect:VibeSettingsLiveEffectWaveformTheme];
    _volumeKnobPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(volumeKnobChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_volumeKnobPopUp];
    [self addItem:STR_SETTINGS_THEME_VOLUME_KNOB_BAR value:SETTINGS_VALUE_VOLUME_KNOB_BAR to:_volumeKnobPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_volumeKnobPopUp];
    [self addItem:STR_SETTINGS_THEME_VOLUME_WAVEFORM value:SETTINGS_VALUE_VOLUME_WAVEFORM to:_volumeKnobPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_volumeKnobPopUp];
    _volumeKnobPair = [self darkLightPairForBase:kVibeThemeColorVolumeKnob
                                          effect:VibeSettingsLiveEffectWaveformTheme];
    _volumeLabelsSwitch = [self themeSwitchWithEffect:VibeSettingsLiveEffectVolume
            write:^(AppTheme *theme, BOOL on) { theme.showVolumeLabels = on; }];
    _volumeLocationPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(volumeLocationChanged:)];
    [self addItem:STR_SETTINGS_THEME_VOLUME_LOCATION_BOTTOM value:SETTINGS_VALUE_VOLUME_LOCATION_BOTTOM
               to:_volumeLocationPopUp];
    [self addItem:STR_SETTINGS_THEME_VOLUME_LOCATION_TOP_RIGHT value:SETTINGS_VALUE_VOLUME_LOCATION_TOP_RIGHT
               to:_volumeLocationPopUp];
    _volumeVisibilityPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                                 action:@selector(volumeVisibilityChanged:)];
    [self addItem:STR_SETTINGS_THEME_VOLUME_VISIBILITY_ALWAYS value:SETTINGS_VALUE_VOLUME_VISIBILITY_ALWAYS
               to:_volumeVisibilityPopUp];
    [self addItem:STR_SETTINGS_THEME_VOLUME_VISIBILITY_HOVER_CLOSE value:SETTINGS_VALUE_VOLUME_VISIBILITY_HOVER_CLOSE
               to:_volumeVisibilityPopUp];
    [self addItem:STR_SETTINGS_THEME_VOLUME_VISIBILITY_HOVER_EXACT value:SETTINGS_VALUE_VOLUME_VISIBILITY_HOVER_EXACT
               to:_volumeVisibilityPopUp];

    return [SettingsSectionView sectionWithHeader:STR_SETTINGS_VOLUME_SECTION rows:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_VOLUME_LOCATION
                              caption:STR_SETTINGS_THEME_VOLUME_LOCATION_CAPTION
                              control:_volumeLocationPopUp],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_VOLUME_VISIBILITY control:_volumeVisibilityPopUp],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SHOW_VOLUME_LABELS control:_volumeLabelsSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_VOLUME_BAR controls:@[_volumeBarPair, _volumeBarPopUp]],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_VOLUME_KNOB controls:@[_volumeKnobPair, _volumeKnobPopUp]],
    ]];
}

// Automatic or Custom, with the pair's wells beside the choice.
- (SettingsRowView *)switchedPlaylistColorRowForBase:(NSString *)base title:(NSString *)title {
    NSPopUpButton *popUp = [self standardOrCustomPopUpWithAction:@selector(playlistColorModeChanged:)
                                                       standard:STR_SETTINGS_THEME_AUTOMATIC];
    popUp.identifier = base;
    NSStackView *pair = [self darkLightPairForBase:base effect:VibeThemePlaylistColorEditEffect(base)];
    _playlistColorPopUps[base] = popUp;
    _playlistColorPairs[base] = pair;
    return [SettingsRowView rowWithTitle:title controls:@[pair, popUp]];
}

- (SettingsSectionView *)buildPlaylistSection {
    _playlistBackgroundPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                                   action:@selector(playlistBackgroundStyleChanged:)];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_GLASS value:SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS to:_playlistBackgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_SOLID value:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID to:_playlistBackgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_CLEAR value:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR to:_playlistBackgroundPopUp];

    // The background is one layer color and the row colors skip the cell
    // rebuild, so their drags take lighter effects than PlaylistAppearance.
    _playlistBackgroundColorsPair = [self darkLightPairForBase:kVibeThemeColorPlaylistBackground
                                                        effect:VibeSettingsLiveEffectPlaylistBackground];

    _playlistTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                             action:@selector(playlistTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_playlistTintPopUp];
    _playlistTintPair = [self darkLightPairForBase:kVibeThemeColorPlaylistTint
                                            effect:VibeSettingsLiveEffectWindowTint];

    _playlistColorPopUps = [NSMutableDictionary dictionary];
    _playlistColorPairs = [NSMutableDictionary dictionary];

    NSTextField *playlistFontValue = nil;
    NSStackView *playlistFontCluster = [self fontClusterForSlot:VibeFontSlotPlaylist valueLabel:&playlistFontValue];
    NSTextField *playlistDurationFontValue = nil;
    NSStackView *playlistDurationFontCluster =
            [self fontClusterForSlot:VibeFontSlotPlaylistDuration
                          valueLabel:&playlistDurationFontValue];
    _playlistFontValue = playlistFontValue;
    _playlistDurationFontValue = playlistDurationFontValue;

    return [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYLIST_SECTION rows:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BACKGROUND_LABEL
                             controls:@[_playlistBackgroundColorsPair, _playlistBackgroundPopUp]],
        [SettingsRowView rowWithTitle:STR_SETTINGS_BACKGROUND_TINT_LABEL
                             controls:@[_playlistTintPair, _playlistTintPopUp]],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_PLAYLIST control:playlistFontCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_PLAYLIST_DURATION
                control:playlistDurationFontCluster],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistNumber
                                        title:STR_SETTINGS_THEME_PLAYLIST_NUMBER_COLOR],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistTitle title:STR_SETTINGS_THEME_COLOR_TITLE],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistArtist title:STR_SETTINGS_THEME_COLOR_ARTIST],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistDuration
                                        title:STR_SETTINGS_THEME_PLAYLIST_DURATION_COLOR],
        // Each row fill, then its columns' text in the columns' order.
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYING_ROW
                control:[self darkLightPairForBase:kVibeThemeColorPlaylistPlayingRow
                                            effect:VibeSettingsLiveEffectPlaylistRowColors]],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistPlayingRowNumber
                                        title:STR_SETTINGS_THEME_PLAYING_ROW_NUMBER],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistPlayingRowTitle
                                        title:STR_SETTINGS_THEME_PLAYING_ROW_TITLE],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistPlayingRowArtist
                                        title:STR_SETTINGS_THEME_PLAYING_ROW_ARTIST],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistPlayingRowDuration
                                        title:STR_SETTINGS_THEME_PLAYING_ROW_DURATION],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYING_ROW_EQUALIZER
                control:[self darkLightPairForBase:kVibeThemeColorPlaylistEqualizer
                                            effect:VibeSettingsLiveEffectPlaylistRowColors]],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SELECTED_ROW
                control:[self darkLightPairForBase:kVibeThemeColorPlaylistSelectedRow
                                            effect:VibeSettingsLiveEffectPlaylistRowColors]],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistSelectedRowNumber
                                        title:STR_SETTINGS_THEME_SELECTED_ROW_NUMBER],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistSelectedRowTitle
                                        title:STR_SETTINGS_THEME_SELECTED_ROW_TITLE],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistSelectedRowArtist
                                        title:STR_SETTINGS_THEME_SELECTED_ROW_ARTIST],
        [self switchedPlaylistColorRowForBase:kVibeThemeColorPlaylistSelectedRowDuration
                                        title:STR_SETTINGS_THEME_SELECTED_ROW_DURATION],
    ]];
}

@end
