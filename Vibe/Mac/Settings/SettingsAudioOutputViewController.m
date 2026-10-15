//
//  SettingsAudioOutputViewController.m
//  Vibe
//

#import "SettingsAudioOutputViewController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioDeviceManager.h"
#import "AudioPlayer.h"
#import "CoreAudioUtil.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Transport.h"
#import "OutputDevicesMenuController.h"
#import "OutputFormatRules.h"
#import "VibeStrings.h"

@interface SettingsAudioOutputViewController () <AudioDeviceManagerObserver, NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SettingsAudioOutputViewController {
    NSTableView *_outputTable;
    NSArray<AudioDevice *> *_outputDevices;
    BOOL _refreshingOutputList;
    VibeSwitch *_bitPerfectSwitch;
    SettingsRowView *_bitPerfectRow;
    VibeSwitch *_exclusiveOutputSwitch;
    SettingsRowView *_exclusiveOutputRow;
    VibeSwitch *_declickSwitch;
    SettingsRowView *_declickRow;
    SettingsSectionView *_deviceSection;
}

- (void)loadView {
    // TRAP: tiling the table runs before the first refreshOutputDevice, and
    // AppKit, denied an empty selection, selects row 0 itself; read as a
    // request, that would switch the output to System Output and persist it.
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
    _exclusiveOutputSwitch = [self switchWithAction:@selector(toggleExclusiveOutput:)];
    _exclusiveOutputRow = [SettingsRowView rowWithTitle:STR_SETTINGS_EXCLUSIVE_OUTPUT
                                               caption:STR_SETTINGS_EXCLUSIVE_OUTPUT_CAPTION
                                               control:_exclusiveOutputSwitch];
    _declickSwitch = [self switchWithAction:@selector(toggleDeclick:)];
    _declickRow = [SettingsRowView rowWithTitle:STR_SETTINGS_DECLICK
                                        caption:STR_SETTINGS_DECLICK_CAPTION
                                        control:_declickSwitch];

    _deviceSection = [SettingsSectionView sectionWithHeader:STR_SETTINGS_DEVICE_SECTION rows:@[
        _bitPerfectRow,
        _exclusiveOutputRow,
    ]];
    // Declick is one choice for every device, so it sits in the Output card
    // under the list, ahead of the card that belongs to the selected device.
    SettingsRowView *listRow = [SettingsRowView rowWithTableView:_outputTable rowCount:7];
    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_OUTPUT_LABEL rows:@[
            listRow,
            _declickRow,
        ]],
        _deviceSection,
    ]];
    // The list is its own divider; the section's hairline would double it.
    _declickRow.showsTopSeparator = NO;
    _refreshingOutputList = NO;
}

- (void)refreshFromSettings {
    [self refreshOutputDevice];
}

// On, the caption is the player's report, which settles asynchronously: the
// toggle's own call shows the previous one until the report-change call.
- (void)refreshBitPerfectRows {
    if (!_outputTable) {
        return;
    }
    AudioPlayer *audioPlayer = self.playerController.audioPlayer;
    NSInteger requestedId = audioPlayer ? audioPlayer.currentlyRequestedAudioDeviceId : -1;
    AudioDevice *device = [AudioDeviceManager.sharedInstance outputDeviceForId:requestedId];
    BOOL eligible = device.uid.length > 0 && VibeBitPerfectDeviceEligible(device.transportType, AppSettings.sharedInstance.allowBitPerfectOnAnyDevice);
    BOOL on = AppSettings.sharedInstance.bitPerfectOutput;
    BOOL pending = self.playerController.devicesMenuController.outputDeviceSelectionPending;
    // TRAP: until the bind settles, mode writes still name the old saved UID,
    // so both mode switches stay disabled while a selection is pending.
    [SettingsRowView setControl:_bitPerfectSwitch enabled:!pending && (on || eligible)];
    _bitPerfectSwitch.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    // Two captions for two remedies: -1 is the System Output policy, which
    // names no device (its own may well be wired); a concrete ineligible id is
    // a transport the mode cannot drive.
    NSString *ineligibleCaption = requestedId < 0 ? STR_SETTINGS_BIT_PERFECT_SYSTEM_OUTPUT
            : STR_SETTINGS_BIT_PERFECT_NEEDS_DEVICE;
    // What the switch does stays on the first line whatever the state; the
    // second says why it cannot be used, or, on, how the output settled.
    NSString *status = !eligible ? ineligibleCaption : on ? [self.playerController bitPerfectStatusText] : nil;
    BOOL captionChanged = [_bitPerfectRow setCaption:STR_SETTINGS_BIT_PERFECT_CAPTION_OFF detail:status];
    BOOL exclusiveSupported = eligible
            && [CoreAudioUtil supportsHogModeForDeviceID:(AudioDeviceID)device.deviceId];
    [SettingsRowView setControl:_exclusiveOutputSwitch enabled:!pending && on && exclusiveSupported];
    _exclusiveOutputSwitch.state = AppSettings.sharedInstance.exclusiveOutput
            ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *exclusiveReason = !on ? STR_SETTINGS_EXCLUSIVE_OUTPUT_NEEDS_BIT_PERFECT
            : !eligible ? ineligibleCaption
            : !exclusiveSupported ? STR_SETTINGS_EXCLUSIVE_OUTPUT_UNSUPPORTED : nil;
    captionChanged |= [_exclusiveOutputRow setCaption:STR_SETTINGS_EXCLUSIVE_OUTPUT_CAPTION
                                             detail:exclusiveReason];
    NSString *deviceName = requestedId < 0 ? STR_MENU_OUTPUT_SYSTEM : device.name;
    [_deviceSection setHeader:deviceName.length
            ? [NSString stringWithFormat:STR_SETTINGS_DEVICE_SECTION_NAMED, deviceName]
            : STR_SETTINGS_DEVICE_SECTION];
    _declickSwitch.state = AppSettings.sharedInstance.declick ? NSControlStateValueOn : NSControlStateValueOff;
    if (captionChanged) {
        [self paneContentDidChange];
    }
}

- (void)toggleBitPerfect:(id)sender {
    AppSettings.sharedInstance.bitPerfectOutput = (_bitPerfectSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfectApply];
    [self refreshOutputDevice];
}

- (void)toggleExclusiveOutput:(id)sender {
    AppSettings.sharedInstance.exclusiveOutput = (_exclusiveOutputSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectBitPerfect];
    [self refreshBitPerfectRows];
}

- (void)toggleDeclick:(id)sender {
    AppSettings.sharedInstance.declick = (_declickSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectDeclick];
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

// Observed only while on screen: the pane outlives the window, and
// viewWillAppear's refresh covers what changed while hidden.
- (void)viewDidAppear {
    [super viewDidAppear];
    [AudioDeviceManager.sharedInstance addObserver:self];
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    [AudioDeviceManager.sharedInstance removeObserver:self];
}

- (void)audioOutputDevicesDidChange {
    [self refreshOutputDevice];
}

- (void)systemDefaultOutputDeviceDidChange {
    [self refreshOutputDevice];
}

@end
