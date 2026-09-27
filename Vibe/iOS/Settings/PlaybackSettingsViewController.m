//
//  PlaybackSettingsViewController.m
//  Vibe (iOS)
//

#import "PlaybackSettingsViewController.h"

#import "AppSettings.h"
#import "PlaybackController.h"
#import "SettingsChoiceViewController.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibePlaybackSection) {
    VibePlaybackSectionTransitions = 0,
    VibePlaybackSectionSound,
    VibePlaybackSectionCount,
};

// The Track transitions rows; Sound has the one Resampling row.
typedef NS_ENUM(NSInteger, VibePlaybackRow) {
    VibePlaybackRowOnTrackEnd = 0,
    VibePlaybackRowCrossfade,
    VibePlaybackRowCount,
};

static const NSInteger kResamplingRowHigh    = 0;
static const NSInteger kResamplingRowMaximum = 1;

// Not a cast of the BOOL: a row index is a screen position.
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

// A picker writes without telling this screen.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Current values

// In preset order, so an index names the same length in both.
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
    return section == VibePlaybackSectionSound ? 1 : VibePlaybackRowCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == VibePlaybackSectionSound ? STR_SETTINGS_PLAYBACK_AUDIO_SECTION
                                               : STR_SETTINGS_TRANSITIONS_SECTION;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == VibePlaybackSectionSound ? STR_SETTINGS_RESAMPLING_CAPTION : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
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
    UIViewController *next = indexPath.section == VibePlaybackSectionSound ? [self resamplingPicker]
            : (VibePlaybackRow)indexPath.row == VibePlaybackRowCrossfade ? [self crossfadePicker]
            : [self onTrackEndPicker];
    [self.navigationController pushViewController:next animated:YES];
}

// The store applies no effects (Common/CLAUDE.md): every write ends on the
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
