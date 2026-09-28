//
//  AppearanceSettingsViewController.m
//  Vibe (iOS)
//

#import "AppearanceSettingsViewController.h"

#import "AppSettings.h"
#import "PlayerDisplaySettings.h"
#import "SettingsChoiceViewController.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"
#import "WaveformThemeSettingsViewController.h"

typedef NS_ENUM(NSInteger, VibeAppearanceRow) {
    VibeAppearanceRowWaveformStyle = 0,
    VibeAppearanceRowWidgetWaveformStyle,
    VibeAppearanceRowWaveformTheme,
    VibeAppearanceRowTimeDisplay,
    VibeAppearanceRowFileInfo,
    VibeAppearanceRowCount,
};

// Not a cast of the BOOL: a row index is a screen position.
static const NSInteger kTimeRowTotal     = 0;
static const NSInteger kTimeRowRemaining = 1;

static NSString *const kValueCellIdentifier  = @"value";

@implementation AppearanceSettingsViewController {
    // IDENTIFIERS, sorted by localized display name; a display name is never
    // a key.
    NSArray<NSString *> *_waveformStyles;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = STR_MENU_VIEW_APPEARANCE;
    _waveformStyles = [[WaveformRendererRegistry availableIdentifiers]
            sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [[WaveformRendererRegistry displayNameForIdentifier:a]
                localizedStandardCompare:[WaveformRendererRegistry displayNameForIdentifier:b]];
    }];
}

// A picker writes without telling this screen.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark - Current values

// Resolved, not the stored value: an unknown identifier draws as the default.
- (NSString *)currentWaveformStyle {
    return [WaveformRendererRegistry resolveStyleIdentifier:AppSettings.sharedInstance.waveformStyle];
}

- (NSString *)waveformStyleValueText {
    return [WaveformRendererRegistry displayNameForIdentifier:[self currentWaveformStyle]];
}

// Match app reads as itself, NOT the app's style name, which would say the widget
// is pinned when it is following.
- (NSString *)widgetWaveformStyleValueText {
    NSString *identifier = AppSettings.sharedInstance.widgetWaveformStyle;
    return identifier ? [WaveformRendererRegistry displayNameForIdentifier:identifier]
                      : STR_SETTINGS_WIDGET_WAVEFORM_MATCH;
}

- (NSString *)timeDisplayValueText {
    return VibeShowsRemainingTime() ? STR_SETTINGS_TIME_REMAINING : STR_SETTINGS_TIME_TOTAL;
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return VibeAppearanceRowCount;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ((VibeAppearanceRow)indexPath.row == VibeAppearanceRowFileInfo) {
        return [SettingsChoiceViewController switchCellInTableView:tableView title:STR_SETTINGS_FILE_INFO
                                                                on:VibeShowsFileInfo()
                                                            target:self action:@selector(fileInfoToggled:)];
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kValueCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:kValueCellIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    switch ((VibeAppearanceRow)indexPath.row) {
        case VibeAppearanceRowWaveformStyle:
            content.text = STR_SETTINGS_SECTION_WAVEFORM;
            content.secondaryText = [self waveformStyleValueText];
            break;
        case VibeAppearanceRowWidgetWaveformStyle:
            content.text = STR_SETTINGS_SECTION_WIDGET_WAVEFORM;
            content.secondaryText = [self widgetWaveformStyleValueText];
            break;
        case VibeAppearanceRowWaveformTheme:
            content.text = STR_SETTINGS_SECTION_WAVEFORM_THEME;
            content.secondaryText = [WaveformThemeSettingsViewController currentThemeDisplayName];
            break;
        default:
            content.text = STR_SETTINGS_SECTION_TIME;
            content.secondaryText = [self timeDisplayValueText];
            break;
    }
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIViewController *next = nil;
    switch ((VibeAppearanceRow)indexPath.row) {
        case VibeAppearanceRowWaveformStyle:
            next = [self waveformStylePicker];
            break;
        case VibeAppearanceRowWidgetWaveformStyle:
            next = [self widgetWaveformStylePicker];
            break;
        case VibeAppearanceRowWaveformTheme:
            next = [[WaveformThemeSettingsViewController alloc] init];
            break;
        case VibeAppearanceRowTimeDisplay:
            next = [self timeDisplayPicker];
            break;
        default:
            return;     // the switch row
    }
    [self.navigationController pushViewController:next animated:YES];
}

// In _waveformStyles' order, so a picker's row index maps back to it.
- (NSMutableArray<NSString *> *)waveformStyleNames {
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:_waveformStyles.count];
    for (NSString *identifier in _waveformStyles) {
        [names addObject:[WaveformRendererRegistry displayNameForIdentifier:identifier]];
    }
    return names;
}

- (SettingsChoiceViewController *)waveformStylePicker {
    NSMutableArray<NSString *> *names = [self waveformStyleNames];
    NSArray<NSString *> *styles = _waveformStyles;
    NSInteger selected = (NSInteger)[styles indexOfObject:[self currentWaveformStyle]];
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_SECTION_WAVEFORM
                  choices:names
            selectedIndex:selected
                 onSelect:^(NSInteger index) {
        AppSettings.sharedInstance.waveformStyle = styles[(NSUInteger)index];
        VibeNotifyDisplaySettingsChanged();
    }];
}

// Match app first, so every other row is offset by one against the styles.
- (SettingsChoiceViewController *)widgetWaveformStylePicker {
    NSMutableArray<NSString *> *names = [self waveformStyleNames];
    [names insertObject:STR_SETTINGS_WIDGET_WAVEFORM_MATCH atIndex:0];
    NSArray<NSString *> *styles = _waveformStyles;
    NSString *current = AppSettings.sharedInstance.widgetWaveformStyle;
    NSInteger selected = 0;
    if (current) {
        NSUInteger index = [styles indexOfObject:current];
        // An unregistered style falls back to Match app's checkmark.
        selected = index == NSNotFound ? 0 : (NSInteger)index + 1;
    }
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_SECTION_WIDGET_WAVEFORM
                  choices:names
            selectedIndex:selected
                 onSelect:^(NSInteger index) {
        AppSettings.sharedInstance.widgetWaveformStyle =
                index == 0 ? nil : styles[(NSUInteger)index - 1];
        VibeNotifyDisplaySettingsChanged();
    }];
}

- (SettingsChoiceViewController *)timeDisplayPicker {
    return [[SettingsChoiceViewController alloc]
            initWithTitle:STR_SETTINGS_SECTION_TIME
                  choices:@[STR_SETTINGS_TIME_TOTAL, STR_SETTINGS_TIME_REMAINING]
            selectedIndex:(VibeShowsRemainingTime() ? kTimeRowRemaining : kTimeRowTotal)
                 onSelect:^(NSInteger index) {
        VibeSetShowsRemainingTime(index == kTimeRowRemaining);
        VibeNotifyDisplaySettingsChanged();
    }];
}

- (void)fileInfoToggled:(UISwitch *)toggle {
    VibeSetShowsFileInfo(toggle.isOn);
    VibeNotifyDisplaySettingsChanged();
}

@end
