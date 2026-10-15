//
//  PlaybackSettingsViewController.m
//  Vibe (iOS)
//

#import "PlaybackSettingsViewController.h"

#import "AppSettings.h"
#import "Formatters.h"
#import "PlaybackController.h"
#import "SettingsChoiceViewController.h"
#import "SettingsRules.h"
#import "VibeStrings.h"

// On track end is two checkmarked choices in place, a small set needs no
// pushed screen. The other three sections hold one row each.
typedef NS_ENUM(NSInteger, VibePlaybackSection) {
    VibePlaybackSectionOnTrackEnd = 0,
    VibePlaybackSectionCrossfade,
    VibePlaybackSectionEffects,
    VibePlaybackSectionAnalysis,
    VibePlaybackSectionCount,
};

// Not a cast of the BOOL: a row index is a screen position.
static const NSInteger kOnEndRowPause    = 1;
static const NSInteger kOnEndRowCount    = 2;

static NSString *const kChoiceCellIdentifier = @"choice";

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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibePlaybackSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == VibePlaybackSectionOnTrackEnd ? kOnEndRowCount : 1;
}

// The crossfade row carries its own title, so its section has no header.
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ((VibePlaybackSection)section) {
        case VibePlaybackSectionOnTrackEnd: return STR_SETTINGS_ON_END_LABEL;
        case VibePlaybackSectionEffects: return STR_SETTINGS_FX_SECTION;
        case VibePlaybackSectionAnalysis: return STR_SETTINGS_ANALYSIS_SECTION;
        default: return nil;
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
    if (indexPath.section == VibePlaybackSectionCrossfade) {
        return [self crossfadeCell];
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kChoiceCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kChoiceCellIdentifier];
    }
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = indexPath.row == kOnEndRowPause ? STR_SETTINGS_ON_END_PAUSE : STR_SETTINGS_ON_END_PLAY_NEXT;
    cell.contentConfiguration = content;
    BOOL pause = AppSettings.sharedInstance.pauseAtTrackEnd;
    cell.accessoryType = (indexPath.row == kOnEndRowPause) == pause ? UITableViewCellAccessoryCheckmark
                                                                      : UITableViewCellAccessoryNone;
    return cell;
}

#pragma mark - Selection

// Apply the transition setting through the model to re-park the successor.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != VibePlaybackSectionOnTrackEnd) {
        return; // the switch and slider rows
    }
    BOOL pause = indexPath.row == kOnEndRowPause;
    if (pause == AppSettings.sharedInstance.pauseAtTrackEnd) {
        return;
    }
    AppSettings.sharedInstance.pauseAtTrackEnd = pause;
    [_playback applyTrackTransitionSettings];
    // The whole section, so the checkmark leaves the row it was on.
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:VibePlaybackSectionOnTrackEnd]
             withRowAnimation:UITableViewRowAnimationNone];
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
        [_crossfadeSlider addTarget:self action:@selector(crossfadeSettled:)
                   forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
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
    _crossfadeSlider.value = (float)milliseconds;
    _crossfadeValueLabel.text = [Formatters.sharedInstance crossfadeString:milliseconds];
}

// The knob snaps to the setting's steps, each one stored as it is crossed.
// The model applies once the drag ends: its apply also republishes the play
// order and Now Playing, which a drag across thirty steps would repeat. An
// adjustment without a drag — VoiceOver's — applies at once.
- (void)crossfadeSlid:(UISlider *)slider {
    NSInteger milliseconds = VibeNormalizedCrossfadeMilliseconds(lroundf(slider.value));
    [self renderCrossfade:milliseconds];
    if (milliseconds == AppSettings.sharedInstance.crossfadeMilliseconds) {
        return;
    }
    AppSettings.sharedInstance.crossfadeMilliseconds = milliseconds;
    if (!slider.tracking) {
        [_playback applyTrackTransitionSettings];
    }
}

- (void)crossfadeSettled:(UISlider *)slider {
    [_playback applyTrackTransitionSettings];
}

@end
