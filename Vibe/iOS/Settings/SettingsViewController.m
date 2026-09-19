//
//  SettingsViewController.m
//  Vibe (iOS)
//
//  See SettingsViewController.h.
//

#import "SettingsViewController.h"

#import "AboutSettingsViewController.h"
#import "AppearanceSettingsViewController.h"
#import "FilesSettingsViewController.h"
#import "PlaybackSettingsViewController.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibeSettingsSection) {
    VibeSettingsSectionGroups = 0,
    // About is alone below the rule because it is the one screen here that
    // changes nothing — it reports.
    VibeSettingsSectionAbout,
    VibeSettingsSectionCount,
};

typedef NS_ENUM(NSInteger, VibeSettingsGroupRow) {
    VibeSettingsGroupRowPlayback = 0,
    VibeSettingsGroupRowAppearance,
    VibeSettingsGroupRowFiles,
    VibeSettingsGroupRowCount,
};

static NSString *const kGroupCellIdentifier = @"group";

@implementation SettingsViewController {
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
    self.title = STR_SETTINGS_TITLE;
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (VibeSettingsSection)section == VibeSettingsSectionAbout ? 1
                                                                    : VibeSettingsGroupRowCount;
}

// The same words and the same symbols as the mac Settings window's sidebar
// rows, so the two apps' settings read as one product — see
// SettingsWindowController.
- (NSString *)titleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeSettingsSection)indexPath.section == VibeSettingsSectionAbout) {
        return STR_SETTINGS_ABOUT;
    }
    switch ((VibeSettingsGroupRow)indexPath.row) {
        case VibeSettingsGroupRowPlayback: return STR_MENU_PLAYBACK;
        case VibeSettingsGroupRowFiles:    return STR_SETTINGS_FILES;
        default:                           return STR_MENU_VIEW_APPEARANCE;
    }
}

- (NSString *)symbolNameForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeSettingsSection)indexPath.section == VibeSettingsSectionAbout) {
        return @"info.circle";
    }
    switch ((VibeSettingsGroupRow)indexPath.row) {
        case VibeSettingsGroupRowPlayback: return @"play.circle";
        case VibeSettingsGroupRowFiles:    return @"folder";
        default:                           return @"paintbrush";
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kGroupCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kGroupCellIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = [self titleForRowAtIndexPath:indexPath];
    content.image = [UIImage systemImageNamed:[self symbolNameForRowAtIndexPath:indexPath]];
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next;
    if ((VibeSettingsSection)indexPath.section == VibeSettingsSectionAbout) {
        next = [[AboutSettingsViewController alloc] init];
    }
    else if (indexPath.row == VibeSettingsGroupRowPlayback) {
        next = [[PlaybackSettingsViewController alloc] initWithPlayback:_playback];
    }
    else if (indexPath.row == VibeSettingsGroupRowFiles) {
        next = [[FilesSettingsViewController alloc] init];
    }
    else {
        next = [[AppearanceSettingsViewController alloc] init];
    }
    [self.navigationController pushViewController:next animated:YES];
}

@end
