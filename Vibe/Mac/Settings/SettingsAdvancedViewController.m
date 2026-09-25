//
//  SettingsAdvancedViewController.m
//  Vibe
//

#import "SettingsAdvancedViewController.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
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
    // The Audio group: one readout per stage of the render chain, keyed by
    // the stage name the player reports, refreshed once a second while the
    // pane is on screen. The readouts are single-line, so a refresh costs
    // the label's own layout and never a pane solve (Mac/Settings/CLAUDE.md).
    NSDictionary<NSString *, NSTextField *> *_audioPathValues;
    dispatch_source_t _audioPathTimer;
    // The snapshot is a player-queue round trip taken off main; only the
    // newest request may write the readouts, and one is in flight at a time.
    NSUInteger _audioPathGeneration;
    BOOL _audioPathInFlight;
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
    NSArray<NSArray<NSString *> *> *audioStages = @[
        @[@"source", STR_SETTINGS_AUDIO_PATH_SOURCE], @[@"decode", STR_SETTINGS_AUDIO_PATH_DECODE],
        @[@"bus", STR_SETTINGS_AUDIO_PATH_BUS], @[@"varispeed", STR_SETTINGS_AUDIO_PATH_PITCH],
        @[@"fx", STR_SETTINGS_AUDIO_PATH_FX], @[@"meter", STR_SETTINGS_AUDIO_PATH_METER],
        @[@"output", STR_SETTINGS_AUDIO_PATH_OUTPUT], @[@"device", STR_SETTINGS_AUDIO_PATH_DEVICE],
    ];
    NSMutableDictionary<NSString *, NSTextField *> *audioValues = [NSMutableDictionary dictionary];
    NSMutableArray<SettingsRowView *> *audioRows = [NSMutableArray array];
    for (NSArray<NSString *> *stage in audioStages) {
        NSTextField *value = [self audioPathValueLabel];
        audioValues[stage[0]] = value;
        [audioRows addObject:[SettingsRowView rowWithTitle:stage[1] control:value]];
    }
    _audioPathValues = audioValues;

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
        [SettingsSectionView sectionWithHeader:STR_SETTINGS_AUDIO_PATH_SECTION rows:audioRows],
    ]];
}

- (void)dealloc {
    [self stopAudioPathTimer];
}

#pragma mark - The audio path

// A readout that stays one line whatever the stage reports, so a change
// costs the label's own layout and never the pane's: the title wins the
// width and the value truncates at its tail.
- (NSTextField *)audioPathValueLabel {
    NSTextField *label = [self valueLabel];
    label.alignment = NSTextAlignmentRight;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = 1;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label.widthAnchor constraintLessThanOrEqualToConstant:640].active = YES; // the device row's six columns at their longest
    return label;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self refreshAudioPath];
    [self startAudioPathTimer];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self stopAudioPathTimer];
}

- (void)startAudioPathTimer {
    if (_audioPathTimer) {
        return;
    }
    _audioPathTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_audioPathTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    __weak __typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_audioPathTimer, ^{ [weakSelf refreshAudioPath]; });
    dispatch_resume(_audioPathTimer);
}

- (void)stopAudioPathTimer {
    if (_audioPathTimer) {
        dispatch_source_cancel(_audioPathTimer);
        _audioPathTimer = nil;
    }
}

static NSString *VibeAudioPathJoin(NSArray<NSString *> *parts) {
    return [parts componentsJoinedByString:VibeNotLocalized(@" · ")];
}

// A channel description, for the decoder's mixing readout.
static NSString *VibeAudioPathChannels(NSUInteger channels) {
    if (channels == 1) return STR_SETTINGS_AUDIO_PATH_MONO;
    if (channels == 2) return STR_SETTINGS_AUDIO_PATH_STEREO;
    return [NSString stringWithFormat:STR_SETTINGS_AUDIO_PATH_CHANNELS, [Formatters.sharedInstance countString:channels]];
}

// A row's channel column.
static NSString *VibeAudioPathChannelCount(NSUInteger channels) {
    return [NSString stringWithFormat:STR_SETTINGS_AUDIO_PATH_CHANNEL_COUNT, [Formatters.sharedInstance countString:channels]];
}

static NSString *VibeAudioPathDepth(NSUInteger bits, BOOL isFloat) {
    if (isFloat) return STR_SETTINGS_AUDIO_PATH_FLOAT;
    return [NSString stringWithFormat:STR_SETTINGS_AUDIO_PATH_BITS, [Formatters.sharedInstance countString:bits]];
}

static NSString *VibeAudioPathSampleFormat(NSString *name) {
    return [name isEqualToString:@"int16"] ? STR_SETTINGS_AUDIO_PATH_INT16 : STR_SETTINGS_AUDIO_PATH_FLOAT;
}

// One row, the same shape for every stage: name · rate · depth · channels ·
// status · latency, each column present only where the stage has one, so the
// rows read across. The latency is the stage's own, and only a stage in the
// render has one.
static NSString *VibeAudioPathRow(NSString *name, NSString *rate, NSString *depth, NSString *channels, NSString *status,
                                  NSNumber *latencySeconds) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *column in @[name ?: @"", rate ?: @"", depth ?: @"", channels ?: @"", status ?: @""]) {
        if (column.length) [parts addObject:column];
    }
    if (latencySeconds != nil) {
        [parts addObject:[NSString stringWithFormat:STR_SETTINGS_AUDIO_PATH_LATENCY,
                          [Formatters.sharedInstance decimalString:latencySeconds.doubleValue * 1000 fractionDigits:1]]];
    }
    return VibeAudioPathJoin(parts);
}

// The format the stages that carry the signal unchanged — the pitch, the
// effects, the meter — read and write: the bus's while one exists, else the
// output's, which the bus is built at.
static NSDictionary<NSString *, id> *VibeAudioPathCarrierFormat(NSArray<NSDictionary<NSString *, id> *> *path) {
    NSDictionary *output = nil;
    for (NSDictionary *stage in path) {
        if ([stage[@"stage"] isEqualToString:@"bus"] && [stage[@"present"] boolValue]) return stage;
        if ([stage[@"stage"] isEqualToString:@"output"]) output = stage;
    }
    return output;
}

// One line per stage from the facts the player reports (AudioPlayer.h's
// audioPathSnapshot); the keys are the model's.
- (NSString *)audioPathTextForStage:(NSDictionary<NSString *, id> *)stage inPath:(NSArray<NSDictionary<NSString *, id> *> *)path {
    Formatters *formatters = Formatters.sharedInstance;
    NSString *name = stage[@"stage"];
    BOOL present = [stage[@"present"] boolValue];
    NSString *rate = [formatters sampleRateString:[stage[@"sampleRate"] doubleValue]];
    NSDictionary *carrier = VibeAudioPathCarrierFormat(path);
    NSString *carrierRate = [formatters sampleRateString:[carrier[@"sampleRate"] doubleValue]];
    NSString *carrierChannels = VibeAudioPathChannelCount([carrier[@"channels"] unsignedIntegerValue]);
    if ([name isEqualToString:@"source"]) {
        if (!present) return STR_SETTINGS_AUDIO_PATH_NONE;
        NSUInteger bits = [stage[@"bitsPerChannel"] unsignedIntegerValue];
        BOOL isFloat = [stage[@"float"] boolValue];
        return VibeAudioPathRow(stage[@"codec"], rate, bits || isFloat ? VibeAudioPathDepth(bits, isFloat) : nil,
                                VibeAudioPathChannelCount([stage[@"channels"] unsignedIntegerValue]), nil, nil);
    }
    if ([name isEqualToString:@"decode"]) {
        if (!present) return STR_SETTINGS_AUDIO_PATH_NONE;
        NSMutableArray<NSString *> *status = [NSMutableArray array];
        if ([stage[@"read"] isEqualToString:@"direct"]) {
            [status addObject:STR_SETTINGS_AUDIO_PATH_DIRECT];
        }
        if ([stage[@"resampled"] boolValue]) {
            [status addObject:[NSString stringWithFormat:STR_SETTINGS_AUDIO_PATH_RESAMPLED,
                               [formatters sampleRateString:[stage[@"fromSampleRate"] doubleValue]],
                               [formatters sampleRateString:[stage[@"toSampleRate"] doubleValue]]]];
        }
        if ([stage[@"mixed"] boolValue]) {
            [status addObject:[NSString stringWithFormat:STR_SETTINGS_AUDIO_PATH_MIXED,
                               VibeAudioPathChannels([stage[@"fromChannels"] unsignedIntegerValue]),
                               VibeAudioPathChannels([stage[@"toChannels"] unsignedIntegerValue])]];
        }
        return VibeAudioPathRow(nil, rate, VibeAudioPathSampleFormat(stage[@"toSampleFormat"] ?: stage[@"sampleFormat"]),
                                VibeAudioPathChannelCount([stage[@"channels"] unsignedIntegerValue]), VibeAudioPathJoin(status), nil);
    }
    if ([name isEqualToString:@"bus"]) {
        if (!present) return STR_SETTINGS_AUDIO_PATH_NONE;
        return VibeAudioPathRow(nil, rate, STR_SETTINGS_AUDIO_PATH_FLOAT, VibeAudioPathChannelCount([stage[@"channels"] unsignedIntegerValue]),
                                [NSString stringWithFormat:STR_SETTINGS_AUDIO_PATH_VOICES,
                                 [formatters countString:[stage[@"liveVoices"] unsignedIntegerValue]]], @0);
    }
    if ([name isEqualToString:@"varispeed"]) {
        BOOL engaged = present && [stage[@"engaged"] boolValue];
        return VibeAudioPathRow(engaged ? [formatters signedPercentString:[stage[@"pitch"] doubleValue]] : nil,
                                carrierRate, STR_SETTINGS_AUDIO_PATH_FLOAT, carrierChannels,
                                engaged ? STR_SETTINGS_AUDIO_PATH_ON : STR_SETTINGS_AUDIO_PATH_OFF,
                                @(engaged ? [stage[@"latencySeconds"] doubleValue] : 0));
    }
    if ([name isEqualToString:@"fx"]) {
        if (!present || ![stage[@"connected"] boolValue]) {
            return VibeAudioPathRow(nil, carrierRate, STR_SETTINGS_AUDIO_PATH_FLOAT, carrierChannels, STR_SETTINGS_AUDIO_PATH_OFF, @0);
        }
        NSDictionary *stages = stage[@"stages"];
        NSMutableArray<NSString *> *active = [NSMutableArray array];
        if ([stages[@"lowKill"][@"active"] boolValue]) [active addObject:STR_MENU_FX_LOW_KILL];
        if ([stages[@"reverb"][@"active"] boolValue]) [active addObject:STR_MENU_FX_REVERB];
        if ([stages[@"delay"][@"active"] boolValue]) [active addObject:STR_MENU_FX_DELAY_8];
        if ([stages[@"shortDelay"][@"active"] boolValue]) [active addObject:STR_MENU_FX_DELAY_16];
        return VibeAudioPathRow(active.count ? [NSListFormatter localizedStringByJoiningStrings:active] : nil,
                                carrierRate, STR_SETTINGS_AUDIO_PATH_FLOAT, carrierChannels,
                                active.count ? STR_SETTINGS_AUDIO_PATH_ON : STR_SETTINGS_AUDIO_PATH_NOTHING_ACTIVE,
                                @([stage[@"latencySeconds"] doubleValue]));
    }
    if ([name isEqualToString:@"meter"]) {
        BOOL on = present && [stage[@"inRender"] boolValue];
        return VibeAudioPathRow(nil, present ? rate : carrierRate, STR_SETTINGS_AUDIO_PATH_FLOAT, carrierChannels,
                                on ? STR_SETTINGS_AUDIO_PATH_ON : STR_SETTINGS_AUDIO_PATH_OFF, @0);
    }
    if ([name isEqualToString:@"output"]) {
        NSString *activity = ![stage[@"running"] boolValue] ? STR_SETTINGS_AUDIO_PATH_IDLE
                : [stage[@"idleStopPending"] boolValue] ? STR_SETTINGS_AUDIO_PATH_WAITING_TO_IDLE : STR_SETTINGS_AUDIO_PATH_RUNNING;
        return VibeAudioPathRow(nil, rate, STR_SETTINGS_AUDIO_PATH_FLOAT, VibeAudioPathChannelCount([stage[@"channels"] unsignedIntegerValue]),
                                activity, stage[@"bufferLatency"]);
    }
    if ([name isEqualToString:@"device"]) {
        if (!present) return STR_SETTINGS_AUDIO_PATH_NONE;
        NSUInteger bits = [stage[@"physicalBitsPerChannel"] unsignedIntegerValue];
        NSUInteger channels = [stage[@"physicalChannels"] unsignedIntegerValue];
        NSDictionary *bitPerfect = stage[@"bitPerfect"];
        NSMutableArray<NSString *> *status = [NSMutableArray array];
        if ([bitPerfect[@"enabled"] boolValue] && [bitPerfect[@"status"] isEqualToString:@"active"]) [status addObject:STR_SETTINGS_BIT_PERFECT];
        if ([stage[@"exclusive"] boolValue]) [status addObject:STR_SETTINGS_EXCLUSIVE_OUTPUT];
        return VibeAudioPathRow(stage[@"name"], [formatters sampleRateString:[stage[@"nominalSampleRate"] doubleValue]],
                                bits ? VibeAudioPathDepth(bits, [stage[@"physicalFloat"] boolValue]) : nil,
                                channels ? VibeAudioPathChannelCount(channels) : nil, VibeAudioPathJoin(status), stage[@"latencySeconds"]);
    }
    return @"";
}

// TRAP: the snapshot waits on the player queue, which a device rebind or a
// device that stopped answering holds for seconds — the acceptance matrix's
// dead-device cases hold it 14 s — so it is never taken on main: a
// dispatch_sync here beachballed the app for the length of the teardown.
- (void)refreshAudioPath {
    AudioPlayer *player = self.playerController.audioPlayer;
    if (!player || !self.view.window.isVisible || _audioPathInFlight) {
        return;
    }
    NSUInteger generation = ++_audioPathGeneration;
    _audioPathInFlight = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary<NSString *, id> *> *path = player.audioPathSnapshot;
        dispatch_async(dispatch_get_main_queue(), ^{
            __typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            strongSelf->_audioPathInFlight = NO;
            if (generation == strongSelf->_audioPathGeneration) {
                [strongSelf applyAudioPath:path];
            }
        });
    });
}

- (void)applyAudioPath:(NSArray<NSDictionary<NSString *, id> *> *)path {
    for (NSDictionary *stage in path) {
        NSTextField *label = _audioPathValues[stage[@"stage"]];
        NSString *text = [self audioPathTextForStage:stage inPath:path];
        if (label && ![label.stringValue isEqualToString:text]) {
            label.stringValue = text;
            label.toolTip = text;
        }
    }
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
    [self refreshAudioPath];
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
