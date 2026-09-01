//
//  SettingsAppearanceViewController.m
//  Vibe
//
// Two pages in one pane, System Settings style. The LIST page holds the
// common settings — appearance and traffic lights, the two appearance choices
// that live outside any theme — and the theme list, where selection IS
// activation. The EDITOR page, a sibling of the pane's section stack that
// swaps in over it, edits the active theme's every field; a built-in shows
// read-only with Duplicate as the customization path.
//
// The editor deliberately never joins the shared pane-size settlement: it
// scrolls inside whatever size the panes settled at, because its ~20 rows
// would otherwise grow every pane of a window that cannot be resized. The
// page swap is therefore size-neutral, and the editor's conditional rows
// reflow only their own scrolled stack.
//

#import "SettingsAppearanceViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AppSettings.h"
#import "Fonts.h"
#import "NSImage+Util.h"
#import "WaveformRendererRegistry.h"
#import "MainPlayerController+Menus.h"
#import "MainPlayerController+Settings.h"
#import "SettingsWindowController.h" // the toolbar navigation control follows the pane's pages
#import "VibeStrings.h"

static const CGFloat kAppearancePopUpWidth = 220;
static const CGFloat kAlbumArtPreviewSize = 64;
// The two corner badges over an artwork preview — the clear ✕ and the
// missing-image (!) — sized as one pair. The box carries a little more than
// the glyph, which is the inset they sit at; scaling both by the same factor
// keeps that. SF Symbols quantize a point size to whole points, so the glyph
// lands near, not exactly on, the box's own ratio.
static const CGFloat kAlbumArtBadgeSize = 22.5;       // 18 * 1.25
static const CGFloat kAlbumArtBadgePointSize = 16.25; // NSFont.systemFontSize * 1.25
// Both badges sit fully INSIDE the preview, at this inset from its corners.
// They stay inside deliberately: a subview hanging past its superview's bounds
// is not hit-tested, which would cost the (!) its tooltip and the ✕ most of its
// click target.
static const CGFloat kAlbumArtBadgeInset = 1.5;

static const CGFloat kThemeListRowHeight = 22;
// Ten rows: the two group headers, the built-ins, and room for a handful of
// the user's own before it scrolls.
static const CGFloat kThemeListHeight = 10 * kThemeListRowHeight;
static NSString *const kThemeCellIdentifier = @"themeCell";

// A color well's binding to its theme pair; see wellForDark:display:set:effect:.
typedef VibeColor *(^ThemeColorGetter)(AppTheme *theme, BOOL isDark);
typedef void (^ThemeColorSetter)(AppTheme *theme, VibeColor *color, BOOL isDark);
static NSString *const kWellDisplay = @"display";
static NSString *const kWellSet = @"set";
static NSString *const kWellEffect = @"effect";
static NSString *const kWellDark = @"dark";
static NSString *const kThemeGroupCellIdentifier = @"themeGroupCell";

// The corner-radius slider, with a tick above and below the track at the
// factory default — the visual for the action's magnetic detent. NSSlider's
// own tick marks are evenly spaced and single-sided, so the pair is drawn
// here; the knob geometry mirrors AppKit's linear layout (half the knob
// inset at each end).
@interface VibeDetentSlider : NSSlider
@end

@implementation VibeDetentSlider

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    if (self.maxValue <= self.minValue) {
        return;
    }
    CGFloat knob = ((NSSliderCell *)self.cell).knobThickness;
    CGFloat fraction = (kVibeThemeCornerRadiusDefault - self.minValue)
            / (self.maxValue - self.minValue);
    CGFloat x = round(knob / 2 + fraction * (NSWidth(self.bounds) - knob));
    CGFloat midY = NSMidY(self.bounds);
    [[NSColor.secondaryLabelColor colorWithAlphaComponent:0.6] setFill];
    NSRectFillUsingOperation(NSMakeRect(x - 0.5, midY + 5, 1, 4), NSCompositingOperationSourceOver);
    NSRectFillUsingOperation(NSMakeRect(x - 0.5, midY - 9, 1, 4), NSCompositingOperationSourceOver);
}

@end

@interface SettingsAppearanceViewController ()
        <NSTableViewDataSource, NSTableViewDelegate, NSFontChanging, NSTextFieldDelegate>
@end

@implementation SettingsAppearanceViewController {
    // The list page.
    NSPopUpButton *_appearancePopUp;
    NSSwitch *_trafficLightsSwitch;
    NSTableView *_themeTable;
    NSPopUpButton *_addThemeButton;
    NSButton *_removeThemeButton;
    NSButton *_editThemeButton;
    NSButton *_exportThemeButton;
    // The themes in store order: built-ins first, then user themes. The table
    // shows a group header above each run, so a row is one past the headers
    // before it rather than an index into this — see identifierForRow:.
    NSArray<NSString *> *_themeIdentifiers;
    // The pane's own sections, kept so the editor swap can hide them — the
    // stack itself is the base class's.
    NSArray<NSView *> *_listSections;

    // The editor page.
    NSView *_detailContainer;
    NSButton *_duplicateButton;
    SettingsRowView *_builtInRow;
    NSStackView *_editorStack;
    SettingsSectionView *_infoSection;
    NSTextField *_nameField;
    // The theme the name field's text was populated for. The rename commit
    // reads the ACTIVE identifier, and the active theme can change while the
    // field editor is open (View > Theme works while this window is key), so
    // without this capture a commit would rename whatever theme is now active
    // to the old one's half-typed text — the album-art sheet's stale-target
    // drop, for the field editor.
    NSString *_nameFieldThemeIdentifier;
    SettingsRowView *_nameRow;
    NSPopUpButton *_backgroundPopUp;
    SettingsRowView *_backgroundColorsRow;
    NSPopUpButton *_windowTintPopUp;
    SettingsRowView *_windowTintDarkRow, *_windowTintLightRow;
    VibeDetentSlider *_cornerRadiusSlider;
    NSTextField *_cornerRadiusValue;
    NSSwitch *_fileInfoSwitch;
    NSButton *_timeTotalRadio, *_timeRemainingRadio;
    NSSwitch *_showBPMSwitch, *_showKeySwitch;
    NSPopUpButton *_keyNotationPopUp;
    NSSwitch *_keyColorsSwitch;
    NSSwitch *_waveformGradientSwitch;
    NSSwitch *_playlistArtworkSwitch;
    NSPopUpButton *_modePopUp;
    NSButton *_artDarkPreviewButton;
    NSButton *_artDarkClearButton;
    NSImageView *_artDarkMissingBadge;
    NSButton *_artLightPreviewButton;
    NSButton *_artLightClearButton;
    NSImageView *_artLightMissingBadge;
    NSSwitch *_playlistDurationSwitch;
    // Every Dark/Light well pair, for the fixed-theme collapse to one well.
    NSMutableArray<NSStackView *> *_darkLightPairs;
    // Every themed color well → how it reads, writes and repaints its side
    // of its pair (wellForDark:display:set:effect:). One action, one refresh
    // loop and one seed walk serve all of them.
    NSMapTable<NSColorWell *, NSDictionary *> *_wellBindings;
    NSPopUpButton *_waveformPopUp;
    // The list page's shortcut to the same theme field as _waveformPopUp.
    NSPopUpButton *_listWaveformPopUp;
    NSPopUpButton *_waveformThemePopUp;
    // A played/unplayed pair per appearance — one pair cannot read on both
    // backdrops.
    SettingsRowView *_customDarkRow, *_customLightRow;
    NSPopUpButton *_playlistBackgroundPopUp;
    SettingsRowView *_playlistBackgroundColorsRow;
    NSPopUpButton *_playlistTintPopUp;
    SettingsRowView *_playlistTintDarkRow, *_playlistTintLightRow;
    NSTextField *_titleFontValue, *_artistFontValue, *_infoFontValue, *_playlistFontValue;
    NSTextField *_playlistDurationFontValue;
    // The font panel's target slot, carried as the Select buttons' tags. None
    // while the panel is not editing a slot; changeFont: no-ops then, which is
    // what keeps a stray panel from restyling anything.
    VibeFontSlot _fontEditingSlot;
    BOOL _editorShown;
    // Armed by a Back pop; the toolbar's forward half re-opens the editor.
    BOOL _editorForwardAvailable;
    // Reentrancy guard: reloadData and the programmatic reselect both post
    // selection-changed, and the delegate treating those as user activations
    // recursed refreshFromSettings into a stack overflow. Observed, not
    // hypothetical.
    BOOL _refreshingThemeList;
}

#pragma mark - Construction

- (void)loadView {
    [self buildListControls];
    [self loadPaneWithSections:_listSections];
    [self buildEditorPage];
}

- (void)buildListControls {
    _appearancePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                           action:@selector(appearanceChanged:)];
    [self addItem:STR_MENU_APPEARANCE_SYSTEM value:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT to:_appearancePopUp];
    [self addItem:STR_MENU_APPEARANCE_LIGHT value:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT to:_appearancePopUp];
    [self addItem:STR_MENU_APPEARANCE_DARK value:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK to:_appearancePopUp];

    _trafficLightsSwitch = [self switchWithAction:@selector(toggleTrafficLights:)];

    _themeTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _themeTable.headerView = nil;
    _themeTable.allowsMultipleSelection = NO;
    _themeTable.allowsEmptySelection = NO;
    _themeTable.dataSource = self;
    _themeTable.delegate = self;
    _themeTable.rowHeight = kThemeListRowHeight;
    _themeTable.target = self;
    _themeTable.doubleAction = @selector(editTheme:);
    [_themeTable addTableColumn:[[NSTableColumn alloc] initWithIdentifier:kThemeCellIdentifier]];
    [_themeTable registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.documentView = _themeTable;
    scrollView.hasVerticalScroller = YES;
    scrollView.borderType = NSBezelBorder;
    [scrollView.heightAnchor constraintEqualToConstant:kThemeListHeight].active = YES;

    _addThemeButton = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [_addThemeButton addItemWithTitle:STR_SETTINGS_THEME_ADD];
    [_addThemeButton addItemWithTitle:STR_SETTINGS_THEME_ADD_NEW];
    _addThemeButton.lastItem.target = self;
    _addThemeButton.lastItem.action = @selector(addNewTheme:);
    [_addThemeButton addItemWithTitle:STR_SETTINGS_THEME_DUPLICATE];
    _addThemeButton.lastItem.target = self;
    _addThemeButton.lastItem.action = @selector(duplicateTheme:);
    [_addThemeButton addItemWithTitle:STR_SETTINGS_THEME_IMPORT];
    _addThemeButton.lastItem.target = self;
    _addThemeButton.lastItem.action = @selector(importTheme:);
    _removeThemeButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_REMOVE
                                            target:self action:@selector(removeTheme:)];
    _editThemeButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_EDIT
                                          target:self action:@selector(editTheme:)];
    _exportThemeButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_EXPORT
                                            target:self action:@selector(exportTheme:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:
            @[_addThemeButton, _removeThemeButton, _editThemeButton, _exportThemeButton]];
    buttons.spacing = 8;
    SettingsRowView *buttonRow = [SettingsRowView rowWithContentView:buttons];

    // The waveform style is a THEME field surfaced on the list page: it
    // follows every theme switch, and editing it here goes through the same
    // working-record funnel as the editor's row — over a built-in it lands
    // in the divergence key rather than dirtying the theme.
    _listWaveformPopUp = [self waveformStylePopUpButton];

    _listSections = @[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_APPEARANCE_LABEL control:_appearancePopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_TRAFFIC_LIGHTS control:_trafficLightsSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_SECTION control:_listWaveformPopUp],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_THEMES_SECTION rows:@[
            [SettingsRowView rowWithContentView:scrollView],
            buttonRow,
        ]],
    ];
    // The buttons act on the list right above them; the hairline the section
    // stamps between rows reads as a divider between two unrelated ones.
    buttonRow.showsTopSeparator = NO;
}

// A well bound to one side of a themed color pair: it reads its color through
// the theme's display accessor (the override, or the unset slot's constant),
// writes it through the setter, and requests the effect. Alpha is part of the
// choice: a fill's strength, the solid background's opacity, a waveform
// side's resting level.
- (NSColorWell *)wellForDark:(BOOL)isDark
                     display:(ThemeColorGetter)display
                         set:(ThemeColorSetter)set
                      effect:(VibeSettingsLiveEffect)effect {
    NSColorWell *well = [[NSColorWell alloc] init];
    well.target = self;
    well.action = @selector(colorWellChanged:);
    if (!_wellBindings) {
        _wellBindings = [NSMapTable strongToStrongObjectsMapTable];
    }
    [_wellBindings setObject:@{kWellDisplay: [display copy], kWellSet: [set copy],
                               kWellEffect: @(effect), kWellDark: @(isDark)}
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

- (NSStackView *)darkLightPairWithDark:(NSView *)dark light:(NSView *)light {
    NSStackView *pair = [self wellPair:dark caption:STR_SETTINGS_THEME_DARK
                                  well:light caption:STR_SETTINGS_THEME_LIGHT];
    if (!_darkLightPairs) {
        _darkLightPairs = [NSMutableArray array];
    }
    [_darkLightPairs addObject:pair];
    return pair;
}

// Both sides of one themed color pair as the Dark/Light row control.
- (NSStackView *)darkLightPairDisplay:(ThemeColorGetter)display
                                  set:(ThemeColorSetter)set
                               effect:(VibeSettingsLiveEffect)effect {
    return [self darkLightPairWithDark:[self wellForDark:YES display:display set:set effect:effect]
                                 light:[self wellForDark:NO display:display set:set effect:effect]];
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

// One side of the Default artwork pair: a preview of that side's resolved
// placeholder as the click target (click picks a custom image), with a
// hover-revealed clear badge over its corner while a custom image is set.
// The badge is a real button so the walker can address it by its undrawn
// title. System Settings appearance-picker shape.
- (NSView *)albumArtClusterForDark:(BOOL)isDark {
    NSButton *preview = [NSButton buttonWithImage:[AppTheme imageForDefaultArtwork:@""]
                                           target:self action:@selector(chooseAlbumArt:)];
    preview.bordered = NO;
    preview.title = @""; // the factory's "Button" would name it in the walker
    preview.wantsLayer = YES;
    preview.layer.cornerRadius = 6;
    preview.layer.masksToBounds = YES;
    ((NSButtonCell *)preview.cell).imageScaling = NSImageScaleProportionallyUpOrDown;
    NSButton *clear = [NSButton buttonWithImage:[NSImage symbolNamed:@"xmark.circle.fill"
            pointSize:kAlbumArtBadgePointSize weight:NSFontWeightRegular
              palette:@[NSColor.whiteColor, [NSColor colorWithWhite:0 alpha:0.6]]
            accessibilityDescription:STR_SETTINGS_THEME_ALBUM_ART_CLEAR]
                                         target:self action:@selector(clearCustomArtwork:)];
    clear.bordered = NO;
    clear.title = STR_SETTINGS_THEME_ALBUM_ART_CLEAR; // image-only: named, never drawn
    clear.imagePosition = NSImageOnly;
    clear.hidden = YES;
    // The missing-image badge mirrors that clear badge across the preview, and
    // is NOT hover-gated: it reports a state rather than offering an action,
    // and a warning nobody can see without hovering the thing it warns about
    // is no warning. An image view, not a button — there is nothing to press,
    // and a button would promise one to VoiceOver.
    NSImageView *missing = [NSImageView imageViewWithImage:[NSImage
            symbolNamed:@"exclamationmark.circle.fill"
              pointSize:kAlbumArtBadgePointSize weight:NSFontWeightRegular
                palette:@[NSColor.whiteColor, NSColor.systemRedColor]
            accessibilityDescription:STR_SETTINGS_THEME_ALBUM_ART_MISSING]];
    missing.toolTip = STR_SETTINGS_THEME_ALBUM_ART_MISSING;
    missing.accessibilityLabel = STR_SETTINGS_THEME_ALBUM_ART_MISSING;
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
        [cluster.widthAnchor constraintEqualToConstant:kAlbumArtPreviewSize],
        [cluster.heightAnchor constraintEqualToConstant:kAlbumArtPreviewSize],
        [preview.leadingAnchor constraintEqualToAnchor:cluster.leadingAnchor],
        [preview.trailingAnchor constraintEqualToAnchor:cluster.trailingAnchor],
        [preview.topAnchor constraintEqualToAnchor:cluster.topAnchor],
        [preview.bottomAnchor constraintEqualToAnchor:cluster.bottomAnchor],
        // Pinned to the glyph's size: the undrawn title still feeds the
        // button's intrinsic width, which stretched it across the preview.
        [clear.widthAnchor constraintEqualToConstant:kAlbumArtBadgeSize],
        [clear.heightAnchor constraintEqualToConstant:kAlbumArtBadgeSize],
        [clear.topAnchor constraintEqualToAnchor:cluster.topAnchor
                                        constant:kAlbumArtBadgeInset],
        [clear.trailingAnchor constraintEqualToAnchor:cluster.trailingAnchor
                                             constant:-kAlbumArtBadgeInset],
        [missing.widthAnchor constraintEqualToConstant:kAlbumArtBadgeSize],
        [missing.heightAnchor constraintEqualToConstant:kAlbumArtBadgeSize],
        [missing.topAnchor constraintEqualToAnchor:cluster.topAnchor
                                          constant:kAlbumArtBadgeInset],
        [missing.leadingAnchor constraintEqualToAnchor:cluster.leadingAnchor
                                              constant:kAlbumArtBadgeInset],
    ]];
    // The controller owns the hover tracking; userInfo names the side, since
    // both clusters share one owner. ActiveInActiveApp, not ActiveInKeyWindow:
    // the font or color panel is often key while this page is edited, and the
    // badge must still appear. Posted debug events cannot fire it — the window
    // server drives tracking areas — so a scripted clear needs a real hover
    // (input.swift).
    [cluster addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp
                    | NSTrackingInVisibleRect
            owner:self userInfo:@{@"artClearForDark": @(isDark)}]];
    if (isDark) {
        _artDarkPreviewButton = preview;
        _artDarkClearButton = clear;
        _artDarkMissingBadge = missing;
    } else {
        _artLightPreviewButton = preview;
        _artLightClearButton = clear;
        _artLightMissingBadge = missing;
    }
    return cluster;
}

- (void)buildEditorPage {
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

    // Default artwork follows the color pairs: one preview per appearance
    // under Light & Dark Modes, collapsing to the dark-keyed one — the single
    // slot's home — under Single Mode.
    NSStackView *artPair = [self darkLightPairWithDark:[self albumArtClusterForDark:YES]
                                                 light:[self albumArtClusterForDark:NO]];

    _backgroundPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(backgroundStyleChanged:)];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_GLASS value:SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS to:_backgroundPopUp];
    [self addItem:STR_SETTINGS_THEME_BACKGROUND_SOLID value:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID to:_backgroundPopUp];
    _backgroundColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BACKGROUND_COLORS
            control:[self darkLightPairDisplay:^(AppTheme *t, BOOL dark) { return [t displayWindowBackgroundColorForDark:dark]; }
                                           set:^(AppTheme *t, VibeColor *c, BOOL dark) { [t setWindowBackgroundColor:c forDark:dark]; }
                                        effect:VibeSettingsLiveEffectWindowChrome]];

    _windowTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(windowTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_windowTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_windowTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_windowTintPopUp];
    ThemeColorGetter windowTintDisplay = ^(AppTheme *t, BOOL dark) { return [t displayWindowTintColorForDark:dark]; };
    ThemeColorSetter windowTintSet = ^(AppTheme *t, VibeColor *c, BOOL dark) { [t setWindowTintColor:c forDark:dark]; };
    _windowTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
            control:[self wellForDark:YES display:windowTintDisplay set:windowTintSet
                                effect:VibeSettingsLiveEffectWindowTint]];
    _windowTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
            control:[self wellForDark:NO display:windowTintDisplay set:windowTintSet
                                effect:VibeSettingsLiveEffectWindowTint]];

    _cornerRadiusSlider = [VibeDetentSlider sliderWithValue:kVibeThemeCornerRadiusDefault
                                                   minValue:0 maxValue:kVibeThemeCornerRadiusMax
                                                     target:self action:@selector(cornerRadiusChanged:)];
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

    _fileInfoSwitch = [self switchWithAction:@selector(toggleFileInfo:)];
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
    NSStackView *titleColors = [self darkLightPairDisplay:^(AppTheme *t, BOOL dark) { return [t displayTitleColorForDark:dark]; }
            set:^(AppTheme *t, VibeColor *c, BOOL dark) { [t setTitleColor:c forDark:dark]; }
            effect:VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance];
    NSStackView *artistColors = [self darkLightPairDisplay:^(AppTheme *t, BOOL dark) { return [t displayArtistColorForDark:dark]; }
            set:^(AppTheme *t, VibeColor *c, BOOL dark) { [t setArtistColor:c forDark:dark]; }
            effect:VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance];
    NSStackView *infoColors = [self darkLightPairDisplay:^(AppTheme *t, BOOL dark) { return [t displayInfoColorForDark:dark]; }
            set:^(AppTheme *t, VibeColor *c, BOOL dark) { [t setInfoColor:c forDark:dark]; }
            effect:VibeSettingsLiveEffectTrackDisplay];
    NSStackView *timeColors = [self darkLightPairDisplay:^(AppTheme *t, BOOL dark) { return [t displayTimeColorForDark:dark]; }
            set:^(AppTheme *t, VibeColor *c, BOOL dark) { [t setTimeColor:c forDark:dark]; }
            effect:VibeSettingsLiveEffectTrackDisplay];

    _waveformPopUp = [self waveformStylePopUpButton];
    _waveformThemePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformThemeChanged:)];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_MONO value:SETTINGS_VALUE_WAVEFORM_THEME_MONO to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ORANGE value:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART value:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_CUSTOM value:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM to:_waveformThemePopUp];

    _waveformGradientSwitch = [self switchWithAction:@selector(toggleWaveformGradient:)];
    _playlistArtworkSwitch = [self switchWithAction:@selector(togglePlaylistArtwork:)];
    _playlistDurationSwitch = [self switchWithAction:@selector(togglePlaylistDuration:)];
    ThemeColorGetter playedDisplay = ^(AppTheme *t, BOOL dark) { return [t displayWaveformPlayedColorForDark:dark]; };
    ThemeColorSetter playedSet = ^(AppTheme *t, VibeColor *c, BOOL dark) { [t setWaveformPlayedColor:c forDark:dark]; };
    ThemeColorGetter unplayedDisplay = ^(AppTheme *t, BOOL dark) { return [t displayWaveformUnplayedColorForDark:dark]; };
    ThemeColorSetter unplayedSet = ^(AppTheme *t, VibeColor *c, BOOL dark) { [t setWaveformUnplayedColor:c forDark:dark]; };
    NSStackView *(^customWells)(BOOL) = ^(BOOL dark) {
        return [self wellPair:[self wellForDark:dark display:playedDisplay set:playedSet
                                          effect:VibeSettingsLiveEffectWaveformTheme]
                      caption:STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED
                         well:[self wellForDark:dark display:unplayedDisplay set:unplayedSet
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
            control:[self darkLightPairDisplay:^(AppTheme *t, BOOL dark) { return [t displayPlaylistBackgroundColorForDark:dark]; }
                                           set:^(AppTheme *t, VibeColor *c, BOOL dark) { [t setPlaylistBackgroundColor:c forDark:dark]; }
                                        effect:VibeSettingsLiveEffectPlaylistBackground]];

    // The playlist's tint mirrors the window's: the same three choices, the
    // same custom-color rows shown only under Custom.
    _playlistTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                             action:@selector(playlistTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_playlistTintPopUp];
    ThemeColorGetter playlistTintDisplay = ^(AppTheme *t, BOOL dark) { return [t displayPlaylistTintColorForDark:dark]; };
    ThemeColorSetter playlistTintSet = ^(AppTheme *t, VibeColor *c, BOOL dark) { [t setPlaylistTintColor:c forDark:dark]; };
    _playlistTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
            control:[self wellForDark:YES display:playlistTintDisplay set:playlistTintSet
                                effect:VibeSettingsLiveEffectWindowTint]];
    _playlistTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
            control:[self wellForDark:NO display:playlistTintDisplay set:playlistTintSet
                                effect:VibeSettingsLiveEffectWindowTint]];

    NSStackView *playingRowColors = [self darkLightPairDisplay:^(AppTheme *t, BOOL dark) { return [t displayPlaylistPlayingRowColorForDark:dark]; }
            set:^(AppTheme *t, VibeColor *c, BOOL dark) { [t setPlaylistPlayingRowColor:c forDark:dark]; }
            effect:VibeSettingsLiveEffectPlaylistRowFills];
    NSStackView *selectedRowColors = [self darkLightPairDisplay:^(AppTheme *t, BOOL dark) { return [t displayPlaylistSelectedRowColorForDark:dark]; }
            set:^(AppTheme *t, VibeColor *c, BOOL dark) { [t setPlaylistSelectedRowColor:c forDark:dark]; }
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

    // The Info section is captured so its rows can be disabled as a group
    // when Show file info is off (see resolveLayoutStateFromSettings).
    _infoSection = [SettingsSectionView sectionWithHeader:STR_SETTINGS_INFO_SECTION rows:@[
        [SettingsRowView rowWithTitle:STR_SETTINGS_FILE_INFO control:_fileInfoSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_INFO control:infoFontCluster],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_INFO control:infoColors],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TIMES control:timeColors],
        [SettingsRowView rowWithTitle:STR_SETTINGS_TIME_LABEL control:timeRadios],
        [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_BPM control:_showBPMSwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_KEY control:_showKeySwitch],
        [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_NOTATION_LABEL control:_keyNotationPopUp],
        [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_COLORS control:_keyColorsSwitch],
    ]];

    NSArray<NSView *> *sections = @[
        // The pair swaps visibility — exactly one shows — so the second row
        // must not keep the between-rows hairline the section stamps on it.
        [SettingsSectionView sectionWithRows:@[_builtInRow, _nameRow]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_APPEARANCE control:_modePopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BACKGROUND_LABEL control:_backgroundPopUp],
            _backgroundColorsRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_BACKGROUND_TINT_LABEL control:_windowTintPopUp],
            _windowTintDarkRow,
            _windowTintLightRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_CORNER_RADIUS control:radiusCluster],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYER_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_ALBUM_ART control:artPair],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_MAIN control:titleFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TITLE control:titleColors],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_ARTIST control:artistFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_ARTIST control:artistColors],
        ]],
        _infoSection,
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WAVEFORM_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_LABEL control:_waveformPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_THEME_LABEL control:_waveformThemePopUp],
            _customDarkRow,
            _customLightRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_GRADIENT control:_waveformGradientSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYLIST_SECTION rows:@[
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
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYING_ROW control:playingRowColors],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SELECTED_ROW control:selectedRowColors],
        ]],
    ];

    _nameRow.showsTopSeparator = NO;
    _editorStack = [NSStackView stackViewWithViews:sections];
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
        // Top-pinned in the clip view: an unflipped documentView otherwise
        // gravity-anchors at the bottom.
        [_editorStack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [_editorStack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [_editorStack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
    ]];
}

#pragma mark - Page swap

// Size-neutral by design: the editor never joins the shared-size settlement
// (naturalPaneSize measures only the base section stack), so no
// paneContentDidChange pass is needed — nothing about the window moves.
- (void)applyEditorVisibility {
    _detailContainer.hidden = !_editorShown;
    for (NSView *section in _listSections) {
        section.hidden = _editorShown;
    }
    // The editor page retitles the window the way a pane switch would: the
    // pane sets only its own title, and updateThemeNavigation below re-pushes
    // the pane-title chain (the host owns the container nesting). The sidebar
    // label reads the tab ITEM, so it keeps saying Appearance.
    NSString *active = AppSettings.sharedInstance.activeThemeIdentifier;
    self.title = _editorShown
            ? ([AppSettings.sharedInstance displayNameForThemeIdentifier:active]
                    ?: STR_MENU_VIEW_APPEARANCE)
            : STR_MENU_VIEW_APPEARANCE;
    [(SettingsWindowController *)self.view.window.windowController updateThemeNavigation];
}

- (BOOL)canGoBack {
    return _editorShown;
}

- (BOOL)canGoForward {
    return _editorForwardAvailable && !_editorShown;
}

- (void)navigateBack {
    _editorShown = NO;
    _editorForwardAvailable = YES;
    [self closeEditorPanels];
    [self refreshFromSettings]; // reaches applyEditorVisibility via the resolver
}

- (void)navigateForward {
    if (self.canGoForward) {
        [self showThemeEditorForActiveTheme];
    }
}

- (void)showThemeEditorForActiveTheme {
    _editorShown = YES;
    _editorForwardAvailable = NO;
    [self refreshFromSettings]; // reaches applyEditorVisibility via the resolver
}

- (void)previewAppearanceDark:(BOOL)dark {
    AppSettings.sharedInstance.windowAppearancePreviewStyle =
            dark ? SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK
                 : SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWindowAppearance];
    // Re-reads the toggle from what the window ended up at, so a caller that
    // is not the toggle itself — the debug channel — leaves it honest too.
    [(SettingsWindowController *)self.view.window.windowController updateThemeNavigation];
}

// The preview is the page's, not a setting, so it ends with the page: leaving
// the pane and closing the window are one event here, which is the only reason
// there is one place to drop it.
- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self closeEditorPanels];
    if (AppSettings.sharedInstance.windowAppearancePreviewStyle) {
        AppSettings.sharedInstance.windowAppearancePreviewStyle = nil;
        [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWindowAppearance];
    }
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
            ((NSControl *)subview).enabled = enabled;
        }
    });
}

// An unknown persisted style identifier renders as the default style — the
// waveform view's own fallback — so show that rather than misreport.
- (void)selectWaveformStyle:(NSString *)identifier in:(NSPopUpButton *)popUp {
    [self selectValue:identifier in:popUp];
    if (popUp.indexOfSelectedItem < 0) {
        [self selectValue:SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT in:popUp];
    }
}

- (void)refreshFromSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;

    // The common card, plus the list page's waveform shortcut.
    [self selectValue:settings.windowAppearanceStyle in:_appearancePopUp];
    _trafficLightsSwitch.state = StateForBOOL(settings.showTrafficLights);
    [self selectWaveformStyle:theme.waveformStyle in:_listWaveformPopUp];

    // The theme list. Selection mirrors activation, so reselect the active
    // row after every reload.
    NSString *active = settings.activeThemeIdentifier;
    _themeIdentifiers = settings.orderedThemeIdentifiers;
    _refreshingThemeList = YES;
    [_themeTable reloadData];
    NSInteger activeRow = [self rowForIdentifier:active];
    if (activeRow >= 0) {
        [_themeTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)activeRow]
                 byExtendingSelection:NO];
        // A programmatic selection does not scroll, and the user group sits
        // past the fold once a few themes exist — so an added or imported
        // theme would land selected and invisible.
        [_themeTable scrollRowToVisible:activeRow];
    }
    _refreshingThemeList = NO;
    BOOL builtIn = [AppTheme isBuiltInIdentifier:active];
    _removeThemeButton.enabled = !builtIn;

    // The editor, from the working theme. (The name/built-in row swap lives
    // in resolveLayoutStateFromSettings with the other conditional rows.)
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
    [self selectValue:theme.windowBackgroundStyle in:_backgroundPopUp];
    [self selectValue:theme.windowTint in:_windowTintPopUp];
    for (NSColorWell *well in _wellBindings) {
        NSDictionary *binding = [_wellBindings objectForKey:well];
        well.color = ((ThemeColorGetter)binding[kWellDisplay])(theme, [binding[kWellDark] boolValue]);
    }
    _cornerRadiusSlider.doubleValue = theme.windowCornerRadius;
    [self refreshCornerRadiusValue];

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
    [self selectValue:theme.waveformTheme in:_waveformThemePopUp];
    _waveformGradientSwitch.state = StateForBOOL(theme.waveformGradient);
    _playlistArtworkSwitch.state = StateForBOOL(theme.showPlaylistArtworkColumn);
    _artDarkPreviewButton.image =
            [AppTheme imageForDefaultArtwork:[theme defaultArtworkForDark:YES]];
    _artLightPreviewButton.image =
            [AppTheme imageForDefaultArtwork:[theme defaultArtworkForDark:NO]];
    _artDarkClearButton.hidden = YES;
    _artLightClearButton.hidden = YES;
    _artDarkMissingBadge.hidden =
            ![AppTheme defaultArtworkIsMissing:[theme defaultArtworkForDark:YES]];
    _artLightMissingBadge.hidden =
            ![AppTheme defaultArtworkIsMissing:[theme defaultArtworkForDark:NO]];
    _playlistDurationSwitch.state = StateForBOOL(theme.showPlaylistDurationColumn);
    [self selectValue:theme.playlistBackgroundStyle in:_playlistBackgroundPopUp];
    [self selectValue:theme.playlistTint in:_playlistTintPopUp];

    [self refreshFontValueLabels];

    // Read-only built-ins: every editor control disables, honestly reported
    // by the debug walker; then the always-live sub-rules re-apply.
    SetDescendantControlsEnabled(_editorStack, !builtIn);
    // The built-in page's one live control sits inside the swept stack now
    // that the caption row is a card row: without this, a built-in could
    // never be duplicated from its own page. Observed, not hypothetical.
    _duplicateButton.enabled = YES;
    if (!builtIn) {
        // Everything below Show file info dims when it is off — the header
        // shows none of it, so nothing those rows govern is on screen.
        BOOL info = AppSettings.sharedInstance.currentTheme.showFileInfo;
        SetDescendantControlsEnabled(_infoSection, info);
        _fileInfoSwitch.enabled = YES; // the toggle that governs them stays live
        // Key notation and key colors additionally require Show key.
        _keyNotationPopUp.enabled = info && showKey;
        _keyColorsSwitch.enabled = info && showKey;
    }
    if (builtIn) {
        [self closeEditorPanels];
    }

    [self resolveLayoutStateFromSettings];
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

// The pane's themed rows all funnel here after writing their currentTheme
// field: persist the working record, then request the row's live effect.
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect {
    [AppSettings.sharedInstance currentThemeDidChange];
    [self.playerController applySettingsLiveEffects:effect];
}

#pragma mark - Theme list

// Row 0 is the Built-in header and the User header sits one past the last
// built-in, so every row-to-theme hop is arithmetic over the built-in count
// rather than a second array to keep in step with the store's order.

// -1 while the user has no themes: the group does not exist rather than
// standing empty.
- (NSInteger)userGroupRow {
    NSInteger builtIns = (NSInteger)AppTheme.builtInThemeIdentifiers.count;
    return (NSInteger)_themeIdentifiers.count > builtIns ? builtIns + 1 : -1;
}

// nil for a group header, and for no row at all — which is what makes a
// header unselectable and keeps selection-IS-activation off them.
- (nullable NSString *)identifierForRow:(NSInteger)row {
    NSInteger userHeader = [self userGroupRow];
    if (row <= 0 || row == userHeader) {
        return nil;
    }
    NSInteger index = (userHeader >= 0 && row > userHeader) ? row - 2 : row - 1;
    return index < (NSInteger)_themeIdentifiers.count ? _themeIdentifiers[(NSUInteger)index] : nil;
}

- (NSInteger)rowForIdentifier:(NSString *)identifier {
    NSUInteger index = [_themeIdentifiers indexOfObject:identifier];
    if (index == NSNotFound) {
        return -1;
    }
    return (NSInteger)index + (index >= AppTheme.builtInThemeIdentifiers.count ? 2 : 1);
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_themeIdentifiers.count + ([self userGroupRow] >= 0 ? 2 : 1);
}

// A header is an ordinary row the delegate refuses to select, NOT an AppKit
// group row: that style tacks a section gap above each header and its own row
// height onto a list whose whole budget is ten rows.
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return [self identifierForRow:row] != nil;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *identifier = [self identifierForRow:row];
    if (!identifier) {
        return [self groupCellInTableView:tableView title:
                (row == 0 ? STR_SETTINGS_THEME_GROUP_BUILT_IN : STR_SETTINGS_THEME_GROUP_USER)];
    }
    NSTableCellView *cell = [tableView makeViewWithIdentifier:kThemeCellIdentifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = kThemeCellIdentifier;
        NSImageView *check = [[NSImageView alloc] initWithFrame:NSZeroRect];
        check.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField *label = [NSTextField labelWithString:@""];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:check];
        [cell addSubview:label];
        cell.imageView = check;
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [check.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [check.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [check.widthAnchor constraintEqualToConstant:16],
            [label.leadingAnchor constraintEqualToAnchor:check.trailingAnchor constant:6],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    BOOL isActive = [identifier isEqualToString:AppSettings.sharedInstance.activeThemeIdentifier];
    cell.imageView.image = isActive
            ? [NSImage imageWithSystemSymbolName:@"checkmark" accessibilityDescription:nil]
            : nil;
    cell.textField.stringValue =
            [AppSettings.sharedInstance displayNameForThemeIdentifier:identifier] ?: identifier;
    return cell;
}

// A header row: the label alone, at the card's own left margin so the themes
// under it read as indented beneath their group.
- (NSTableCellView *)groupCellInTableView:(NSTableView *)tableView title:(NSString *)title {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:kThemeGroupCellIdentifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = kThemeGroupCellIdentifier;
        NSTextField *label = [NSTextField labelWithString:@""];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize
                                       weight:NSFontWeightSemibold];
        label.textColor = NSColor.secondaryLabelColor;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:label];
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    cell.textField.stringValue = title;
    return cell;
}

// Selection IS activation: one concept instead of a selection-vs-checkbox
// split, an instant whole-app preview, and the same semantics as the View >
// Theme menu.
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_refreshingThemeList) {
        return;
    }
    NSString *identifier = [self selectedThemeIdentifier];
    if (!identifier ||
        [identifier isEqualToString:AppSettings.sharedInstance.activeThemeIdentifier]) {
        return;
    }
    [self activateThemeWithIdentifier:identifier];
}

- (nullable NSString *)selectedThemeIdentifier {
    return [self identifierForRow:_themeTable.selectedRow];
}

#pragma mark - Dropping theme files in

// Theme files only — the Import… panel's two types — asked of the pasteboard
// rather than the file system, for the Files pane's reasons: validation runs
// per mouse move, and a stat can block on an unreachable mount.
+ (NSDictionary<NSPasteboardReadingOptionKey, id> *)themeFileReadingOptions {
    return @{
        NSPasteboardURLReadingFileURLsOnlyKey: @YES,
        NSPasteboardURLReadingContentsConformToTypesKey:
                @[UTTypeJSON.identifier, UTTypeZIP.identifier],
    };
}

// Retargeted onto the list as a whole: an import lands in the user group
// wherever the drop points, so an insertion point would promise a position
// the store cannot honor.
- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)operation {
    if (![info.draggingPasteboard canReadObjectForClasses:@[NSURL.class]
                                                  options:self.class.themeFileReadingOptions]) {
        return NSDragOperationNone;
    }
    [tableView setDropRow:-1 dropOperation:NSTableViewDropOn];
    return NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)operation {
    return [self importThemesFromURLs:[info.draggingPasteboard
            readObjectsForClasses:@[NSURL.class]
                          options:self.class.themeFileReadingOptions]];
}

- (void)activateThemeWithIdentifier:(NSString *)identifier {
    [AppSettings.sharedInstance applyThemeWithIdentifier:identifier];
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

- (void)addNewTheme:(id)sender {
    NSString *identifier = [AppSettings.sharedInstance
            addUserThemeWithRecord:AppSettings.sharedInstance.currentTheme.dictionaryRepresentation
                              name:STR_SETTINGS_THEME_ADD_NEW];
    [self activateThemeWithIdentifier:identifier];
}

// Copy the active theme and edit the copy. Selection IS activation, so the
// Add pulldown's Duplicate and the read-only editor page's both mean this.
- (void)duplicateTheme:(id)sender {
    NSString *identifier = [AppSettings.sharedInstance duplicateThemeWithIdentifier:
            AppSettings.sharedInstance.activeThemeIdentifier];
    if (identifier) {
        [self activateThemeWithIdentifier:identifier];
    }
}

// No confirmation, following the Files pane's Remove — and a sheet would
// block settings_click.
- (void)removeTheme:(id)sender {
    NSString *selected = [self selectedThemeIdentifier];
    if (!selected || [AppTheme isBuiltInIdentifier:selected]) {
        return;
    }
    // Land on the neighbor, not the first row: the next theme takes the
    // removed row's index, and removing the last row falls back to the row
    // before it. Selection IS activation, so the store applies the neighbor.
    NSUInteger index = [_themeIdentifiers indexOfObject:selected];
    NSString *neighbor = nil;
    if (index != NSNotFound) {
        neighbor = index + 1 < _themeIdentifiers.count ? _themeIdentifiers[index + 1]
                : (index > 0 ? _themeIdentifiers[index - 1] : nil);
    }
    [AppSettings.sharedInstance removeUserThemeWithIdentifier:selected fallingBackTo:neighbor];
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

- (void)editTheme:(id)sender {
    // A double-click on a group header or the empty area below the rows names
    // no theme, and opening the active theme's editor from there would be an
    // activation the click never made.
    if (sender == _themeTable && [self identifierForRow:_themeTable.clickedRow] == nil) {
        return;
    }
    // Opening a theme's page activates it first — selection already did on a
    // click; this covers the double-click's row change landing late.
    NSString *selected = [self selectedThemeIdentifier];
    if (selected &&
        ![selected isEqualToString:AppSettings.sharedInstance.activeThemeIdentifier]) {
        [self activateThemeWithIdentifier:selected];
    }
    [self showThemeEditorForActiveTheme];
}

- (void)importTheme:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.allowedContentTypes = @[UTTypeJSON, UTTypeZIP];
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result == NSModalResponseOK) {
            [self importThemesFromURLs:panel.URLs];
        }
    }];
}

// One import funnel for the Import… panel and the theme list's drop, both of
// which hand over a LIST: the same sanitize-and-store gate either way.
//
// Activation happens once, after the whole list. Activating per file would
// re-apply every live effect N times to land on the last one regardless, and
// a file that fails in the middle would leave the previous file's theme
// active — the same place a clean run ends, so the failure would not show.
//
// Read mapped: the size gate inside AppTheme rejects an over-cap archive, but
// only after the bytes exist, and a mistakenly picked multi-gigabyte file
// must not be pulled into memory to be told it is too big.
- (BOOL)importThemesFromURLs:(NSArray<NSURL *> *)urls {
    NSString *lastImported = nil;
    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSString *name = nil;
        NSData *data = [NSData dataWithContentsOfURL:url
                                             options:NSDataReadingMappedIfSafe
                                               error:NULL];
        NSDictionary *record = [AppTheme recordFromJSONOrArchiveData:data
                                                                name:&name
                                                               error:NULL];
        if (!record) {
            [failed addObject:url.lastPathComponent];
            continue;
        }
        lastImported = [AppSettings.sharedInstance
                addUserThemeWithRecord:record
                                  name:(name.length ? name : STR_THEME_NAME_IMPORTED)];
    }
    if (lastImported) {
        [self activateThemeWithIdentifier:lastImported];
    }
    if (failed.count) {
        [self presentThemeImportFailedAlertForFiles:failed];
    }
    return lastImported != nil;
}

// The names are data, not copy, so they carry the detail and the localized
// line above them carries none — which is also why the plural form states no
// count: no language then needs plural agreement for it.
- (void)presentThemeImportFailedAlertForFiles:(NSArray<NSString *> *)files {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = files.count > 1 ? STR_SETTINGS_THEME_IMPORT_FAILED_SOME
                                        : STR_SETTINGS_THEME_IMPORT_FAILED;
    alert.informativeText = [files componentsJoinedByString:VibeNotLocalized(@"\n")];
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

- (void)exportTheme:(id)sender {
    NSString *selected = [self selectedThemeIdentifier];
    if (!selected) {
        return;
    }
    NSString *name = [AppSettings.sharedInstance displayNameForThemeIdentifier:selected] ?: selected;
    // A default-artwork image travels beside the JSON, so those themes export
    // as a ZIP; everything else stays a plain JSON file. WHICH it is comes from
    // the record's own references, because the images themselves are read only
    // once the user has confirmed the save — a theme's artwork runs to
    // megabytes, and a cancelled panel must not have paid for it.
    NSDictionary *record = [AppSettings.sharedInstance recordForThemeIdentifier:selected];
    AppTheme *exported = [[AppTheme alloc] initWithRecord:record];
    BOOL carriesArtwork = NO;
    for (NSNumber *dark in @[@YES, @NO]) {
        NSString *art = [exported defaultArtworkForDark:dark.boolValue];
        carriesArtwork = carriesArtwork ||
                (art.length > 0 && ![AppTheme defaultArtworkIsMissing:art]);
    }
    NSString *extension = carriesArtwork ? @"zip" : @"json";
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[carriesArtwork ? UTTypeZIP : UTTypeJSON];
    panel.nameFieldStringValue = [name stringByAppendingPathExtension:extension]
            ?: [@"theme" stringByAppendingPathExtension:extension];
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) {
            return;
        }
        // The archive can still come back nil — an image deleted while the
        // panel was up — and the theme is worth more than its artwork, so the
        // JSON goes out rather than nothing.
        NSData *payload = carriesArtwork ? [AppTheme archiveDataForRecord:record name:name] : nil;
        payload = payload ?: [AppTheme JSONDataForRecord:record name:name];
        NSError *error = nil;
        if (payload && [payload writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
            return;
        }
        // A failed write has to say so: a panel that just closes is
        // indistinguishable from a saved file. The system's own message names
        // the reason — a full disk, a read-only volume — better than ours.
        [[NSAlert alertWithError:error ?: [NSError errorWithDomain:NSCocoaErrorDomain
                                                              code:NSFileWriteUnknownError
                                                          userInfo:nil]]
                beginSheetModalForWindow:self.view.window completionHandler:nil];
    }];
}

#pragma mark - Common settings

- (void)toggleTrafficLights:(id)sender {
    AppSettings.sharedInstance.showTrafficLights =
            (_trafficLightsSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectTrafficLights];
}

// The stored choice, which also ends any titlebar preview (the store drops it
// on the write) — so the toggle is re-read from what the window ended up at.
- (void)appearanceChanged:(id)sender {
    AppSettings.sharedInstance.windowAppearanceStyle =
            _appearancePopUp.selectedItem.representedObject;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWindowAppearance];
    [(SettingsWindowController *)self.view.window.windowController updateThemeNavigation];
}

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
                ((ThemeColorSetter)binding[kWellSet])(theme,
                        ((ThemeColorGetter)binding[kWellDisplay])(theme, isDark), isDark);
            }
        }
    }
}

// The one action every themed well sends: write the side, request the
// pair's effect.
- (void)colorWellChanged:(NSColorWell *)sender {
    NSDictionary *binding = [_wellBindings objectForKey:sender];
    ((ThemeColorSetter)binding[kWellSet])(AppSettings.sharedInstance.currentTheme, sender.color,
                                          [binding[kWellDark] boolValue]);
    [self themeFieldDidChange:(VibeSettingsLiveEffect)[binding[kWellEffect] unsignedIntegerValue]];
}

#pragma mark - Editor: window

- (void)backgroundStyleChanged:(id)sender {
    NSString *identifier = _backgroundPopUp.selectedItem.representedObject;
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL solid = [identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    if (solid) {
        [self seedWellsIn:@[_backgroundColorsRow]];
    }
    theme.windowBackgroundStyle = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowChrome];
    [self resolveLayoutStateFromSettings];
}

- (void)windowTintChanged:(id)sender {
    NSString *identifier = _windowTintPopUp.selectedItem.representedObject;
    BOOL custom = [identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if (custom) {
        [self seedWellsIn:@[_windowTintDarkRow, _windowTintLightRow]];
    }
    theme.windowTint = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowTint];
    [self resolveLayoutStateFromSettings];
}

- (void)cornerRadiusChanged:(id)sender {
    // A magnetic detent at the factory radius — the reset, without a button:
    // dragging near the default snaps onto it. The sanitize gate rounds to
    // whole points; the knob re-syncs to what actually landed.
    double radius = _cornerRadiusSlider.doubleValue;
    if (fabs(radius - kVibeThemeCornerRadiusDefault) < 1.5) {
        radius = kVibeThemeCornerRadiusDefault;
    }
    AppSettings.sharedInstance.currentTheme.windowCornerRadius = radius;
    _cornerRadiusSlider.doubleValue = AppSettings.sharedInstance.currentTheme.windowCornerRadius;
    [self refreshCornerRadiusValue];
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowChrome];
}

- (void)refreshCornerRadiusValue {
    _cornerRadiusValue.stringValue = [NSString stringWithFormat:STR_SETTINGS_THEME_CORNER_RADIUS_VALUE,
            (long)lround(AppSettings.sharedInstance.currentTheme.windowCornerRadius)];
}

#pragma mark - Editor: info display

- (void)toggleFileInfo:(id)sender {
    AppSettings.sharedInstance.currentTheme.showFileInfo = (_fileInfoSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay];
    // The rows it governs enable/disable with it.
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

// The clear badge shows only while there is something to clear: a non-empty
// value in the hovered side's slot, on an editable page. Read live — the
// value, the page and the enable state can all have changed since the last
// hover.
- (void)mouseEntered:(NSEvent *)event {
    NSNumber *side = event.trackingArea.userInfo[@"artClearForDark"];
    if (side == nil) {
        return;
    }
    NSButton *preview = side.boolValue ? _artDarkPreviewButton : _artLightPreviewButton;
    NSButton *clear = side.boolValue ? _artDarkClearButton : _artLightClearButton;
    clear.hidden = !preview.enabled || [AppSettings.sharedInstance.currentTheme
            defaultArtworkForDark:side.boolValue].length == 0;
}

- (void)mouseExited:(NSEvent *)event {
    NSNumber *side = event.trackingArea.userInfo[@"artClearForDark"];
    if (side != nil) {
        (side.boolValue ? _artDarkClearButton : _artLightClearButton).hidden = YES;
    }
}

- (void)clearCustomArtwork:(id)sender {
    [AppSettings.sharedInstance.currentTheme setDefaultArtwork:@""
            forDark:sender == _artDarkClearButton];
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay
            | VibeSettingsLiveEffectPlaylistAppearance];
    [self refreshFromSettings]; // also hides the badge — the cursor is still over it
}

- (void)chooseAlbumArt:(id)sender {
    BOOL isDark = sender == _artDarkPreviewButton;
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
            return;
        }
        if (![AppSettings.sharedInstance.activeThemeIdentifier isEqualToString:target]) {
            // Theme changed under the sheet — drop the pick before it is
            // stored, so nothing is left for the sweep to find.
            [self refreshFromSettings];
            return;
        }
        NSError *error = nil;
        // Read mapped, as the theme import is: the byte cap inside AppTheme
        // rejects an oversized image, but only once the bytes exist, and a
        // mistakenly picked huge file must not be pulled into memory to be
        // told it is too big.
        NSString *stored = [AppTheme storeCustomArtworkData:
                [NSData dataWithContentsOfURL:panel.URL
                                      options:NSDataReadingMappedIfSafe
                                        error:NULL] error:&error];
        if (!stored) {
            [self refreshFromSettings];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = STR_SETTINGS_THEME_ALBUM_ART_INVALID;
            alert.informativeText = STR_SETTINGS_THEME_ALBUM_ART_REQUIREMENTS;
            [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
            return;
        }
        [AppSettings.sharedInstance.currentTheme setDefaultArtwork:stored forDark:isDark];
        [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay
                | VibeSettingsLiveEffectPlaylistAppearance];
        [self refreshFromSettings];
    }];
}

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

- (void)toggleWaveformGradient:(id)sender {
    AppSettings.sharedInstance.currentTheme.waveformGradient =
            (_waveformGradientSwitch.state == NSControlStateValueOn);
    [self themeFieldDidChange:VibeSettingsLiveEffectWaveformTheme];
}

// The style popup, built once per surface — the editor's row and the list
// page's shortcut. Identifiers travel in representedObject, localized names
// in the titles — a display name must never reach the store.
- (NSPopUpButton *)waveformStylePopUpButton {
    NSPopUpButton *popUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                               action:@selector(waveformStyleChanged:)];
    NSArray<NSString *> *styles = [[WaveformRendererRegistry availableIdentifiers]
            sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                return [[WaveformRendererRegistry displayNameForIdentifier:a]
                        localizedStandardCompare:[WaveformRendererRegistry displayNameForIdentifier:b]];
            }];
    for (NSString *identifier in styles) {
        [self addItem:[WaveformRendererRegistry displayNameForIdentifier:identifier]
                value:identifier to:popUp];
    }
    return popUp;
}

- (void)waveformStyleChanged:(NSPopUpButton *)sender {
    NSString *identifier = sender.selectedItem.representedObject;
    if (!identifier) {
        return;
    }
    AppSettings.sharedInstance.currentTheme.waveformStyle = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWaveformStyle];
    // Keep the twin surface agreeing without a whole-pane refresh.
    NSPopUpButton *twin = sender == _waveformPopUp ? _listWaveformPopUp : _waveformPopUp;
    [self selectValue:identifier in:twin];
}

- (void)waveformThemeChanged:(id)sender {
    NSString *identifier = _waveformThemePopUp.selectedItem.representedObject;
    BOOL custom = [identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if (custom) {
        [self seedWellsIn:@[_customDarkRow, _customLightRow]];
    }
    theme.waveformTheme = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWaveformTheme];
    [self resolveLayoutStateFromSettings];
}

#pragma mark - Editor: playlist

- (void)playlistBackgroundStyleChanged:(id)sender {
    NSString *identifier = _playlistBackgroundPopUp.selectedItem.representedObject;
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if ([identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID]) {
        [self seedWellsIn:@[_playlistBackgroundColorsRow]];
    }
    theme.playlistBackgroundStyle = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectPlaylistAppearance];
    [self resolveLayoutStateFromSettings];
}

- (void)playlistTintChanged:(id)sender {
    NSString *identifier = _playlistTintPopUp.selectedItem.representedObject;
    BOOL custom = [identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if (custom) {
        [self seedWellsIn:@[_playlistTintDarkRow, _playlistTintLightRow]];
    }
    theme.playlistTint = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowTint];
    [self resolveLayoutStateFromSettings];
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
    _fontEditingSlot = VibeFontSlotNone;
    if (NSFontPanel.sharedFontPanelExists) {
        [NSFontPanel.sharedFontPanel orderOut:nil];
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
