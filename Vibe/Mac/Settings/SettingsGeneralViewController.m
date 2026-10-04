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
#import "SettingsWindowController.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"
#import "Formatters.h"

static const CGFloat kGeneralPopUpWidth = 280;
// Within this many dB of 0 the gain slider snaps to 0.
static const double kWaveformGainDetentDB = 0.75;

@interface SettingsGeneralViewController () <AudioDeviceManagerObserver, NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SettingsGeneralViewController {
    NSString *_page;
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
    VibeSwitch *_volumeControlSwitch;
    SettingsRowView *_volumeControlRow;
    NSButton *_defaultPlayerButton;
    VibeSwitch *_alwaysOnTopSwitch;
    VibeSwitch *_lockWindowPositionSwitch;
    VibeSwitch *_reopenPlaylistSwitch;
    NSPopUpButton *_waveformDragPopUp;
    NSPopUpButton *_artworkDragPopUp;
    // Shown on refresh while the async check runs.
    BOOL _lastKnownIsDefaultPlayer;
    NSUInteger _defaultPlayerCheckGeneration;
    // Appearance: what the window shows, whatever the theme.
    NSPopUpButton *_appearancePopUp, *_dockIconPopUp, *_keyNotationPopUp;
    SettingsRowView *_appearanceRow, *_waveformNormalizeRow;
    VibeSwitch *_trafficLightsSwitch, *_waveformNormalizeSwitch;
    NSSlider *_waveformGainSlider; // a VibeDetentSlider
    NSTextField *_waveformGainValue;
    VibeSwitch *_timeLabelsSwitch, *_statusIconsSwitch, *_fileInfoSwitch, *_showBPMSwitch,
               *_showKeySwitch, *_keyColorsSwitch;
    NSButton *_timeTotalRadio, *_timeRemainingRadio;
    VibeSwitch *_numberColumnSwitch, *_artworkColumnSwitch, *_durationColumnSwitch;
}

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController {
    return [self initWithPlayerController:playerController page:@"general"];
}

- (instancetype)initWithPlayerController:(MainPlayerController *)playerController page:(NSString *)page {
    self = [super initWithPlayerController:playerController];
    if (self) {
        _page = [page copy];
    }
    return self;
}

- (void)loadView {
    if ([_page isEqualToString:@"audio"]) {
        [self loadAudioPane];
        return;
    }
    if ([_page isEqualToString:@"appearance"]) {
        [self loadAppearancePane];
        return;
    }
    // The pane is measured before the async default-app check answers, so
    // floor the button at the wider of its two titles or a long one clips.
    _defaultPlayerButton = [NSButton buttonWithTitle:[self defaultPlayerTitle:NO]
                                              target:self action:@selector(makeDefaultPlayer:)];
    CGFloat widestTitle = _defaultPlayerButton.fittingSize.width;
    _defaultPlayerButton.title = [self defaultPlayerTitle:YES];
    widestTitle = MAX(widestTitle, _defaultPlayerButton.fittingSize.width);
    [_defaultPlayerButton.widthAnchor constraintGreaterThanOrEqualToConstant:widestTitle].active = YES;

    _alwaysOnTopSwitch = [self switchWithAction:@selector(toggleAlwaysOnTop:)];
    _lockWindowPositionSwitch = [self switchWithAction:@selector(toggleLockWindowPosition:)];
    _reopenPlaylistSwitch = [self switchWithAction:@selector(toggleReopenPlaylist:)];

    // No live effect: each view reads its setting per gesture.
    _waveformDragPopUp = [self popUpButtonWithWidth:kGeneralPopUpWidth action:@selector(waveformDragChanged:)];
    [self addItem:STR_SETTINGS_WAVEFORM_DRAG_WINDOW value:SETTINGS_VALUE_WAVEFORM_DRAG_WINDOW to:_waveformDragPopUp];
    [self addItem:STR_SETTINGS_WAVEFORM_DRAG_SEEK value:SETTINGS_VALUE_WAVEFORM_DRAG_SEEK to:_waveformDragPopUp];

    _artworkDragPopUp = [self popUpButtonWithWidth:kGeneralPopUpWidth action:@selector(artworkDragChanged:)];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_FILE value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_FILE to:_artworkDragPopUp];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_PATH value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_PATH to:_artworkDragPopUp];
    [self addItem:STR_SETTINGS_ARTWORK_DRAG_NAME value:SETTINGS_VALUE_ARTWORK_DRAG_COPY_ARTIST_TITLE to:_artworkDragPopUp];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_BEHAVIOR_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_REOPEN_PLAYLIST
                                  caption:STR_SETTINGS_REOPEN_PLAYLIST_CAPTION
                                  control:_reopenPlaylistSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_ALWAYS_ON_TOP
                                  caption:STR_SETTINGS_ALWAYS_ON_TOP_CAPTION control:_alwaysOnTopSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_LOCK_WINDOW_POSITION
                                  caption:STR_SETTINGS_LOCK_WINDOW_POSITION_CAPTION control:_lockWindowPositionSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_DRAG_LABEL control:_waveformDragPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_ARTWORK_DRAG_LABEL control:_artworkDragPopUp],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_SYSTEM_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_DEFAULT_PLAYER_LABEL control:_defaultPlayerButton],
        ]],
    ]];
}

- (void)loadAudioPane {
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
    _volumeControlSwitch = [self switchWithAction:@selector(toggleVolumeControl:)];
    _volumeControlRow = [SettingsRowView rowWithTitle:STR_SETTINGS_VOLUME_CONTROL
                                              caption:STR_SETTINGS_VOLUME_CONTROL_CAPTION
                                              control:_volumeControlSwitch];

    _deviceSection = [SettingsSectionView sectionWithHeader:STR_SETTINGS_DEVICE_SECTION rows:@[
        _bitPerfectRow,
        _exclusiveOutputRow,
    ]];
    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_OUTPUT_LABEL rows:@[
            [SettingsRowView rowWithTableView:_outputTable rowCount:7],
        ]],
        _deviceSection,
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_LEVEL_SECTION rows:@[
            _volumeControlRow,
            _declickRow,
        ]],
    ]];
    _refreshingOutputList = NO;
}

- (void)refreshFromSettings {
    if ([_page isEqualToString:@"audio"]) {
        [self refreshOutputDevice];
        return;
    }
    if ([_page isEqualToString:@"appearance"]) {
        [self refreshAppearancePane];
        return;
    }
    [self refreshDefaultPlayerButton];
    _alwaysOnTopSwitch.state = AppSettings.sharedInstance.alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    _lockWindowPositionSwitch.state = AppSettings.sharedInstance.windowPositionLocked ? NSControlStateValueOn : NSControlStateValueOff;
    _reopenPlaylistSwitch.state = AppSettings.sharedInstance.reopenLastPlaylist ? NSControlStateValueOn : NSControlStateValueOff;
    [self selectValue:AppSettings.sharedInstance.waveformDragBehavior in:_waveformDragPopUp];
    [self selectValue:AppSettings.sharedInstance.artworkDragAction in:_artworkDragPopUp];
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
    _volumeControlSwitch.state = AppSettings.sharedInstance.volumeControl ? NSControlStateValueOn : NSControlStateValueOff;
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

- (void)toggleVolumeControl:(id)sender {
    AppSettings.sharedInstance.volumeControl = (_volumeControlSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectVolume];
}

- (void)toggleAlwaysOnTop:(id)sender {
    AppSettings.sharedInstance.alwaysOnTop = (_alwaysOnTopSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectAlwaysOnTop];
}

- (void)toggleLockWindowPosition:(id)sender {
    AppSettings.sharedInstance.windowPositionLocked = (_lockWindowPositionSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWindowLock];
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

// Observed only while on screen: the pane outlives the window, and
// viewWillAppear's refresh covers what changed while hidden.
- (void)viewDidAppear {
    [super viewDidAppear];
    if ([_page isEqualToString:@"audio"]) {
        [AudioDeviceManager.sharedInstance addObserver:self];
    }
}

- (void)viewWillDisappear {
    [super viewWillDisappear];
    if ([_page isEqualToString:@"audio"]) {
        [AudioDeviceManager.sharedInstance removeObserver:self];
    }
}

- (void)audioOutputDevicesDidChange {
    [self refreshOutputDevice];
}

- (void)systemDefaultOutputDeviceDidChange {
    [self refreshOutputDevice];
}

#pragma mark - Appearance

- (void)loadAppearancePane {
    _appearancePopUp = [self popUpButtonWithWidth:kGeneralPopUpWidth action:@selector(appearanceChanged:)];
    [self addItem:STR_MENU_APPEARANCE_SYSTEM value:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT to:_appearancePopUp];
    [self addItem:STR_MENU_APPEARANCE_LIGHT value:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT to:_appearancePopUp];
    [self addItem:STR_MENU_APPEARANCE_DARK value:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK to:_appearancePopUp];
    _appearanceRow = [SettingsRowView rowWithTitle:STR_SETTINGS_APPEARANCE_LABEL control:_appearancePopUp];
    _trafficLightsSwitch = [self switchWithAction:@selector(toggleTrafficLights:)];
    _dockIconPopUp = [self popUpButtonWithWidth:kGeneralPopUpWidth action:@selector(dockIconChanged:)];
    [self addItem:STR_SETTINGS_DOCK_ICON_ALBUM_ART value:SETTINGS_VALUE_DOCK_ICON_ALBUM_ART to:_dockIconPopUp];
    [self addItem:STR_SETTINGS_THEME_APP_ICON value:SETTINGS_VALUE_DOCK_ICON_APP_ICON to:_dockIconPopUp];

    _waveformNormalizeSwitch = [self switchWithAction:@selector(toggleWaveformNormalize:)];
    _waveformNormalizeRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_NORMALIZE
            caption:STR_SETTINGS_WAVEFORM_LEVELS_CAPTION control:_waveformNormalizeSwitch];
    VibeDetentSlider *gain = [VibeDetentSlider sliderWithValue:0 minValue:-kVibeWaveformGainMaxDB
            maxValue:kVibeWaveformGainMaxDB target:self action:@selector(waveformGainChanged:)];
    _waveformGainSlider = gain;
    NSTextField *gainValue = nil;
    NSStackView *gainCluster = [self clusterWithSlider:gain width:kGeneralPopUpWidth valueLabel:&gainValue];
    _waveformGainValue = gainValue;

    _timeLabelsSwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _timeTotalRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_TOTAL
                                              target:self action:@selector(trackInfoChanged:)];
    _timeRemainingRadio = [NSButton radioButtonWithTitle:STR_SETTINGS_TIME_REMAINING
                                                  target:self action:@selector(trackInfoChanged:)];
    NSStackView *timeRadios = [NSStackView stackViewWithViews:@[_timeTotalRadio, _timeRemainingRadio]];
    timeRadios.spacing = 12;
    _statusIconsSwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _fileInfoSwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _showBPMSwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _showKeySwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _keyNotationPopUp = [self popUpButtonWithWidth:kGeneralPopUpWidth action:@selector(trackInfoChanged:)];
    [self addItem:STR_SETTINGS_KEY_NOTATION_CAMELOT value:SETTINGS_VALUE_KEY_NOTATION_CAMELOT to:_keyNotationPopUp];
    [self addItem:STR_SETTINGS_KEY_NOTATION_MUSICAL value:SETTINGS_VALUE_KEY_NOTATION_MUSICAL to:_keyNotationPopUp];
    _keyColorsSwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _numberColumnSwitch = [self switchWithAction:@selector(playlistColumnsChanged:)];
    _artworkColumnSwitch = [self switchWithAction:@selector(playlistColumnsChanged:)];
    _durationColumnSwitch = [self switchWithAction:@selector(playlistColumnsChanged:)];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            _appearanceRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_TRAFFIC_LIGHTS
                                  caption:STR_SETTINGS_SHOW_TRAFFIC_LIGHTS_CAPTION control:_trafficLightsSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_DOCK_ICON control:_dockIconPopUp],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WAVEFORM_SECTION rows:@[
            _waveformNormalizeRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_GAIN control:gainCluster],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_INFO_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_TIME_LABELS control:_timeLabelsSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_TIME_LABEL control:timeRadios],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_STATUS_ICONS control:_statusIconsSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_FILE_INFO control:_fileInfoSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_BPM control:_showBPMSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_KEY control:_showKeySwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_NOTATION_LABEL control:_keyNotationPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_COLORS control:_keyColorsSwitch],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYLIST_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_PLAYLIST_NUMBER_COLUMN control:_numberColumnSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_PLAYLIST_ARTWORK_COLUMN control:_artworkColumnSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_PLAYLIST_DURATION_COLUMN control:_durationColumnSwitch],
        ]],
    ]];
}

- (void)refreshAppearancePane {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;
    [self selectValue:settings.windowAppearanceStyle in:_appearancePopUp];
    // A single-palette theme pins the window dark; the reason names it, since
    // the theme is chosen on another pane.
    BOOL single = theme.requiredWindowAppearance != nil;
    [SettingsRowView setControl:_appearancePopUp enabled:!single];
    [_appearanceRow setCaption:single ? [NSString stringWithFormat:STR_SETTINGS_APPEARANCE_SINGLE_THEME_CAPTION,
            [settings displayNameForThemeIdentifier:settings.activeThemeIdentifier]] : nil];
    _trafficLightsSwitch.state = StateForBOOL(settings.showTrafficLights);
    [self selectValue:settings.dockIcon in:_dockIconPopUp];

    _waveformNormalizeSwitch.state = StateForBOOL(settings.waveformNormalize);
    _waveformGainSlider.doubleValue = settings.waveformGainDB;
    [self refreshWaveformGainValue];
    BOOL levels = [WaveformRendererRegistry supportsLevelsForIdentifier:theme.waveformStyle];
    [SettingsRowView setControl:_waveformNormalizeSwitch enabled:levels];
    [SettingsRowView setControl:_waveformGainSlider enabled:levels];
    [_waveformNormalizeRow setCaption:STR_SETTINGS_WAVEFORM_LEVELS_CAPTION
            detail:levels ? nil : [NSString stringWithFormat:STR_SETTINGS_WAVEFORM_LEVELS_UNAVAILABLE,
                    [WaveformRendererRegistry displayNameForIdentifier:theme.waveformStyle]]];

    _timeLabelsSwitch.state = StateForBOOL(settings.showTimeLabels);
    _timeTotalRadio.state = StateForBOOL(!settings.showRemainingTime);
    _timeRemainingRadio.state = StateForBOOL(settings.showRemainingTime);
    _statusIconsSwitch.state = StateForBOOL(settings.showStatusIcons);
    _fileInfoSwitch.state = StateForBOOL(settings.showFileInfo);
    _showBPMSwitch.state = StateForBOOL(settings.showBPM);
    _showKeySwitch.state = StateForBOOL(settings.showKey);
    [self selectValue:settings.keyNotation in:_keyNotationPopUp];
    _keyColorsSwitch.state = StateForBOOL(settings.keyColorsEnabled);
    [self refreshTrackInfoEnabling];
    _numberColumnSwitch.state = StateForBOOL(settings.showPlaylistNumberColumn);
    _artworkColumnSwitch.state = StateForBOOL(settings.showPlaylistArtworkColumn);
    _durationColumnSwitch.state = StateForBOOL(settings.showPlaylistDurationColumn);
}

// The store drops any titlebar preview on this write.
- (void)appearanceChanged:(id)sender {
    AppSettings.sharedInstance.windowAppearanceStyle = _appearancePopUp.selectedItem.representedObject;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWindowAppearance];
    [(SettingsWindowController *)self.view.window.windowController updateNavigation];
}

- (void)toggleTrafficLights:(id)sender {
    AppSettings.sharedInstance.showTrafficLights = (_trafficLightsSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectTrafficLights];
}

- (void)dockIconChanged:(id)sender {
    AppSettings.sharedInstance.dockIcon = _dockIconPopUp.selectedItem.representedObject;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectAppIcon];
}

- (void)toggleWaveformNormalize:(id)sender {
    AppSettings.sharedInstance.waveformNormalize = (_waveformNormalizeSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWaveformLevels];
}

- (void)waveformGainChanged:(id)sender {
    // The getter snaps to the half-dB ladder; the knob re-syncs to it.
    double gainDB = _waveformGainSlider.doubleValue;
    if (fabs(gainDB) < kWaveformGainDetentDB) {
        gainDB = 0;
    }
    AppSettings.sharedInstance.waveformGainDB = gainDB;
    _waveformGainSlider.doubleValue = AppSettings.sharedInstance.waveformGainDB;
    [self refreshWaveformGainValue];
    [self applyLiveEffectsDuringDrag:VibeSettingsLiveEffectWaveformLevels];
}

- (void)refreshWaveformGainValue {
    _waveformGainValue.stringValue = [NSString stringWithFormat:STR_SETTINGS_WAVEFORM_GAIN_VALUE,
            [Formatters.sharedInstance signedDecimalString:AppSettings.sharedInstance.waveformGainDB]];
}

// One display pass for every readout control; only the sender's setting is
// written, so a value changed elsewhere while the pane is up survives.
- (void)trackInfoChanged:(NSControl *)sender {
    AppSettings *settings = AppSettings.sharedInstance;
    // Every sender answers state (a VibeSwitch, a radio, the popup).
    BOOL on = [(id)sender state] == NSControlStateValueOn;
    if (sender == _timeLabelsSwitch) {
        settings.showTimeLabels = on;
    } else if (sender == _timeTotalRadio || sender == _timeRemainingRadio) {
        settings.showRemainingTime = (sender == _timeRemainingRadio);
    } else if (sender == _statusIconsSwitch) {
        settings.showStatusIcons = on;
    } else if (sender == _fileInfoSwitch) {
        settings.showFileInfo = on;
    } else if (sender == _showBPMSwitch) {
        settings.showBPM = on;
    } else if (sender == _showKeySwitch) {
        settings.showKey = on;
    } else if (sender == _keyNotationPopUp) {
        settings.keyNotation = _keyNotationPopUp.selectedItem.representedObject;
    } else if (sender == _keyColorsSwitch) {
        settings.keyColorsEnabled = on;
    }
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectTrackDisplay];
    [self refreshTrackInfoEnabling];
}

// The file-info switch hides the whole BPM/key line; Show key, its half.
- (void)refreshTrackInfoEnabling {
    AppSettings *settings = AppSettings.sharedInstance;
    [SettingsRowView setControl:_timeTotalRadio enabled:settings.showTimeLabels];
    [SettingsRowView setControl:_timeRemainingRadio enabled:settings.showTimeLabels];
    [SettingsRowView setControl:_showBPMSwitch enabled:settings.showFileInfo];
    [SettingsRowView setControl:_showKeySwitch enabled:settings.showFileInfo];
    [SettingsRowView setControl:_keyNotationPopUp enabled:settings.showFileInfo && settings.showKey];
    [SettingsRowView setControl:_keyColorsSwitch enabled:settings.showFileInfo && settings.showKey];
}

- (void)playlistColumnsChanged:(id)sender {
    AppSettings *settings = AppSettings.sharedInstance;
    settings.showPlaylistNumberColumn = (_numberColumnSwitch.state == NSControlStateValueOn);
    settings.showPlaylistArtworkColumn = (_artworkColumnSwitch.state == NSControlStateValueOn);
    settings.showPlaylistDurationColumn = (_durationColumnSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectPlaylistAppearance];
}

#pragma mark - Default music player

// The system's panels ask about each type. When it refused them all without
// asking, as it can a sandboxed app, the Finder is the way left.
- (void)makeDefaultPlayer:(id)sender {
    __weak __typeof(self) weakSelf = self;
    [DefaultAppRegistration makeDefaultAppWithCompletion:^(BOOL refused) {
        __typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf refreshDefaultPlayerButton];
        if (refused && strongSelf.view.window) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = [NSString stringWithFormat:STR_SETTINGS_DEFAULT_PLAYER_REFUSED_TITLE, VibeAppName()];
            alert.informativeText = [NSString stringWithFormat:STR_SETTINGS_DEFAULT_PLAYER_REFUSED_MESSAGE, VibeAppName()];
            [alert beginSheetModalForWindow:strongSelf.view.window completionHandler:nil];
        }
    }];
}

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

- (NSString *)defaultPlayerTitle:(BOOL)isDefault {
    return [NSString stringWithFormat:
            isDefault ? STR_SETTINGS_DEFAULT_PLAYER_IS : STR_SETTINGS_DEFAULT_PLAYER_SET, VibeAppName()];
}

- (void)renderDefaultPlayerState:(BOOL)isDefault {
    _defaultPlayerButton.title = [self defaultPlayerTitle:isDefault];
    [SettingsRowView setControl:_defaultPlayerButton enabled:!isDefault];
}

@end
