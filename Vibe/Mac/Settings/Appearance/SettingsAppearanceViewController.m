//
//  SettingsAppearanceViewController.m
//  Vibe
//
// The overview holds the current theme's quick waveform edit, the theme
// library and common display preferences. The editor swaps in as a sibling
// of that section stack; opening a built-in first copies its working record.
//
// The editor deliberately never joins the shared pane-size settlement: it
// scrolls inside whatever size the panes settled at, because its ~20 rows
// would otherwise grow every pane. The
// page swap is therefore size-neutral, and the editor's conditional rows
// reflow only their own scrolled stack.
//
// The editor page's controls and actions are the Editor category
// (SettingsAppearanceViewController+Editor.m); this file is the list page,
// the page swap between the two, and the theme FILE actions — import,
// export and the drop target — which act on the list rather than on any
// one field. The state the two files share is the class extension in
// SettingsAppearanceViewControllerInternal.h.
//

#import "SettingsAppearanceViewController.h"
#import "SettingsAppearanceViewControllerInternal.h"
#import "SettingsAppearanceViewController+Editor.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AppSettings.h"
#import "NSView+DarkMode.h"
#import "AppSettings+Mac.h"
#import "AppTheme+Archive.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme.h"
#import "MainPlayerController+Settings.h"
#import "SettingsWindowController.h" // the toolbar navigation control follows the pane's pages
#import "Formatters.h"
#import "VibeStrings.h"

// Ten rows: the two group headers, the built-ins, and room for a handful of
// the user's own before it scrolls.
static const NSUInteger kThemeListRowCount = 10;
static NSString *const kThemeCellIdentifier = @"themeCell";
static NSString *const kThemeGroupCellIdentifier = @"themeGroupCell";
// The gain slider's magnetic detent: within this many dB of 0 snaps onto the
// plain mapping — the reset, without a button.
static const double kWaveformGainDetentDB = 0.75;

@implementation SettingsAppearanceViewController {
    // The list page.
    NSPopUpButton *_appearancePopUp;
    NSSwitch *_trafficLightsSwitch;
    NSTableView *_themeTable;
    NSButton *_removeThemeButton;
    // The themes in store order: built-ins first, then user themes. The table
    // shows a group header above each run, so a row is one past the headers
    // before it rather than an index into this — see identifierForRow:.
    NSArray<NSString *> *_themeIdentifiers;
    // The pane's own sections, kept so the editor swap can hide them — the
    // stack itself is the base class's.
    NSArray<NSView *> *_listSections;
    // The list page's shortcut to the same theme field as _waveformPopUp.
    NSPopUpButton *_listWaveformPopUp;
    NSSwitch *_waveformNormalizeSwitch;
    SettingsRowView *_appearanceRow, *_currentThemeRow;
    NSArray<SettingsRowView *> *_waveformLevelRows;
    NSButton *_waveformLevelsDisclosure, *_editThemeButton, *_revertThemeButton;
    NSMutableArray<NSImageView *> *_waveformPreviews;
    NSArray *_waveformPreviewKey;
    NSSlider *_waveformGainSlider; // a VibeDetentSlider, typed by what is read of it
    NSTextField *_waveformGainValue;
    BOOL _editorShown;
    // Armed by a Back pop; the toolbar's forward half re-opens the editor.
    BOOL _editorForwardAvailable;
    // TRAP: reentrancy guard. reloadData and the programmatic reselect both
    // post selection-changed, and the delegate treating those as user
    // activations recursed refreshFromSettings into a stack overflow.
    // Observed, not hypothetical.
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

    _themeTable = [SettingsRowView listTableWithColumnIdentifiers:@[@"icon", kThemeCellIdentifier] delegate:self];
    NSTableColumn *name = _themeTable.tableColumns[1];
    name.title = STR_SETTINGS_THEME_NAME_LABEL;
    name.width = 440;
    name.minWidth = 160;
    _themeTable.allowsMultipleSelection = NO;
    _themeTable.allowsEmptySelection = NO;
    _themeTable.target = self;
    _themeTable.doubleAction = @selector(editTheme:);
    [_themeTable registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    SettingsRowView *listRow = [SettingsRowView rowWithTableView:_themeTable
                                                        rowCount:kThemeListRowCount];

    NSPopUpButton *addButton = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [addButton addItemWithTitle:STR_SETTINGS_THEME_ADD];
    [addButton addItemWithTitle:STR_SETTINGS_THEME_ADD_NEW];
    addButton.lastItem.target = self;
    addButton.lastItem.action = @selector(addNewTheme:);
    [addButton addItemWithTitle:STR_SETTINGS_THEME_DUPLICATE];
    addButton.lastItem.target = self;
    addButton.lastItem.action = @selector(duplicateTheme:);
    [addButton addItemWithTitle:STR_SETTINGS_THEME_IMPORT];
    addButton.lastItem.target = self;
    addButton.lastItem.action = @selector(importTheme:);
    _removeThemeButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_REMOVE
                                            target:self action:@selector(removeTheme:)];
    _editThemeButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_EDIT
                                        target:self action:@selector(editTheme:)];
    NSButton *exportButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_EXPORT
                                                target:self action:@selector(exportTheme:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:
            @[addButton, _removeThemeButton, exportButton]];
    buttons.spacing = 8;
    SettingsRowView *buttonRow = [SettingsRowView rowWithContentView:buttons];

    // The waveform style is a THEME field surfaced on the list page: it
    // follows every theme switch, and editing it here goes through the same
    // working-record funnel as the editor's row — over a built-in it lands
    // in the divergence key rather than dirtying the theme.
    _listWaveformPopUp = [self waveformStylePopUpButton];

    _waveformNormalizeSwitch = [self switchWithAction:@selector(toggleWaveformNormalize:)];
    NSStackView *gainCluster = [self detentSliderClusterWithDetent:0
            min:-kVibeWaveformGainMaxDB max:kVibeWaveformGainMaxDB
            action:@selector(waveformGainChanged:) slider:&_waveformGainSlider valueLabel:&_waveformGainValue];

    _appearanceRow = [SettingsRowView rowWithTitle:STR_SETTINGS_APPEARANCE_LABEL control:_appearancePopUp];
    _waveformLevelRows = @[
            [SettingsRowView rowWithTitle:STR_SETTINGS_NORMALIZE_WAVEFORM control:_waveformNormalizeSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_DISPLAY_GAIN control:gainCluster]];
    for (SettingsRowView *row in _waveformLevelRows) {
        row.hidden = YES;
    }
    _waveformLevelsDisclosure = [NSButton buttonWithTitle:@""
            target:self action:@selector(toggleWaveformLevels:)];
    _waveformLevelsDisclosure.bezelStyle = NSBezelStyleDisclosure;
    [_waveformLevelsDisclosure setButtonType:NSButtonTypePushOnPushOff];
    _waveformLevelsDisclosure.accessibilityLabel = STR_SETTINGS_WAVEFORM_LEVELS;
    _revertThemeButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_REVERT
            target:self action:@selector(revertTheme:)];
    NSStackView *themeActions = [NSStackView stackViewWithViews:@[_revertThemeButton, _editThemeButton]];
    themeActions.spacing = 8;
    _currentThemeRow = [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_CURRENT
            control:themeActions];

    _listSections = @[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_THEME_CURRENT rows:@[
            _currentThemeRow,
            [SettingsRowView rowWithContentView:[self waveformPreviewView]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_STYLE control:_listWaveformPopUp],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_THEMES_SECTION rows:@[
            listRow,
            buttonRow,
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_DISPLAY_PREFERENCES rows:@[
            _appearanceRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_TRAFFIC_LIGHTS control:_trafficLightsSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_LEVELS
                    caption:STR_SETTINGS_WAVEFORM_LEVELS_CAPTION control:_waveformLevelsDisclosure],
            _waveformLevelRows[0], _waveformLevelRows[1],
        ]],
    ];
    // The sunk list's edge is the divider above the buttons; the hairline the
    // section stamps would double it.
    buttonRow.showsTopSeparator = NO;
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
    [self applyEditorTitle];
}

// The editor page retitles the window the way a pane switch would: the pane
// sets only its own title, and updateThemeNavigation re-pushes the
// pane-title chain (the host owns the container nesting). The sidebar label
// reads the tab ITEM, so it keeps saying Appearance. While the Name field is
// being edited the title follows the keystrokes; the stored name — deduped
// or fallback-named on commit — takes over when editing ends.
- (void)applyEditorTitle {
    NSString *name = nil;
    if (_editorShown) {
        NSString *typed = _nameField.currentEditor ? _nameField.stringValue : nil;
        name = typed.length ? typed : [AppSettings.sharedInstance
                displayNameForThemeIdentifier:AppSettings.sharedInstance.activeThemeIdentifier];
    }
    self.title = name ? [NSString stringWithFormat:STR_SETTINGS_THEME_EDITOR_TITLE, name]
                      : STR_MENU_VIEW_APPEARANCE;
    [(SettingsWindowController *)self.view.window.windowController updateThemeNavigation];
}

- (BOOL)canRandomize {
    return _editorShown
            && ![AppTheme isBuiltInIdentifier:AppSettings.sharedInstance.activeThemeIdentifier];
}

// A roll is one edit of the whole theme, so it rides ThemeApply like a
// theme switch, then the page re-reads every control.
- (void)randomizeThemeSettings {
    if (!self.canRandomize) {
        return;
    }
    [AppSettings.sharedInstance.currentTheme
            randomizeSettingsWithWaveformStyles:[WaveformRendererRegistry availableIdentifiers]];
    [self themeFieldDidChange:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

- (void)randomizeThemeColors {
    if (!self.canRandomize) {
        return;
    }
    [AppSettings.sharedInstance.currentTheme randomizeColors];
    [self themeFieldDidChange:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

#pragma mark - Undo and redo

// The store owns history; the pane applies the restored theme whole.
- (BOOL)canRestoreThemeHistoryForward:(BOOL)forward {
    AppSettings *settings = AppSettings.sharedInstance;
    return forward ? settings.canRedoThemeEdit : settings.canUndoThemeEdit;
}

- (void)restoreThemeHistoryForward:(BOOL)forward {
    if (![self canRestoreThemeHistoryForward:forward]) {
        return;
    }
    if (forward) [AppSettings.sharedInstance redoThemeEdit];
    else [AppSettings.sharedInstance undoThemeEdit];
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
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
    if ([AppTheme isBuiltInIdentifier:AppSettings.sharedInstance.activeThemeIdentifier]) {
        [self duplicateTheme:nil];
        return;
    }
    _editorShown = YES;
    _editorForwardAvailable = NO;
    [self refreshFromSettings]; // reaches applyEditorVisibility via the resolver
}

- (void)previewAppearanceDark:(BOOL)dark {
    if (AppSettings.sharedInstance.currentTheme.requiredWindowAppearance) return;
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

    // The common cards, plus the list page's waveform style shortcut.
    [self selectValue:settings.windowAppearanceStyle in:_appearancePopUp];
    _trafficLightsSwitch.state = StateForBOOL(settings.showTrafficLights);
    [self selectWaveformStyle:theme.waveformStyle in:_listWaveformPopUp];
    _waveformNormalizeSwitch.state = StateForBOOL(settings.waveformNormalize);
    _waveformGainSlider.doubleValue = settings.waveformGainDB;
    [self refreshWaveformGainValue];
    BOOL levels = [WaveformRendererRegistry supportsLevelsForIdentifier:theme.waveformStyle];
    [SettingsRowView setControl:_waveformNormalizeSwitch enabled:levels];
    [SettingsRowView setControl:_waveformGainSlider enabled:levels];
    [_waveformLevelRows.firstObject setCaption:levels ? nil : [NSString stringWithFormat:STR_SETTINGS_WAVEFORM_LEVELS_UNAVAILABLE,
            [WaveformRendererRegistry displayNameForIdentifier:theme.waveformStyle]]];
    BOOL single = theme.requiredWindowAppearance != nil;
    [SettingsRowView setControl:_appearancePopUp enabled:!single];
    [_appearanceRow setCaption:single ? STR_SETTINGS_THEME_SINGLE_CAPTION : nil];
    NSString *name = [settings displayNameForThemeIdentifier:settings.activeThemeIdentifier];
    BOOL modified = settings.currentThemeIsModified;
    [_currentThemeRow setRowTitle:modified ? [NSString stringWithFormat:STR_SETTINGS_THEME_MODIFIED, name] : name];
    _revertThemeButton.hidden = !modified;

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
    _editThemeButton.title = builtIn ? STR_SETTINGS_THEME_CUSTOMIZE : STR_SETTINGS_THEME_EDIT;
    [SettingsRowView setControl:_removeThemeButton enabled:!builtIn];

    [self refreshWaveformPreviews];
    [self refreshEditorFromSettings];
    [self resolveLayoutStateFromSettings];
}

// The pane's themed rows all funnel here after writing their currentTheme
// field: persist the working record, then request the row's live effect. A
// continuous control's tick — the corner-radius slider, a color well
// tracking its panel — says so, and the store folds the gesture into one
// undo entry.
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect {
    [self themeFieldDidChange:effect continuous:NO];
}

- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect continuous:(BOOL)continuous {
    [AppSettings.sharedInstance currentThemeDidChangeContinuous:continuous];
    [self.playerController applySettingsLiveEffects:effect];
    if (effect & (VibeSettingsLiveEffectWaveformStyle | VibeSettingsLiveEffectWaveformTheme)) {
        [self refreshWaveformPreviews];
    }
    // The undo arrow follows the stack this edit just pushed onto — the
    // toolbar alone, so a drag's ticks never re-read the page under it.
    [(SettingsWindowController *)self.view.window.windowController updateThemeNavigation];
}

#pragma mark - Waveform style, on both pages

- (NSImageView *)waveformPreviewView {
    NSImageView *preview = [[NSImageView alloc] initWithFrame:NSZeroRect];
    preview.imageScaling = NSImageScaleProportionallyUpOrDown;
    [preview.heightAnchor constraintEqualToConstant:64].active = YES;
    if (!_waveformPreviews) _waveformPreviews = [NSMutableArray array];
    [_waveformPreviews addObject:preview];
    return preview;
}

- (void)refreshWaveformPreviews {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;
    BOOL dark = self.view.isDark;
    NSString *style = [WaveformRendererRegistry resolveStyleIdentifier:theme.waveformStyle];
    // The synthetic sample carries no artwork, so album_art resolves to Mono's answer.
    WaveformTheme *palette = [WaveformTheme themeForAppTheme:theme isDark:dark artworkColor:nil];
    NSArray *key = @[style, @(dark), palette.playedColor, palette.unplayedColor,
            @(palette.flatFill), @(theme.waveformBarDensity), @(theme.waveformBarWidth),
            @(settings.waveformNormalize), @(settings.waveformGainDB)];
    if ([_waveformPreviewKey isEqualToArray:key]) return;
    CGImageRef bitmap = [WaveformRendererRegistry newPreviewForIdentifier:style dark:dark theme:palette
            barDensity:theme.waveformBarDensity barWidth:theme.waveformBarWidth
            normalize:settings.waveformNormalize gainDB:settings.waveformGainDB];
    NSImage *image = bitmap ? [[NSImage alloc] initWithCGImage:bitmap size:NSMakeSize(360, 64)] : nil;
    if (bitmap) CGImageRelease(bitmap);
    _waveformPreviewKey = key;
    for (NSImageView *preview in _waveformPreviews) {
        preview.image = image;
        preview.accessibilityLabel = [WaveformRendererRegistry displayNameForIdentifier:style];
    }
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
    [self refreshFromSettings];
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
    if ([tableColumn.identifier isEqualToString:@"icon"]) {
        NSTableCellView *cell = [SettingsRowView listCellWithIdentifier:tableColumn.identifier
                inTableView:tableView imagePosition:NSImageOnly];
        BOOL builtIn = identifier && [AppTheme isBuiltInIdentifier:identifier];
        NSString *kind = builtIn ? STR_SETTINGS_THEME_GROUP_BUILT_IN : STR_SETTINGS_THEME_GROUP_USER;
        cell.imageView.image = identifier ? [NSImage imageWithSystemSymbolName:builtIn ? @"paintpalette" : @"person"
                accessibilityDescription:kind] : nil;
        cell.toolTip = identifier ? kind : nil;
        return cell;
    }
    if (!identifier) {
        return [self groupCellInTableView:tableView title:
                (row == 0 ? STR_SETTINGS_THEME_GROUP_BUILT_IN : STR_SETTINGS_THEME_GROUP_USER)];
    }
    NSTableCellView *cell = [SettingsRowView listCellWithIdentifier:kThemeCellIdentifier
                                                        inTableView:tableView imagePosition:NSNoImage];
    cell.textField.stringValue =
            [AppSettings.sharedInstance displayNameForThemeIdentifier:identifier] ?: identifier;
    cell.toolTip = cell.textField.stringValue;
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [SettingsRowView listRowViewForRow:row];
}

// A header row: the label alone, small and secondary above the names.
- (NSTableCellView *)groupCellInTableView:(NSTableView *)tableView title:(NSString *)title {
    NSTableCellView *cell = [SettingsRowView listCellWithIdentifier:kThemeGroupCellIdentifier
                                                        inTableView:tableView imagePosition:NSNoImage];
    cell.textField.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold];
    cell.textField.textColor = NSColor.secondaryLabelColor;
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

#pragma mark - Theme actions

- (void)activateThemeWithIdentifier:(NSString *)identifier {
    [AppSettings.sharedInstance applyThemeWithIdentifier:identifier];
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

- (void)duplicateTheme:(id)sender {
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *identifier = [settings duplicateThemeWithIdentifier:settings.activeThemeIdentifier];
    if (!identifier) {
        return;
    }
    [self activateThemeWithIdentifier:identifier];
    [self showThemeEditorForActiveTheme];
    [self.view.window makeFirstResponder:_nameField];
    [_nameField selectText:nil];
}

- (void)revertTheme:(id)sender {
    [self activateThemeWithIdentifier:AppSettings.sharedInstance.activeThemeIdentifier];
}

- (void)addNewTheme:(id)sender {
    NSString *identifier = [AppSettings.sharedInstance
            addUserThemeWithRecord:AppSettings.sharedInstance.currentTheme.dictionaryRepresentation
                              name:STR_SETTINGS_THEME_ADD_NEW];
    [self activateThemeWithIdentifier:identifier];
}

// Removal shares the theme undo history, including its custom images.
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

#pragma mark - Import and export

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
    // An image — the placeholder, the app icon, a button's — travels beside
    // the JSON, so those themes export as a ZIP; everything else stays a plain
    // JSON file. WHICH it is comes from the record's own references, because
    // the images themselves are read only once the user has confirmed the
    // save — a theme's images run to megabytes, and a cancelled panel must
    // not have paid for them.
    NSDictionary *record = [AppSettings.sharedInstance recordForThemeIdentifier:selected];
    BOOL carriesImages = NO;
    for (NSString *key in AppTheme.imageFieldKeys) {
        NSString *reference = [record[key] isKindOfClass:NSString.class] ? record[key] : nil;
        carriesImages = carriesImages ||
                (reference.length > 0 && ![AppTheme referenceIsMissing:reference]);
    }
    NSString *extension = carriesImages ? @"zip" : @"json";
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[carriesImages ? UTTypeZIP : UTTypeJSON];
    panel.nameFieldStringValue = [name stringByAppendingPathExtension:extension]
            ?: [@"theme" stringByAppendingPathExtension:extension];
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) {
            return;
        }
        // The archive can still come back nil — an image deleted while the
        // panel was up — and the theme is worth more than its images, so the
        // JSON goes out rather than nothing.
        NSData *payload = carriesImages ? [AppTheme archiveDataForRecord:record name:name] : nil;
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

- (void)toggleWaveformLevels:(NSButton *)sender {
    for (SettingsRowView *row in _waveformLevelRows) {
        row.hidden = sender.state != NSControlStateValueOn;
    }
    [self paneContentDidChange];
}

- (void)toggleTrafficLights:(id)sender {
    AppSettings.sharedInstance.showTrafficLights =
            (_trafficLightsSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectTrafficLights];
}

- (void)toggleWaveformNormalize:(id)sender {
    AppSettings.sharedInstance.waveformNormalize =
            (_waveformNormalizeSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWaveformLevels];
    [self refreshWaveformPreviews];
}

- (void)waveformGainChanged:(id)sender {
    // A magnetic detent at 0 dB — the reset, without a button. The getter
    // answers the half-dB ladder; the knob re-syncs to what actually landed.
    double gainDB = _waveformGainSlider.doubleValue;
    if (fabs(gainDB) < kWaveformGainDetentDB) {
        gainDB = 0;
    }
    AppSettings.sharedInstance.waveformGainDB = gainDB;
    _waveformGainSlider.doubleValue = AppSettings.sharedInstance.waveformGainDB;
    [self refreshWaveformGainValue];
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWaveformLevels];
    [self refreshWaveformPreviews];
}

- (void)refreshWaveformGainValue {
    _waveformGainValue.stringValue = [NSString stringWithFormat:STR_SETTINGS_WAVEFORM_GAIN_VALUE,
            [Formatters.sharedInstance signedDecimalString:AppSettings.sharedInstance.waveformGainDB]];
}

// The stored choice, which also ends any titlebar preview (the store drops it
// on the write) — so the toggle is re-read from what the window ended up at.
- (void)appearanceChanged:(id)sender {
    AppSettings.sharedInstance.windowAppearanceStyle =
            _appearancePopUp.selectedItem.representedObject;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWindowAppearance];
    [(SettingsWindowController *)self.view.window.windowController updateThemeNavigation];
}

@end
