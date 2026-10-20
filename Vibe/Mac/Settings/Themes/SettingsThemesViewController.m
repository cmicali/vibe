//
//  SettingsThemesViewController.m
//  Vibe
//
//  The list page, the page swap and the theme file actions (import, export,
//  the drop target). The Editor category builds the editor page, and the
//  EditorActions category holds its state and actions. The state they share
//  is SettingsThemesViewControllerInternal.h.
//
//  The editor swaps in beside the section stack and scrolls inside whatever
//  height the panes settled at, so its rows never grow every pane.
//

#import "SettingsThemesViewController.h"
#import "SettingsThemesViewControllerInternal.h"
#import "SettingsThemesViewController+Editor.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AppSettings.h"
#import "NSView+DarkMode.h"
#import "AppSettings+Mac.h"
#import "AppTheme+Archive.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme.h"
#import "MainPlayerController+Settings.h"
#import "SettingsWindowController.h" // the toolbar navigation control follows the pane's pages
#import "SettingsRules.h"
#import "VibeStrings.h"

static const NSUInteger kThemeListRowCount = 10;
static NSString *const kThemeCellIdentifier = @"themeCell";
static NSString *const kThemeGroupCellIdentifier = @"themeGroupCell";
// Header rows in _themeRows. Not identifiers: built-ins are plain names and
// user themes are UUIDs, so neither can collide.
static NSString *const kThemeRowUserHeader = @"//user";
static NSString *const kThemeRowBuiltInHeader = @"//built-in";

@implementation SettingsThemesViewController {
    NSTableView *_themeTable;
    NSButton *_removeThemeButton;
    // Store order, built-ins first.
    NSArray<NSString *> *_themeIdentifiers;
    // The list's rows: an identifier, or a group header sentinel. The user's
    // themes come first, under their header, so a new theme lands in view.
    NSArray<NSString *> *_themeRows;
    // Read once per refresh for the active row's "(Modified)".
    BOOL _activeThemeModified;
    NSArray<NSView *> *_listSections;
    // The same theme field as the editor's _waveformPopUp.
    NSPopUpButton *_listWaveformPopUp;
    NSButton *_editThemeButton, *_revertThemeButton;
    NSMutableArray<NSImageView *> *_waveformPreviews;
    NSArray *_waveformPreviewKey;
    BOOL _editorShown;
    // TRAP: reloadData and the programmatic reselect both post
    // selection-changed; treated as activations, they recurse
    // refreshFromSettings into a stack overflow.
    BOOL _refreshingThemeList;
}

#pragma mark - Construction

- (void)loadView {
    [self buildListControls];
    [self loadPaneWithSections:_listSections];
    [self buildEditorPage];
}

- (void)buildListControls {
    // One column, so no header: each name carries its theme's swatch.
    _themeTable = [SettingsRowView listTableWithColumnIdentifiers:@[kThemeCellIdentifier] delegate:self];
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
    _revertThemeButton = [NSButton buttonWithTitle:STR_SETTINGS_THEME_REVERT
            target:self action:@selector(revertTheme:)];
    // The library's buttons lead; the selected theme's own, Revert and
    // Customize…, trail, since the selected row is the current theme.
    NSStackView *buttons = [NSStackView stackViewWithViews:
            @[addButton, _removeThemeButton, exportButton]];
    [buttons addView:_revertThemeButton inGravity:NSStackViewGravityTrailing];
    [buttons addView:_editThemeButton inGravity:NSStackViewGravityTrailing];
    buttons.spacing = 8;
    SettingsRowView *buttonRow = [SettingsRowView rowWithContentView:buttons];

    // A THEME field: over a built-in, an edit lands in the divergence key.
    _listWaveformPopUp = [self waveformStylePopUpButton];

    _listSections = @[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_THEMES_SECTION rows:@[
            listRow,
            buttonRow,
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WAVEFORM_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_THEME_WAVEFORM_STYLE control:_listWaveformPopUp],
            [SettingsRowView rowWithContentView:[self waveformPreviewView]],
        ]],
    ];
    // The list is its own divider; the section's hairline would double it.
    buttonRow.showsTopSeparator = NO;
}

#pragma mark - Page swap

// Size-neutral: the shared height is the base stack's, and the hidden editor
// already holds its width, so nothing is remeasured.
- (void)applyEditorVisibility {
    _detailContainer.hidden = !_editorShown;
    for (NSView *section in _listSections) {
        section.hidden = _editorShown;
    }
    [self applyEditorTitle];
}

// Sets only the pane's title; updateNavigation pushes it to the window.
// The sidebar reads the tab item, so it keeps saying Themes.
- (void)applyEditorTitle {
    NSString *name = nil;
    if (_editorShown) {
        NSString *typed = _nameField.currentEditor ? _nameField.stringValue : nil;
        name = typed.length ? typed : [AppSettings.sharedInstance
                displayNameForThemeIdentifier:AppSettings.sharedInstance.activeThemeIdentifier];
    }
    self.title = name ? [NSString stringWithFormat:STR_SETTINGS_THEME_EDITOR_TITLE, name]
                      : STR_SETTINGS_THEMES_SECTION;
    [(SettingsWindowController *)self.view.window.windowController updateNavigation];
}

- (void)randomizeThemeSettings {
    if (!_editorShown) {
        return;
    }
    [AppSettings.sharedInstance.currentTheme
            randomizeSettingsWithWaveformStyles:[WaveformRendererRegistry availableIdentifiers]];
    [self themeFieldDidChange:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

- (void)randomizeThemeColors {
    if (!_editorShown) {
        return;
    }
    [AppSettings.sharedInstance.currentTheme randomizeColors];
    [self themeFieldDidChange:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

#pragma mark - Undo and redo

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
    [self applyLiveEffects:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

- (BOOL)editorShown {
    return _editorShown;
}

- (void)setEditorShown:(BOOL)shown {
    if (shown == _editorShown) {
        return;
    }
    _editorShown = shown;
    if (!shown) {
        [self closeEditorPanels];
    }
    [self refreshFromSettings]; // reaches applyEditorVisibility via the resolver
    if (shown) {
        // Showing the page scrolls nothing, so the jump bar is synced here.
        [self.view layoutSubtreeIfNeeded];
        [self syncEditorJumpSelection];
    }
}

// A hit only the editor holds opens it, so the row it names is on screen.
- (void)revealSearchHits {
    if (!_editorShown && self.searchQuery) {
        NSArray<SettingsRowView *> *hits = [self rowsMatchingSearch:self.searchQuery];
        BOOL listHit = NO;
        for (SettingsRowView *row in hits) {
            listHit |= ![row isDescendantOf:_detailContainer];
        }
        if (hits.count && !listHit) {
            [self setEditorShown:YES];
        }
    }
    [super revealSearchHits];
}

// The editor's first edit of a built-in: the edit already sits in the working
// record, so a copy of it becomes the active theme and the built-in stays
// pristine. Answers whether it forked.
- (BOOL)forkBuiltInForEdit {
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *active = settings.activeThemeIdentifier;
    if (!_editorShown || ![AppTheme isBuiltInIdentifier:active]) {
        return NO;
    }
    NSString *copy = [settings duplicateThemeWithIdentifier:active];
    if (!copy) {
        return NO;
    }
    [settings applyThemeWithIdentifier:copy];
    return YES;
}

- (void)previewAppearanceDark:(BOOL)dark {
    if (AppSettings.sharedInstance.currentTheme.requiredWindowAppearance) return;
    AppSettings.sharedInstance.windowAppearancePreviewStyle =
            dark ? SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK
                 : SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT;
    [self applyLiveEffects:VibeSettingsLiveEffectWindowAppearance];
    // For callers other than the toggle (the debug channel).
    [(SettingsWindowController *)self.view.window.windowController updateNavigation];
}

// Leaving the pane and closing the window both end the preview here.
- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self closeEditorPanels];
    if (AppSettings.sharedInstance.windowAppearancePreviewStyle) {
        AppSettings.sharedInstance.windowAppearancePreviewStyle = nil;
        [self applyLiveEffects:VibeSettingsLiveEffectWindowAppearance];
    }
}

#pragma mark - State

- (void)selectWaveformStyle:(NSString *)identifier in:(NSPopUpButton *)popUp {
    [self selectValue:[WaveformRendererRegistry styleIdentifierForIdentifier:
            [WaveformRendererRegistry resolveStyleIdentifier:identifier]] in:popUp];
}

- (void)refreshFromSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;

    [self selectWaveformStyle:theme.waveformStyle in:_listWaveformPopUp];
    _activeThemeModified = settings.currentThemeIsModified;
    _revertThemeButton.hidden = !_activeThemeModified;

    NSString *active = settings.activeThemeIdentifier;
    _themeIdentifiers = settings.orderedThemeIdentifiers;
    NSArray<NSString *> *userThemes = settings.userThemeIdentifiers;
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    if (userThemes.count) {
        [rows addObject:kThemeRowUserHeader];
        [rows addObjectsFromArray:userThemes];
    }
    [rows addObject:kThemeRowBuiltInHeader];
    [rows addObjectsFromArray:AppTheme.builtInThemeIdentifiers];
    _themeRows = rows;
    // The editor covers the list; leaving it refreshes through here again.
    if (!_editorShown) {
        _refreshingThemeList = YES;
        [_themeTable reloadData];
        NSInteger activeRow = [self rowForIdentifier:active];
        if (activeRow >= 0) {
            [_themeTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)activeRow]
                     byExtendingSelection:NO];
            // A programmatic selection does not scroll; an imported theme would
            // land selected past the fold.
            [_themeTable scrollRowToVisible:activeRow];
        }
        _refreshingThemeList = NO;
    }
    BOOL builtIn = [AppTheme isBuiltInIdentifier:active];
    _editThemeButton.title = builtIn ? STR_SETTINGS_THEME_CUSTOMIZE : STR_SETTINGS_THEME_EDIT;
    [SettingsRowView setControl:_removeThemeButton enabled:!builtIn];
    _removeThemeButton.toolTip = builtIn ? STR_SETTINGS_THEME_REMOVE_BUILT_IN_TIP : nil;

    [self refreshWaveformPreviews];
    // Every way onto the editor refreshes through here with _editorShown set.
    if (_editorShown) {
        [self refreshEditorFromSettings];
    }
    [self resolveLayoutStateFromSettings];
}

// continuous: a slider or color well mid-gesture; the store folds the gesture
// into one undo entry.
- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect {
    [self themeFieldDidChange:effect continuous:NO];
}

- (void)themeFieldDidChange:(VibeSettingsLiveEffect)effect continuous:(BOOL)continuous {
    BOOL forked = [self forkBuiltInForEdit];
    [AppSettings.sharedInstance currentThemeDidChangeContinuous:continuous];
    if (continuous) {
        [self applyLiveEffectsDuringDrag:effect];
    } else {
        [self applyLiveEffects:effect];
        [self didApplyDragEffects:effect];
    }
    if (forked) {
        [self refreshFromSettings]; // the list, the Name field and the title
    }
    // The toolbar alone, so a drag's ticks never re-read the page under it.
    [(SettingsWindowController *)self.view.window.windowController updateNavigation];
}

- (void)didApplyDragEffects:(NSUInteger)effects {
    if (effects & (VibeSettingsLiveEffectWaveformStyle | VibeSettingsLiveEffectWaveformTheme
                   | VibeSettingsLiveEffectWaveformLevels)) {
        [self refreshWaveformPreviews];
    }
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
    // No artwork, so album_art resolves to Mono's answer.
    WaveformTheme *palette = [WaveformTheme themeForAppTheme:theme isDark:dark artworkColor:nil];
    NSArray *key = @[style, @(dark), palette.paletteSignature, @(palette.flatFill),
            palette.playheadColor ?: NSNull.null,
            @(theme.waveformBarDensity), @(theme.waveformBarWidth), @(theme.waveformCentered),
            @(settings.waveformNormalize), @(settings.waveformGainDB)];
    if ([_waveformPreviewKey isEqualToArray:key]) return;
    CGImageRef bitmap = [WaveformRendererRegistry newPreviewForIdentifier:style dark:dark theme:palette
            barDensity:theme.waveformBarDensity barWidth:theme.waveformBarWidth
            centered:theme.waveformCentered
            normalize:settings.waveformNormalize gainDB:settings.waveformGainDB];
    NSImage *image = bitmap ? [[NSImage alloc] initWithCGImage:bitmap size:NSMakeSize(360, 64)] : nil;
    if (bitmap) CGImageRelease(bitmap);
    _waveformPreviewKey = key;
    for (NSImageView *preview in _waveformPreviews) {
        preview.image = image;
        preview.accessibilityLabel = [WaveformRendererRegistry displayNameForIdentifier:style];
    }
}

- (NSPopUpButton *)waveformStylePopUpButton {
    NSPopUpButton *popUp = [self popUpButtonWithWidth:kAppearancePopUpWidth
                                               action:@selector(waveformStyleChanged:)];
    for (NSString *identifier in [WaveformRendererRegistry styleIdentifiers]) {
        [self addItem:[WaveformRendererRegistry displayNameForIdentifier:identifier]
                value:identifier to:popUp];
    }
    return popUp;
}

// Rechoosing Detailed keeps its type.
- (void)waveformStyleChanged:(NSPopUpButton *)sender {
    NSString *identifier = sender.selectedItem.representedObject;
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    if (!identifier || [[WaveformRendererRegistry styleIdentifierForIdentifier:
            [WaveformRendererRegistry resolveStyleIdentifier:theme.waveformStyle]] isEqualToString:identifier]) {
        return;
    }
    theme.waveformStyle = identifier;
    [self themeFieldDidChange:VibeSettingsLiveEffectWaveformStyle];
    [self refreshFromSettings];
}

#pragma mark - Theme list

// nil for a group header or no row, which keeps headers unselectable.
- (nullable NSString *)identifierForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_themeRows.count) {
        return nil;
    }
    NSString *entry = _themeRows[(NSUInteger)row];
    return entry == kThemeRowUserHeader || entry == kThemeRowBuiltInHeader ? nil : entry;
}

- (NSInteger)rowForIdentifier:(NSString *)identifier {
    NSUInteger row = [_themeRows indexOfObject:identifier];
    return row == NSNotFound ? -1 : (NSInteger)row;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_themeRows.count;
}

// Not an AppKit group row: that style adds a gap and its own row height to a
// ten-row budget.
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return [self identifierForRow:row] != nil;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *identifier = [self identifierForRow:row];
    if (!identifier) {
        return [SettingsRowView listGroupCellWithIdentifier:kThemeGroupCellIdentifier inTableView:tableView title:
                (_themeRows[(NSUInteger)row] == kThemeRowUserHeader ? STR_SETTINGS_THEME_GROUP_USER
                                                                     : STR_SETTINGS_THEME_GROUP_BUILT_IN)];
    }
    NSTableCellView *cell = [SettingsRowView listCellWithIdentifier:kThemeCellIdentifier
                                                        inTableView:tableView imagePosition:NSImageLeft];
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *name = [settings displayNameForThemeIdentifier:identifier] ?: identifier;
    // A built-in that diverged says so on its own row, beside Revert.
    BOOL modified = _activeThemeModified && [identifier isEqualToString:settings.activeThemeIdentifier];
    cell.textField.stringValue = modified ? [NSString stringWithFormat:STR_SETTINGS_THEME_MODIFIED, name] : name;
    cell.imageView.image = [SettingsThemesViewController swatchForThemeIdentifier:identifier
                                                                             dark:tableView.isDark];
    cell.toolTip = cell.textField.stringValue;
    return cell;
}

// Each entry keeps the record it was drawn from, and a different record draws
// again. So an edit, an undo or a restored removal can never show a stale
// swatch, whichever theme was active at the time. The active theme draws from
// its working record, which holds a built-in's unsaved divergence.
+ (NSImage *)swatchForThemeIdentifier:(NSString *)identifier dark:(BOOL)dark {
    // "identifier|dark" or "|light" to @[record, image].
    static NSMutableDictionary<NSString *, NSArray *> *swatches;
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *key = [identifier stringByAppendingString:dark ? @"|dark" : @"|light"];
    BOOL active = [identifier isEqualToString:settings.activeThemeIdentifier];
    NSDictionary *record = active ? settings.currentTheme.dictionaryRepresentation
            : [settings recordForThemeIdentifier:identifier];
    NSArray *entry = swatches[key];
    if ([entry.firstObject isEqualToDictionary:record]) {
        return entry.lastObject;
    }
    AppTheme *theme = active ? settings.currentTheme : [[AppTheme alloc] initWithRecord:record];
    NSColor *fill = VibeWindowBackgroundTakesColor(theme.windowBackgroundStyle)
            ? [theme displayColorForBase:kVibeThemeColorWindowBackground dark:dark]
            : [theme.windowTint isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]
            ? [theme displayColorForBase:kVibeThemeColorWindowTint dark:dark]
            : [NSColor colorWithWhite:dark ? 0.2 : 0.92 alpha:1];
    WaveformTheme *palette = [WaveformTheme themeForAppTheme:theme isDark:dark artworkColor:nil];
    NSArray<NSColor *> *bars = [WaveformRendererRegistry swatchColorsForIdentifier:theme.waveformStyle
                                                                             theme:palette];
    NSColor *edge = [NSColor colorWithWhite:dark ? 1 : 0 alpha:0.2];
    NSImage *swatch = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 0.5, 0.5)
                                                             xRadius:4 yRadius:4];
        [fill setFill];
        [tile fill];
        [edge setStroke];
        [tile stroke];
        const CGFloat heights[] = {0.45, 0.8, 0.55};
        for (int i = 0; i < 3; i++) {
            [bars[i] setFill];
            CGFloat height = heights[i] * 11;
            NSRectFill(NSMakeRect(4 + i * 3.25, NSMidY(rect) - height / 2, 2, height));
        }
        return YES;
    }];
    if (!swatches) swatches = [NSMutableDictionary dictionary];
    swatches[key] = @[record, swatch];
    return swatch;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [SettingsRowView listRowViewForRow:row];
}

// Selection IS activation, as in View > Theme.
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

// Asked of the pasteboard once per drag (pasteboardOfDrag:canReadURLsWithOptions:).
+ (NSDictionary<NSPasteboardReadingOptionKey, id> *)themeFileReadingOptions {
    return @{
        NSPasteboardURLReadingFileURLsOnlyKey: @YES,
        NSPasteboardURLReadingContentsConformToTypesKey:
                @[UTTypeJSON.identifier, UTTypeZIP.identifier],
    };
}

// Retargeted onto the whole list: an import lands in the user group.
- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)operation {
    if (![self pasteboardOfDrag:info canReadURLsWithOptions:self.class.themeFileReadingOptions]) {
        return NSDragOperationNone;
    }
    [tableView setDropRow:-1 dropOperation:NSTableViewDropOn];
    return NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)operation {
    NSArray<NSURL *> *urls = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class]
                                                                    options:self.class.themeFileReadingOptions];
    [self importThemesFromURLs:urls];
    // Taken once there is something to read. The alert names any file that
    // failed.
    return urls.count > 0;
}

#pragma mark - Theme actions

- (void)activateThemeWithIdentifier:(NSString *)identifier {
    [AppSettings.sharedInstance applyThemeWithIdentifier:identifier];
    [self applyLiveEffects:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

- (void)duplicateTheme:(id)sender {
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *identifier = [settings duplicateThemeWithIdentifier:settings.activeThemeIdentifier];
    if (!identifier) {
        return;
    }
    [self activateThemeWithIdentifier:identifier];
    [self setEditorShown:YES];
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

- (void)removeTheme:(id)sender {
    NSString *selected = [self selectedThemeIdentifier];
    if (!selected || [AppTheme isBuiltInIdentifier:selected]) {
        return;
    }
    // Land on the neighbor: the next theme, else the one before.
    NSUInteger index = [_themeIdentifiers indexOfObject:selected];
    NSString *neighbor = nil;
    if (index != NSNotFound) {
        neighbor = index + 1 < _themeIdentifiers.count ? _themeIdentifiers[index + 1]
                : (index > 0 ? _themeIdentifiers[index - 1] : nil);
    }
    [AppSettings.sharedInstance removeUserThemeWithIdentifier:selected fallingBackTo:neighbor];
    [self applyLiveEffects:VibeSettingsLiveEffectThemeApply];
    [self refreshFromSettings];
}

- (void)editTheme:(id)sender {
    // A double-click on a header or below the rows names no theme.
    if (sender == _themeTable && [self identifierForRow:_themeTable.clickedRow] == nil) {
        return;
    }
    // Covers a double-click's row change landing late.
    NSString *selected = [self selectedThemeIdentifier];
    if (selected &&
        ![selected isEqualToString:AppSettings.sharedInstance.activeThemeIdentifier]) {
        [self activateThemeWithIdentifier:selected];
    }
    [(SettingsWindowController *)self.view.window.windowController showThemeEditor];
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

// The Import… panel's and the drop's one funnel. Activates once, after the
// whole list. Reads mapped, so AppTheme's size gate refuses a huge pick
// without loading it. Reads off main, since a picked file can sit on a share
// or in iCloud.
- (void)importThemesFromURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *contents = [NSMutableArray arrayWithCapacity:urls.count];
        for (NSURL *url in urls) {
            NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:NULL];
            [contents addObject:data ?: NSNull.null];
        }
        run_on_main_thread({
            [self importThemesFromContents:contents ofURLs:urls];
        });
    });
}

- (void)importThemesFromContents:(NSArray *)contents ofURLs:(NSArray<NSURL *> *)urls {
    NSString *lastImported = nil;
    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    for (NSUInteger index = 0; index < urls.count; index++) {
        NSURL *url = urls[index];
        NSString *name = nil;
        NSData *data = contents[index] == NSNull.null ? nil : contents[index];
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
}

// The plural form states no count, so no language needs plural agreement.
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
    // ZIP when the record references images, decided from the references
    // alone: the images are read only after the panel confirms.
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
        // No readable images: fall back to JSON.
        NSData *payload = carriesImages ? [AppTheme archiveDataForRecord:record name:name] : nil;
        payload = payload ?: [AppTheme JSONDataForRecord:record name:name];
        NSError *error = nil;
        if (payload && [payload writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) {
            return;
        }
        [[NSAlert alertWithError:error ?: [NSError errorWithDomain:NSCocoaErrorDomain
                                                              code:NSFileWriteUnknownError
                                                          userInfo:nil]]
                beginSheetModalForWindow:self.view.window completionHandler:nil];
    }];
}

@end
