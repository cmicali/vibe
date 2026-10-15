//
//  WaveformThemeSettingsViewController.m
//  Vibe (iOS)
//

#import "WaveformThemeSettingsViewController.h"

#import "AppSettings.h"
#import "SettingsChoiceViewController.h"
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

// The palettes the style takes. 3-Band and Spectrum ignore the waveform
// theme: under each the screen offers that style's own palettes. The
// widget's screen is only reachable with a widget style of its own.
static VibeWaveformPaletteKind CurrentKind(BOOL widget) {
    AppSettings *settings = AppSettings.sharedInstance;
    return [WaveformRendererRegistry paletteKindForIdentifier:[WaveformRendererRegistry
            resolveStyleIdentifier:(widget ? settings.widgetWaveformStyle : nil) ?: settings.waveformStyle]];
}

// The mac popup's order, and for 3-Band the mac's built-in themes.
static NSArray<NSString *> *ThemeIdentifiers(VibeWaveformPaletteKind kind) {
    switch (kind) {
        case VibeWaveformPaletteKindBands:
            return @[SETTINGS_VALUE_WAVEFORM_BAND_THEME_REKORD_BIN, SETTINGS_VALUE_WAVEFORM_BAND_THEME_DENGINE,
                     SETTINGS_VALUE_WAVEFORM_BAND_THEME_CUSTOM];
        case VibeWaveformPaletteKindSpectrum:
            return VibeWaveformSpectrumPalettes();
        case VibeWaveformPaletteKindTheme:
            return @[SETTINGS_VALUE_WAVEFORM_THEME_MONO, SETTINGS_VALUE_WAVEFORM_THEME_ORANGE,
                     SETTINGS_VALUE_WAVEFORM_THEME_ALBUM_ART, SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM];
    }
}

// The 3-Band palettes are named by their colors: there are no themes on
// iOS, so the mac theme names they come from would mean nothing here.
static NSArray<NSString *> *ThemeDisplayNames(VibeWaveformPaletteKind kind) {
    switch (kind) {
        case VibeWaveformPaletteKindBands:
            return @[STR_SETTINGS_WAVEFORM_BAND_BLUE_ORANGE, STR_SETTINGS_WAVEFORM_BAND_BLUE_GREEN,
                     STR_SETTINGS_WAVEFORM_THEME_CUSTOM];
        case VibeWaveformPaletteKindSpectrum: {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NSString *palette in VibeWaveformSpectrumPalettes()) {
                [names addObject:VibeWaveformSpectrumPaletteDisplayName(palette)];
            }
            return names;
        }
        case VibeWaveformPaletteKindTheme:
            return @[STR_SETTINGS_WAVEFORM_THEME_MONO, STR_SETTINGS_WAVEFORM_THEME_ORANGE,
                     STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART, STR_SETTINGS_WAVEFORM_THEME_CUSTOM];
    }
}

// Both band styles' Custom is the band wells.
static NSArray<NSString *> *ColorRowNames(VibeWaveformPaletteKind kind) {
    return kind == VibeWaveformPaletteKindTheme
            ? @[STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED, STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED]
            : @[STR_SETTINGS_WAVEFORM_BAND_LOW, STR_SETTINGS_WAVEFORM_BAND_MID, STR_SETTINGS_WAVEFORM_BAND_HIGH];
}

// Normalized on read, so it always matches a row.
static NSString *CurrentTheme(VibeWaveformPaletteKind kind, BOOL widget) {
    AppSettings *settings = AppSettings.sharedInstance;
    switch (kind) {
        case VibeWaveformPaletteKindBands: return [settings waveformBandThemeForWidget:widget];
        case VibeWaveformPaletteKindSpectrum: return [settings waveformSpectrumPaletteForWidget:widget];
        case VibeWaveformPaletteKindTheme: return [settings waveformThemeForWidget:widget];
    }
}

// Every kind's Custom is the last row.
static BOOL IsCustom(VibeWaveformPaletteKind kind, NSString *identifier) {
    return [identifier isEqualToString:ThemeIdentifiers(kind).lastObject];
}

// A built-in band or spectrum palette's three colors, low, mid and high, as
// three bars beside its name, in this appearance's colors so the high band's
// white reads on a light cell. The waveform themes carry no swatch. Custom
// takes an empty one, so its name lines up with the rest. Drawn once per
// palette and appearance, since every reload asks for every row's.
static UIImage *PaletteSwatch(VibeWaveformPaletteKind kind, NSString *identifier, BOOL isDark) {
    if (kind == VibeWaveformPaletteKindTheme) {
        return nil;
    }
    static NSMutableDictionary<NSString *, UIImage *> *cache;
    cache = cache ?: [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%ld/%@/%d", (long)kind, identifier, isDark];
    if (cache[key]) {
        return cache[key];
    }
    BOOL custom = IsCustom(kind, identifier);
    NSArray<UIColor *> *colors = custom ? @[] : kind == VibeWaveformPaletteKindBands
            ? [WaveformTheme bandColorsForIdentifier:identifier isDark:isDark customBands:@[]]
            : [WaveformTheme spectrumColorsForIdentifier:identifier isDark:isDark customBands:@[]];
    const CGFloat barWidth = 8, barGap = 3, height = 22;
    CGSize size = CGSizeMake(barWidth * 3 + barGap * 2, height);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *swatch = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        for (NSUInteger band = 0; band < 3 && band < colors.count; band++) {
            [colors[band] setFill];
            CGRect bar = CGRectMake(band * (barWidth + barGap), 0, barWidth, height);
            [[UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:2] fill];
        }
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    cache[key] = swatch;
    return swatch;
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
static void SeedCustomWaveformColors(AppSettings *settings, BOOL widget) {
    for (int darkPass = 0; darkPass <= 1; darkPass++) {
        BOOL isDark = darkPass == 1;
        if (![settings waveformCustomPlayedColorForDark:isDark widget:widget]) {
            [settings setWaveformCustomPlayedColor:DefaultCustomPlayedColor(isDark) forDark:isDark widget:widget];
        }
        if (![settings waveformCustomUnplayedColorForDark:isDark widget:widget]) {
            [settings setWaveformCustomUnplayedColor:DefaultCustomUnplayedColor(isDark) forDark:isDark widget:widget];
        }
    }
}

// row is the well's in its section: Played and Unplayed, or Low, Mid and
// High.
static void StoreCustomWaveformColor(UIColor *color, NSInteger row, BOOL isDark,
                                     VibeWaveformPaletteKind kind, BOOL widget) {
    AppSettings *settings = AppSettings.sharedInstance;
    if (kind != VibeWaveformPaletteKindTheme) {
        [settings setWaveformCustomBandColor:color band:(NSUInteger)row forDark:isDark widget:widget];
    }
    else if (row == 0) {
        [settings setWaveformCustomPlayedColor:color forDark:isDark widget:widget];
    }
    else {
        [settings setWaveformCustomUnplayedColor:color forDark:isDark widget:widget];
    }
}


@implementation WaveformThemeSettingsViewController {
    BOOL _widget;
}

+ (NSString *)currentThemeDisplayNameForWidget:(BOOL)widget {
    VibeWaveformPaletteKind kind = CurrentKind(widget);
    NSUInteger row = [ThemeIdentifiers(kind) indexOfObject:CurrentTheme(kind, widget)];
    return ThemeDisplayNames(kind)[row == NSNotFound ? 0 : row];
}

- (instancetype)initForWidget:(BOOL)widget {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _widget = widget;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_SETTINGS_SECTION_WAVEFORM_THEME;
}

- (BOOL)customThemeActive {
    VibeWaveformPaletteKind kind = CurrentKind(_widget);
    return IsCustom(kind, CurrentTheme(kind, _widget));
}

// The widget's screen shows no light wells, and so no header to tell the
// sections apart.
- (BOOL)showsSection:(VibeThemeSection)section {
    return section == VibeThemeSectionChoice
        || ([self customThemeActive] && (section == VibeThemeSectionDark || !_widget));
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return VibeThemeSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ((VibeThemeSection)section == VibeThemeSectionChoice) {
        return (NSInteger)ThemeIdentifiers(CurrentKind(_widget)).count;
    }
    return [self showsSection:(VibeThemeSection)section] ? (NSInteger)ColorRowNames(CurrentKind(_widget)).count : 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ((VibeThemeSection)section == VibeThemeSectionChoice || _widget
            || ![self showsSection:(VibeThemeSection)section]) {
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
    VibeWaveformPaletteKind kind = CurrentKind(_widget);
    NSString *identifier = ThemeIdentifiers(kind)[indexPath.row];
    BOOL dark = tableView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    return [SettingsChoiceViewController checkmarkCellInTableView:tableView
                                                            title:ThemeDisplayNames(kind)[indexPath.row]
                                                            image:PaletteSwatch(kind, identifier, dark)
                                                          checked:[identifier isEqualToString:CurrentTheme(kind, _widget)]];
}

// Not dequeued: reuse would drag a well's state and wiring to another row.
- (UITableViewCell *)colorCellForRow:(NSInteger)row dark:(BOOL)isDark {
    VibeWaveformPaletteKind kind = CurrentKind(_widget);
    BOOL widget = _widget;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                  reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = ColorRowNames(kind)[row];
    cell.contentConfiguration = content;
    // accessoryView is placed by frame, and a UIColorWell starts at zero.
    UIColorWell *well = [[UIColorWell alloc] initWithFrame:CGRectMake(0, 0, 34, 34)];
    AppSettings *settings = AppSettings.sharedInstance;
    if (kind != VibeWaveformPaletteKindTheme) {
        // The bands are opaque, since 3-Band's layers stack. An unset one
        // draws Rekord Bin's under either band style, so nothing is seeded.
        well.supportsAlpha = NO;
        well.selectedColor = [settings waveformCustomBandColor:(NSUInteger)row forDark:isDark widget:widget]
                ?: [WaveformTheme bandColorsForIdentifier:SETTINGS_VALUE_WAVEFORM_BAND_THEME_REKORD_BIN
                                                   isDark:isDark customBands:@[]][row];
    }
    else {
        // A color's alpha is its side's resting level (WaveformTheme.h).
        well.supportsAlpha = YES;
        well.selectedColor = row == 0
                ? ([settings waveformCustomPlayedColorForDark:isDark widget:widget] ?: DefaultCustomPlayedColor(isDark))
                : ([settings waveformCustomUnplayedColorForDark:isDark widget:widget] ?: DefaultCustomUnplayedColor(isDark));
    }
    [well addAction:[UIAction actionWithHandler:^(UIAction *action) {
        UIColor *color = ((UIColorWell *)action.sender).selectedColor;
        if (color) {
            StoreCustomWaveformColor(color, row, isDark, kind, widget);
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
    VibeWaveformPaletteKind kind = CurrentKind(_widget);
    NSString *identifier = ThemeIdentifiers(kind)[indexPath.row];
    AppSettings *settings = AppSettings.sharedInstance;
    switch (kind) {
        case VibeWaveformPaletteKindBands:
            [settings setWaveformBandTheme:identifier forWidget:_widget];
            break;
        case VibeWaveformPaletteKindSpectrum:
            [settings setWaveformSpectrumPalette:identifier forWidget:_widget];
            break;
        case VibeWaveformPaletteKindTheme:
            if (IsCustom(kind, identifier)) {
                SeedCustomWaveformColors(settings, _widget);
            }
            [settings setWaveformTheme:identifier forWidget:_widget];
            break;
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
