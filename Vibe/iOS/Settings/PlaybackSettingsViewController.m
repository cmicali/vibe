//
//  PlaybackSettingsViewController.m
//  Vibe (iOS)
//

#import "PlaybackSettingsViewController.h"

#import "AppSettings.h"
#import "Formatters.h"
#import "PlaybackController.h"
#import "PlayerDisplaySettings.h"
#import "SettingsChoiceViewController.h"
#import "SettingsRules.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibePlaybackSection) {
    VibePlaybackSectionTransitions = 0,
    VibePlaybackSectionEffects,
    VibePlaybackSectionAnalysis,
    VibePlaybackSectionCount,
};

// The Track transitions rows; the other two sections hold one row each —
// the effects switch and the BPM detection switch.
typedef NS_ENUM(NSInteger, VibePlaybackRow) {
    VibePlaybackRowOnTrackEnd = 0,
    VibePlaybackRowCrossfade,
    VibePlaybackRowCount,
};

// Not a cast of the BOOL: a row index is a screen position.
static const NSInteger kOnEndRowPlayNext = 0;
static const NSInteger kOnEndRowPause    = 1;

static NSString *const kValueCellIdentifier = @"value";

@implementation PlaybackSettingsViewController {
    PlaybackController *_playback;
    // The one slider row, built once: the table has no second.
    UITableViewCell *_crossfadeCell;
    UISlider *_crossfadeSlider;
    UILabel *_crossfadeValueLabel;
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

// A picker writes without telling this screen.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Current values

- (NSString *)onTrackEndValueText {
    return AppSettings.sharedInstance.pauseAtTrackEnd ? STR_SETTINGS_ON_END_PAUSE
                                                       : STR_SETTINGS_ON_END_PLAY_NEXT;
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
        case VibePlaybackSectionEffects: return STR_SETTINGS_FX_SECTION;
        case VibePlaybackSectionAnalysis: return STR_SETTINGS_ANALYSIS_SECTION;
        default: return STR_SETTINGS_TRANSITIONS_SECTION;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch ((VibePlaybackSection)section) {
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
    if ((VibePlaybackRow)indexPath.row == VibePlaybackRowCrossfade) {
        return [self crossfadeCell];
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValueCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kValueCellIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    content.text = STR_SETTINGS_ON_END_LABEL;
    content.secondaryText = [self onTrackEndValueText];
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != VibePlaybackSectionTransitions || indexPath.row != VibePlaybackRowOnTrackEnd) {
        return; // the switch and slider rows
    }
    [self.navigationController pushViewController:[self onTrackEndPicker] animated:YES];
}

// The store applies no effects (Common/AGENTS.md): every write ends on the
// model.
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

#pragma mark - Crossfade

- (UITableViewCell *)crossfadeCell {
    if (!_crossfadeCell) {
        _crossfadeCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        _crossfadeCell.selectionStyle = UITableViewCellSelectionStyleNone;
        UILabel *title = [UILabel new];
        title.text = STR_SETTINGS_CROSSFADE_LABEL;
        title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        title.adjustsFontForContentSizeCategory = YES;
        _crossfadeValueLabel = [UILabel new];
        _crossfadeValueLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        _crossfadeValueLabel.adjustsFontForContentSizeCategory = YES;
        _crossfadeValueLabel.textColor = UIColor.secondaryLabelColor;
        _crossfadeValueLabel.textAlignment = NSTextAlignmentRight;
        UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[title, _crossfadeValueLabel]];
        _crossfadeSlider = [UISlider new];
        _crossfadeSlider.minimumValue = 0;
        _crossfadeSlider.maximumValue = kVibeCrossfadeMaxMilliseconds;
        [_crossfadeSlider addTarget:self action:@selector(crossfadeSlid:) forControlEvents:UIControlEventValueChanged];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[header, _crossfadeSlider]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 8;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_crossfadeCell.contentView addSubview:stack];
        UILayoutGuide *margins = _crossfadeCell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [stack.topAnchor constraintEqualToAnchor:margins.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        ]];
    }
    [self renderCrossfade:AppSettings.sharedInstance.crossfadeMilliseconds];
    return _crossfadeCell;
}

- (void)renderCrossfade:(NSInteger)milliseconds {
    _crossfadeSlider.value = milliseconds > kVibeCrossfadeOffMilliseconds ? (float)milliseconds : 0;
    _crossfadeValueLabel.text = [Formatters.sharedInstance crossfadeString:milliseconds];
}

// The knob snaps to the setting's steps; only a new step is written, since
// each write re-parks the successor and republishes the play order.
- (void)crossfadeSlid:(UISlider *)slider {
    NSInteger milliseconds = VibeNormalizedCrossfadeMilliseconds(lroundf(slider.value));
    [self renderCrossfade:milliseconds];
    if (milliseconds == AppSettings.sharedInstance.crossfadeMilliseconds) {
        return;
    }
    AppSettings.sharedInstance.crossfadeMilliseconds = milliseconds;
    [_playback applyTrackTransitionSettings];
}

@end
