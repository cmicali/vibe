// The settings screens: each row list against the rules and registry it
// shows, and each choice written through AppSettings and read back. Rows are
// asked of the data source, as the table asks for them.

#import "IOSSimTestCase.h"

#import "AboutSettingsViewController.h"
#import "AppearanceSettingsViewController.h"
#import "AppSettings.h"
#import "FilesSettingsViewController.h"
#import "PlaybackSettingsViewController.h"
#import "SettingsChoiceViewController.h"
#import "SettingsRules.h"
#import "SettingsViewController.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"
#import "WaveformThemeSettingsViewController.h"

@interface SettingsScreensTests : IOSSimTestCase
@end

@implementation SettingsScreensTests {
    FakePlayback *_playback;
}

- (void)setUp {
    [super setUp];
    _playback = [[FakePlayback alloc] init];
    AppSettings *settings = AppSettings.sharedInstance;
    settings.waveformStyle = SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT;
    settings.widgetWaveformStyle = nil;
    [settings setWaveformTheme:SETTINGS_VALUE_WAVEFORM_THEME_MONO forWidget:NO];
}

- (UITableViewController *)show:(UITableViewController *)screen {
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:screen];
    [self.window layoutIfNeeded];
    [screen.tableView layoutIfNeeded];
    return screen;
}

static UITableViewCell *Cell(UITableViewController *screen, NSInteger section, NSInteger row) {
    return [screen tableView:screen.tableView
       cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]];
}

static NSString *Text(UITableViewController *screen, NSInteger section, NSInteger row) {
    id content = Cell(screen, section, row).contentConfiguration;
    return [content isKindOfClass:UIListContentConfiguration.class] ? ((UIListContentConfiguration *)content).text : nil;
}

static NSArray<NSString *> *Texts(UITableViewController *screen, NSInteger section) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSInteger rows = [screen tableView:screen.tableView numberOfRowsInSection:section];
    for (NSInteger row = 0; row < rows; row++) {
        [texts addObject:Text(screen, section, row) ?: @""];
    }
    return texts;
}

static NSInteger CheckedRow(UITableViewController *screen, NSInteger section) {
    NSInteger rows = [screen tableView:screen.tableView numberOfRowsInSection:section];
    NSInteger checked = -1;
    for (NSInteger row = 0; row < rows; row++) {
        if (Cell(screen, section, row).accessoryType == UITableViewCellAccessoryCheckmark) {
            if (checked >= 0) {
                return -2;  // two checkmarks
            }
            checked = row;
        }
    }
    return checked;
}

static void Select(UITableViewController *screen, NSInteger section, NSInteger row) {
    [screen tableView:screen.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]];
}

static UISwitch *Switch(UITableViewController *screen, NSInteger section, NSInteger row) {
    return (UISwitch *)Cell(screen, section, row).accessoryView;
}

static void Flip(UISwitch *toggle) {
    toggle.on = !toggle.on;
    [toggle sendActionsForControlEvents:UIControlEventValueChanged];
}

- (XCTestExpectation *)expectDisplayNotification {
    return [self expectationForNotification:VibeDisplaySettingsDidChangeNotification object:nil handler:nil];
}

#pragma mark - The top screen

- (void)testTheTopScreenListsTheGroupsAndPushesEach {
    SettingsViewController *screen = (SettingsViewController *)[self show:
            [[SettingsViewController alloc] initWithPlayback:_playback.asPlayback]];
    XCTAssertEqual([screen numberOfSectionsInTableView:screen.tableView], 2);
    XCTAssertEqualObjects(Texts(screen, 0), (@[STR_MENU_PLAYBACK, STR_MENU_VIEW_APPEARANCE, STR_SETTINGS_FILES_DROPBOX]));
    XCTAssertEqualObjects(Texts(screen, 1), @[STR_SETTINGS_ABOUT]);
    // A stack of its own for each push: one asked for during a transition
    // is dropped.
    NSArray<NSIndexPath *> *rows = @[[NSIndexPath indexPathForRow:0 inSection:0], [NSIndexPath indexPathForRow:1 inSection:0],
                                     [NSIndexPath indexPathForRow:2 inSection:0], [NSIndexPath indexPathForRow:0 inSection:1]];
    NSArray<Class> *pushed = @[PlaybackSettingsViewController.class, AppearanceSettingsViewController.class,
                               FilesSettingsViewController.class, AboutSettingsViewController.class];
    for (NSUInteger i = 0; i < rows.count; i++) {
        SettingsViewController *top = (SettingsViewController *)[self show:
                [[SettingsViewController alloc] initWithPlayback:_playback.asPlayback]];
        UINavigationController *stack = top.navigationController;
        XCTAssertTrue([self eventually:^BOOL { return stack.transitionCoordinator == nil; }]);
        [top tableView:top.tableView didSelectRowAtIndexPath:rows[i]];
        XCTAssertTrue([stack.topViewController isKindOfClass:pushed[i]], @"%@", rows[i]);
    }
}

- (void)testAboutBuildsItsSections {
    AboutSettingsViewController *screen = (AboutSettingsViewController *)[self show:
            [[AboutSettingsViewController alloc] init]];
    NSInteger sections = [screen numberOfSectionsInTableView:screen.tableView];
    XCTAssertGreaterThan(sections, 0);
    for (NSInteger section = 0; section < sections; section++) {
        XCTAssertGreaterThan(Texts(screen, section).count, 0u);
    }
    XCTAssertNotNil(screen.tableView.tableHeaderView);
}

#pragma mark - Files

- (void)testFolderSortRowsAreTheRulesNamesAndAChoiceIsStored {
    AppSettings.sharedInstance.folderOpenSort = VibeFolderOpenSortName;
    FilesSettingsViewController *screen = (FilesSettingsViewController *)[self show:
            [[FilesSettingsViewController alloc] init]];
    const NSInteger sortSection = 1;
    XCTAssertEqualObjects(Texts(screen, sortSection), (@[
        VibeFolderOpenSortDisplayName(VibeFolderOpenSortName),
        VibeFolderOpenSortDisplayName(VibeFolderOpenSortNewestFirst),
        VibeFolderOpenSortDisplayName(VibeFolderOpenSortAsReceived),
    ]));
    XCTAssertEqual(CheckedRow(screen, sortSection), 0);
    Select(screen, sortSection, 1);
    XCTAssertEqual(AppSettings.sharedInstance.folderOpenSort, VibeFolderOpenSortNewestFirst);
    XCTAssertEqual(CheckedRow(screen, sortSection), 1);
    Select(screen, sortSection, 2);
    XCTAssertEqual(AppSettings.sharedInstance.folderOpenSort, VibeFolderOpenSortAsReceived);
}

// No account in the test host: Connect alone.
- (void)testAnUnlinkedDropboxIsOneRow {
    FilesSettingsViewController *screen = (FilesSettingsViewController *)[self show:
            [[FilesSettingsViewController alloc] init]];
    XCTAssertEqual([screen tableView:screen.tableView numberOfRowsInSection:0], 1);
    XCTAssertEqual([screen tableView:screen.tableView numberOfRowsInSection:2], 1);
}

#pragma mark - Playback

- (void)testOnTrackEndIsStoredAndReachesTheModel {
    AppSettings.sharedInstance.pauseAtTrackEnd = NO;
    PlaybackSettingsViewController *screen = (PlaybackSettingsViewController *)[self show:
            [[PlaybackSettingsViewController alloc] initWithPlayback:_playback.asPlayback]];
    XCTAssertEqualObjects(Texts(screen, 0), (@[STR_SETTINGS_ON_END_PLAY_NEXT, STR_SETTINGS_ON_END_PAUSE]));
    XCTAssertEqual(CheckedRow(screen, 0), 0);
    [_playback clearCalls];
    Select(screen, 0, 1);
    XCTAssertTrue(AppSettings.sharedInstance.pauseAtTrackEnd);
    XCTAssertEqual(CheckedRow(screen, 0), 1);
    XCTAssertEqualObjects(_playback.calls, @[@"applyTrackTransitionSettings"]);
    Select(screen, 0, 1);
    XCTAssertEqual(_playback.calls.count, 1u, @"rechoosing the checked row does nothing");
}

- (void)testTheEffectsSwitchAppliesAndNotifiesTheCard {
    AppSettings.sharedInstance.audioFXEnabled = YES;
    PlaybackSettingsViewController *screen = (PlaybackSettingsViewController *)[self show:
            [[PlaybackSettingsViewController alloc] initWithPlayback:_playback.asPlayback]];
    UISwitch *effects = Switch(screen, 2, 0);
    XCTAssertTrue(effects.on);
    [_playback clearCalls];
    [self expectDisplayNotification];
    Flip(effects);
    [self waitForExpectationsWithTimeout:VIBE_TEST_HANG_TIMEOUT handler:nil];
    XCTAssertFalse(AppSettings.sharedInstance.audioFXEnabled);
    XCTAssertEqualObjects(_playback.calls, @[@"applyFXSetting"]);
}

- (void)testDetectBPMWritesOnlyTheSetting {
    AppSettings.sharedInstance.analyzeBPM = YES;
    PlaybackSettingsViewController *screen = (PlaybackSettingsViewController *)[self show:
            [[PlaybackSettingsViewController alloc] initWithPlayback:_playback.asPlayback]];
    [_playback clearCalls];
    Flip(Switch(screen, 3, 0));
    XCTAssertFalse(AppSettings.sharedInstance.analyzeBPM);
    XCTAssertEqual(_playback.calls.count, 0u);
}

#pragma mark - Appearance

- (void)testTimeDisplayIsStoredAndNotified {
    AppSettings.sharedInstance.showRemainingTime = NO;
    AppearanceSettingsViewController *screen = (AppearanceSettingsViewController *)[self show:
            [[AppearanceSettingsViewController alloc] initWithPlayback:_playback.asPlayback]];
    XCTAssertEqualObjects(Texts(screen, 0), (@[STR_SETTINGS_TIME_TOTAL, STR_SETTINGS_TIME_REMAINING]));
    XCTAssertEqual(CheckedRow(screen, 0), 0);
    [self expectDisplayNotification];
    Select(screen, 0, 1);
    [self waitForExpectationsWithTimeout:VIBE_TEST_HANG_TIMEOUT handler:nil];
    XCTAssertTrue(AppSettings.sharedInstance.showRemainingTime);
    XCTAssertEqual(CheckedRow(screen, 0), 1);
}

- (void)testTheNowPlayingSwitchesWriteTheirSettings {
    AppSettings.sharedInstance.showFileInfo = NO;
    AppSettings.sharedInstance.showShuffleRepeat = YES;
    AppearanceSettingsViewController *screen = (AppearanceSettingsViewController *)[self show:
            [[AppearanceSettingsViewController alloc] initWithPlayback:_playback.asPlayback]];
    Flip(Switch(screen, 1, 0));
    XCTAssertTrue(AppSettings.sharedInstance.showFileInfo);
    [_playback clearCalls];
    Flip(Switch(screen, 1, 1));
    XCTAssertFalse(AppSettings.sharedInstance.showShuffleRepeat);
    XCTAssertEqualObjects(_playback.calls, @[@"applyTrackTransitionSettings"], @"the modes are cleared through the model");
}

// Type shows only for a style with types, and Coloring only for Spectrum.
// Both sit under Style. Under Match app the widget's group is Style alone.
- (void)testTheWaveformGroupsFollowTheStyle {
    AppearanceSettingsViewController *screen = (AppearanceSettingsViewController *)[self show:
            [[AppearanceSettingsViewController alloc] initWithPlayback:_playback.asPlayback]];
    BOOL types = [WaveformRendererRegistry typeIdentifiersForIdentifier:
            [WaveformRendererRegistry resolveStyleIdentifier:AppSettings.sharedInstance.waveformStyle]].count > 0;
    NSMutableArray<NSString *> *expected = [@[STR_SETTINGS_THEME_WAVEFORM_STYLE, STR_SETTINGS_SECTION_WAVEFORM_THEME,
                                              STR_SETTINGS_WAVEFORM_PLAYHEAD_LINE, STR_SETTINGS_WAVEFORM_CENTERED] mutableCopy];
    if (types) {
        [expected insertObject:STR_SETTINGS_WAVEFORM_TYPE atIndex:1];
    }
    XCTAssertEqualObjects(Texts(screen, 2), expected);
    XCTAssertEqualObjects(Texts(screen, 3), @[STR_SETTINGS_THEME_WAVEFORM_STYLE]);

    for (NSString *style in WaveformRendererRegistry.styleIdentifiers) {
        if ([WaveformRendererRegistry paletteKindForIdentifier:style] == VibeWaveformPaletteKindSpectrum) {
            AppSettings.sharedInstance.waveformStyle = style;
        }
    }
    [screen.tableView reloadData];
    XCTAssertEqualObjects(Texts(screen, 2), (@[STR_SETTINGS_THEME_WAVEFORM_STYLE, STR_SETTINGS_WAVEFORM_SPECTRUM_COLORING,
                                              STR_SETTINGS_SECTION_WAVEFORM_THEME, STR_SETTINGS_WAVEFORM_PLAYHEAD_LINE,
                                              STR_SETTINGS_WAVEFORM_CENTERED]),
                          @"a style's own settings sit under Style");

    AppSettings.sharedInstance.widgetWaveformStyle = SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE;
    [screen.tableView reloadData];
    XCTAssertGreaterThan(Texts(screen, 3).count, 1u, @"a style of its own shows the group");
}

#pragma mark - Waveform theme

- (void)testTheThemeRowsFollowThePaletteKindAndAChoiceReadsBack {
    WaveformThemeSettingsViewController *screen = (WaveformThemeSettingsViewController *)[self show:
            [[WaveformThemeSettingsViewController alloc] initForWidget:NO]];
    XCTAssertEqualObjects(Texts(screen, 0), (@[STR_SETTINGS_WAVEFORM_THEME_MONO, STR_SETTINGS_WAVEFORM_THEME_ORANGE,
                                              STR_SETTINGS_WAVEFORM_THEME_ALBUM_ART, STR_SETTINGS_WAVEFORM_THEME_CUSTOM]));
    XCTAssertEqual(CheckedRow(screen, 0), 0);
    Select(screen, 0, 1);
    XCTAssertEqualObjects([AppSettings.sharedInstance waveformThemeForWidget:NO], SETTINGS_VALUE_WAVEFORM_THEME_ORANGE);
    XCTAssertEqual(CheckedRow(screen, 0), 1);
    XCTAssertEqualObjects([WaveformThemeSettingsViewController currentThemeDisplayNameForWidget:NO],
                          STR_SETTINGS_WAVEFORM_THEME_ORANGE);

    NSString *bands = nil;
    for (NSString *style in WaveformRendererRegistry.styleIdentifiers) {
        if ([WaveformRendererRegistry paletteKindForIdentifier:style] == VibeWaveformPaletteKindBands) {
            bands = style;
        }
    }
    XCTAssertNotNil(bands);
    AppSettings.sharedInstance.waveformStyle = bands;
    [screen.tableView reloadData];
    XCTAssertEqualObjects(Texts(screen, 0), (@[STR_SETTINGS_WAVEFORM_BAND_BLUE_ORANGE,
                                              STR_SETTINGS_WAVEFORM_BAND_BLUE_GREEN,
                                              STR_SETTINGS_WAVEFORM_THEME_CUSTOM]),
                          @"3-Band offers its band palettes, not the themes");
    Select(screen, 0, 1);
    XCTAssertEqualObjects([AppSettings.sharedInstance waveformBandThemeForWidget:NO],
                          SETTINGS_VALUE_WAVEFORM_BAND_THEME_DENGINE);
}

// Custom seeds its wells and shows them; the widget's copy shows the dark
// wells alone.
- (void)testCustomShowsItsWellsAndSeedsThem {
    WaveformThemeSettingsViewController *screen = (WaveformThemeSettingsViewController *)[self show:
            [[WaveformThemeSettingsViewController alloc] initForWidget:NO]];
    XCTAssertEqual([screen tableView:screen.tableView numberOfRowsInSection:1], 0);
    Select(screen, 0, 3);
    XCTAssertEqualObjects([AppSettings.sharedInstance waveformThemeForWidget:NO], SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM);
    XCTAssertEqualObjects(Texts(screen, 1), (@[STR_SETTINGS_WAVEFORM_CUSTOM_PLAYED, STR_SETTINGS_WAVEFORM_CUSTOM_UNPLAYED]));
    XCTAssertEqual([screen tableView:screen.tableView numberOfRowsInSection:2], 2);
    XCTAssertNotNil([AppSettings.sharedInstance waveformCustomPlayedColorForDark:YES widget:NO]);
    XCTAssertNotNil([AppSettings.sharedInstance waveformCustomUnplayedColorForDark:NO widget:NO]);

    AppSettings.sharedInstance.widgetWaveformStyle = SETTINGS_VALUE_WAVEFORM_STYLE_DEFAULT;
    [AppSettings.sharedInstance setWaveformTheme:SETTINGS_VALUE_WAVEFORM_THEME_CUSTOM forWidget:YES];
    WaveformThemeSettingsViewController *widget = (WaveformThemeSettingsViewController *)[self show:
            [[WaveformThemeSettingsViewController alloc] initForWidget:YES]];
    XCTAssertEqual([widget tableView:widget.tableView numberOfRowsInSection:1], 2);
    XCTAssertEqual([widget tableView:widget.tableView numberOfRowsInSection:2], 0, @"the widget is always dark");
}

#pragma mark - The choice screen

- (void)testTheChoiceScreenMovesItsCheckmarkAndReportsOnce {
    NSMutableArray<NSNumber *> *picked = [NSMutableArray array];
    SettingsChoiceViewController *screen = (SettingsChoiceViewController *)[self show:
            [[SettingsChoiceViewController alloc] initWithTitle:@"T" choices:@[@"A", @"B", @"C"] selectedIndex:1
                                                       onSelect:^(NSInteger index) { [picked addObject:@(index)]; }]];
    XCTAssertEqualObjects(Texts(screen, 0), (@[@"A", @"B", @"C"]));
    XCTAssertEqual(CheckedRow(screen, 0), 1);
    Select(screen, 0, 1);
    XCTAssertEqual(picked.count, 0u);
    Select(screen, 0, 2);
    XCTAssertEqualObjects(picked, @[@2]);
    XCTAssertEqual(CheckedRow(screen, 0), 2);
}

@end
