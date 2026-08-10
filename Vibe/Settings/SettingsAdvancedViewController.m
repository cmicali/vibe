//
//  SettingsAdvancedViewController.m
//  Vibe
//

#import "SettingsAdvancedViewController.h"
#import "AppStats.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "Formatters.h"
#import "MainPlayerController.h"
#import "VibeStrings.h"

static const CGFloat kAdvancedPaneHeight = 260;

@implementation SettingsAdvancedViewController {
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
    _cacheSizeValue = [NSTextField labelWithString:@""];
    _clearCacheButton = [NSButton buttonWithTitle:STR_SETTINGS_CLEAR_CACHE
                                           target:self action:@selector(clearCache:)];
    _filesOpenedValue = [NSTextField labelWithString:@""];
    _foldersOpenedValue = [NSTextField labelWithString:@""];
    _audioPlayedValue = [NSTextField labelWithString:@""];

    NSGridView *grid = [self.class formGridWithRows:@[
        @[[NSTextField labelWithString:STR_SETTINGS_CACHE_LABEL], _cacheSizeValue],
        @[NSGridCell.emptyContentView, _clearCacheButton],
        @[[NSTextField labelWithString:STR_SETTINGS_FILES_OPENED_LABEL], _filesOpenedValue],
        @[[NSTextField labelWithString:STR_SETTINGS_FOLDERS_OPENED_LABEL], _foldersOpenedValue],
        @[[NSTextField labelWithString:STR_SETTINGS_AUDIO_PLAYED_LABEL], _audioPlayedValue],
    ]];
    [self loadPaneWithSize:NSMakeSize(kSettingsPaneWidth, kAdvancedPaneHeight) grid:grid];
}

- (void)refreshFromSettings {
    [self refreshCacheSize];
    [self refreshPlaybackStats];
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
