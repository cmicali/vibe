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
#import "MainPlayerContentView.h" // the solid background's default, shown by the wells
#import "PlaylistRowView.h"       // the row fills' unthemed default, shown by the wells
#import "Fonts.h"
#import "MainPlayerController+Menus.h"
#import "MainPlayerController+Settings.h"
#import "SettingsWindowController.h" // the toolbar navigation control follows the pane's pages
#import "VibeStrings.h"

static const CGFloat kAppearancePopUpWidth = 220;
static const CGFloat kAlbumArtPreviewSize = 64;
static const CGFloat kThemeListRowHeight = 22;
// Ten rows: the two group headers, the built-ins, and room for a handful of
// the user's own before it scrolls.
static const CGFloat kThemeListHeight = 10 * kThemeListRowHeight;
static NSString *const kThemeCellIdentifier = @"themeCell";
static NSString *const kThemeGroupCellIdentifier = @"themeGroupCell";

// The font panel's target slot, carried as the Select buttons' tags. None
// while the panel is not editing a slot; changeFont: no-ops then, which is
// what keeps a stray panel from restyling anything.
typedef NS_ENUM(NSInteger, VibeThemeFontSlot) {
    VibeThemeFontSlotNone = 0,
    VibeThemeFontSlotTitle,
    VibeThemeFontSlotArtist,
    VibeThemeFontSlotInfo,
    VibeThemeFontSlotPlaylist,
    VibeThemeFontSlotPlaylistDuration,
};

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
    SettingsRowView *_nameRow;
    NSPopUpButton *_backgroundPopUp;
    NSColorWell *_backgroundDarkWell, *_backgroundLightWell;
    SettingsRowView *_backgroundColorsRow;
    NSPopUpButton *_windowTintPopUp;
    NSColorWell *_windowTintDarkWell, *_windowTintLightWell;
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
    NSButton *_artLightPreviewButton;
    NSButton *_artLightClearButton;
    NSSwitch *_playlistDurationSwitch;
    // Every Dark/Light well pair, for the fixed-theme collapse to one well.
    NSMutableArray<NSStackView *> *_darkLightPairs;
    NSColorWell *_titleDarkWell, *_titleLightWell;
    NSColorWell *_artistDarkWell, *_artistLightWell;
    NSColorWell *_infoDarkWell, *_infoLightWell;
    NSColorWell *_timeDarkWell, *_timeLightWell;
    NSPopUpButton *_waveformPopUp;
    NSPopUpButton *_waveformThemePopUp;
    // A played/unplayed pair per appearance — one pair cannot read on both
    // backdrops.
    NSColorWell *_customDarkPlayedWell, *_customDarkUnplayedWell;
    NSColorWell *_customLightPlayedWell, *_customLightUnplayedWell;
    SettingsRowView *_customDarkRow, *_customLightRow;
    NSPopUpButton *_playlistBackgroundPopUp;
    NSColorWell *_playlistBackgroundDarkWell, *_playlistBackgroundLightWell;
    SettingsRowView *_playlistBackgroundColorsRow;
    NSPopUpButton *_playlistTintPopUp;
    NSColorWell *_playlistTintDarkWell, *_playlistTintLightWell;
    SettingsRowView *_playlistTintDarkRow, *_playlistTintLightRow;
    NSColorWell *_playingRowDarkWell, *_playingRowLightWell;
    NSColorWell *_selectedRowDarkWell, *_selectedRowLightWell;
    NSTextField *_titleFontValue, *_artistFontValue, *_infoFontValue, *_playlistFontValue;
    NSTextField *_playlistDurationFontValue;
    VibeThemeFontSlot _fontEditingSlot;
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

    _listSections = @[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_APPEARANCE_LABEL control:_appearancePopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_TRAFFIC_LIGHTS control:_trafficLightsSwitch],
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

// A well whose alpha is part of the choice: a fill's strength, the solid
// background's opacity, a waveform side's resting level.
- (NSColorWell *)themeColorWellWithAction:(SEL)action {
    NSColorWell *well = [[NSColorWell alloc] init];
    well.target = self;
    well.action = action;
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

// A font row's trailing cluster: the current choice, then Select…, which
// opens the font panel onto that slot.
- (NSStackView *)fontClusterForSlot:(VibeThemeFontSlot)slot valueLabel:(NSTextField **)outLabel {
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
    NSButton *clear = [NSButton buttonWithImage:[[NSImage
            imageWithSystemSymbolName:@"xmark.circle.fill"
              accessibilityDescription:STR_SETTINGS_THEME_ALBUM_ART_CLEAR]
            imageWithSymbolConfiguration:[NSImageSymbolConfiguration
                    configurationWithPaletteColors:@[NSColor.whiteColor,
                            [NSColor colorWithWhite:0 alpha:0.6]]]]
                                         target:self action:@selector(clearCustomArtwork:)];
    clear.bordered = NO;
    clear.title = STR_SETTINGS_THEME_ALBUM_ART_CLEAR; // image-only: named, never drawn
    clear.imagePosition = NSImageOnly;
    clear.hidden = YES;
    NSView *cluster = [[NSView alloc] initWithFrame:NSZeroRect];
    cluster.translatesAutoresizingMaskIntoConstraints = NO;
    preview.translatesAutoresizingMaskIntoConstraints = NO;
    clear.translatesAutoresizingMaskIntoConstraints = NO;
    [cluster addSubview:preview];
    [cluster addSubview:clear];
    [NSLayoutConstraint activateConstraints:@[
        [cluster.widthAnchor constraintEqualToConstant:kAlbumArtPreviewSize],
        [cluster.heightAnchor constraintEqualToConstant:kAlbumArtPreviewSize],
        [preview.leadingAnchor constraintEqualToAnchor:cluster.leadingAnchor],
        [preview.trailingAnchor constraintEqualToAnchor:cluster.trailingAnchor],
        [preview.topAnchor constraintEqualToAnchor:cluster.topAnchor],
        [preview.bottomAnchor constraintEqualToAnchor:cluster.bottomAnchor],
        // Pinned to the glyph's size: the undrawn title still feeds the
        // button's intrinsic width, which stretched it across the preview.
        [clear.widthAnchor constraintEqualToConstant:18],
        [clear.heightAnchor constraintEqualToConstant:18],
        [clear.topAnchor constraintEqualToAnchor:cluster.topAnchor constant:3],
        [clear.trailingAnchor constraintEqualToAnchor:cluster.trailingAnchor constant:-3],
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
    } else {
        _artLightPreviewButton = preview;
        _artLightClearButton = clear;
    }
    return cluster;
}

- (void)buildEditorPage {
    _nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _nameField.delegate = self;
    [_nameField.widthAnchor constraintEqualToConstant:kAppearancePopUpWidth].active = YES;
    _nameRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_NAME_LABEL control:_nameField];
    _duplicateButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_DUPLICATE
                                          target:self action:@selector(duplicateActiveTheme:)];
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
    _backgroundDarkWell = [self themeColorWellWithAction:@selector(backgroundColorChanged:)];
    _backgroundLightWell = [self themeColorWellWithAction:@selector(backgroundColorChanged:)];
    _backgroundColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BACKGROUND_COLORS
            control:[self darkLightPairWithDark:_backgroundDarkWell light:_backgroundLightWell]];

    _windowTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(windowTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_windowTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_windowTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_windowTintPopUp];
    _windowTintDarkWell = [self themeColorWellWithAction:@selector(windowTintColorChanged:)];
    _windowTintLightWell = [self themeColorWellWithAction:@selector(windowTintColorChanged:)];
    _windowTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
                                               control:_windowTintDarkWell];
    _windowTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
                                                control:_windowTintLightWell];

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

    _titleDarkWell = [self themeColorWellWithAction:@selector(labelColorChanged:)];
    _titleLightWell = [self themeColorWellWithAction:@selector(labelColorChanged:)];
    _artistDarkWell = [self themeColorWellWithAction:@selector(labelColorChanged:)];
    _artistLightWell = [self themeColorWellWithAction:@selector(labelColorChanged:)];
    _infoDarkWell = [self themeColorWellWithAction:@selector(labelColorChanged:)];
    _infoLightWell = [self themeColorWellWithAction:@selector(labelColorChanged:)];
    _timeDarkWell = [self themeColorWellWithAction:@selector(labelColorChanged:)];
    _timeLightWell = [self themeColorWellWithAction:@selector(labelColorChanged:)];

    // Identifiers travel in representedObject, localized names in the titles
    // — a display name must never reach the store.
    _waveformPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformStyleChanged:)];
    MainPlayerController *player = self.playerController;
    NSArray<NSString *> *styles = [[player availableWaveformStyleIdentifiers]
            sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                return [[player displayNameForWaveformStyle:a]
                        localizedStandardCompare:[player displayNameForWaveformStyle:b]];
            }];
    for (NSString *identifier in styles) {
        [self addItem:[player displayNameForWaveformStyle:identifier] value:identifier to:_waveformPopUp];
    }
    _waveformThemePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformThemeChanged:)];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_MONO value:SETTINGS_VALUE_WAVEFORM_THEME_MONO to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ORANGE value:SETTINGS_VALUE_WAVEFORM_THEME_ORANGE to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART value:SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART to:_waveformThemePopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_THEME_CUSTOM value:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM to:_waveformThemePopUp];

    _waveformGradientSwitch = [self switchWithAction:@selector(toggleWaveformGradient:)];
    _playlistArtworkSwitch = [self switchWithAction:@selector(togglePlaylistArtwork:)];
    _playlistDurationSwitch = [self switchWithAction:@selector(togglePlaylistDuration:)];
    _customDarkPlayedWell = [self themeColorWellWithAction:@selector(customColorChanged:)];
    _customDarkUnplayedWell = [self themeColorWellWithAction:@selector(customColorChanged:)];
    _customLightPlayedWell = [self themeColorWellWithAction:@selector(customColorChanged:)];
    _customLightUnplayedWell = [self themeColorWellWithAction:@selector(customColorChanged:)];
    _customDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL
            control:[self wellPair:_customDarkPlayedWell caption:STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED
                              well:_customDarkUnplayedWell caption:STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED]];
    _customLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_CUSTOM_LIGHT_LABEL
            control:[self wellPair:_customLightPlayedWell caption:STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED
                              well:_customLightUnplayedWell caption:STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED]];

    _playlistBackgroundDarkWell = [self themeColorWellWithAction:@selector(playlistColorChanged:)];
    _playlistBackgroundLightWell = [self themeColorWellWithAction:@selector(playlistColorChanged:)];
    _playlistBackgroundColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_BACKGROUND_COLORS
            control:[self darkLightPairWithDark:_playlistBackgroundDarkWell light:_playlistBackgroundLightWell]];

    // The playlist's tint mirrors the window's: the same three choices, the
    // same custom-color rows shown only under Custom.
    _playlistTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                             action:@selector(playlistTintChanged:)];
    [self addItem:STR_SETTINGS_WINDOW_TINT_NONE value:SETTINGS_VALUE_WINDOW_TINT_MONO to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_ARTWORK value:SETTINGS_VALUE_WINDOW_TINT_ARTWORK to:_playlistTintPopUp];
    [self addItem:STR_SETTINGS_WINDOW_TINT_CUSTOM value:SETTINGS_VALUE_WINDOW_TINT_CUSTOM to:_playlistTintPopUp];
    _playlistTintDarkWell = [self themeColorWellWithAction:@selector(playlistTintColorChanged:)];
    _playlistTintLightWell = [self themeColorWellWithAction:@selector(playlistTintColorChanged:)];
    _playlistTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
                                                 control:_playlistTintDarkWell];
    _playlistTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
                                                  control:_playlistTintLightWell];

    _playingRowDarkWell = [self themeColorWellWithAction:@selector(playlistColorChanged:)];
    _playingRowLightWell = [self themeColorWellWithAction:@selector(playlistColorChanged:)];
    _selectedRowDarkWell = [self themeColorWellWithAction:@selector(playlistColorChanged:)];
    _selectedRowLightWell = [self themeColorWellWithAction:@selector(playlistColorChanged:)];

    NSTextField *titleFontValue = nil, *infoFontValue = nil, *playlistFontValue = nil;
    NSStackView *titleFontCluster = [self fontClusterForSlot:VibeThemeFontSlotTitle valueLabel:&titleFontValue];
    NSTextField *artistFontValue = nil;
    NSStackView *artistFontCluster = [self fontClusterForSlot:VibeThemeFontSlotArtist valueLabel:&artistFontValue];
    NSStackView *infoFontCluster = [self fontClusterForSlot:VibeThemeFontSlotInfo valueLabel:&infoFontValue];
    NSStackView *playlistFontCluster = [self fontClusterForSlot:VibeThemeFontSlotPlaylist valueLabel:&playlistFontValue];
    NSTextField *playlistDurationFontValue = nil;
    NSStackView *playlistDurationFontCluster =
            [self fontClusterForSlot:VibeThemeFontSlotPlaylistDuration
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
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_INFO
                control:[self darkLightPairWithDark:_infoDarkWell light:_infoLightWell]],
        [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TIMES
                control:[self darkLightPairWithDark:_timeDarkWell light:_timeLightWell]],
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
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TITLE
                    control:[self darkLightPairWithDark:_titleDarkWell light:_titleLightWell]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_ARTIST control:artistFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_ARTIST
                    control:[self darkLightPairWithDark:_artistDarkWell light:_artistLightWell]],
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
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYING_ROW
                    control:[self darkLightPairWithDark:_playingRowDarkWell light:_playingRowLightWell]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SELECTED_ROW
                    control:[self darkLightPairWithDark:_selectedRowDarkWell light:_selectedRowLightWell]],
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

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self closeEditorPanels];
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
    BOOL single = [theme.mode isEqualToString:SETTINGS_VALUE_THEME_MODE_SINGLE];
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

- (void)refreshFromSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;

    // The common card.
    [_appearancePopUp selectItemAtIndex:
            [_appearancePopUp indexOfItemWithRepresentedObject:settings.windowAppearanceStyle]];
    _trafficLightsSwitch.state = StateForBOOL(settings.showTrafficLights);

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
    // open/close, the window regaining key) would silently discard the edit.
    if (_nameField.currentEditor == nil) {
        _nameField.stringValue = builtIn ? @"" : ([settings displayNameForThemeIdentifier:active] ?: @"");
    }

    [_modePopUp selectItemAtIndex:
            [_modePopUp indexOfItemWithRepresentedObject:theme.mode]];
    [_backgroundPopUp selectItemAtIndex:
            [_backgroundPopUp indexOfItemWithRepresentedObject:theme.windowBackgroundStyle]];
    _backgroundDarkWell.color = [theme windowBackgroundColorForDark:YES]
            ?: [MainPlayerContentView defaultSolidBackgroundColorForDark:YES];
    _backgroundLightWell.color = [theme windowBackgroundColorForDark:NO]
            ?: [MainPlayerContentView defaultSolidBackgroundColorForDark:NO];
    [_windowTintPopUp selectItemAtIndex:
            [_windowTintPopUp indexOfItemWithRepresentedObject:theme.windowTint]];
    _windowTintDarkWell.color = [theme windowTintColorForDark:YES] ?: DefaultWindowTintColor(YES);
    _windowTintLightWell.color = [theme windowTintColorForDark:NO] ?: DefaultWindowTintColor(NO);
    _cornerRadiusSlider.doubleValue = theme.windowCornerRadius;
    [self refreshCornerRadiusValue];

    _fileInfoSwitch.state = StateForBOOL(theme.showFileInfo);
    BOOL remaining = theme.showRemainingTime;
    _timeTotalRadio.state = StateForBOOL(!remaining);
    _timeRemainingRadio.state = StateForBOOL(remaining);
    _showBPMSwitch.state = StateForBOOL(theme.showBPM);
    BOOL showKey = theme.showKey;
    _showKeySwitch.state = StateForBOOL(showKey);
    [_keyNotationPopUp selectItemAtIndex:
            [_keyNotationPopUp indexOfItemWithRepresentedObject:theme.keyNotation]];
    _keyColorsSwitch.state = StateForBOOL(theme.keyColorsEnabled);

    _titleDarkWell.color = [theme displayTitleColorForDark:YES];
    _titleLightWell.color = [theme displayTitleColorForDark:NO];
    _artistDarkWell.color = [theme displayArtistColorForDark:YES];
    _artistLightWell.color = [theme displayArtistColorForDark:NO];
    _infoDarkWell.color = [theme displayInfoColorForDark:YES];
    _infoLightWell.color = [theme displayInfoColorForDark:NO];
    _timeDarkWell.color = [theme displayTimeColorForDark:YES];
    _timeLightWell.color = [theme displayTimeColorForDark:NO];

    // An unknown persisted style identifier renders as the default style —
    // the waveform view's own fallback — so show that rather than misreport.
    NSInteger styleIndex = [_waveformPopUp indexOfItemWithRepresentedObject:theme.waveformStyle];
    if (styleIndex < 0) {
        styleIndex = [_waveformPopUp
                indexOfItemWithRepresentedObject:SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT];
    }
    [_waveformPopUp selectItemAtIndex:styleIndex];
    [_waveformThemePopUp selectItemAtIndex:
            [_waveformThemePopUp indexOfItemWithRepresentedObject:theme.waveformTheme]];
    _waveformGradientSwitch.state = StateForBOOL(theme.waveformGradient);
    _playlistArtworkSwitch.state = StateForBOOL(theme.showPlaylistArtworkColumn);
    _artDarkPreviewButton.image =
            [AppTheme imageForDefaultArtwork:[theme defaultArtworkForDark:YES]];
    _artLightPreviewButton.image =
            [AppTheme imageForDefaultArtwork:[theme defaultArtworkForDark:NO]];
    _artDarkClearButton.hidden = YES;
    _artLightClearButton.hidden = YES;
    _playlistDurationSwitch.state = StateForBOOL(theme.showPlaylistDurationColumn);
    _customDarkPlayedWell.color = [theme waveformPlayedColorForDark:YES] ?: DefaultCustomPlayedColor(YES);
    _customDarkUnplayedWell.color = [theme waveformUnplayedColorForDark:YES] ?: DefaultCustomUnplayedColor(YES);
    _customLightPlayedWell.color = [theme waveformPlayedColorForDark:NO] ?: DefaultCustomPlayedColor(NO);
    _customLightUnplayedWell.color = [theme waveformUnplayedColorForDark:NO] ?: DefaultCustomUnplayedColor(NO);

    [_playlistBackgroundPopUp selectItemAtIndex:
            [_playlistBackgroundPopUp indexOfItemWithRepresentedObject:theme.playlistBackgroundStyle]];
    _playlistBackgroundDarkWell.color = [theme playlistBackgroundColorForDark:YES]
            ?: [MainPlayerContentView defaultSolidBackgroundColorForDark:YES];
    _playlistBackgroundLightWell.color = [theme playlistBackgroundColorForDark:NO]
            ?: [MainPlayerContentView defaultSolidBackgroundColorForDark:NO];
    [_playlistTintPopUp selectItemAtIndex:
            [_playlistTintPopUp indexOfItemWithRepresentedObject:theme.playlistTint]];
    _playlistTintDarkWell.color = [theme playlistTintColorForDark:YES] ?: DefaultWindowTintColor(YES);
    _playlistTintLightWell.color = [theme playlistTintColorForDark:NO] ?: DefaultWindowTintColor(NO);
    _playingRowDarkWell.color = [theme playlistPlayingRowColorForDark:YES]
            ?: [PlaylistRowView neutralRowFillColorForDark:YES];
    _playingRowLightWell.color = [theme playlistPlayingRowColorForDark:NO]
            ?: [PlaylistRowView neutralRowFillColorForDark:NO];
    _selectedRowDarkWell.color = [theme playlistSelectedRowColorForDark:YES]
            ?: [PlaylistRowView neutralRowFillColorForDark:YES];
    _selectedRowLightWell.color = [theme playlistSelectedRowColorForDark:NO]
            ?: [PlaylistRowView neutralRowFillColorForDark:NO];

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
        @(VibeThemeFontSlotTitle): _titleFontValue,
        @(VibeThemeFontSlotArtist): _artistFontValue,
        @(VibeThemeFontSlotInfo): _infoFontValue,
        @(VibeThemeFontSlotPlaylist): _playlistFontValue,
        @(VibeThemeFontSlotPlaylistDuration): _playlistDurationFontValue,
    };
    for (NSNumber *slot in labels) {
        NSFont *font = [self currentFontForSlot:slot.integerValue];
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

- (void)duplicateTheme:(id)sender {
    NSString *selected = [self selectedThemeIdentifier];
    if (!selected) {
        return;
    }
    NSString *identifier = [AppSettings.sharedInstance duplicateThemeWithIdentifier:selected];
    if (identifier) {
        [self activateThemeWithIdentifier:identifier];
    }
}

// The read-only editor page's one action: copy, then edit the copy.
- (void)duplicateActiveTheme:(id)sender {
    NSString *identifier = [AppSettings.sharedInstance duplicateThemeWithIdentifier:
            AppSettings.sharedInstance.activeThemeIdentifier];
    if (identifier) {
        [self activateThemeWithIdentifier:identifier];
    }
}

// No confirmation, following the Files pane's Remove — and a sheet would
// block settings_click. Removing the active theme falls back to Vibe inside
// the store; the effect request repaints either way.
- (void)removeTheme:(id)sender {
    NSString *selected = [self selectedThemeIdentifier];
    if (!selected || [AppTheme isBuiltInIdentifier:selected]) {
        return;
    }
    // Land on the neighbor, not the first row: the next theme takes the
    // removed row's index, and removing the last row falls back to the row
    // before it. Selection IS activation, so the neighbor is applied rather
    // than merely selected — without this the store's own active-removal
    // fallback snapped the list to Vibe.
    NSUInteger index = [_themeIdentifiers indexOfObject:selected];
    NSString *neighbor = nil;
    if (index != NSNotFound) {
        neighbor = index + 1 < _themeIdentifiers.count ? _themeIdentifiers[index + 1]
                : (index > 0 ? _themeIdentifiers[index - 1] : nil);
    }
    [AppSettings.sharedInstance removeUserThemeWithIdentifier:selected];
    if (neighbor) {
        [AppSettings.sharedInstance applyThemeWithIdentifier:neighbor];
    }
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

- (void)editTheme:(id)sender {
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
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[UTTypeJSON, UTTypeZIP];
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result != NSModalResponseOK || !panel.URL) {
            return;
        }
        NSString *name = nil;
        NSError *error = nil;
        NSDictionary *record = [AppTheme
                recordFromJSONOrArchiveData:[NSData dataWithContentsOfURL:panel.URL]
                                       name:&name
                                      error:&error];
        if (!record) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = STR_SETTINGS_THEME_IMPORT_FAILED;
            [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
            return;
        }
        NSString *identifier = [AppSettings.sharedInstance
                addUserThemeWithRecord:record
                                  name:(name.length ? name : STR_THEME_NAME_IMPORTED)];
        [self activateThemeWithIdentifier:identifier];
    }];
}

- (void)exportTheme:(id)sender {
    NSString *selected = [self selectedThemeIdentifier];
    if (!selected) {
        return;
    }
    NSString *name = [AppSettings.sharedInstance displayNameForThemeIdentifier:selected] ?: selected;
    // A custom image travels beside the JSON, so those themes export as a
    // ZIP; everything else stays a plain JSON file.
    NSDictionary *record = [AppSettings.sharedInstance recordForThemeIdentifier:selected];
    NSData *archive = [AppTheme archiveDataForRecord:record name:name];
    NSString *extension = archive ? @"zip" : @"json";
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[archive ? UTTypeZIP : UTTypeJSON];
    panel.nameFieldStringValue =
            [name stringByAppendingPathExtension:extension] ?: @"theme.json";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) {
            return;
        }
        NSData *payload = archive ?: [AppTheme JSONDataForRecord:record name:name];
        [payload writeToURL:panel.URL atomically:YES];
    }];
}

#pragma mark - Common settings

- (void)toggleTrafficLights:(id)sender {
    AppSettings.sharedInstance.showTrafficLights =
            (_trafficLightsSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectTrafficLights];
}

- (void)appearanceChanged:(id)sender {
    AppSettings.sharedInstance.windowAppearanceStyle =
            _appearancePopUp.selectedItem.representedObject;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWindowAppearance];
}

// Which color slot every consumer reads moves with the mode, so the whole
// theme re-applies.
- (void)themeModeChanged:(id)sender {
    AppSettings.sharedInstance.currentTheme.mode =
            _modePopUp.selectedItem.representedObject;
    [self themeFieldDidChange:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings]; // ends in resolveLayoutStateFromSettings
}

// Seeds each unset side of a color pair from its displayed fallback, so the
// surface immediately matches what the wells show when a popup reveals them.
// Dark side FIRST: under single mode both reads and writes canonicalize to
// the dark-keyed slot, so the dark pass seeds it and the light pass finds it
// set and skips — the one slot takes the dark default with no special case.
- (void)seedUnsetColors:(VibeColor *_Nullable (^)(BOOL isDark))current
               fallback:(VibeColor *(^)(BOOL isDark))fallback
                 setter:(void (^)(VibeColor *color, BOOL isDark))setter {
    for (int darkPass = 1; darkPass >= 0; darkPass--) {
        BOOL isDark = darkPass == 1;
        if (!current(isDark)) {
            setter(fallback(isDark), isDark);
        }
    }
}

#pragma mark - Editor: window

- (void)backgroundStyleChanged:(id)sender {
    NSString *identifier = _backgroundPopUp.selectedItem.representedObject;
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL solid = [identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    if (solid) {
        [self seedUnsetColors:^(BOOL isDark) { return [theme windowBackgroundColorForDark:isDark]; }
                     fallback:^(BOOL isDark) { return [MainPlayerContentView defaultSolidBackgroundColorForDark:isDark]; }
                       setter:^(VibeColor *color, BOOL isDark) { [theme setWindowBackgroundColor:color forDark:isDark]; }];
    }
    theme.windowBackgroundStyle = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowChrome];
    [self resolveLayoutStateFromSettings];
}

- (void)backgroundColorChanged:(NSColorWell *)sender {
    [AppSettings.sharedInstance.currentTheme setWindowBackgroundColor:sender.color
            forDark:(sender == _backgroundDarkWell)];
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowChrome];
}

// The custom wash's fallbacks, shared by the wells' display and the seed on
// choosing Custom, so the window always matches what the wells show. Neutral
// grays in the middle of each appearance's clamp band, at the same alpha the
// artwork wash uses there — a starting point to pick a hue from.
static NSColor *DefaultWindowTintColor(BOOL isDark) {
    return isDark ? [NSColor colorWithWhite:0.14 alpha:0.40]
                  : [NSColor colorWithWhite:0.88 alpha:0.55];
}

- (void)windowTintChanged:(id)sender {
    NSString *identifier = _windowTintPopUp.selectedItem.representedObject;
    BOOL custom = [identifier isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM];
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if (custom) {
        [self seedUnsetColors:^(BOOL isDark) { return [theme windowTintColorForDark:isDark]; }
                     fallback:^(BOOL isDark) { return DefaultWindowTintColor(isDark); }
                       setter:^(VibeColor *color, BOOL isDark) { [theme setWindowTintColor:color forDark:isDark]; }];
    }
    theme.windowTint = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowTint];
    [self resolveLayoutStateFromSettings];
}

- (void)windowTintColorChanged:(NSColorWell *)sender {
    [AppSettings.sharedInstance.currentTheme setWindowTintColor:sender.color
                                                        forDark:(sender == _windowTintDarkWell)];
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowTint];
}

- (void)cornerRadiusChanged:(id)sender {
    // A magnetic detent at the factory radius — the reset, without a button:
    // dragging near the default snaps onto it.
    double radius = _cornerRadiusSlider.doubleValue;
    if (fabs(radius - kVibeThemeCornerRadiusDefault) < 1.5) {
        radius = kVibeThemeCornerRadiusDefault;
        _cornerRadiusSlider.doubleValue = radius;
    }
    AppSettings.sharedInstance.currentTheme.windowCornerRadius = radius;
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

- (void)labelColorChanged:(NSColorWell *)sender {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    // Title and artist paint the playlist rows too; info and time appear only
    // in the header, so their drags skip the table reload.
    VibeSettingsLiveEffect effect = VibeSettingsLiveEffectTrackDisplay;
    if (sender == _titleDarkWell || sender == _titleLightWell) {
        [theme setTitleColor:sender.color forDark:(sender == _titleDarkWell)];
        effect |= VibeSettingsLiveEffectPlaylistAppearance;
    } else if (sender == _artistDarkWell || sender == _artistLightWell) {
        [theme setArtistColor:sender.color forDark:(sender == _artistDarkWell)];
        effect |= VibeSettingsLiveEffectPlaylistAppearance;
    } else if (sender == _infoDarkWell || sender == _infoLightWell) {
        [theme setInfoColor:sender.color forDark:(sender == _infoDarkWell)];
    } else {
        [theme setTimeColor:sender.color forDark:(sender == _timeDarkWell)];
    }
    [self themeFieldDidChange:effect];
}

#pragma mark - Editor: waveform

// The custom pairs' fallbacks, shared by the wells' display and the seed on
// choosing Custom, so the waveform always matches what the wells show. Their
// alphas are the Mono theme's resting levels; the played hue is the
// appearance's own base.
static NSColor *DefaultCustomPlayedColor(BOOL isDark) {
    return isDark ? [NSColor colorWithRed:1 green:1 blue:1 alpha:0.75]
                  : [NSColor colorWithRed:0 green:0 blue:0 alpha:0.75];
}

static NSColor *DefaultCustomUnplayedColor(BOOL isDark) {
    return [NSColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:0.75];
}

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
        NSError *error = nil;
        NSString *stored = [AppTheme storeCustomArtworkData:
                [NSData dataWithContentsOfURL:panel.URL] error:&error];
        if (!stored) {
            [self refreshFromSettings];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = STR_SETTINGS_THEME_ALBUM_ART_INVALID;
            alert.informativeText = STR_SETTINGS_THEME_ALBUM_ART_REQUIREMENTS;
            [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
            return;
        }
        if (![AppSettings.sharedInstance.activeThemeIdentifier isEqualToString:target]) {
            [self refreshFromSettings]; // theme changed under the sheet — drop it
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

- (void)waveformStyleChanged:(id)sender {
    NSString *identifier = _waveformPopUp.selectedItem.representedObject;
    if (!identifier) {
        return;
    }
    AppSettings.sharedInstance.currentTheme.waveformStyle = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWaveformStyle];
}

- (void)waveformThemeChanged:(id)sender {
    NSString *identifier = _waveformThemePopUp.selectedItem.representedObject;
    BOOL custom = [identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if (custom) {
        [self seedUnsetColors:^(BOOL isDark) { return [theme waveformPlayedColorForDark:isDark]; }
                     fallback:^(BOOL isDark) { return DefaultCustomPlayedColor(isDark); }
                       setter:^(VibeColor *color, BOOL isDark) { [theme setWaveformPlayedColor:color forDark:isDark]; }];
        [self seedUnsetColors:^(BOOL isDark) { return [theme waveformUnplayedColorForDark:isDark]; }
                     fallback:^(BOOL isDark) { return DefaultCustomUnplayedColor(isDark); }
                       setter:^(VibeColor *color, BOOL isDark) { [theme setWaveformUnplayedColor:color forDark:isDark]; }];
    }
    theme.waveformTheme = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWaveformTheme];
    [self resolveLayoutStateFromSettings];
}

- (void)customColorChanged:(NSColorWell *)sender {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if (sender == _customDarkPlayedWell) {
        [theme setWaveformPlayedColor:sender.color forDark:YES];
    } else if (sender == _customDarkUnplayedWell) {
        [theme setWaveformUnplayedColor:sender.color forDark:YES];
    } else if (sender == _customLightPlayedWell) {
        [theme setWaveformPlayedColor:sender.color forDark:NO];
    } else {
        [theme setWaveformUnplayedColor:sender.color forDark:NO];
    }
    [self themeFieldDidChange:VibeSettingsLiveEffectWaveformTheme];
}

#pragma mark - Editor: playlist

- (void)playlistBackgroundStyleChanged:(id)sender {
    NSString *identifier = _playlistBackgroundPopUp.selectedItem.representedObject;
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if ([identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID]) {
        [self seedUnsetColors:^(BOOL isDark) { return [theme playlistBackgroundColorForDark:isDark]; }
                     fallback:^(BOOL isDark) { return [MainPlayerContentView defaultSolidBackgroundColorForDark:isDark]; }
                       setter:^(VibeColor *color, BOOL isDark) { [theme setPlaylistBackgroundColor:color forDark:isDark]; }];
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
        [self seedUnsetColors:^(BOOL isDark) { return [theme playlistTintColorForDark:isDark]; }
                     fallback:^(BOOL isDark) { return DefaultWindowTintColor(isDark); }
                       setter:^(VibeColor *color, BOOL isDark) { [theme setPlaylistTintColor:color forDark:isDark]; }];
    }
    theme.playlistTint = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowTint];
    [self resolveLayoutStateFromSettings];
}

- (void)playlistTintColorChanged:(NSColorWell *)sender {
    [AppSettings.sharedInstance.currentTheme setPlaylistTintColor:sender.color
            forDark:(sender == _playlistTintDarkWell)];
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowTint];
}

- (void)playlistColorChanged:(NSColorWell *)sender {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if (sender == _playlistBackgroundDarkWell || sender == _playlistBackgroundLightWell) {
        [theme setPlaylistBackgroundColor:sender.color
                                  forDark:(sender == _playlistBackgroundDarkWell)];
    } else if (sender == _playingRowDarkWell || sender == _playingRowLightWell) {
        [theme setPlaylistPlayingRowColor:sender.color forDark:(sender == _playingRowDarkWell)];
    } else {
        [theme setPlaylistSelectedRowColor:sender.color forDark:(sender == _selectedRowDarkWell)];
    }
    // Background wells rebuild the playlist background; the playing/selected
    // row fills are read per draw and only need a redraw (the lighter bit).
    BOOL background = sender == _playlistBackgroundDarkWell
            || sender == _playlistBackgroundLightWell;
    [self themeFieldDidChange:background ? VibeSettingsLiveEffectPlaylistAppearance
                                         : VibeSettingsLiveEffectPlaylistRowFills];
}

#pragma mark - Editor: name

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object != _nameField) {
        return;
    }
    NSString *active = AppSettings.sharedInstance.activeThemeIdentifier;
    if ([AppTheme isBuiltInIdentifier:active]) {
        return;
    }
    [AppSettings.sharedInstance renameUserThemeWithIdentifier:active
                                                       toName:_nameField.stringValue];
    // The stored name may have been deduped or fallback-named; show what
    // actually landed.
    [self refreshFromSettings];
}

#pragma mark - Editor: fonts

- (NSFont *)currentFontForSlot:(VibeThemeFontSlot)slot {
    switch (slot) {
        case VibeThemeFontSlotInfo:     return [Fonts infoFont:kVibeThemeInfoFontBaseSize bold:NO];
        case VibeThemeFontSlotPlaylist: return [Fonts playlistFont:kVibeThemePlaylistFontBaseSize];
        case VibeThemeFontSlotPlaylistDuration:
            return [Fonts playlistDurationFont:kVibeThemePlaylistDurationFontBaseSize];
        case VibeThemeFontSlotArtist:   return [Fonts artistFont:kVibeThemeArtistFontBaseSize];
        default:                        return [Fonts titleFont:kVibeThemeTitleFontBaseSize];
    }
}

- (void)selectFont:(NSButton *)sender {
    _fontEditingSlot = (VibeThemeFontSlot)sender.tag;
    // TRAP: a focused field editor is an NSTextView, which implements
    // changeFont: and would eat the panel's sends to restyle the Name field —
    // park first responder on the pane's own view before opening the panel.
    [self.view.window makeFirstResponder:self.view];
    NSFontManager *manager = NSFontManager.sharedFontManager;
    [manager setSelectedFont:[self currentFontForSlot:_fontEditingSlot] isMultiple:NO];
    [manager orderFrontFontPanel:self];
}

- (NSFontPanelModeMask)validModesForFontPanel:(NSFontPanel *)fontPanel {
    return NSFontPanelModeMaskCollection | NSFontPanelModeMaskFace | NSFontPanelModeMaskSize;
}

// Continuous browsing in the panel lands here per pick — a live preview for
// free. The store clamps the size; face names resolve through Fonts'
// never-nil fallback at draw time.
- (void)changeFont:(NSFontManager *)sender {
    if (_fontEditingSlot == VibeThemeFontSlotNone) {
        return;
    }
    NSFont *font = [sender convertFont:[self currentFontForSlot:_fontEditingSlot]];
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    switch (_fontEditingSlot) {
        case VibeThemeFontSlotInfo:
            theme.infoFontFace = font.fontName;
            theme.infoFontSize = font.pointSize;
            break;
        case VibeThemeFontSlotPlaylist:
            theme.playlistFontFace = font.fontName;
            theme.playlistFontSize = font.pointSize;
            break;
        case VibeThemeFontSlotPlaylistDuration:
            theme.playlistDurationFontFace = font.fontName;
            theme.playlistDurationFontSize = font.pointSize;
            break;
        case VibeThemeFontSlotArtist:
            theme.artistFontFace = font.fontName;
            theme.artistFontSize = font.pointSize;
            break;
        default:
            theme.titleFontFace = font.fontName;
            theme.titleFontSize = font.pointSize;
            break;
    }
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
    _fontEditingSlot = VibeThemeFontSlotNone;
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
