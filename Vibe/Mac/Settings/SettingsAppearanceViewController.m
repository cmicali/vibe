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
#import "MainPlayerContentView.h" // the playlist wash's unthemed default, shown by the wells
#import "PlaylistRowView.h"       // the row fills' unthemed default, shown by the wells
#import "Fonts.h"
#import "MainPlayerController+Menus.h"
#import "MainPlayerController+Settings.h"
#import "SettingsWindowController.h" // the toolbar navigation control follows the pane's pages
#import "VibeStrings.h"

static const CGFloat kAppearancePopUpWidth = 220;
static const CGFloat kThemeListHeight = 150;
static NSString *const kThemeCellIdentifier = @"themeCell";

// The font panel's target slot, carried as the Select buttons' tags. None
// while the panel is not editing a slot; changeFont: no-ops then, which is
// what keeps a stray panel from restyling anything.
typedef NS_ENUM(NSInteger, VibeThemeFontSlot) {
    VibeThemeFontSlotNone = 0,
    VibeThemeFontSlotMain,
    VibeThemeFontSlotInfo,
    VibeThemeFontSlotPlaylist,
};

// The corner-radius slider, with a tick above and below the track at the
// factory default — the visual for the action's magnetic detent. NSSlider's
// own tick marks are evenly spaced and single-sided, so the pair is drawn
// here; the knob geometry mirrors AppKit's linear layout (half the knob
// inset at each end).
@interface VibeDetentSlider : NSSlider
@property (nonatomic) double detentValue;
@end

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

@interface SettingsAppearanceViewController ()
        <NSTableViewDataSource, NSTableViewDelegate, NSFontChanging, NSTextFieldDelegate>
@end

@implementation SettingsAppearanceViewController {
    // The list page.
    NSPopUpButton *_appearancePopUp;
    NSPopUpButton *_modePopUp;
    NSSwitch *_trafficLightsSwitch;
    NSTableView *_themeTable;
    NSPopUpButton *_addThemeButton;
    NSButton *_removeThemeButton;
    NSButton *_editThemeButton;
    NSButton *_exportThemeButton;
    // The table's rows, in store order: built-ins first, then user themes.
    NSArray<NSString *> *_themeIdentifiers;
    // The pane's own sections, kept so the editor swap can hide them — the
    // stack itself is the base class's.
    NSArray<NSView *> *_listSections;

    // The editor page.
    NSView *_detailContainer;
    NSButton *_duplicateButton;
    SettingsRowView *_builtInRow;
    NSStackView *_editorStack;
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
    NSColorWell *_playingRowDarkWell, *_playingRowLightWell;
    NSColorWell *_selectedRowDarkWell, *_selectedRowLightWell;
    NSTextField *_mainFontValue, *_infoFontValue, *_playlistFontValue;
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
    [_appearancePopUp addItemWithTitle:STR_MENU_APPEARANCE_SYSTEM];
    _appearancePopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT;
    [_appearancePopUp addItemWithTitle:STR_MENU_APPEARANCE_LIGHT];
    _appearancePopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT;
    [_appearancePopUp addItemWithTitle:STR_MENU_APPEARANCE_DARK];
    _appearancePopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK;

    _trafficLightsSwitch = [self switchWithAction:@selector(toggleTrafficLights:)];

    _themeTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _themeTable.headerView = nil;
    _themeTable.allowsMultipleSelection = NO;
    _themeTable.allowsEmptySelection = NO;
    _themeTable.dataSource = self;
    _themeTable.delegate = self;
    _themeTable.rowHeight = 22;
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

    _listSections = @[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_APPEARANCE_LABEL control:_appearancePopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_TRAFFIC_LIGHTS control:_trafficLightsSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_THEMES_SECTION rows:@[
            [SettingsRowView rowWithContentView:scrollView],
            [SettingsRowView rowWithContentView:buttons],
        ]],
    ];
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
- (NSStackView *)wellPair:(NSColorWell *)first caption:(NSString *)firstCaption
                     well:(NSColorWell *)second caption:(NSString *)secondCaption {
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

- (NSStackView *)darkLightPairWithDark:(NSColorWell *)dark light:(NSColorWell *)light {
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
    [_modePopUp addItemWithTitle:STR_SETTINGS_THEME_MODE_DUAL];
    _modePopUp.lastItem.representedObject = SETTINGS_VALUE_THEME_MODE_DUAL;
    [_modePopUp addItemWithTitle:STR_SETTINGS_THEME_MODE_SINGLE];
    _modePopUp.lastItem.representedObject = SETTINGS_VALUE_THEME_MODE_SINGLE;

    _backgroundPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(backgroundStyleChanged:)];
    [_backgroundPopUp addItemWithTitle:STR_SETTINGS_THEME_BACKGROUND_GLASS];
    _backgroundPopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS;
    [_backgroundPopUp addItemWithTitle:STR_SETTINGS_THEME_BACKGROUND_SOLID];
    _backgroundPopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID;
    _backgroundDarkWell = [self themeColorWellWithAction:@selector(backgroundColorChanged:)];
    _backgroundLightWell = [self themeColorWellWithAction:@selector(backgroundColorChanged:)];
    _backgroundColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_BACKGROUND_COLORS
            control:[self darkLightPairWithDark:_backgroundDarkWell light:_backgroundLightWell]];

    _windowTintPopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(windowTintChanged:)];
    [_windowTintPopUp addItemWithTitle:STR_SETTINGS_WINDOW_TINT_NONE];
    _windowTintPopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_TINT_MONO;
    [_windowTintPopUp addItemWithTitle:STR_SETTINGS_WINDOW_TINT_ARTWORK];
    _windowTintPopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_TINT_ARTWORK;
    [_windowTintPopUp addItemWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM];
    _windowTintPopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_TINT_CUSTOM;
    _windowTintDarkWell = [self themeColorWellWithAction:@selector(windowTintColorChanged:)];
    _windowTintLightWell = [self themeColorWellWithAction:@selector(windowTintColorChanged:)];
    _windowTintDarkRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_DARK_LABEL
                                               control:_windowTintDarkWell];
    _windowTintLightRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WINDOW_TINT_CUSTOM_LIGHT_LABEL
                                                control:_windowTintLightWell];

    _cornerRadiusSlider = [VibeDetentSlider sliderWithValue:kVibeThemeCornerRadiusDefault
                                                   minValue:0 maxValue:kVibeThemeCornerRadiusMax
                                                     target:self action:@selector(cornerRadiusChanged:)];
    _cornerRadiusSlider.detentValue = kVibeThemeCornerRadiusDefault;
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
    [_playlistBackgroundPopUp addItemWithTitle:STR_SETTINGS_THEME_BACKGROUND_GLASS];
    _playlistBackgroundPopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_BACKGROUND_GLASS;
    [_playlistBackgroundPopUp addItemWithTitle:STR_SETTINGS_THEME_BACKGROUND_SOLID];
    _playlistBackgroundPopUp.lastItem.representedObject = SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID;

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
    [_keyNotationPopUp addItemWithTitle:STR_SETTINGS_KEY_NOTATION_CAMELOT];
    _keyNotationPopUp.lastItem.representedObject = SETTINGS_VALUE_KEY_NOTATION_CAMELOT;
    [_keyNotationPopUp addItemWithTitle:STR_SETTINGS_KEY_NOTATION_MUSICAL];
    _keyNotationPopUp.lastItem.representedObject = SETTINGS_VALUE_KEY_NOTATION_MUSICAL;
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
        [_waveformPopUp addItemWithTitle:[player displayNameForWaveformStyle:identifier]];
        _waveformPopUp.lastItem.representedObject = identifier;
    }
    _waveformThemePopUp = [self popUpButtonWithWidth:kAppearancePopUpWidth action:@selector(waveformThemeChanged:)];
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_MONO];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_MONO;
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_ORANGE];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_ORANGE;
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART;
    [_waveformThemePopUp addItemWithTitle:STR_SETTINGS_WAVEFORM_THEME_CUSTOM];
    _waveformThemePopUp.lastItem.representedObject = SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;

    _waveformGradientSwitch = [self switchWithAction:@selector(toggleWaveformGradient:)];
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
    _playingRowDarkWell = [self themeColorWellWithAction:@selector(playlistColorChanged:)];
    _playingRowLightWell = [self themeColorWellWithAction:@selector(playlistColorChanged:)];
    _selectedRowDarkWell = [self themeColorWellWithAction:@selector(playlistColorChanged:)];
    _selectedRowLightWell = [self themeColorWellWithAction:@selector(playlistColorChanged:)];

    NSTextField *mainFontValue = nil, *infoFontValue = nil, *playlistFontValue = nil;
    NSStackView *mainFontCluster = [self fontClusterForSlot:VibeThemeFontSlotMain valueLabel:&mainFontValue];
    NSStackView *infoFontCluster = [self fontClusterForSlot:VibeThemeFontSlotInfo valueLabel:&infoFontValue];
    NSStackView *playlistFontCluster = [self fontClusterForSlot:VibeThemeFontSlotPlaylist valueLabel:&playlistFontValue];
    _mainFontValue = mainFontValue;
    _infoFontValue = infoFontValue;
    _playlistFontValue = playlistFontValue;

    NSArray<NSView *> *sections = @[
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
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_FONTS_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_MAIN control:mainFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_INFO control:infoFontCluster],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_FONT_PLAYLIST control:playlistFontCluster],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYER_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TITLE
                    control:[self darkLightPairWithDark:_titleDarkWell light:_titleLightWell]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_ARTIST
                    control:[self darkLightPairWithDark:_artistDarkWell light:_artistLightWell]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_INFO
                    control:[self darkLightPairWithDark:_infoDarkWell light:_infoLightWell]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_COLOR_TIMES
                    control:[self darkLightPairWithDark:_timeDarkWell light:_timeLightWell]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_FILE_INFO control:_fileInfoSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_TIME_LABEL control:timeRadios],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_BPM control:_showBPMSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_KEY control:_showKeySwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_NOTATION_LABEL control:_keyNotationPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_COLORS control:_keyColorsSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WAVEFORM_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_LABEL control:_waveformPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_THEME_LABEL control:_waveformThemePopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_GRADIENT control:_waveformGradientSwitch],
            _customDarkRow,
            _customLightRow,
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYLIST_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_BACKGROUND
                    control:_playlistBackgroundPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYLIST_BACKGROUND_COLORS
                    control:[self darkLightPairWithDark:_playlistBackgroundDarkWell light:_playlistBackgroundLightWell]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_PLAYING_ROW
                    control:[self darkLightPairWithDark:_playingRowDarkWell light:_playingRowLightWell]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_SELECTED_ROW
                    control:[self darkLightPairWithDark:_selectedRowDarkWell light:_selectedRowLightWell]],
        ]],
    ];

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
// animatePaneContentChange pass is needed — nothing about the window moves.
- (void)applyEditorVisibility {
    _detailContainer.hidden = !_editorShown;
    for (NSView *section in _listSections) {
        section.hidden = _editorShown;
    }
    // The editor page retitles the window the way a pane switch would — the
    // title rides the pane-title chain (pane → tab controller → split, whose
    // title the window binds), and the sidebar label reads the tab ITEM, so
    // it keeps saying Appearance.
    NSString *active = AppSettings.sharedInstance.activeThemeIdentifier;
    self.title = _editorShown
            ? ([AppSettings.sharedInstance displayNameForThemeIdentifier:active]
                    ?: STR_MENU_VIEW_APPEARANCE)
            : STR_MENU_VIEW_APPEARANCE;
    self.parentViewController.parentViewController.title = self.title;
    [(SettingsWindowController *)self.view.window.windowController updateThemeNavigation];
}

- (BOOL)canGoBack {
    return _editorShown;
}

- (BOOL)canGoForward {
    return _editorForwardAvailable && !_editorShown;
}

- (void)navigateBack {
    [self popToThemeList:nil];
}

- (void)navigateForward {
    if (self.canGoForward) {
        [self showThemeEditorForActiveTheme];
    }
}

- (void)showThemeEditorForActiveTheme {
    _editorShown = YES;
    _editorForwardAvailable = NO;
    [self refreshFromSettings];
    [self applyEditorVisibility];
}

- (void)popToThemeList:(id)sender {
    _editorShown = NO;
    _editorForwardAvailable = YES;
    [self closeFontPanel];
    [self applyEditorVisibility];
    [self refreshFromSettings];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self closeFontPanel];
}

#pragma mark - State

- (void)resolveLayoutStateFromSettings {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
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
    [self applyEditorVisibility];
}

static void SetDescendantControlsEnabled(NSView *view, BOOL enabled) {
    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:NSControl.class]) {
            ((NSControl *)subview).enabled = enabled;
        }
        SetDescendantControlsEnabled(subview, enabled);
    }
}

- (void)refreshFromSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;

    // The common card.
    [_appearancePopUp selectItemAtIndex:
            [_appearancePopUp indexOfItemWithRepresentedObject:settings.windowAppearanceStyle]];
    _trafficLightsSwitch.state = settings.showTrafficLights
            ? NSControlStateValueOn : NSControlStateValueOff;

    // The theme list. Selection mirrors activation, so reselect the active
    // row after every reload.
    NSString *active = settings.activeThemeIdentifier;
    _themeIdentifiers = settings.orderedThemeIdentifiers;
    _refreshingThemeList = YES;
    [_themeTable reloadData];
    NSUInteger activeRow = [_themeIdentifiers indexOfObject:active];
    if (activeRow != NSNotFound) {
        [_themeTable selectRowIndexes:[NSIndexSet indexSetWithIndex:activeRow]
                 byExtendingSelection:NO];
    }
    _refreshingThemeList = NO;
    BOOL builtIn = [AppTheme isBuiltInIdentifier:active];
    _removeThemeButton.enabled = !builtIn;

    // The editor, from the working theme.
    _nameField.stringValue = builtIn ? @"" : ([settings displayNameForThemeIdentifier:active] ?: @"");
    _nameRow.hidden = builtIn;
    _builtInRow.hidden = !builtIn;

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

    _fileInfoSwitch.state = theme.showFileInfo ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL remaining = theme.showRemainingTime;
    _timeTotalRadio.state = remaining ? NSControlStateValueOff : NSControlStateValueOn;
    _timeRemainingRadio.state = remaining ? NSControlStateValueOn : NSControlStateValueOff;
    _showBPMSwitch.state = theme.showBPM ? NSControlStateValueOn : NSControlStateValueOff;
    BOOL showKey = theme.showKey;
    _showKeySwitch.state = showKey ? NSControlStateValueOn : NSControlStateValueOff;
    [_keyNotationPopUp selectItemAtIndex:
            [_keyNotationPopUp indexOfItemWithRepresentedObject:theme.keyNotation]];
    _keyColorsSwitch.state = theme.keyColorsEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    _titleDarkWell.color = [theme titleColorForDark:YES] ?: NSColor.labelColor;
    _titleLightWell.color = [theme titleColorForDark:NO] ?: NSColor.labelColor;
    _artistDarkWell.color = [theme artistColorForDark:YES] ?: NSColor.secondaryLabelColor;
    _artistLightWell.color = [theme artistColorForDark:NO] ?: NSColor.secondaryLabelColor;
    _infoDarkWell.color = [theme infoColorForDark:YES] ?: NSColor.tertiaryLabelColor;
    _infoLightWell.color = [theme infoColorForDark:NO] ?: NSColor.tertiaryLabelColor;
    _timeDarkWell.color = [theme timeColorForDark:YES] ?: NSColor.secondaryLabelColor;
    _timeLightWell.color = [theme timeColorForDark:NO] ?: NSColor.secondaryLabelColor;

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
    _waveformGradientSwitch.state =
            theme.waveformGradient ? NSControlStateValueOn : NSControlStateValueOff;
    _customDarkPlayedWell.color = [theme waveformPlayedColorForDark:YES] ?: DefaultCustomPlayedColor(YES);
    _customDarkUnplayedWell.color = [theme waveformUnplayedColorForDark:YES] ?: DefaultCustomUnplayedColor(YES);
    _customLightPlayedWell.color = [theme waveformPlayedColorForDark:NO] ?: DefaultCustomPlayedColor(NO);
    _customLightUnplayedWell.color = [theme waveformUnplayedColorForDark:NO] ?: DefaultCustomUnplayedColor(NO);

    [_playlistBackgroundPopUp selectItemAtIndex:
            [_playlistBackgroundPopUp indexOfItemWithRepresentedObject:theme.playlistBackgroundStyle]];
    BOOL playlistSolid = [theme.playlistBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    _playlistBackgroundDarkWell.color = [theme playlistBackgroundColorForDark:YES]
            ?: (playlistSolid ? [MainPlayerContentView defaultSolidBackgroundColorForDark:YES]
                              : [MainPlayerContentView defaultPlaylistBackgroundColorForDark:YES]);
    _playlistBackgroundLightWell.color = [theme playlistBackgroundColorForDark:NO]
            ?: (playlistSolid ? [MainPlayerContentView defaultSolidBackgroundColorForDark:NO]
                              : [MainPlayerContentView defaultPlaylistBackgroundColorForDark:NO]);
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
        _keyNotationPopUp.enabled = showKey;
        _keyColorsSwitch.enabled = showKey;
    }
    if (builtIn) {
        [self closeFontPanel];
    }

    [self resolveLayoutStateFromSettings];
}

- (void)refreshFontValueLabels {
    NSFont *main = [Fonts mainFont:kVibeThemeMainFontBaseSize];
    NSFont *info = [Fonts infoFont:kVibeThemeInfoFontBaseSize bold:NO];
    NSFont *playlist = [Fonts playlistFont:kVibeThemePlaylistFontBaseSize];
    _mainFontValue.stringValue = [NSString stringWithFormat:STR_SETTINGS_THEME_FONT_VALUE,
            main.displayName, (long)lround(main.pointSize)];
    _infoFontValue.stringValue = [NSString stringWithFormat:STR_SETTINGS_THEME_FONT_VALUE,
            info.displayName, (long)lround(info.pointSize)];
    _playlistFontValue.stringValue = [NSString stringWithFormat:STR_SETTINGS_THEME_FONT_VALUE,
            playlist.displayName, (long)lround(playlist.pointSize)];
}

// The pane's themed rows all funnel here after writing their currentTheme
// field: persist the working record, then request the row's live effect.
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect {
    [AppSettings.sharedInstance currentThemeDidChange];
    [self.playerController applySettingsLiveEffects:effect];
}

#pragma mark - Theme list

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_themeIdentifiers.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
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
    NSString *identifier = _themeIdentifiers[(NSUInteger)row];
    BOOL isActive = [identifier isEqualToString:AppSettings.sharedInstance.activeThemeIdentifier];
    cell.imageView.image = isActive
            ? [NSImage imageWithSystemSymbolName:@"checkmark" accessibilityDescription:nil]
            : nil;
    cell.textField.stringValue =
            [AppSettings.sharedInstance displayNameForThemeIdentifier:identifier] ?: identifier;
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
    NSInteger row = _themeTable.selectedRow;
    if (row < 0 || row >= (NSInteger)_themeIdentifiers.count) {
        return nil;
    }
    return _themeIdentifiers[(NSUInteger)row];
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
    [AppSettings.sharedInstance removeUserThemeWithIdentifier:selected];
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
    panel.allowedContentTypes = @[UTTypeJSON];
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSInteger result) {
        if (result != NSModalResponseOK || !panel.URL) {
            return;
        }
        NSString *name = nil;
        NSError *error = nil;
        NSDictionary *record = [AppTheme recordFromJSONData:[NSData dataWithContentsOfURL:panel.URL]
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
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypeJSON];
    panel.nameFieldStringValue = [name stringByAppendingPathExtension:@"json"] ?: @"theme.json";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) {
            return;
        }
        NSData *json = [AppTheme JSONDataForRecord:
                [AppSettings.sharedInstance recordForThemeIdentifier:selected] name:name];
        [json writeToURL:panel.URL atomically:YES];
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
    [self resolveLayoutStateFromSettings];
    [self refreshFromSettings];
}

#pragma mark - Editor: window

- (void)backgroundStyleChanged:(id)sender {
    NSString *identifier = _backgroundPopUp.selectedItem.representedObject;
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL solid = [identifier isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    if (solid) {
        // Choosing Solid seeds any unset color from the wells' displayed
        // fallbacks, so the window immediately matches them. Single mode has
        // one slot, seeded once from the dark default — without the guard the
        // light pass would land the light default in it.
        for (int darkPass = theme.isSingleMode ? 1 : 0; darkPass <= 1; darkPass++) {
            BOOL isDark = darkPass == 1;
            if (![theme windowBackgroundColorForDark:isDark]) {
                [theme setWindowBackgroundColor:
                        [MainPlayerContentView defaultSolidBackgroundColorForDark:isDark]
                                        forDark:isDark];
            }
        }
    }
    theme.windowBackgroundStyle = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowAppearance
            | VibeSettingsLiveEffectWindowChrome];
    [self resolveLayoutStateFromSettings];
}

- (void)backgroundColorChanged:(NSColorWell *)sender {
    [AppSettings.sharedInstance.currentTheme setWindowBackgroundColor:sender.color
            forDark:(sender == _backgroundDarkWell)];
    // WindowAppearance too: a single-mode theme's background color decides
    // which side the window pins to.
    [self themeFieldDidChange:VibeSettingsLiveEffectWindowAppearance
            | VibeSettingsLiveEffectWindowChrome];
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
        for (int darkPass = theme.isSingleMode ? 1 : 0; darkPass <= 1; darkPass++) {
            BOOL isDark = darkPass == 1;
            if (![theme windowTintColorForDark:isDark]) {
                [theme setWindowTintColor:DefaultWindowTintColor(isDark) forDark:isDark];
            }
        }
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
    if (sender == _titleDarkWell || sender == _titleLightWell) {
        [theme setTitleColor:sender.color forDark:(sender == _titleDarkWell)];
    } else if (sender == _artistDarkWell || sender == _artistLightWell) {
        [theme setArtistColor:sender.color forDark:(sender == _artistDarkWell)];
    } else if (sender == _infoDarkWell || sender == _infoLightWell) {
        [theme setInfoColor:sender.color forDark:(sender == _infoDarkWell)];
    } else {
        [theme setTimeColor:sender.color forDark:(sender == _timeDarkWell)];
    }
    // The label colors span the header and the playlist, so both repaint.
    [self themeFieldDidChange:VibeSettingsLiveEffectTrackDisplay
            | VibeSettingsLiveEffectPlaylistAppearance];
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
        // Choosing Custom seeds any unset color from the wells' displayed
        // fallbacks, so the waveform immediately matches what the wells show.
        for (int darkPass = theme.isSingleMode ? 1 : 0; darkPass <= 1; darkPass++) {
            BOOL isDark = darkPass == 1;
            if (![theme waveformPlayedColorForDark:isDark]) {
                [theme setWaveformPlayedColor:DefaultCustomPlayedColor(isDark) forDark:isDark];
            }
            if (![theme waveformUnplayedColorForDark:isDark]) {
                [theme setWaveformUnplayedColor:DefaultCustomUnplayedColor(isDark) forDark:isDark];
            }
        }
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
        // Choosing Solid seeds any unset color from the wells' displayed
        // fallbacks, so the playlist immediately matches them.
        for (int darkPass = 0; darkPass <= 1; darkPass++) {
            BOOL isDark = darkPass == 1;
            if (![theme playlistBackgroundColorForDark:isDark]) {
                [theme setPlaylistBackgroundColor:
                        [MainPlayerContentView defaultSolidBackgroundColorForDark:isDark]
                                          forDark:isDark];
            }
        }
    }
    theme.playlistBackgroundStyle = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectPlaylistAppearance];
    [self refreshFromSettings];
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
    [self themeFieldDidChange:VibeSettingsLiveEffectPlaylistAppearance];
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
        default:                        return [Fonts mainFont:kVibeThemeMainFontBaseSize];
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
        default:
            theme.mainFontFace = font.fontName;
            theme.mainFontSize = font.pointSize;
            break;
    }
    [self themeFieldDidChange:VibeSettingsLiveEffectFonts
            | VibeSettingsLiveEffectPlaylistAppearance
            | VibeSettingsLiveEffectTrackDisplay];
    [self refreshFontValueLabels];
}

- (void)closeFontPanel {
    _fontEditingSlot = VibeThemeFontSlotNone;
    if (NSFontPanel.sharedFontPanelExists) {
        [NSFontPanel.sharedFontPanel orderOut:nil];
    }
}

@end
