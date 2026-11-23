//
//  VibeiOSAppDelegate.m
//  Vibe (iOS)
//

#import "VibeiOSAppDelegate.h"
#import "AppSettings.h"
#import "AudioAnalysisObservers.h"
#import "AudioError.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "DropboxMirror+Shared.h"
#import "Formatters.h"
#import "LinkStore.h"
#import "LocationStore.h"
#import "NSBundle+BuildInfo.h"
#import "PINCache+VibeAudioCache.h"
#import "SettingsRules.h"
#import "VibePlayerCardHost.h"
#import "VibeStrings.h"
#import "WaveformRendererRegistry.h"
#import "WaveformScrubberView.h"
#import "WaveformTheme+Settings.h"
#if DEBUG
#import "DebugCommonVerbs.h"
#import "DebugiOSEntry.h"
#endif

// The now-playing card asks the app for its words, formats and settings.
static NSString *const kWaveformTempoBackfillKey = @"VibeiOSWaveformTempoBackfilled";

@interface VibeiOSAppDelegate () <VibePlayerCardHost>
@end

@implementation VibeiOSAppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    LogInfo(@"Vibe %@ starting", NSBundle.mainBundle.vibeVersionString);
    VibeLogBuildProvenance();
    // Before the player exists, so every play-path error carries the app's domain.
    VibeAudioErrorSetDomain(NSBundle.mainBundle.bundleIdentifier);
#if DEBUG
    // Before the scene makes the player, which reads its debug output when it
    // makes it.
    VibeDebugApplyLaunchFlags();
#endif
    // Before any scene makes its card.
    VibePlayerCardInstallHost(self);
    // Before any scene names a folder.
    LocationStore.deviceModelName = UIDevice.currentDevice.localizedModel;
    // Before the scene restores a playlist, which may name a mirror file or a
    // link. From here their placeholders are dataless. Opening one downloads
    // it, and its tags are read by range. Opening a folder then does not
    // download it whole.
    [DropboxMirror.shared installAsRemoteBackend];
    [LinkStore.shared installAsRemoteBackend];
    // Off main: the token refresh and the connections the first play would
    // otherwise open, once, and nothing without an account.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [DropboxMirror.shared.client warmUp];
    });
#if DEBUG
    VibeiOSInstallDebugCommandHook();
#endif
    [PINCache removeOtherAudioCacheVersionsKeeping:[AudioTrackMetadataCache.cacheNames arrayByAddingObject:AudioWaveformCache.cacheName]
                                          rootPath:nil
                                        completion:nil];
    [self copyWelcomeTrackIfFirstLaunch];
    return YES;
}

// Once per install, so a user who deletes it from On My iPhone keeps it gone.
- (void)copyWelcomeTrackIfFirstLaunch {
    if (AppSettings.sharedInstance.welcomeTrackSpent) {
        return;
    }
    AppSettings.sharedInstance.welcomeTrackSpent = YES;
    NSURL *source = [NSBundle.mainBundle URLForResource:@"vibe-theme" withExtension:@"mp3"];
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                            inDomains:NSUserDomainMask].firstObject;
    if (!source || !documents) {
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSURL *target = [documents URLByAppendingPathComponent:source.lastPathComponent];
        if (![NSFileManager.defaultManager copyItemAtURL:source toURL:target error:&error]) {
            LogWarn(@"Welcome track not copied: %@", error.localizedDescription);
        }
    });
}

#pragma mark - VibePlayerCardHost

- (NSString *)playerCardLabel:(VibePlayerCardLabel)label {
    switch (label) {
        case VibePlayerCardLabelTimeUnknown: return STR_LABEL_TIME_UNKNOWN;
        case VibePlayerCardLabelBuffering: return STR_LABEL_BUFFERING;
        case VibePlayerCardLabelMinimize: return STR_A11Y_PLAYER_MINIMIZE;
        case VibePlayerCardLabelOutputRoute: return STR_A11Y_PLAYER_OUTPUT_ROUTE;
        case VibePlayerCardLabelWaveform: return STR_A11Y_WAVEFORM;
        case VibePlayerCardLabelTime: return STR_SETTINGS_SECTION_TIME;
        case VibePlayerCardLabelShuffle: return STR_TRANSPORT_SHUFFLE;
        case VibePlayerCardLabelPrevious: return STR_TRANSPORT_PREVIOUS;
        case VibePlayerCardLabelNext: return STR_TRANSPORT_NEXT;
        case VibePlayerCardLabelPlay: return STR_TRANSPORT_PLAY;
        case VibePlayerCardLabelPause: return STR_TRANSPORT_PAUSE;
        case VibePlayerCardLabelFXPill: return STR_PLAYER_FX_PILL;
        case VibePlayerCardLabelFXAxisLowCut: return STR_PLAYER_FX_AXIS_LOW_CUT;
        case VibePlayerCardLabelFXAxisReverbDelay: return STR_PLAYER_FX_AXIS_REVERB_DELAY;
        case VibePlayerCardLabelFXPad: return STR_A11Y_PLAYER_FX_PAD;
        case VibePlayerCardLabelFXPadHint: return STR_A11Y_PLAYER_FX_PAD_HINT;
    }
    return @"";
}

- (NSString *)playerCardRepeatTitle:(VibeRepeatMode)mode {
    return VibeRepeatModeTitle(mode);
}

- (NSString *)playerCardDuration:(NSTimeInterval)duration {
    return [Formatters.sharedInstance durationStringFromTimeInterval:duration];
}

- (NSString *)playerCardFileInfoForItem:(id<VibePlayerCardItem>)item {
    if (!AppSettings.sharedInstance.showFileInfo) {
        return nil;
    }
    return [Formatters.sharedInstance fileInfoLineForMetadata:item.metadata];
}

// The mac's second info line: the tempo, tagged or analyzed, and the key.
// Tagged only, in Camelot, the mac's default notation. Key analysis and the
// notation setting are macOS-only.
- (NSString *)playerCardTempoForItem:(id<VibePlayerCardItem>)item {
    if (!AppSettings.sharedInstance.showFileInfo) {
        return nil;
    }
    return [Formatters.sharedInstance tempoLineWithBPM:item.bpm keyText:VibeMusicalKeyCamelotName(item.key)];
}

- (NSString *)playerCardInfoLineFromFields:(NSArray<NSString *> *)fields {
    return [Formatters.sharedInstance infoLineFromFields:fields];
}

- (BOOL)playerCardShowsRemainingTime {
    return AppSettings.sharedInstance.showRemainingTime;
}

- (void)setPlayerCardShowsRemainingTime:(BOOL)shows {
    AppSettings.sharedInstance.showRemainingTime = shows;
}

- (BOOL)playerCardShowsFXPad {
    return AppSettings.sharedInstance.audioFXEnabled;
}

- (BOOL)playerCardShowsShuffleRepeat {
    return AppSettings.sharedInstance.showShuffleRepeat;
}

// The playhead line is the style's default until the switch is touched
// (Settings/AGENTS.md), decided here as the widget decides its own.
- (void)playerCardConfigureWaveformView:(WaveformScrubberView *)view {
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *style = [WaveformRendererRegistry resolveStyleIdentifier:settings.waveformStyle];
    // A global block, so the assignment costs nothing.
    view.themeProvider = ^WaveformTheme *(BOOL isDark, UIColor *artworkColor) {
        return [WaveformTheme themeForSettings:AppSettings.sharedInstance widget:NO isDark:isDark
                                  artworkColor:artworkColor];
    };
    view.centered = [settings waveformCenteredForWidget:NO];
    view.drawsPlayheadLine = [WaveformRendererRegistry
            drawsPlayheadLineForIdentifier:style chosen:[settings waveformPlayheadLineForWidget:NO]];
    [view syncWaveformStyle:style];
    [view syncWaveformTheme];
}

// No key observer: key detection is macOS-only. The bands are for the card's
// style or the widget's, which bakes from the card's waveform. A nil widget
// style is the card's.
- (UIImage *)playerCardPlaceholderArt {
    return [UIImage imageNamed:@"record-bg"];
}

- (void)playerCardConfigureWaveformCache:(AudioWaveformCache *)cache {
    // Queued before the card's first lookup, so no page reads a waveform
    // cached before its tempo was analyzed.
    if (![NSUserDefaults.standardUserDefaults boolForKey:kWaveformTempoBackfillKey]) {
        [cache invalidateWithCompletion:nil];
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kWaveformTempoBackfillKey];
    }
    cache.analysisProvider = ^VibeWaveformAnalysis{
        AppSettings *settings = AppSettings.sharedInstance;
        return (VibeWaveformAnalysis){
            .bands = [WaveformRendererRegistry readsBandsForIdentifier:settings.waveformStyle]
                  || [WaveformRendererRegistry readsBandsForIdentifier:settings.widgetWaveformStyle],
            .observers = settings.analyzeBPM ? @[AudioBPMAnalyzer.waveformObserver] : @[],
        };
    };
}

@end
