//
//  SettingsGeneralViewController.m
//  Vibe
//

#import "SettingsGeneralViewController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioDeviceManager.h"
#import "AudioPlayer.h"
#import "CoreAudioUtil.h"
#import "DefaultAppRegistration.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Transport.h"
#import "OutputDevicesMenuController.h"
#import "OutputFormatRules.h"
#import "VibeStrings.h"

static const CGFloat kGeneralPopUpWidth = 280;

@interface SettingsGeneralViewController () <AudioDeviceManagerObserver, NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SettingsGeneralViewController {
    BOOL _audioPane;
    NSTableView *_outputTable;
    NSArray<AudioDevice *> *_outputDevices;
    BOOL _refreshingOutputList;
    // Enabled only for a device bit-perfect output can drive; the row's
    // caption says why otherwise, and names the format while it is active.
    NSSwitch *_bitPerfectSwitch;
    SettingsRowView *_bitPerfectRow;
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    NSSwitch *_exclusiveOutputSwitch;
    SettingsRowView *_exclusiveOutputRow;
#endif
    NSButton *_defaultPlayerButton;
    NSSwitch *_alwaysOnTopSwitch;
    NSSwitch *_reopenPlaylistSwitch;
    NSPopUpButton *_waveformDragPopUp;
    NSPopUpButton *_artworkDragPopUp;
    // The last answer from the async default-app check, shown immediately on
    // refresh while the fresh one is fetched; the generation drops a stale
    // reply that lands after a newer refresh.
    BOOL _lastKnownIsDefaultPlayer;
    NSUInteger _defaultPlayerCheckGeneration;
}

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController {
    return [self initWithPlayerController:playerController audioPane:NO];
}

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController audioPane:(BOOL)audioPane {
    self = [super initWithPlayerController:playerController];
    if (self) {
        _audioPane = audioPane;
        if (audioPane) {
            [AudioDeviceManager.sharedInstance addObserver:self];
        }
    }
    return self;
}

- (void)loadView {
    if (_audioPane) {
        [self loadAudioPane];
        return;
    }
    // The pane is measured once, here, while the async default-app check is
    // still out and the real title has not arrived. Floor the button at the
    // wider of the two titles it can carry, or the pane's width freezes
    // against an empty one and a locale whose title outgrows the design width
    // gets a clipped button — this pane's widest control.
    _defaultPlayerButton = [NSButton buttonWithTitle:[self defaultPlayerTitle:NO]
                                              target:self action:@selector(makeDefaultPlayer:)];
    CGFloat widestTitle = _defaultPlayerButton.fittingSize.width;
    _defaultPlayerButton.title = [self defaultPlayerTitle:YES];
    widestTitle = MAX(widestTitle, _defaultPlayerButton.fittingSize.width);
    [_defaultPlayerButton.widthAnchor constraintGreaterThanOrEqualToConstant:widestTitle].active = YES;

    _alwaysOnTopSwitch = [self switchWithAction:@selector(toggleAlwaysOnTop:)];
    _reopenPlaylistSwitch = [self switchWithAction:@selector(toggleReopenPlaylist:)];

    // Identifiers in representedObject, localized names in the titles — a
    // display name must never reach NSUserDefaults. No live effect for
    // either popup: the waveform view reads its setting per mouse-down, the
    // art view reads its own per drag start.
    _waveformDragPopUp = [self popUpButtonWithWidth:kGeneralPopUpWidth action:@selector(waveformDragChanged:)];
    [self addItem:STR_SETTINGS_WAVEFORM_DRAG_WINDOW value:SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW to:_waveformDragPopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_DRAG_SEEK value:SETTINGS_VALUE_WAVEFORM_DRAG_SEEK to:_waveformDragPopUp];

    _artworkDragPopUp = [self popUpButtonWithWidth:kGeneralPopUpWidth action:@selector(artworkDragChanged:)];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_FILE value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE to:_artworkDragPopUp];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_PATH value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_PATH to:_artworkDragPopUp];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_NAME value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_ARTIST_TITLE to:_artworkDragPopUp];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_STARTUP_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_REOPEN_PLAYLIST
                                  caption:STR_SETTINGS_REOPEN_PLAYLIST_CAPTION
                                  control:_reopenPlaylistSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_ALWAYS_ON_TOP control:_alwaysOnTopSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_DRAG_LABEL control:_waveformDragPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_ARTWORK_DRAG_LABEL control:_artworkDragPopUp],
        ]],
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_DEFAULT_PLAYER_LABEL control:_defaultPlayerButton],
        ]],
    ]];
}

- (void)loadAudioPane {
    // TRAP: tiling the table below runs before the first refreshOutputDevice,
    // and AppKit, denied an empty selection, selects row 0 on its own. Read as
    // a request that switched the output to System Output, and persisted it,
    // every time this pane was first shown.
    _refreshingOutputList = YES;
    _outputTable = [SettingsRowView listTableWithColumnIdentifiers:@[@"icon", @"name", @"type"] delegate:self];
    _outputTable.allowsEmptySelection = NO;
    _outputTable.accessibilityLabel = STR_SETTINGS_OUTPUT_LABEL;
    NSTableColumn *name = _outputTable.tableColumns[1];
    name.title = STR_SETTINGS_DEVICE_NAME;
    name.width = 300;
    name.minWidth = 160;
    NSTableColumn *type = _outputTable.tableColumns[2];
    type.title = STR_SETTINGS_DEVICE_TYPE;
    type.width = 140;
    type.minWidth = 100;

    _bitPerfectSwitch = [self switchWithAction:@selector(toggleBitPerfect:)];
    _bitPerfectRow = [SettingsRowView rowWithTitle:STR_SETTINGS_BIT_PERFECT
                                           caption:STR_SETTINGS_BIT_PERFECT_CAPTION_OFF
                                           control:_bitPerfectSwitch];
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    _exclusiveOutputSwitch = [self switchWithAction:@selector(toggleExclusiveOutput:)];
    _exclusiveOutputRow = [SettingsRowView rowWithTitle:STR_SETTINGS_EXCLUSIVE_OUTPUT
                                               caption:STR_SETTINGS_EXCLUSIVE_OUTPUT_CAPTION
                                               control:_exclusiveOutputSwitch];
#endif

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_OUTPUT_LABEL rows:@[
            [SettingsRowView rowWithTableView:_outputTable rowCount:7],
        ]],
        [SettingsSectionView sectionWithRows:@[
            _bitPerfectRow,
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
            _exclusiveOutputRow,
#endif
        ]],
    ]];
    _refreshingOutputList = NO;
}

- (void)refreshFromSettings {
    if (_audioPane) {
        [self refreshOutputDevice];
        return;
    }
    [self refreshDefaultPlayerButton];
    _alwaysOnTopSwitch.state = AppSettings.sharedInstance.alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    _reopenPlaylistSwitch.state = AppSettings.sharedInstance.reopenLastPlaylist ? NSControlStateValueOn : NSControlStateValueOff;
    // The getters are normalized, so a match always exists.
    [self selectValue:AppSettings.sharedInstance.waveformDragBehavior in:_waveformDragPopUp];
    [self selectValue:AppSettings.sharedInstance.artworkDragAction in:_artworkDragPopUp];
}

// The switch follows the selected output device: enabled only while the
// chosen device is one the mode can drive (OutputFormatRules.h), with the
// caption saying why otherwise. On, the caption is the player's own report —
// the same sentence the header's open lock shows on hover — and the report
// settles asynchronously, so the toggle's own call shows the previous one
// until the player controller's report-change call corrects it.
- (void)refreshBitPerfectRows {
    if (!_outputTable) {
        return;
    }
    AudioPlayer *audioPlayer = self.playerController.audioPlayer;
    NSInteger requestedId = audioPlayer ? audioPlayer.currentlyRequestedAudioDeviceId : -1;
    AudioDevice *device = [AudioDeviceManager.sharedInstance outputDeviceForId:requestedId];
    BOOL eligible = device.uid.length > 0 && VibeBitPerfectDeviceEligible(device.transportType);
    BOOL on = AppSettings.sharedInstance.bitPerfectOutput;
    BOOL pending = self.playerController.devicesMenuController.outputDeviceSelectionPending;
    // TRAP: until the bind settles, mode writes still name the old saved UID.
    [SettingsRowView setControl:_bitPerfectSwitch enabled:!pending && (on || eligible)];
    _bitPerfectSwitch.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    // The two ways the mode has no device to drive need different remedies, so
    // they get different captions: -1 is the System Output policy, which names
    // no device at all (its own device may well be wired), while a concrete id
    // that is not eligible is a transport the mode cannot drive.
    NSString *ineligibleCaption = requestedId < 0 ? STR_SETTINGS_BIT_PERFECT_SYSTEM_OUTPUT
            : STR_SETTINGS_BIT_PERFECT_NEEDS_DEVICE;
    NSString *caption;
    if (!eligible) {
        caption = ineligibleCaption;
    }
    else if (on) {
        caption = [self.playerController bitPerfectStatusText];
    }
    else {
        caption = STR_SETTINGS_BIT_PERFECT_CAPTION_OFF;
    }
    BOOL captionChanged = [_bitPerfectRow setCaption:caption];
#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
    BOOL exclusiveSupported = eligible
            && [CoreAudioUtil supportsHogModeForDeviceID:(AudioDeviceID)device.deviceId];
    [SettingsRowView setControl:_exclusiveOutputSwitch enabled:!pending && on && exclusiveSupported];
    _exclusiveOutputSwitch.state = AppSettings.sharedInstance.exclusiveOutput
            ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *exclusiveCaption = !on ? STR_SETTINGS_EXCLUSIVE_OUTPUT_NEEDS_BIT_PERFECT
            : !eligible ? ineligibleCaption
            : !exclusiveSupported ? STR_SETTINGS_EXCLUSIVE_OUTPUT_UNSUPPORTED
            : STR_SETTINGS_EXCLUSIVE_OUTPUT_CAPTION;
    captionChanged |= [_exclusiveOutputRow setCaption:exclusiveCaption];
#endif
    if (captionChanged) {
        [self paneContentDidChange];
    }
}

- (void)toggleBitPerfect:(id)sender {
    AppSettings.sharedInstance.bitPerfectOutput = (_bitPerfectSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfectApply];
    [self refreshOutputDevice];
}

#if VIBE_ENABLE_EXCLUSIVE_OUTPUT
- (void)toggleExclusiveOutput:(id)sender {
    AppSettings.sharedInstance.exclusiveOutput = (_exclusiveOutputSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfect];
    [self refreshBitPerfectRows];
}
#endif

- (void)toggleAlwaysOnTop:(id)sender {
    AppSettings.sharedInstance.alwaysOnTop = (_alwaysOnTopSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectAlwaysOnTop];
}

- (void)toggleReopenPlaylist:(id)sender {
    AppSettings.sharedInstance.reopenLastPlaylist = (_reopenPlaylistSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectReopenLastPlaylist];
}

- (void)waveformDragChanged:(id)sender {
    AppSettings.sharedInstance.waveformDragBehavior = _waveformDragPopUp.selectedItem.representedObject;
}

- (void)artworkDragChanged:(id)sender {
    AppSettings.sharedInstance.artworkDragAction = _artworkDragPopUp.selectedItem.representedObject;
}

#pragma mark - Output device

- (void)refreshOutputDevice {
    if (!_outputTable) {
        return;
    }
    _outputDevices = AudioDeviceManager.sharedInstance.outputDevices;
    NSInteger requestedId = self.playerController.audioPlayer.currentlyRequestedAudioDeviceId;
    NSInteger selectedRow = 0;
    for (NSUInteger i = 0; i < _outputDevices.count; i++) {
        if (_outputDevices[i].deviceId == requestedId) {
            selectedRow = (NSInteger)i + 1;
            break;
        }
    }
    BOOL selectionChanged = _outputTable.selectedRow != selectedRow;
    // Reload and reselect post selection notifications; neither is a device request.
    _refreshingOutputList = YES;
    [_outputTable reloadData];
    [_outputTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)selectedRow]
             byExtendingSelection:NO];
    _refreshingOutputList = NO;
    if (selectionChanged) {
        [_outputTable scrollRowToVisible:selectedRow];
    }
    [self refreshBitPerfectRows];
}

- (AudioDevice *)outputDeviceAtRow:(NSInteger)row {
    if (row == 0) {
        for (AudioDevice *device in _outputDevices) {
            if (device.isSystemDefault) {
                return device;
            }
        }
    }
    return row >= 1 && row < (NSInteger)_outputDevices.count + 1 ? _outputDevices[(NSUInteger)row - 1] : nil;
}

- (NSString *)typeNameForDevice:(AudioDevice *)device symbolName:(NSString **)symbolName {
    switch (device.transportType) {
        case kAudioDeviceTransportTypeBuiltIn: *symbolName = @"speaker.wave.2"; return STR_SETTINGS_DEVICE_BUILT_IN;
        case kAudioDeviceTransportTypeAggregate: *symbolName = @"square.stack.3d.up"; return STR_SETTINGS_DEVICE_AGGREGATE;
        case kAudioDeviceTransportTypeVirtual: *symbolName = @"point.3.connected.trianglepath.dotted"; return STR_SETTINGS_DEVICE_VIRTUAL;
        case kAudioDeviceTransportTypePCI: *symbolName = @"cpu"; return VibeNotLocalized(@"PCI");
        case kAudioDeviceTransportTypeUSB: *symbolName = @"cable.connector"; return VibeNotLocalized(@"USB");
        case kAudioDeviceTransportTypeFireWire: *symbolName = @"cable.connector"; return VibeNotLocalized(@"FireWire");
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE: *symbolName = @"headphones"; return VibeNotLocalized(@"Bluetooth");
        case kAudioDeviceTransportTypeHDMI: *symbolName = @"display"; return VibeNotLocalized(@"HDMI");
        case kAudioDeviceTransportTypeDisplayPort: *symbolName = @"display"; return VibeNotLocalized(@"DisplayPort");
        case kAudioDeviceTransportTypeAirPlay: *symbolName = @"airplayaudio"; return VibeNotLocalized(@"AirPlay");
        case kAudioDeviceTransportTypeAVB: *symbolName = @"network"; return VibeNotLocalized(@"AVB");
        case kAudioDeviceTransportTypeThunderbolt: *symbolName = @"bolt"; return VibeNotLocalized(@"Thunderbolt");
        default: *symbolName = @"hifispeaker"; return STR_SETTINGS_DEVICE_OTHER;
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_outputDevices.count + 1;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    BOOL iconColumn = [tableColumn.identifier isEqualToString:@"icon"];
    NSTableCellView *cell = [SettingsRowView listCellWithIdentifier:tableColumn.identifier
                                                        inTableView:tableView
                                                      imagePosition:iconColumn ? NSImageOnly : NSNoImage];
    AudioDevice *device = [self outputDeviceAtRow:row];
    NSString *symbolName;
    NSString *typeName = [self typeNameForDevice:device symbolName:&symbolName];
    if (iconColumn) {
        cell.imageView.image = [NSImage imageWithSystemSymbolName:row == 0 ? @"desktopcomputer" : symbolName
                                       accessibilityDescription:row == 0 ? STR_MENU_OUTPUT_SYSTEM : typeName];
        cell.toolTip = row == 0 ? STR_MENU_OUTPUT_SYSTEM : typeName;
    }
    else {
        cell.textField.stringValue = [tableColumn.identifier isEqualToString:@"type"]
                ? typeName : row > 0 ? device.name : device
                        ? [NSString stringWithFormat:STR_MENU_OUTPUT_SYSTEM_NAMED, device.name] : STR_MENU_OUTPUT_SYSTEM;
        cell.toolTip = cell.textField.stringValue;
    }
    return cell;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [SettingsRowView listRowViewForRow:row];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_refreshingOutputList) {
        return;
    }
    NSInteger row = _outputTable.selectedRow;
    if (row < 0) {
        [self refreshOutputDevice]; // the list has no empty selection
        return;
    }
    NSInteger deviceId = row == 0 ? -1 : [self outputDeviceAtRow:row].deviceId;
    if (deviceId != self.playerController.audioPlayer.currentlyRequestedAudioDeviceId) {
        [self.playerController.devicesMenuController selectOutputDevice:deviceId];
    }
}

- (void)audioOutputDevicesDidChange {
    [self refreshOutputDevice];
}

- (void)systemDefaultOutputDeviceDidChange {
    [self refreshOutputDevice];
}

#pragma mark - Default music player

- (void)makeDefaultPlayer:(id)sender {
    // The system runs its own confirmation panel and reports the outcome
    // itself; the button retitles on the base class's key-window refresh.
    [DefaultAppRegistration makeDefaultApp];
}

// The check walks Launch Services off the main thread, so show the last-known
// state now and correct it when the fresh answer lands.
- (void)refreshDefaultPlayerButton {
    [self renderDefaultPlayerState:_lastKnownIsDefaultPlayer];
    NSUInteger generation = ++_defaultPlayerCheckGeneration;
    __weak __typeof(self) weakSelf = self;
    [DefaultAppRegistration checkIsDefaultAppForAllFileTypes:^(BOOL isDefault) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_defaultPlayerCheckGeneration) {
            return;
        }
        strongSelf->_lastKnownIsDefaultPlayer = isDefault;
        [strongSelf renderDefaultPlayerState:isDefault];
    }];
}

// Nothing to do once Vibe already holds every type, so the title says so and
// the button disables rather than offering a no-op.
- (NSString *)defaultPlayerTitle:(BOOL)isDefault {
    return [NSString stringWithFormat:
            isDefault ? STR_SETTINGS_DEFAULT_PLAYER_IS : STR_SETTINGS_DEFAULT_PLAYER_SET, VibeAppName()];
}

- (void)renderDefaultPlayerState:(BOOL)isDefault {
    _defaultPlayerButton.title = [self defaultPlayerTitle:isDefault];
    [SettingsRowView setControl:_defaultPlayerButton enabled:!isDefault];
}

@end
