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
#import "AppSettings+Mac.h"
#import "AppTheme+Archive.h"
#import "WaveformRendererRegistry.h"
#import "MainPlayerController+Settings.h"
#import "SettingsWindowController.h" // the toolbar navigation control follows the pane's pages
#import "Formatters.h"
#import "VibeStrings.h"

static const CGFloat kThemeListRowHeight = 22;
// Ten rows: the two group headers, the built-ins, and room for a handful of
// the user's own before it scrolls.
static const CGFloat kThemeListHeight = 10 * kThemeListRowHeight;
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
    NSButton *editButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_EDIT
                                              target:self action:@selector(editTheme:)];
    NSButton *exportButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_EXPORT
                                                target:self action:@selector(exportTheme:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:
            @[addButton, _removeThemeButton, editButton, exportButton]];
    buttons.spacing = 8;
    SettingsRowView *buttonRow = [SettingsRowView rowWithContentView:buttons];

    // The waveform style is a THEME field surfaced on the list page: it
    // follows every theme switch, and editing it here goes through the same
    // working-record funnel as the editor's row — over a built-in it lands
    // in the divergence key rather than dirtying the theme.
    _listWaveformPopUp = [self waveformStylePopUpButton];

    // The level mapping's two common settings sit beside it. The gain takes
    // the corner-radius cluster's shape: a detent slider and a fixed-width
    // readout, so the changing digit count never nudges the slider.
    _waveformNormalizeSwitch = [self switchWithAction:@selector(toggleWaveformNormalize:)];
    VibeDetentSlider *gainSlider = [VibeDetentSlider sliderWithValue:0
                                                            minValue:-kVibeWaveformGainMaxDB
                                                            maxValue:kVibeWaveformGainMaxDB
                                                              target:self action:@selector(waveformGainChanged:)];
    gainSlider.detentValue = 0;
    gainSlider.continuous = YES;
    [gainSlider.widthAnchor constraintEqualToConstant:kAppearancePopUpWidth].active = YES;
    _waveformGainSlider = gainSlider;
    _waveformGainValue = [NSTextField labelWithString:@""];
    _waveformGainValue.textColor = NSColor.secondaryLabelColor;
    _waveformGainValue.alignment = NSTextAlignmentRight;
    [_waveformGainValue.widthAnchor constraintEqualToConstant:50].active = YES;
    NSStackView *gainCluster = [NSStackView stackViewWithViews:@[_waveformGainSlider, _waveformGainValue]];
    gainCluster.spacing = 10;

    _listSections = @[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_APPEARANCE_LABEL control:_appearancePopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_TRAFFIC_LIGHTS control:_trafficLightsSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WAVEFORM_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_LABEL control:_listWaveformPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_NORMALIZE
                                  caption:STR_SETTINGS_WAVEFORM_NORMALIZE_CAPTION
                                  control:_waveformNormalizeSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_GAIN
                                  caption:STR_SETTINGS_WAVEFORM_GAIN_CAPTION
                                  control:gainCluster],
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

    [self refreshEditorFromSettings];
    [self resolveLayoutStateFromSettings];
}

// The pane's themed rows all funnel here after writing their currentTheme
// field: persist the working record, then request the row's live effect.
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect {
    [AppSettings.sharedInstance currentThemeDidChange];
    [self.playerController applySettingsLiveEffects:effect];
}

#pragma mark - Waveform style, on both pages

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

#pragma mark - Theme actions

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

- (void)toggleWaveformNormalize:(id)sender {
    AppSettings.sharedInstance.waveformNormalize =
            (_waveformNormalizeSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWaveformLevels];
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
