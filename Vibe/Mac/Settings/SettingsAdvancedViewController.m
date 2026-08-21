//
//  SettingsAdvancedViewController.m
//  Vibe
//

#import "SettingsAdvancedViewController.h"
#import "AppSettings.h"
#import "AppStats.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "Formatters.h"
#import "MainPlayerController.h"
#import "VibeStrings.h"

static const CGFloat kAdvancedPopUpWidth = 200;

// The rate ladder lives in AppSettings.h (kVibeUIUpdateHzCapPresets), like the
// Playback pane's, because the getter snaps a persisted value to it.

@implementation SettingsAdvancedViewController {
    NSPopUpButton *_refreshRatePopUp;
    NSTextField *_cacheSizeValue;
    NSButton *_clearCacheButton;
    NSTextField *_filesOpenedValue;
    NSTextField *_foldersOpenedValue;
    NSTextField *_audioPlayedValue;
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

    _cacheSizeValue = [self valueLabel];
    _clearCacheButton = [NSButton buttonWithTitle:STR_SETTINGS_CLEAR_CACHE
                                           target:self action:@selector(clearCache:)];
    _filesOpenedValue = [self valueLabel];
    _foldersOpenedValue = [self valueLabel];
    _audioPlayedValue = [self valueLabel];

    [self loadPaneWithSections:@[
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_REFRESH_RATE_LABEL control:_refreshRatePopUp],
        ]],
        [SettingsSectionView sectionWithRows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_CACHE_LABEL
                                 controls:@[_cacheSizeValue, _clearCacheButton]],
        ]],
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_STATS_SECTION rows:@[
            [SettingsRowView rowWithTitle:STR_SETTINGS_FILES_OPENED_LABEL control:_filesOpenedValue],
            [SettingsRowView rowWithTitle:STR_SETTINGS_FOLDERS_OPENED_LABEL control:_foldersOpenedValue],
            [SettingsRowView rowWithTitle:STR_SETTINGS_AUDIO_PLAYED_LABEL control:_audioPlayedValue],
        ]],
    ]];
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
    [self refreshCacheSize];
    [self refreshPlaybackStats];
}

#pragma mark - Playhead refresh

- (void)refreshRateChanged:(id)sender {
    AppSettings.sharedInstance.uiUpdateHzCap = _refreshRatePopUp.selectedTag;
    // The live half: the timer re-arms at once, without waiting for the next
    // track start or resize to recompute the rate.
    [self.playerController syncUITimerRate];
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
        dispatch_async(dispatch_get_main_queue(), ^{
            if (--pending == 0) {
                __typeof(self) strongSelf = weakSelf;
                if (strongSelf) {
                    strongSelf->_clearCacheButton.enabled = YES;
                    [strongSelf refreshCacheSize];
                }
            }
        });
    };
    [player.metadataCache invalidateWithCompletion:done];
    [player.waveformCache invalidateWithCompletion:done];
}

#pragma mark - Playback statistics

- (void)refreshPlaybackStats {
    AppStats *stats = AppStats.sharedInstance;
    Formatters *formatters = Formatters.sharedInstance;
    _filesOpenedValue.stringValue = [formatters countString:stats.totalFilesOpened];
    _foldersOpenedValue.stringValue = [formatters countString:stats.totalFoldersOpened];
    _audioPlayedValue.stringValue = [formatters spelledDurationString:stats.totalSecondsPlayed];
}

@end
