//
//  SettingsAdvancedViewController.m
//  Vibe
//

#import "SettingsAdvancedViewController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "Formatters.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Window.h"
#import "NSBundle+BuildInfo.h"
#import "VibeStrings.h"

static const CGFloat kAdvancedPopUpWidth = 200;

// The rate ladder lives in AppSettings+Mac.h (kVibeUIUpdateHzCapPresets), like
// the Playback pane's, because the getter snaps a persisted value to it.

@implementation SettingsAdvancedViewController {
    NSPopUpButton *_refreshRatePopUp;
    NSButton *_resetButton;
    NSTextField *_cacheSizeValue;
    NSButton *_clearCacheButton;
    // Drops a stale usage reply: each refresh bumps it, and only the newest
    // request may write the label — a clear right after a refresh would
    // otherwise race the older, larger answer over the fresh zero.
    NSUInteger _usageRequestGeneration;
}

- (void)loadView {
    _refreshRatePopUp = [self popUpButtonWithWidth:kAdvancedPopUpWidth
                                            action:@selector(refreshRateChanged:)];
    NSArray<NSString *> *rateTitles = @[STR_SETTINGS_REFRESH_RATE_LOW,
                                        STR_SETTINGS_REFRESH_RATE_NORMAL,
                                        STR_SETTINGS_REFRESH_RATE_HIGH];
    NSAssert(rateTitles.count == kVibeUIUpdateHzCapPresetCount,
             @"Every refresh-rate preset needs a title");
    for (size_t i = 0; i < kVibeUIUpdateHzCapPresetCount; i++) {
        [_refreshRatePopUp addItemWithTitle:rateTitles[i]];
        _refreshRatePopUp.lastItem.tag = kVibeUIUpdateHzCapPresets[i];
    }

    _resetButton = [NSButton buttonWithTitle:STR_SETTINGS_RESET_DEFAULTS
                                      target:self action:@selector(resetSettings:)];
    _cacheSizeValue = [self valueLabel];
    _clearCacheButton = [NSButton buttonWithTitle:STR_SETTINGS_CLEAR_CACHE
                                           target:self action:@selector(clearCache:)];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_REFRESH_RATE_LABEL control:_refreshRatePopUp],
        ]],
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_CACHE_LABEL
                                 controls:@[_cacheSizeValue, _clearCacheButton]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_FACTORY_RESET_LABEL control:_resetButton],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_BUILD_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_VERSION_LABEL
                                  control:[self valueLabelWithString:NSBundle.mainBundle.vibeVersionString]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_GIT_LABEL
                                  control:[self valueLabelWithString:NSBundle.mainBundle.vibeGitString]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_LANGUAGE_LABEL
                                  control:[self valueLabelWithString:[self currentLanguageText]]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_LANGUAGES_LABEL
                                  control:[self availableLanguagesLabel]],
        ]],
    ]];
}

#pragma mark - Build

// The flag for a language: the region its identifier carries (pt-BR), else
// the one the language is most identified with. nil when neither names one.
static NSString *VibeFlagForLanguage(NSString *language) {
    static NSDictionary<NSString *, NSString *> *regions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regions = @{
            @"bg": @"BG", @"cs": @"CZ", @"da": @"DK", @"de": @"DE",
            @"el": @"GR", @"en": @"US", @"es": @"ES", @"fi": @"FI",
            @"fr": @"FR", @"hr": @"HR", @"hu": @"HU", @"id": @"ID",
            @"it": @"IT", @"ja": @"JP", @"ko": @"KR", @"nb": @"NO",
            @"nl": @"NL", @"pl": @"PL", @"ro": @"RO", @"ru": @"RU",
            @"sk": @"SK", @"sv": @"SE", @"th": @"TH", @"tr": @"TR",
            @"uk": @"UA", @"vi": @"VN", @"zh-Hans": @"CN", @"zh-Hant": @"TW",
        };
    });
    NSString *region = [NSLocale componentsFromLocaleIdentifier:language][NSLocaleCountryCode]
            ?: regions[language];
    if (region.length != 2) {
        return nil;
    }
    UTF32Char indicators[2] = {0x1F1E6 + ([region characterAtIndex:0] - 'A'),
                               0x1F1E6 + ([region characterAtIndex:1] - 'A')};
    return [[NSString alloc] initWithBytes:indicators length:sizeof(indicators)
                                  encoding:NSUTF32LittleEndianStringEncoding];
}

- (NSString *)currentLanguageText {
    NSString *language = NSBundle.mainBundle.preferredLocalizations.firstObject ?: @"en";
    NSString *name = [NSLocale.currentLocale localizedStringForLocaleIdentifier:language] ?: language;
    NSString *flag = VibeFlagForLanguage(language);
    return flag ? [NSString stringWithFormat:@"%@ %@", flag, name] : name;
}

// One flag per shipped .lproj, read from the bundle so the row can never
// drift from what the build actually contains.
- (NSTextField *)availableLanguagesLabel {
    NSMutableArray<NSString *> *flags = [NSMutableArray array];
    for (NSString *language in [NSBundle.mainBundle.localizations
            sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if ([language isEqualToString:@"Base"]) {
            continue;
        }
        NSString *flag = VibeFlagForLanguage(language);
        [flags addObject:flag ?: language];
    }
    NSTextField *label = [NSTextField wrappingLabelWithString:[flags componentsJoinedByString:@" "]];
    label.selectable = NO;
    label.alignment = NSTextAlignmentRight;
    label.preferredMaxLayoutWidth = 240;
    [label.widthAnchor constraintLessThanOrEqualToConstant:240].active = YES;
    return label;
}

- (NSTextField *)valueLabelWithString:(NSString *)string {
    NSTextField *label = [self valueLabel];
    label.stringValue = string;
    return label;
}

// The readouts are informational, so they take the secondary color a System
// Settings value column uses.
- (NSTextField *)valueLabel {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.textColor = NSColor.secondaryLabelColor;
    return label;
}

- (void)refreshFromSettings {
    // The getter snaps to a preset, so this always matches an item.
    [_refreshRatePopUp selectItemWithTag:AppSettings.sharedInstance.uiUpdateHzCap];
    _resetButton.enabled = !AppSettings.sharedInstance.allSettingsAtDefaults;
    [self refreshCacheSize];
}

#pragma mark - Reset to defaults

// The reset only clears the store, so this applies every running-app effect;
// the audio FX graph and output device land at the next launch exactly as
// their captions say. Each pane resolves the rows the reset hid before the
// shared size is retaken, but hidden panes defer their full refresh until
// selected. TRAP: the window's own two settings are cleared by the same pass
// and no pane shows them, so the window is put back to its shipping shape
// separately — that action writes its own state and frame. Without it the
// window keeps a shape the store no longer agrees with and snaps at the next
// launch.
- (void)resetSettings:(id)sender {
    [AppSettings.sharedInstance resetToDefaults];
    MainPlayerController *player = self.playerController;
    [player applySettingsLiveEffects:VibeSettingsLiveEffectAll];
    [player resetWindowToDefaultShape];
    for (__kindof NSViewController *pane in self.parentViewController.childViewControllers) {
        if ([pane isKindOfClass:SettingsPaneViewController.class]) {
            [pane resolveLayoutStateFromSettings];
        }
    }
    [self refreshFromSettings];
    [self paneContentDidChange];
}

#pragma mark - Playhead refresh

- (void)refreshRateChanged:(id)sender {
    AppSettings.sharedInstance.uiUpdateHzCap = _refreshRatePopUp.selectedTag;
    [self.playerController applySettingsLiveEffects:VibeSettingsLiveEffectUIUpdateRate];
}

#pragma mark - Cache

// Sums both stores — metadata and waveform — since "the cache" is one thing
// to the user, exactly as the Clear Cache button and the debug channel's
// clear_caches treat it.
- (void)refreshCacheSize {
    MainPlayerController *player = self.playerController;
    NSUInteger generation = ++_usageRequestGeneration;
    __block NSUInteger totalFiles = 0;
    __block unsigned long long totalBytes = 0;
    __block NSUInteger pending = 2;
    __weak __typeof(self) weakSelf = self;
    void (^accumulate)(NSUInteger, unsigned long long) = ^(NSUInteger fileCount, unsigned long long bytes) {
        totalFiles += fileCount;
        totalBytes += bytes;
        if (--pending == 0) {
            [weakSelf renderCacheSizeFiles:totalFiles bytes:totalBytes generation:generation];
        }
    };
    [player.metadataCache diskUsageWithCompletion:accumulate];
    [player.waveformCache diskUsageWithCompletion:accumulate];
}

- (void)renderCacheSizeFiles:(NSUInteger)files bytes:(unsigned long long)bytes generation:(NSUInteger)generation {
    if (generation != _usageRequestGeneration) {
        return;
    }
    Formatters *formatters = Formatters.sharedInstance;
    _cacheSizeValue.stringValue = [NSString stringWithFormat:STR_SETTINGS_CACHE_VALUE,
            [formatters countString:files],
            [formatters decimalString:(double)bytes / (1000.0 * 1000.0) fractionDigits:1]];
}

- (void)clearCache:(id)sender {
    _clearCacheButton.enabled = NO;
    MainPlayerController *player = self.playerController;
    __block NSUInteger pending = 2;
    __weak __typeof(self) weakSelf = self;
    // The invalidate completions land on the caches' own queues.
    dispatch_block_t done = ^{
        run_on_main_thread({
            if (--pending == 0) {
                __typeof(self) strongSelf = weakSelf;
                if (strongSelf) {
                    strongSelf->_clearCacheButton.enabled = YES;
                    NSTabViewController *tabs = (NSTabViewController *)strongSelf.parentViewController;
                    NSInteger selected = tabs.selectedTabViewItemIndex;
                    BOOL stillSelected = selected >= 0 && selected < (NSInteger)tabs.tabViewItems.count
                            && tabs.tabViewItems[(NSUInteger)selected].viewController == strongSelf;
                    if (stillSelected && strongSelf.view.window.isVisible) {
                        [strongSelf refreshCacheSize];
                    }
                }
            }
        });
    };
    [player.metadataCache invalidateWithCompletion:done];
    [player.waveformCache invalidateWithCompletion:done];
}

@end
