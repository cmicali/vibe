//
//  SettingsAppearanceViewController.m
//  Vibe
//

#import "SettingsAppearanceViewController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "Formatters.h"
#import "MainPlayerController+Settings.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"

static const CGFloat kAppearancePanePopUpWidth = 280;
// Within this many dB of 0 the gain slider snaps to 0.
static const double kWaveformGainDetentDB = 0.75;

// Stable identifiers for the Time display popup, so the debug channel can
// pick an item by name.
static NSString *const kTimeDisplayTotal = @"total";
static NSString *const kTimeDisplayRemaining = @"remaining";

@implementation SettingsAppearanceViewController {
    NSPopUpButton *_appearancePopUp, *_dockIconPopUp, *_keyNotationPopUp, *_timeDisplayPopUp;
    SettingsRowView *_appearanceRow, *_waveformNormalizeRow;
    VibeSwitch *_trafficLightsSwitch, *_volumeSliderSwitch, *_waveformNormalizeSwitch;
    NSSlider *_waveformGainSlider; // a VibeDetentSlider
    NSTextField *_waveformGainValue;
    VibeSwitch *_timeLabelsSwitch, *_statusIconsSwitch, *_fileInfoSwitch, *_showBPMSwitch,
               *_showKeySwitch, *_keyColorsSwitch;
    // Their captions say why they are off: the switch above them governs them.
    SettingsRowView *_showBPMRow, *_showKeyRow, *_keyNotationRow, *_keyColorsRow;
    VibeSwitch *_numberColumnSwitch, *_artworkColumnSwitch, *_durationColumnSwitch;
}

- (void)loadView {
    _appearancePopUp = [self popUpButtonWithWidth:kAppearancePanePopUpWidth action:@selector(appearanceChanged:)];
    [self addItem:STR_MENU_APPEARANCE_SYSTEM value:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DEFAULT to:_appearancePopUp];
    [self addItem:STR_MENU_APPEARANCE_LIGHT value:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_LIGHT to:_appearancePopUp];
    [self addItem:STR_MENU_APPEARANCE_DARK value:SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK to:_appearancePopUp];
    _appearanceRow = [SettingsRowView rowWithTitle:STR_SETTINGS_APPEARANCE_LABEL control:_appearancePopUp];
    _trafficLightsSwitch = [self switchWithAction:@selector(toggleTrafficLights:)];
    _volumeSliderSwitch = [self switchWithAction:@selector(toggleVolumeSlider:)];
    _dockIconPopUp = [self popUpButtonWithWidth:kAppearancePanePopUpWidth action:@selector(dockIconChanged:)];
    [self addItem:STR_SETTINGS_DOCK_ICON_ALBUM_ART value:SETTINGS_VALUE_DOCK_ICON_ALBUM_ART to:_dockIconPopUp];
    [self addItem:STR_SETTINGS_THEME_APP_ICON value:SETTINGS_VALUE_DOCK_ICON_APP_ICON to:_dockIconPopUp];

    _waveformNormalizeSwitch = [self switchWithAction:@selector(toggleWaveformNormalize:)];
    _waveformNormalizeRow = [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_NORMALIZE
            caption:STR_SETTINGS_WAVEFORM_LEVELS_CAPTION control:_waveformNormalizeSwitch];
    NSStackView *gainCluster = [self detentSliderClusterWithDetent:0
            min:-kVibeWaveformGainMaxDB max:kVibeWaveformGainMaxDB action:@selector(waveformGainChanged:)
            width:kAppearancePanePopUpWidth slider:&_waveformGainSlider valueLabel:&_waveformGainValue];

    _timeLabelsSwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _timeDisplayPopUp = [self popUpButtonWithWidth:kAppearancePanePopUpWidth action:@selector(trackInfoChanged:)];
    [self addItem:STR_SETTINGS_TIME_TOTAL value:kTimeDisplayTotal to:_timeDisplayPopUp];
    [self addItem:STR_SETTINGS_TIME_REMAINING value:kTimeDisplayRemaining to:_timeDisplayPopUp];
    _statusIconsSwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _fileInfoSwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _showBPMSwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _showKeySwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _keyNotationPopUp = [self popUpButtonWithWidth:kAppearancePanePopUpWidth action:@selector(trackInfoChanged:)];
    [self addItem:STR_SETTINGS_KEY_NOTATION_CAMELOT value:SETTINGS_VALUE_KEY_NOTATION_CAMELOT to:_keyNotationPopUp];
    [self addItem:STR_SETTINGS_KEY_NOTATION_MUSICAL value:SETTINGS_VALUE_KEY_NOTATION_MUSICAL to:_keyNotationPopUp];
    _keyColorsSwitch = [self switchWithAction:@selector(trackInfoChanged:)];
    _showBPMRow = [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_BPM control:_showBPMSwitch];
    _showKeyRow = [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_KEY control:_showKeySwitch];
    _keyNotationRow = [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_NOTATION_LABEL control:_keyNotationPopUp];
    _keyColorsRow = [SettingsRowView rowWithTitle:STR_SETTINGS_KEY_COLORS control:_keyColorsSwitch];
    _numberColumnSwitch = [self switchWithAction:@selector(playlistColumnsChanged:)];
    _artworkColumnSwitch = [self switchWithAction:@selector(playlistColumnsChanged:)];
    _durationColumnSwitch = [self switchWithAction:@selector(playlistColumnsChanged:)];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WINDOW_SECTION rows:@[
            _appearanceRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_TRAFFIC_LIGHTS
                                  caption:STR_SETTINGS_SHOW_TRAFFIC_LIGHTS_CAPTION control:_trafficLightsSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_VOLUME_SLIDER control:_volumeSliderSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_DOCK_ICON control:_dockIconPopUp],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_WAVEFORM_SECTION rows:@[
            _waveformNormalizeRow,
            [SettingsRowView rowWithTitle:STR_SETTINGS_WAVEFORM_GAIN control:gainCluster],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_INFO_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_TIME_LABELS control:_timeLabelsSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_TIME_LABEL control:_timeDisplayPopUp],
            [SettingsRowView rowWithTitle:STR_SETTINGS_SHOW_STATUS_ICONS control:_statusIconsSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_FILE_INFO control:_fileInfoSwitch],
            _showBPMRow,
            _showKeyRow,
            _keyNotationRow,
            _keyColorsRow,
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_PLAYLIST_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_PLAYLIST_NUMBER_COLUMN control:_numberColumnSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_PLAYLIST_ARTWORK_COLUMN control:_artworkColumnSwitch],
            [SettingsRowView rowWithTitle:STR_SETTINGS_PLAYLIST_DURATION_COLUMN control:_durationColumnSwitch],
        ]],
    ]];
}

- (void)refreshFromSettings {
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;
    // A single-palette theme pins the window dark; the popup shows Dark so
    // it agrees with the window, and the reason names the theme, since the
    // theme is chosen on another pane.
    BOOL single = theme.requiredWindowAppearance != nil;
    [self selectValue:single ? SETTINGS_VALUE_WINDOW_APPEARANCE_SYSTEM_DARK : settings.windowAppearanceStyle
                   in:_appearancePopUp];
    [SettingsRowView setControl:_appearancePopUp enabled:!single];
    [_appearanceRow setCaption:single ? [NSString stringWithFormat:STR_SETTINGS_APPEARANCE_SINGLE_THEME_CAPTION,
            [settings displayNameForThemeIdentifier:settings.activeThemeIdentifier]] : nil];
    _trafficLightsSwitch.state = StateForBOOL(settings.showTrafficLights);
    _volumeSliderSwitch.state = StateForBOOL(settings.volumeControl);
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
    [self selectValue:settings.showRemainingTime ? kTimeDisplayRemaining : kTimeDisplayTotal in:_timeDisplayPopUp];
    _statusIconsSwitch.state = StateForBOOL(settings.showStatusIcons);
    _fileInfoSwitch.state = StateForBOOL(settings.showFileInfo);
    _showBPMSwitch.state = StateForBOOL(settings.showBPM);
    _showKeySwitch.state = StateForBOOL(settings.showKey);
    [self selectValue:settings.keyNotation in:_keyNotationPopUp];
    _keyColorsSwitch.state = StateForBOOL(settings.keyColorsEnabled);
    // The refresh caller checks layout changes after these captions settle.
    [self refreshTrackInfoEnabling];
    _numberColumnSwitch.state = StateForBOOL(settings.showPlaylistNumberColumn);
    _artworkColumnSwitch.state = StateForBOOL(settings.showPlaylistArtworkColumn);
    _durationColumnSwitch.state = StateForBOOL(settings.showPlaylistDurationColumn);
}

// The store drops any titlebar preview on this write.
- (void)appearanceChanged:(id)sender {
    AppSettings.sharedInstance.windowAppearanceStyle = _appearancePopUp.selectedItem.representedObject;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectWindowAppearance];
}

- (void)toggleTrafficLights:(id)sender {
    AppSettings.sharedInstance.showTrafficLights = (_trafficLightsSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectTrafficLights];
}

// Volume pushes effectiveVolume: the slider's position while on, 1 otherwise.
- (void)toggleVolumeSlider:(id)sender {
    AppSettings.sharedInstance.volumeControl = (_volumeSliderSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectVolume];
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
    // Every sender answers state (a VibeSwitch, a popup).
    BOOL on = [(id)sender state] == NSControlStateValueOn;
    if (sender == _timeLabelsSwitch) {
        settings.showTimeLabels = on;
    } else if (sender == _timeDisplayPopUp) {
        settings.showRemainingTime = [_timeDisplayPopUp.selectedItem.representedObject isEqual:kTimeDisplayRemaining];
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
    if ([self refreshTrackInfoEnabling]) {
        [self paneContentDidChange]; // a reason appeared or went, moving rows
    }
}

// The file-info switch hides the whole BPM/key line; Show key, its half. A
// row it disables says so, as the Audio Output pane's do. Answers whether a
// caption's height moved.
- (BOOL)refreshTrackInfoEnabling {
    AppSettings *settings = AppSettings.sharedInstance;
    BOOL fileInfo = settings.showFileInfo;
    BOOL key = fileInfo && settings.showKey;
    [SettingsRowView setControl:_timeDisplayPopUp enabled:settings.showTimeLabels];
    [SettingsRowView setControl:_showBPMSwitch enabled:fileInfo];
    [SettingsRowView setControl:_showKeySwitch enabled:fileInfo];
    [SettingsRowView setControl:_keyNotationPopUp enabled:key];
    [SettingsRowView setControl:_keyColorsSwitch enabled:key];
    NSString *fileInfoReason = fileInfo ? nil : STR_SETTINGS_REQUIRES_FILE_INFO;
    NSString *keyReason = key ? nil : fileInfo ? STR_SETTINGS_REQUIRES_SHOW_KEY : STR_SETTINGS_REQUIRES_FILE_INFO;
    BOOL changed = [_showBPMRow setCaption:fileInfoReason];
    changed |= [_showKeyRow setCaption:fileInfoReason];
    changed |= [_keyNotationRow setCaption:keyReason];
    changed |= [_keyColorsRow setCaption:keyReason];
    return changed;
}

- (void)playlistColumnsChanged:(id)sender {
    AppSettings *settings = AppSettings.sharedInstance;
    settings.showPlaylistNumberColumn = (_numberColumnSwitch.state == NSControlStateValueOn);
    settings.showPlaylistArtworkColumn = (_artworkColumnSwitch.state == NSControlStateValueOn);
    settings.showPlaylistDurationColumn = (_durationColumnSwitch.state == NSControlStateValueOn);
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectPlaylistAppearance];
}

@end
