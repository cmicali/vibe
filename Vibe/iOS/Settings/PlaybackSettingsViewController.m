//
//  PlaybackSettingsViewController.m
//  Vibe (iOS)
//
//  See PlaybackSettingsViewController.h.
//

#import "PlaybackSettingsViewController.h"

#import "AppSettings.h"
#import "PlaybackController.h"
#import "SettingsChoiceViewController.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibePlaybackRow) {
    VibePlaybackRowOnTrackEnd = 0,
    VibePlaybackRowCrossfade,
    VibePlaybackRowCount,
};

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

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return VibePlaybackRowCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return STR_SETTINGS_TRANSITIONS_SECTION;
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
    if ((VibePlaybackRow)indexPath.row == VibePlaybackRowCrossfade) {
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
    UIViewController *next = (VibePlaybackRow)indexPath.row == VibePlaybackRowCrossfade
            ? [self crossfadePicker] : [self onTrackEndPicker];
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
