//
//  SettingsShortcutsViewController.m
//  Vibe
//

#import "SettingsShortcutsViewController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "MainMenuBuilder.h"
#import "MainPlayerController+Settings.h"
#import "ShortcutRules.h"
#import "VibeStrings.h"

static NSString *const kCommandColumn = @"command";
static NSString *const kShortcutColumn = @"shortcut";
static NSString *const kGroupCellIdentifier = @"group";
static const NSUInteger kShortcutListRowCount = 14;
static const CGFloat kShortcutColumnWidth = 120;
// The caption's wrap width before first layout, as the Files pane's.
static const CGFloat kCaptionWrapWidth = 408;

@interface SettingsShortcutsViewController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SettingsShortcutsViewController {
    NSTableView *_table;
    NSButton *_recordButton;
    NSButton *_clearButton;
    NSButton *_resetAllButton;
    NSTextField *_captionLabel;
    // A command identifier, or a header's title wrapped in an array, per row.
    NSArray *_rows;
    BOOL _reloadingList;
    // The last outcome to report; nil shows the explainer.
    NSString *_status;
    // Set while recording: the command, and the monitor that swallows every
    // key in this window until the captured key is released.
    NSString *_recordingIdentifier;
    id _recordingMonitor;
    NSArray<id> *_recordingObservers;
}

#pragma mark - Building

- (void)loadView {
    _table = [SettingsRowView listTableWithColumnIdentifiers:@[kCommandColumn, kShortcutColumn] delegate:self];
    [_table tableColumnWithIdentifier:kCommandColumn].title = STR_SETTINGS_SHORTCUTS_COLUMN_COMMAND;
    NSTableColumn *shortcutColumn = [_table tableColumnWithIdentifier:kShortcutColumn];
    shortcutColumn.title = STR_SETTINGS_SHORTCUTS_COLUMN_SHORTCUT;
    shortcutColumn.width = shortcutColumn.minWidth = shortcutColumn.maxWidth = kShortcutColumnWidth;
    shortcutColumn.resizingMask = NSTableColumnNoResizing;
    _table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    _table.target = self;
    _table.doubleAction = @selector(recordShortcut:);
    SettingsRowView *listRow = [SettingsRowView rowWithTableView:_table rowCount:kShortcutListRowCount];

    _recordButton = [NSButton buttonWithTitle:STR_SETTINGS_SHORTCUTS_RECORD target:self action:@selector(recordShortcut:)];
    _clearButton = [NSButton buttonWithTitle:STR_SETTINGS_SHORTCUTS_CLEAR target:self action:@selector(clearShortcut:)];
    _resetAllButton = [NSButton buttonWithTitle:STR_SETTINGS_SHORTCUTS_RESET_ALL target:self action:@selector(resetAllShortcuts:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[_recordButton, _clearButton, _resetAllButton]];
    buttons.spacing = 8;
    SettingsRowView *buttonRow = [SettingsRowView rowWithContentView:buttons];

    // Wraps at the row's real width (viewDidLayout); compression resistance
    // below the fitting priority, so the unwrapped text never widens the pane.
    _captionLabel = [NSTextField wrappingLabelWithString:STR_SETTINGS_SHORTCUTS_EXPLAIN];
    _captionLabel.selectable = NO;
    _captionLabel.textColor = NSColor.secondaryLabelColor;
    _captionLabel.preferredMaxLayoutWidth = kCaptionWrapWidth;
    [_captionLabel setContentCompressionResistancePriority:NSLayoutPriorityFittingSizeCompression - 1
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithRows:@[
            listRow,
            buttonRow,
            [SettingsRowView rowWithContentView:_captionLabel],
        ]],
    ]];
    // The list is its own divider; the section's hairlines would double it.
    listRow.showsTopSeparator = NO;
    buttonRow.showsTopSeparator = NO;
}

- (void)viewDidLayout {
    [super viewDidLayout];
    CGFloat width = NSWidth(_captionLabel.frame);
    if (width > 0 && fabs(_captionLabel.preferredMaxLayoutWidth - width) > 0.5) {
        _captionLabel.preferredMaxLayoutWidth = width;
    }
}

- (void)dealloc {
    [self endRecording];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [self endRecording];
    _status = nil;
}

// The main menu's own titles in its own order, so a row reads as the item it
// sets. Rebuilt per refresh: the menu is the source, and it is cheap.
- (NSArray *)rowsFromMainMenu {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSMenuItem *topLevel in NSApp.mainMenu.itemArray) {
        NSMutableArray<NSString *> *commands = [NSMutableArray array];
        [self collectCommandsIn:topLevel.submenu into:commands];
        if (commands.count) {
            [rows addObject:@[topLevel.title]];
            [rows addObjectsFromArray:commands];
        }
    }
    return rows;
}

- (void)collectCommandsIn:(NSMenu *)menu into:(NSMutableArray<NSString *> *)commands {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) {
            [self collectCommandsIn:item.submenu into:commands];
        }
        else if (item.identifier && [VibeShortcutIdentifiers() containsObject:item.identifier]) {
            [commands addObject:item.identifier];
        }
    }
}

// Validation retitles two items, so those take their stable names.
- (NSString *)labelForCommand:(NSString *)identifier {
    if ([identifier isEqualToString:kVibeMenuPlay]) {
        return STR_SETTINGS_SHORTCUTS_PLAY_PAUSE;
    }
    if ([identifier isEqualToString:kVibeMenuConvertToFLAC]) {
        return VibeConvertMenuTitle(NO);
    }
    NSMenuItem *item = [MainMenuBuilder mainMenuItemWithIdentifier:identifier];
    NSMenu *parent = item.menu.supermenu;
    if (parent && parent != NSApp.mainMenu) {
        NSInteger index = [parent indexOfItemWithSubmenu:item.menu];
        if (index >= 0) {
            return [NSString stringWithFormat:STR_SETTINGS_SHORTCUTS_SUBMENU_ITEM,
                                              [parent itemAtIndex:index].title, item.title];
        }
    }
    return item.title ?: identifier;
}

- (nullable NSString *)identifierForRow:(NSInteger)row {
    id entry = row >= 0 && row < (NSInteger)_rows.count ? _rows[(NSUInteger)row] : nil;
    return [entry isKindOfClass:NSString.class] ? entry : nil;
}

- (nullable NSString *)selectedIdentifier {
    return [self identifierForRow:_table.selectedRow];
}

#pragma mark - Refresh

- (void)refreshFromSettings {
    NSString *selected = [self selectedIdentifier];
    _rows = [self rowsFromMainMenu];
    // TRAP: the reload and reselection post selection changes; one treated as
    // the user's would cancel a recording a regained key just refreshed over.
    _reloadingList = YES;
    [_table reloadData];
    NSUInteger row = selected ? [_rows indexOfObject:selected] : NSNotFound;
    if (row != NSNotFound) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    }
    _reloadingList = NO;
    [self refreshControls];
}

- (void)refreshControls {
    NSString *identifier = [self selectedIdentifier];
    BOOL recording = _recordingIdentifier != nil;
    NSDictionary *overrides = AppSettings.sharedInstance.shortcutOverrides;
    [SettingsRowView setControl:_recordButton enabled:identifier && !recording];
    [SettingsRowView setControl:_clearButton enabled:identifier && !recording
            && VibeShortcutEffective(identifier, overrides) != kVibeShortcutNone];
    [SettingsRowView setControl:_resetAllButton enabled:!recording && overrides.count > 0];
    NSString *caption = recording
            ? [NSString stringWithFormat:STR_SETTINGS_SHORTCUTS_RECORDING, [self labelForCommand:_recordingIdentifier]]
            : _status ?: STR_SETTINGS_SHORTCUTS_EXPLAIN;
    if (![_captionLabel.stringValue isEqualToString:caption]) {
        _captionLabel.stringValue = caption;
        [self paneContentDidChange]; // a longer caption can wrap to another line
    }
}

#pragma mark - Actions

- (void)recordShortcut:(id)sender {
    NSString *identifier = [self selectedIdentifier];
    if (!identifier || _recordingIdentifier) {
        return;
    }
    _recordingIdentifier = identifier;
    NSWindow *window = self.view.window;
    __weak SettingsShortcutsViewController *weakSelf = self;
    // Every key in this window is swallowed while the monitor stands, so a
    // recorded ⌘W or a bare skip key never reaches a menu key equivalent.
    // It stands until the captured key is released, so its repeats are
    // swallowed too.
    _recordingMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
                                                              handler:^NSEvent *(NSEvent *event) {
        SettingsShortcutsViewController *strongSelf = weakSelf;
        if (!strongSelf || event.window != window) {
            return event;
        }
        if (event.type == NSEventTypeKeyUp) {
            if (!strongSelf->_recordingIdentifier) {
                [strongSelf endRecording];
            }
        }
        else if (strongSelf->_recordingIdentifier && !event.isARepeat) {
            [strongSelf captureKeyEvent:event];
        }
        return nil;
    }];
    // Nothing delivers the release once focus or a menu takes the keyboard.
    void (^cancel)(NSNotification *) = ^(NSNotification *note) {
        [weakSelf endRecording];
        [weakSelf refreshControls];
    };
    _recordingObservers = @[
        [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResignKeyNotification object:window
                                                         queue:NSOperationQueue.mainQueue usingBlock:cancel],
        [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidBeginTrackingNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:cancel],
    ];
    [self refreshControls];
}

- (void)captureKeyEvent:(NSEvent *)event {
    NSString *identifier = _recordingIdentifier;
    _recordingIdentifier = nil;  // the monitor stays for the release
    unsigned short keyCode = VibeShortcutCanonicalKeyCode(event.keyCode);
    NSEventModifierFlags modifiers = event.modifierFlags & kVibeShortcutModifierMask;
    if (keyCode == 53 && modifiers == 0) {   // Escape
        [self refreshControls];
        return;
    }
    VibeShortcut shortcut = VibeShortcutMake(keyCode, modifiers);
    unichar character = [MainMenuBuilder characterForKeyCode:keyCode];
    if (VibeShortcutIsReserved(keyCode, character, modifiers)) {
        _status = [NSString stringWithFormat:STR_SETTINGS_SHORTCUTS_RESERVED,
                                             [MainMenuBuilder displayStringForShortcut:shortcut]];
    }
    else if (![MainMenuBuilder labelForKeyCode:keyCode]) {
        _status = STR_SETTINGS_SHORTCUTS_UNUSABLE;
    }
    else {
        NSString *loser = [self assignShortcut:shortcut character:character to:identifier];
        _status = loser ? [NSString stringWithFormat:STR_SETTINGS_SHORTCUTS_REASSIGNED,
                                                     [MainMenuBuilder displayStringForShortcut:shortcut],
                                                     [self labelForCommand:identifier],
                                                     [self labelForCommand:loser]]
                        : nil;
    }
    [self refreshFromSettings];
}

- (void)endRecording {
    _recordingIdentifier = nil;
    if (_recordingMonitor) {
        [NSEvent removeMonitor:_recordingMonitor];
        _recordingMonitor = nil;
    }
    for (id observer in _recordingObservers) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
    }
    _recordingObservers = nil;
}

- (void)clearShortcut:(id)sender {
    NSString *identifier = [self selectedIdentifier];
    if (identifier) {
        [self assignShortcut:kVibeShortcutNone character:0 to:identifier];
        _status = nil;
        [self refreshFromSettings];
    }
}

- (void)resetAllShortcuts:(id)sender {
    AppSettings.sharedInstance.shortcutOverrides = @{};
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectShortcuts];
    _status = nil;
    [self refreshFromSettings];
}

// The store, then the effect: the pane's one write path. Answers the command
// that lost the shortcut.
- (nullable NSString *)assignShortcut:(VibeShortcut)shortcut character:(unichar)character
                                   to:(NSString *)identifier {
    NSString *loser = nil;
    AppSettings *settings = AppSettings.sharedInstance;
    settings.shortcutOverrides = VibeShortcutOverridesByAssigning(settings.shortcutOverrides, identifier,
                                                                  shortcut, character, &loser);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectShortcuts];
    return loser;
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_rows.count;
}

// A header is an ordinary row the delegate refuses, as the theme list's.
- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return [self identifierForRow:row] != nil;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [SettingsRowView listRowViewForRow:row];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSString *identifier = [self identifierForRow:row];
    BOOL commandColumn = [tableColumn.identifier isEqualToString:kCommandColumn];
    if (!identifier) {
        NSTableCellView *cell = [SettingsRowView listCellWithIdentifier:kGroupCellIdentifier
                                                            inTableView:tableView imagePosition:NSNoImage];
        cell.textField.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize weight:NSFontWeightSemibold];
        cell.textField.textColor = NSColor.secondaryLabelColor;
        cell.textField.stringValue = commandColumn ? [_rows[(NSUInteger)row] firstObject] : @"";
        return cell;
    }
    NSTableCellView *cell = [SettingsRowView listCellWithIdentifier:tableColumn.identifier
                                                        inTableView:tableView imagePosition:NSNoImage];
    if (commandColumn) {
        cell.textField.stringValue = [self labelForCommand:identifier];
        return cell;
    }
    VibeShortcut shortcut = VibeShortcutEffective(identifier, AppSettings.sharedInstance.shortcutOverrides);
    cell.textField.stringValue = [MainMenuBuilder displayStringForShortcut:shortcut];
    cell.textField.textColor = shortcut == kVibeShortcutNone ? NSColor.tertiaryLabelColor : NSColor.labelColor;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_reloadingList) {
        return;
    }
    // A click elsewhere abandons a recording.
    [self endRecording];
    [self refreshControls];
}

@end
