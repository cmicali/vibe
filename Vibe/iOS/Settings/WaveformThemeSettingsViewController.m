//
//  WaveformThemeSettingsViewController.m
//  Vibe (iOS)
//

#import "WaveformThemeSettingsViewController.h"

#import "AppSettings.h"
#import "SettingsRules.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"
#import "WaveformTheme.h"

// The color sections hold rows only while Custom is active: a pair or the
// three bands per appearance, because one set cannot read on both backdrops.
typedef NS_ENUM(NSInteger, VibeThemeSection) {
    VibeThemeSectionChoice = 0,
    VibeThemeSectionDark,
    VibeThemeSectionLight,
    VibeThemeSectionCount,
};

// The style this screen colors: the card's, or the widget's when the card's
// takes no palette. Spectrum takes none, because its hues are fixed. nil when
// neither style takes one.
static NSString *_Nullable PalettedStyle(void) {
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *card = [WaveformRendererRegistry resolveStyleIdentifier:settings.waveformStyle];
    NSString *widget = [WaveformRendererRegistry resolveStyleIdentifier:settings.widgetWaveformStyle ?: card];
    for (NSString *style in @[card, widget]) {
        if (![WaveformRendererRegistry readsBandsForIdentifier:style]
            || [WaveformRendererRegistry usesBandPaletteForIdentifier:style]) {
            return style;
        }
    }
    return nil;
}

// 3-Band draws its bands and ignores the waveform theme, so under it the
// screen offers the band palettes instead.
static BOOL ShowsBands(void) {
    return [WaveformRendererRegistry usesBandPaletteForIdentifier:PalettedStyle()];
}

// The mac popup's order, and the mac's built-in 3-Band themes.
static NSArray<NSString *> *ThemeIdentifiers(BOOL bands) {
    return bands ? @[SETTINGS_VALUE_WAVEFORM_BAND_THEME_REKORD_BIN, SETTINGS_VALUE_WAVEFORM_BAND_THEME_DENGINE,
                     SETTINGS_VALUE_WAVEFORM_BAND_THEME_CUSTOM]
                 : @[SETTINGS_VALUE_WAVEFORM_THEME_MONO, SETTINGS_VALUE_WAVEFORM_THEME_ORANGE,
                     SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART, SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
}

// The palettes carry the mac themes' names, which no language translates.
static NSArray<NSString *> *ThemeDisplayNames(BOOL bands) {
    return bands ? @[VibeNotLocalized(@"Rekord Bin"), VibeNotLocalized(@"Dengine"),
                     STR_SETTINGS_WAVEFORM_THEME_CUSTOM]
                 : @[STR_SETTINGS_WAVEFORM_THEME_MONO, STR_SETTINGS_WAVEFORM_THEME_ORANGE,
                     STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART, STR_SETTINGS_WAVEFORM_THEME_CUSTOM];
}

static NSArray<NSString *> *ColorRowNames(BOOL bands) {
    return bands ? @[STR_SETTINGS_WAVEFORM_BAND_LOW, STR_SETTINGS_WAVEFORM_BAND_MID, STR_SETTINGS_WAVEFORM_BAND_HIGH]
                 : @[STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED, STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED];
}

// Normalized on read, so it always matches a row.
static NSString *CurrentTheme(BOOL bands) {
    AppSettings *settings = AppSettings.sharedInstance;
    return bands ? settings.waveformBandTheme : settings.waveformTheme;
}

// Shared by the wells and the seed on choosing Custom, so the waveform matches
// what the wells show. The alphas are Mono's resting levels (a color's alpha is
// its side's level, WaveformTheme.h).
static UIColor *DefaultCustomPlayedColor(BOOL isDark) {
    return isDark ? [UIColor colorWithRed:1 green:1 blue:1 alpha:0.75]
                  : [UIColor colorWithRed:0 green:0 blue:0 alpha:0.75];
}

static UIColor *DefaultCustomUnplayedColor(BOOL isDark) {
    return [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:0.75];
}

// Seeds any unset color from the wells' fallbacks, as the mac does.
static void SeedCustomWaveformColors(AppSettings *settings) {
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

// row is the well's in its section: Played and Unplayed, or Low, Mid and
// High.
static void StoreCustomWaveformColor(UIColor *color, NSInteger row, BOOL isDark, BOOL bands) {
    AppSettings *settings = AppSettings.sharedInstance;
    if (bands) {
        [settings setWaveformCustomBandColor:color band:(NSUInteger)row forDark:isDark];
    }
    else if (row == 0) {
        [settings setWaveformCustomPlayedColor:color forDark:isDark];
    }
    else {
        [settings setWaveformCustomUnplayedColor:color forDark:isDark];
    }
}

static NSString *const kChoiceCellIdentifier = @"choice";

@implementation WaveformThemeSettingsViewController

+ (BOOL)appliesToCurrentStyles {
    return PalettedStyle() != nil;
}

+ (NSString *)currentThemeDisplayName {
    BOOL bands = ShowsBands();
    NSUInteger row = [ThemeIdentifiers(bands) indexOfObject:CurrentTheme(bands)];
    return ThemeDisplayNames(bands)[row == NSNotFound ? 0 : row];
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_SETTINGS_SECTION_WAVEFORM_THEME;
}

- (BOOL)customThemeActive {
    BOOL bands = ShowsBands();
    return [CurrentTheme(bands) isEqualToString:bands ? SETTINGS_VALUE_WAVEFORM_BAND_THEME_CUSTOM
                                                      : SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeThemeSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ((VibeThemeSection)section == VibeThemeSectionChoice) {
        return (NSInteger)ThemeIdentifiers(ShowsBands()).count;
    }
    return [self customThemeActive] ? (NSInteger)ColorRowNames(ShowsBands()).count : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ((VibeThemeSection)section == VibeThemeSectionChoice || ![self customThemeActive]) {
        return nil;
    }
    return section == VibeThemeSectionDark ? STR_SETTINGS_WAVEFORM_CUSTOM_DARK_LABEL
                                           : STR_SETTINGS_WAVEFORM_CUSTOM_LIGHT_LABEL;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeThemeSection)indexPath.section != VibeThemeSectionChoice) {
        return [self colorCellForRow:indexPath.row dark:indexPath.section == VibeThemeSectionDark];
    }
    BOOL bands = ShowsBands();
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kChoiceCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kChoiceCellIdentifier];
    }
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = ThemeDisplayNames(bands)[indexPath.row];
    cell.contentConfiguration = content;
    cell.accessoryType = [ThemeIdentifiers(bands)[indexPath.row] isEqualToString:CurrentTheme(bands)]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

// Not dequeued: reuse would drag a well's state and wiring to another row.
- (UITableViewCell *)colorCellForRow:(NSInteger)row dark:(BOOL)isDark {
    BOOL bands = ShowsBands();
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = ColorRowNames(bands)[row];
    cell.contentConfiguration = content;
    // accessoryView is placed by frame, and a UIColorWell starts at zero.
    UIColorWell *well = [[UIColorWell alloc] initWithFrame:CGRectMake(0, 0, 34, 34)];
    AppSettings *settings = AppSettings.sharedInstance;
    if (bands) {
        // The bands are opaque, since the layers stack. An unset one draws
        // Rekord Bin's, so nothing is seeded.
        well.supportsAlpha = NO;
        well.selectedColor = [settings waveformCustomBandColor:(NSUInteger)row forDark:isDark]
                ?: [WaveformTheme bandColorsForIdentifier:SETTINGS_VALUE_WAVEFORM_BAND_THEME_REKORD_BIN
                                                   isDark:isDark customBands:@[]][row];
    }
    else {
        // A color's alpha is its side's resting level (WaveformTheme.h).
        well.supportsAlpha = YES;
        well.selectedColor = row == 0
                ? ([settings waveformCustomPlayedColorForDark:isDark] ?: DefaultCustomPlayedColor(isDark))
                : ([settings waveformCustomUnplayedColorForDark:isDark] ?: DefaultCustomUnplayedColor(isDark));
    }
    [well addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UIColor *color = ((UIColorWell *)action.sender).selectedColor;
        if (color) {
            StoreCustomWaveformColor(color, row, isDark, bands);
            VibeNotifyDisplaySettingsChanged();
        }
    }] forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = well;
    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ((VibeThemeSection)indexPath.section != VibeThemeSectionChoice) {
        return;
    }
    BOOL bands = ShowsBands();
    NSString *identifier = ThemeIdentifiers(bands)[indexPath.row];
    AppSettings *settings = AppSettings.sharedInstance;
    if (bands) {
        settings.waveformBandTheme = identifier;
    }
    else {
        if ([identifier isEqualToString:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM]) {
            SeedCustomWaveformColors(settings);
        }
        settings.waveformTheme = identifier;
    }
    // TRAP: reloadData, NOT a reloadSections: per section. The checkmark moves
    // and the colors sections change row count in one turn, and two
    // reloadSections: calls COALESCE into one batch update whose validation
    // raises _Bug_Detected_In_Client_Of_UITableView_Invalid_Batch_Updates on
    // the unaccounted count change. A lone reloadSections: is fine.
    [tableView reloadData];
    VibeNotifyDisplaySettingsChanged();
}

@end
