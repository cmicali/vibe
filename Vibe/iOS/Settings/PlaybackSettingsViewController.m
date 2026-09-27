//
//  PlaybackSettingsViewController.m
//  Vibe (iOS)
//
//  See PlaybackSettingsViewController.h.
//

#import "PlaybackSettingsViewController.h"

#import "AppSettings.h"
#import "PlaybackController.h"
#import "PlayerDisplaySettings.h"
#import "SettingsChoiceViewController.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibePlaybackSection) {
    VibePlaybackSectionTransitions = 0,
    VibePlaybackSectionSound,
    VibePlaybackSectionEffects,
    VibePlaybackSectionAnalysis,
    VibePlaybackSectionCount,
};

// The Track transitions rows; the other three sections hold one row each —
// Resampling, the effects switch and the BPM detection switch.
typedef NS_ENUM(NSInteger, VibePlaybackRow) {
    VibePlaybackRowOnTrackEnd = 0,
    VibePlaybackRowCrossfade,
    VibePlaybackRowCount,
};

// Resampling's two answers, the default first.
static const NSInteger kResamplingRowHigh    = 0;
static const NSInteger kResamplingRowMaximum = 1;

// On track end's two answers, in the order the mac's popup lists them.
// Deliberately not a cast of the BOOL: a row index is a screen position.
static const NSInteger kOnEndRowPlayNext = 0;
static const NSInteger kOnEndRowPause    = 1;

static NSString *const kValueCellIdentifier = @"value";

@implementation PlaybackSettingsViewController {
    PlaybackController *_playback;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _playback = playback;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_MENU_PLAYBACK;
}

// A picker writes its setting without telling anyone here, so the value
// column is re-read on the way back — the Appearance screen's rule.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Current values

// The crossfade presets' titles in ladder order, the mac popup's three, so an
// index into either names the same length.
- (NSArray<NSString *> *)crossfadeTitles {
    NSArray<NSString *> *titles = @[STR_SETTINGS_CROSSFADE_INSTANT,
                                    STR_SETTINGS_CROSSFADE_SHORT,
                                    STR_SETTINGS_CROSSFADE_LONG];
    NSAssert(titles.count == kVibeCrossfadePresetCount, @"Every crossfade preset needs a title");
    return titles;
}

// The getter snaps to a preset, so this always finds one.
- (NSInteger)currentCrossfadeIndex {
    NSInteger milliseconds = AppSettings.sharedInstance.crossfadeMilliseconds;
    for (size_t i = 0; i < kVibeCrossfadePresetCount; i++) {
        if (kVibeCrossfadePresets[i] == milliseconds) {
            return (NSInteger)i;
        }
    }
    return 0;
}

- (NSString *)onTrackEndValueText {
    return AppSettings.sharedInstance.pauseAtTrackEnd ? STR_SETTINGS_ON_END_PAUSE
                                                       : STR_SETTINGS_ON_END_PLAY_NEXT;
}

- (NSInteger)currentResamplingIndex {
    return AppSettings.sharedInstance.maximumResamplingQuality ? kResamplingRowMaximum
                                                               : kResamplingRowHigh;
}

- (NSArray<NSString *> *)resamplingTitles {
    return @[STR_SETTINGS_RESAMPLING_HIGH, STR_SETTINGS_RESAMPLING_MAXIMUM];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibePlaybackSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == VibePlaybackSectionTransitions ? VibePlaybackRowCount : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((VibePlaybackSection)section) {
        case VibePlaybackSectionSound: return STR_SETTINGS_PLAYBACK_AUDIO_SECTION;
        case VibePlaybackSectionEffects: return STR_SETTINGS_FX_SECTION;
        case VibePlaybackSectionAnalysis: return STR_SETTINGS_ANALYSIS_SECTION;
        default: return STR_SETTINGS_TRANSITIONS_SECTION;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch ((VibePlaybackSection)section) {
        case VibePlaybackSectionSound: return STR_SETTINGS_RESAMPLING_CAPTION;
        case VibePlaybackSectionEffects: return STR_SETTINGS_FX_CAPTION;
        case VibePlaybackSectionAnalysis: return STR_SETTINGS_DETECT_BPM_CAPTION;
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == VibePlaybackSectionEffects) {
        return [SettingsChoiceViewController switchCellInTableView:tableView title:STR_SETTINGS_ENABLE_FX
                                                                on:AppSettings.sharedInstance.audioFXEnabled
                                                            target:self action:@selector(effectsToggled:)];
    }
    if (indexPath.section == VibePlaybackSectionAnalysis) {
        return [SettingsChoiceViewController switchCellInTableView:tableView title:STR_SETTINGS_DETECT_BPM
                                                                on:AppSettings.sharedInstance.analyzeBPM
                                                            target:self action:@selector(detectBPMToggled:)];
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValueCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kValueCellIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    if (indexPath.section == VibePlaybackSectionSound) {
        content.text = STR_SETTINGS_RESAMPLING_LABEL;
        content.secondaryText = [self resamplingTitles][(NSUInteger)[self currentResamplingIndex]];
    }
    else if ((VibePlaybackRow)indexPath.row == VibePlaybackRowCrossfade) {
        content.text = STR_SETTINGS_CROSSFADE_LABEL;
        content.secondaryText = [self crossfadeTitles][(NSUInteger)[self currentCrossfadeIndex]];
    }
    else {
        content.text = STR_SETTINGS_ON_END_LABEL;
        content.secondaryText = [self onTrackEndValueText];
    }
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == VibePlaybackSectionEffects || indexPath.section == VibePlaybackSectionAnalysis) {
        return; // the switch rows
    }
    UIViewController *next = indexPath.section == VibePlaybackSectionSound ? [self resamplingPicker]
            : (VibePlaybackRow)indexPath.row == VibePlaybackRowCrossfade ? [self crossfadePicker]
            : [self onTrackEndPicker];
    [self.navigationController pushViewController:next animated:YES];
}

// The store never applies effects (Common/CLAUDE.md): every write here ends
// on the model, which is the iOS spelling of the mac's live-effect request.
- (SettingsChoiceViewController *)onTrackEndPicker {
    PlaybackController *playback = _playback;
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_ON_END_LABEL
                  choices:@[STR_SETTINGS_ON_END_PLAY_NEXT, STR_SETTINGS_ON_END_PAUSE]
            selectedIndex:(AppSettings.sharedInstance.pauseAtTrackEnd ? kOnEndRowPause
                                                                       : kOnEndRowPlayNext)
                 onSelect:^(NSInteger index) {
        AppSettings.sharedInstance.pauseAtTrackEnd = (index == kOnEndRowPause);
        [playback applyTrackTransitionSettings];
    }];
}

- (SettingsChoiceViewController *)resamplingPicker {
    PlaybackController *playback = _playback;
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_RESAMPLING_LABEL
                  choices:[self resamplingTitles]
            selectedIndex:[self currentResamplingIndex]
                 onSelect:^(NSInteger index) {
        AppSettings.sharedInstance.maximumResamplingQuality = (index == kResamplingRowMaximum);
        [playback applyResamplingSetting];
    }];
}

// The one Playback write that also notifies the card: the FX pad it shows or
// hides is drawn from this setting, so the display notification carries it
// the way the Appearance screen's writes are carried.
- (void)effectsToggled:(UISwitch *)toggle {
    AppSettings.sharedInstance.audioFXEnabled = toggle.isOn;
    [_playback applyFXSetting];
    VibeNotifyDisplaySettingsChanged();
}

// Nothing to apply: the loader asks the provider on its next decode.
- (void)detectBPMToggled:(UISwitch *)toggle {
    AppSettings.sharedInstance.analyzeBPM = toggle.isOn;
}

- (SettingsChoiceViewController *)crossfadePicker {
    PlaybackController *playback = _playback;
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_CROSSFADE_LABEL
                  choices:[self crossfadeTitles]
            selectedIndex:[self currentCrossfadeIndex]
                 onSelect:^(NSInteger index) {
        AppSettings.sharedInstance.crossfadeMilliseconds = kVibeCrossfadePresets[index];
        [playback applyTrackTransitionSettings];
    }];
}

@end
