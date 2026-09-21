//
//  SettingsAdvancedViewController.m
//  Vibe
//

#import "SettingsAdvancedViewController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "DebugInfo.h"
#import "Formatters.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Window.h"
#import "NSBundle+BuildInfo.h"
#import "OutputDevicesMenuController.h"
#import "VibeStrings.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const CGFloat kAdvancedPopUpWidth = 200;

// The rate ladder lives in AppSettings+Mac.h (kVibeUIUpdateHzCapPresets), like
// the Playback pane's, because the getter snaps a persisted value to it.

@implementation SettingsAdvancedViewController {
    NSPopUpButton *_refreshRatePopUp;
    NSButton *_resetButton;
    NSButton *_factoryResetButton;
    NSTextField *_cacheSizeValue;
    NSButton *_clearCacheButton;
    NSButton *_debugInfoButton;
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
    _factoryResetButton = [NSButton buttonWithTitle:STR_SETTINGS_FACTORY_RESET_LABEL
                                             target:self action:@selector(resetSettings:)];
    _cacheSizeValue = [self valueLabel];
    _clearCacheButton = [NSButton buttonWithTitle:STR_SETTINGS_CLEAR_CACHE
                                           target:self action:@selector(clearCache:)];
    _debugInfoButton = [NSButton buttonWithTitle:STR_SETTINGS_DEBUG_INFO_SAVE
                                          target:self action:@selector(saveDebugInfo:)];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_REFRESH_RATE_LABEL control:_refreshRatePopUp],
        ]],
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_CACHE_LABEL
                                 controls:@[_cacheSizeValue, _clearCacheButton]],
            [SettingsRowView rowWithTitle:STR_SETTINGS_RESET_LABEL
                                 caption:STR_SETTINGS_RESET_CAPTION control:_resetButton],
            [SettingsRowView rowWithTitle:STR_SETTINGS_FACTORY_RESET_LABEL
                                 caption:STR_SETTINGS_FACTORY_RESET_CAPTION control:_factoryResetButton],
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
            [SettingsRowView rowWithTitle:STR_SETTINGS_DEBUG_INFO_LABEL
                                  caption:STR_SETTINGS_DEBUG_INFO_CAPTION control:_debugInfoButton],
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
    [SettingsRowView setControl:_resetButton enabled:!AppSettings.sharedInstance.allSettingsAtDefaults];
    [SettingsRowView setControl:_factoryResetButton enabled:_resetButton.enabled
            || AppSettings.sharedInstance.orderedThemeIdentifiers.count > AppTheme.builtInThemeIdentifiers.count];
    [self refreshCacheSize];
}

#pragma mark - Debug info

// Saved where the user picks, which the sandbox already allows, then revealed,
// because the next step is always attaching it somewhere. The snapshot is taken
// on main at the click; everything slow runs off main, so a report can be saved
// in the middle of the stall it is about.
- (void)saveDebugInfo:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    NSDateFormatter *stamp = [[NSDateFormatter alloc] init];
    stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    stamp.dateFormat = @"yyyy-MM-dd HH.mm.ss";
    panel.nameFieldStringValue = [NSString stringWithFormat:VibeNotLocalized(@"Vibe Debug Info %@.txt"),
                                  [stamp stringFromDate:NSDate.date]];
    panel.allowedContentTypes = @[UTTypePlainText];
    MainPlayerController *controller = self.playerController;
    NSButton *button = _debugInfoButton;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        NSURL *url = panel.URL;
        if (response != NSModalResponseOK || !url) {
            return;
        }
        NSDictionary *snapshot = VibeDebugInfoSnapshot(controller);
        AudioPlayer *player = controller.audioPlayer;
        [SettingsRowView setControl:button enabled:NO];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            BOOL written = [VibeDebugInfoText(snapshot, player) writeToURL:url atomically:YES
                                                                  encoding:NSUTF8StringEncoding error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                [SettingsRowView setControl:button enabled:YES];
                if (written) {
                    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[url]];
                } else {
                    LogError(@"Debug info: could not write %@: %@", url.path, error);
                    [button.window presentError:error];
                }
            });
        });
    }];
}

#pragma mark - Reset to defaults

// Hidden panes resolve layout before remeasurement but defer their full refresh.
// TRAP: reset clears both window-shape settings; no pane applies them, so
// restore the window separately or its shape disagrees with the store until launch.
- (void)resetSettings:(id)sender {
    if (sender == _factoryResetButton) {
        [AppSettings.sharedInstance factoryReset];
    } else {
        [AppSettings.sharedInstance resetToDefaults];
    }
    MainPlayerController *player = self.playerController;
    [player applySettingsLiveEffects:VibeSettingsLiveEffectAll];
    // TRAP: a cleared device UID with the old binding leaves mode switches
    // enabled for a device their setters cannot write to.
    [player.devicesMenuController selectOutputDevice:-1];
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
    [SettingsRowView setControl:_clearCacheButton enabled:NO];
    MainPlayerController *player = self.playerController;
    __block NSUInteger pending = 2;
    __weak __typeof(self) weakSelf = self;
    // The invalidate completions land on the caches' own queues.
    dispatch_block_t done = ^{
        run_on_main_thread({
            if (--pending == 0) {
                __typeof(self) strongSelf = weakSelf;
                if (strongSelf) {
                    [SettingsRowView setControl:strongSelf->_clearCacheButton enabled:YES];
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
