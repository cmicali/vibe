//
//  WaveformThemeSettingsViewController.m
//  Vibe (iOS)
//
//  See WaveformThemeSettingsViewController.h.
//

#import "WaveformThemeSettingsViewController.h"

#import "AppSettings.h"
#import "PlayerDisplaySettings.h"
#import "SettingsRules.h"
#import "VibeStrings.h"

typedef NS_ENUM(NSInteger, VibeThemeSection) {
    VibeThemeSectionChoice = 0,
    // Only while Custom is active: a played/unplayed pair per appearance,
    // because one pair cannot read on both backdrops.
    VibeThemeSectionColors,
    VibeThemeSectionCount,
};

// The mac's four, in the mac popup's order. Album art draws its palette from
// the playing track's cover; on this platform each page of the pager supplies
// its own, so the whole pager is not painted with one track's color.
typedef NS_ENUM(NSInteger, VibeThemeChoiceRow) {
    VibeThemeChoiceRowMono = 0,
    VibeThemeChoiceRowOrange,
    VibeThemeChoiceRowAlbumArt,
    VibeThemeChoiceRowCustom,
    VibeThemeChoiceRowCount,
};

typedef NS_ENUM(NSInteger, VibeThemeColorRow) {
    VibeThemeColorRowPlayedDark = 0,
    VibeThemeColorRowUnplayedDark,
    VibeThemeColorRowPlayedLight,
    VibeThemeColorRowUnplayedLight,
    VibeThemeColorRowCount,
};

static BOOL ThemeColorRowIsPlayed(NSInteger row) {
    return row == VibeThemeColorRowPlayedDark || row == VibeThemeColorRowPlayedLight;
}

static BOOL ThemeColorRowIsDark(NSInteger row) {
    return row == VibeThemeColorRowPlayedDark || row == VibeThemeColorRowUnplayedDark;
}

static NSString *ThemeIdentifierForRow(NSInteger row) {
    switch ((VibeThemeChoiceRow)row) {
        case VibeThemeChoiceRowOrange:   return SETTINGS_VALUE_WAVEFORM_THEME_ORANGE;
        case VibeThemeChoiceRowAlbumArt: return SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART;
        case VibeThemeChoiceRowCustom:   return SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM;
        default:                         return SETTINGS_VALUE_WAVEFORM_THEME_MONO;
    }
}

static NSString *ThemeDisplayNameForRow(NSInteger row) {
    switch ((VibeThemeChoiceRow)row) {
        case VibeThemeChoiceRowOrange:   return STR_SETTINGS_WAVEFORM_THEME_ORANGE;
        case VibeThemeChoiceRowAlbumArt: return STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART;
        case VibeThemeChoiceRowCustom:   return STR_SETTINGS_WAVEFORM_THEME_CUSTOM;
        default:                         return STR_SETTINGS_WAVEFORM_THEME_MONO;
    }
}

static NSString *ThemeColorRowName(NSInteger row) {
    switch ((VibeThemeColorRow)row) {
        case VibeThemeColorRowPlayedDark:   return STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED_DARK;
        case VibeThemeColorRowUnplayedDark: return STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED_DARK;
        case VibeThemeColorRowPlayedLight:  return STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED_LIGHT;
        default:                            return STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED_LIGHT;
    }
}

// The custom pairs' fallbacks, shared by the wells' display and the seed on
// choosing Custom, so the waveform always matches what the wells show. Their
// alphas are the Mono theme's resting levels, so a fresh Custom starts at a
// sane intensity — a color's alpha is its side's level (WaveformTheme.h) — and
// the played hue is the appearance's own base.
static UIColor *DefaultCustomPlayedColor(BOOL isDark) {
    return isDark ? [UIColor colorWithRed:1 green:1 blue:1 alpha:0.75]
                  : [UIColor colorWithRed:0 green:0 blue:0 alpha:0.75];
}

static UIColor *DefaultCustomUnplayedColor(BOOL isDark) {
    return [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:0.75];
}

// The stored identifier. Every one of the four has a row now, so unlike the
// style list there is nothing to resolve — an identifier from a later version
// simply matches no row, and currentThemeDisplayName falls back to Mono, which
// is also what WaveformTheme draws for it.
static NSString *CurrentWaveformTheme(void) {
    return AppSettings.sharedInstance.waveformTheme;
}

static NSString *const kChoiceCellIdentifier = @"choice";

@implementation WaveformThemeSettingsViewController

+ (NSString *)currentThemeDisplayName {
    NSString *theme = CurrentWaveformTheme();
    for (NSInteger row = 0; row < VibeThemeChoiceRowCount; row++) {
        if ([ThemeIdentifierForRow(row) isEqualToString:theme]) {
            return ThemeDisplayNameForRow(row);
        }
    }
    return ThemeDisplayNameForRow(VibeThemeChoiceRowMono);
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_SETTINGS_SECTION_WAVEFORM_THEME;
}

- (BOOL)customThemeActive {
    return [CurrentWaveformTheme() isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeThemeSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ((VibeThemeSection)section == VibeThemeSectionColors) {
        return [self customThemeActive] ? VibeThemeColorRowCount : 0;
    }
    return VibeThemeChoiceRowCount;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeThemeSection)indexPath.section == VibeThemeSectionColors) {
        return [self colorCellForRow:indexPath.row];
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kChoiceCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kChoiceCellIdentifier];
    }
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = ThemeDisplayNameForRow(indexPath.row);
    cell.contentConfiguration = content;
    cell.accessoryType = [ThemeIdentifierForRow(indexPath.row) isEqualToString:CurrentWaveformTheme()]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

// Built fresh rather than dequeued: each row's color well carries that row's
// own state and target wiring, which reuse would drag to the other row.
- (UITableViewCell *)colorCellForRow:(NSInteger)row {
    BOOL played = ThemeColorRowIsPlayed(row);
    BOOL isDark = ThemeColorRowIsDark(row);
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = ThemeColorRowName(row);
    cell.contentConfiguration = content;
    // accessoryView is placed by frame, not intrinsic size, and a UIColorWell
    // starts at zero — left unset it lands at the cell's origin.
    UIColorWell *well = [[UIColorWell alloc] initWithFrame:CGRectMake(0, 0, 34, 34)];
    // The alpha is part of the choice: a color's alpha is its side's resting
    // level (WaveformTheme.h).
    well.supportsAlpha = YES;
    AppSettings *settings = AppSettings.sharedInstance;
    well.selectedColor = played
            ? ([settings waveformCustomPlayedColorForDark:isDark] ?: DefaultCustomPlayedColor(isDark))
            : ([settings waveformCustomUnplayedColorForDark:isDark] ?: DefaultCustomUnplayedColor(isDark));
    well.tag = row;
    [well addTarget:self action:@selector(themeColorChanged:)
   forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = well;
    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((VibeThemeSection)indexPath.section == VibeThemeSectionColors) {
        return;     // the color wells are their own controls
    }
    NSString *identifier = ThemeIdentifierForRow(indexPath.row);
    if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM]) {
        // Choosing Custom seeds any unset color from the wells' fallbacks —
        // the mac pane's behavior.
        AppSettings *settings = AppSettings.sharedInstance;
        for (int darkPass = 0; darkPass <= 1; darkPass++) {
            BOOL isDark = darkPass == 1;
            if (![settings waveformCustomPlayedColorForDark:isDark]) {
                [settings setWaveformCustomPlayedColor:DefaultCustomPlayedColor(isDark) forDark:isDark];
            }
            if (![settings waveformCustomUnplayedColorForDark:isDark]) {
                [settings setWaveformCustomUnplayedColor:DefaultCustomUnplayedColor(isDark) forDark:isDark];
            }
        }
    }
    AppSettings.sharedInstance.waveformTheme = identifier;
    // TRAP: reloadData, NOT a reloadSections: per section. Choosing a theme has
    // to move the checkmark in one section AND take the colors section from
    // four rows to none (or back) in the other, and two reloadSections: calls
    // in the same turn COALESCE into one implicit batch update — whose
    // validation then sees a section whose row count changed with no insert or
    // delete to account for it, and raises
    // _Bug_Detected_In_Client_Of_UITableView_Invalid_Batch_Updates.
    // A lone reloadSections: is fine with a changed count and is what the
    // Files screen's folder list uses; it is the pairing that is not. Explicit
    // insert/delete rows in a performBatchUpdates: would also be correct — this
    // screen has at most eight rows and no animation worth the machinery.
    [tableView reloadData];
    VibeNotifyDisplaySettingsChanged();
}

- (void)themeColorChanged:(UIColorWell *)well {
    if (!well.selectedColor) {
        return;
    }
    BOOL isDark = ThemeColorRowIsDark(well.tag);
    if (ThemeColorRowIsPlayed(well.tag)) {
        [AppSettings.sharedInstance setWaveformCustomPlayedColor:well.selectedColor forDark:isDark];
    }
    else {
        [AppSettings.sharedInstance setWaveformCustomUnplayedColor:well.selectedColor forDark:isDark];
    }
    VibeNotifyDisplaySettingsChanged();
}

@end
