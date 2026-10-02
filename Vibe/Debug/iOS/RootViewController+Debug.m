//
//  RootViewController+Debug.m
//  Vibe (iOS)
//
//  Composes the model's handles (PlaybackController+Debug), the chrome and art
//  window (PlayerViewController+Debug) and the shell's own tab and card state.
//

#import "RootViewController+Debug.h"

#if DEBUG

// The search screen's section order, whose enum is private to it.
static const NSInteger VibeDebugSearchFilesSection = 1;

#import "PlaybackController+Debug.h"
#import "PlayerViewController+Debug.h"

#import "AppSettings.h"
#import "SettingsRules.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "FavoritesStore.h"
#import "LibraryViewController.h"
#import "SearchViewController.h"
#import "DebugCommonVerbs.h"
#import "PlaybackController.h"
#import "AudioFX.h"
#import "Playlist.h"

// The layout probe's series: samples taken on a display link between
// sample_layout_anchors and dump_layout_anchors.
static NSMutableArray<NSDictionary *> *sLayoutSamples;
static CADisplayLink *sLayoutSampler;
static CFTimeInterval sLayoutSamplingEndsAt;

static NSArray<NSNumber *> *VibeRectArray(CGRect rect) {
    return @[@(rect.origin.x), @(rect.origin.y), @(rect.size.width), @(rect.size.height)];
}

// The first label under `view` reading `text`, depth first.
static UILabel *VibeLabelWithText(UIView *view, NSString *text) {
    if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text isEqualToString:text]) {
        return (UILabel *)view;
    }
    for (UIView *subview in view.subviews) {
        UILabel *label = VibeLabelWithText(subview, text);
        if (label) {
            return label;
        }
    }
    return nil;
}

// The frame-rate probe: a display link asking for the display's full rate,
// counting what it is granted and how often a frame ran long. The answer to
// "is this 60 or 120, and does it hitch" that the simulator cannot give.
static CADisplayLink *sFrameProbe;
static CFTimeInterval sFrameProbeStartedAt;
static CFTimeInterval sFrameProbeLastAt;
static CFTimeInterval sFrameProbeEndsAt;
static CFTimeInterval sFrameProbeWorstInterval;
static NSUInteger sFrameProbeFrames;
static NSUInteger sFrameProbeHitches;
static BOOL sFrameProbeLogs;

@implementation RootViewController (Debug)

- (void)debugBeginFrameProbeForSeconds:(NSTimeInterval)seconds logging:(BOOL)logging {
    [sFrameProbe invalidate];
    sFrameProbeStartedAt = CACurrentMediaTime();
    sFrameProbeLastAt = 0;
    sFrameProbeEndsAt = seconds > 0 ? sFrameProbeStartedAt + seconds : 0;
    sFrameProbeWorstInterval = 0;
    sFrameProbeFrames = 0;
    sFrameProbeHitches = 0;
    sFrameProbeLogs = logging;
    sFrameProbe = [CADisplayLink displayLinkWithTarget:self selector:@selector(debugProbeFrame:)];
    sFrameProbe.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    [sFrameProbe addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)debugProbeFrame:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    if (sFrameProbeLastAt > 0) {
        CFTimeInterval interval = now - sFrameProbeLastAt;
        sFrameProbeWorstInterval = MAX(sFrameProbeWorstInterval, interval);
        // A frame that took two of the granted periods or more.
        if (interval >= 2 * (link.targetTimestamp - now) + 0.001) {
            sFrameProbeHitches++;
        }
    }
    sFrameProbeLastAt = now;
    sFrameProbeFrames++;
    // The launch flag's continuous probe logs a window every five seconds.
    if (sFrameProbeLogs && now - sFrameProbeStartedAt >= 5) {
        NSDictionary *report = [self debugFrameProbeReport];
        LogInfo(@"Frame probe: %@ Hz over %@ s, %@ hitches, worst %@ ms",
                report[@"averageHz"], report[@"seconds"], report[@"hitches"], report[@"worstIntervalMs"]);
        sFrameProbeStartedAt = now;
        sFrameProbeFrames = 0;
        sFrameProbeHitches = 0;
        sFrameProbeWorstInterval = 0;
    }
    if (sFrameProbeEndsAt > 0 && now >= sFrameProbeEndsAt) {
        [link invalidate];
        sFrameProbe = nil;
    }
}

- (NSDictionary *)debugFrameProbeReport {
    CFTimeInterval seconds = (sFrameProbeLastAt ?: CACurrentMediaTime()) - sFrameProbeStartedAt;
    double hz = seconds > 0 && sFrameProbeFrames > 1 ? (sFrameProbeFrames - 1) / seconds : 0;
    return @{@"sampling": @(sFrameProbe != nil),
             @"frames": @(sFrameProbeFrames),
             @"seconds": @(round(seconds * 100) / 100),
             @"averageHz": @(round(hz * 10) / 10),
             @"hitches": @(sFrameProbeHitches),
             @"worstIntervalMs": @(round(sFrameProbeWorstInterval * 10000) / 10),
             // 120 only when the app may draw at it: an iPhone caps an app
             // at 60 without CADisableMinimumFrameDurationOnPhone.
             @"maximumHz": @(self.view.window.screen.maximumFramesPerSecond)};
}

// Where the selected tab's chrome and first row sit in the window, read from
// the LIVE views: under a moving card they must not move at all, since what
// scales is a snapshot. Window coordinates, so a shift of any kind shows.
- (NSDictionary *)debugLayoutAnchors {
    NSMutableDictionary *anchors = [NSMutableDictionary dictionary];
    UIViewController *selected = self.tabs.selectedViewController;
    UINavigationController *navigation = [selected isKindOfClass:UINavigationController.class]
            ? (UINavigationController *)selected : selected.navigationController;
    UIViewController *top = navigation.topViewController ?: selected;
    UINavigationBar *bar = navigation.navigationBar;
    if (bar.window) {
        anchors[@"navigationBar"] = VibeRectArray([bar convertRect:bar.bounds toView:nil]);
        UILabel *title = VibeLabelWithText(bar, top.navigationItem.title ?: @"");
        if (title) {
            anchors[@"title"] = VibeRectArray([title convertRect:title.bounds toView:nil]);
        }
    }
    UITableView *table = [top isKindOfClass:UITableViewController.class]
            ? ((UITableViewController *)top).tableView : nil;
    UITableViewCell *firstRow = table.visibleCells.firstObject;
    if (firstRow) {
        anchors[@"firstRow"] = VibeRectArray([firstRow convertRect:firstRow.bounds toView:nil]);
        anchors[@"contentOffsetY"] = @(table.contentOffset.y);
    }
    UITabBar *tabBar = self.tabs.tabBar;
    if (tabBar.window) {
        anchors[@"tabBar"] = VibeRectArray([tabBar convertRect:tabBar.bounds toView:nil]);
    }
    UIView *strip = self.miniPlayerView;
    if (strip.window) {
        anchors[@"strip"] = VibeRectArray([strip convertRect:strip.bounds toView:nil]);
    }
    anchors[@"tabsHidden"] = @(self.tabs.view.hidden);
    anchors[@"backdropScale"] = @(self.backdropScale);
    anchors[@"cardOffset"] = @(self.cardOffset);
    anchors[@"time"] = @(CACurrentMediaTime());
    return anchors;
}

- (void)debugBeginLayoutSamplingForSeconds:(NSTimeInterval)seconds hertz:(NSInteger)hertz {
    [sLayoutSampler invalidate];
    sLayoutSamples = [NSMutableArray array];
    sLayoutSamplingEndsAt = CACurrentMediaTime() + seconds;
    sLayoutSampler = [CADisplayLink displayLinkWithTarget:self selector:@selector(debugSampleLayout:)];
    sLayoutSampler.preferredFrameRateRange = CAFrameRateRangeMake((float)hertz, (float)hertz, (float)hertz);
    [sLayoutSampler addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)debugSampleLayout:(CADisplayLink *)link {
    [sLayoutSamples addObject:[self debugLayoutAnchors]];
    if (CACurrentMediaTime() >= sLayoutSamplingEndsAt) {
        [link invalidate];
        sLayoutSampler = nil;
    }
}

- (NSDictionary *)debugLayoutSamples {
    return @{@"sampling": @(sLayoutSampler != nil),
             @"samples": [sLayoutSamples copy] ?: @[]};
}

- (NSDictionary *)debugStateDictionary {
    NSMutableDictionary *state = VibeDebugCommonStateDictionary(self);
    PlaybackController *playback = self.playback;
    NSMutableDictionary *ui = [[self.player debugChromeDictionary] mutableCopy];
    ui[@"screenState"] = @(playback.screenState);
    ui[@"parked"] = @(playback.debugParked);
    ui[@"trackStartPending"] = @(playback.debugTrackStartPending);
    // Including a seek parked on a metadata delivery, which nothing on screen
    // shows.
    ui[@"seekInFlight"] = @(playback.seekInFlight);
    ui[@"pendingSeekProgress"] = @(playback.pendingSeekProgress);
    ui[@"error"] = playback.errorText ?: @"";
    // Beside the indicator's drawn route, so the publish path is checkable end
    // to end.
    ui[@"outputRoute"] = @{
        @"kind": @(playback.outputRouteKind),
        @"name": playback.outputRouteName ?: @"",
    };
    ui[@"playerPresentation"] = self.isPlayerExpanded ? @"full" : @"minimized";
    ui[@"miniPlayerShown"] = @(self.isMiniPlayerShown);
    ui[@"selectedTab"] = self.selectedTabIdentifier;
    ui[@"libraryEmpty"] = @(playback.playlist.count == 0);
    state[@"ui"] = ui;
    state[@"settings"] = @{
        @"waveformStyle": AppSettings.sharedInstance.waveformStyle ?: @"",
        @"widgetWaveformStyle": AppSettings.sharedInstance.widgetWaveformStyle ?: (id)NSNull.null,
        @"waveformTheme": AppSettings.sharedInstance.waveformTheme,
        @"folderOpenSort": VibeFolderOpenSortIdentifier(AppSettings.sharedInstance.folderOpenSort),
        @"pauseAtTrackEnd": @(AppSettings.sharedInstance.pauseAtTrackEnd),
        @"repeatMode": VibeRepeatModeIdentifier(AppSettings.sharedInstance.repeatMode),
        @"shuffleEnabled": @(AppSettings.sharedInstance.shuffleEnabled),
        @"crossfadeMilliseconds": @(AppSettings.sharedInstance.crossfadeMilliseconds),
        @"audioFXEnabled": @(AppSettings.sharedInstance.audioFXEnabled),
        @"analyzeBPM": @(AppSettings.sharedInstance.analyzeBPM),
    };
    // The gate on every write to the shared container, so a widget test
    // asserts it first.
    state[@"widget"] = @{ @"placed": @(playback.debugWidgetPlaced) };
    return state;
}

- (void)debugSetWaveformZoom:(CGFloat)fraction {
    [self.player debugSetWaveformZoom:fraction];
}

- (BOOL)debugTapFavoriteStar {
    // No library means the Playlist tab, and its star, was never built.
    LibraryViewController *library = self.library;
    if (!library || !self.playback.folderURL) {
        return NO;
    }
    [library favoriteTapped];
    return YES;
}

// The files half answers off a walk and a background match, so this re-reads
// the table until its row counts stop moving, bounded so a stalled provider
// ends the command rather than the client timeout.
- (BOOL)debugSearchQuery:(NSString *)query
              completion:(void (^)(NSDictionary *result))completion {
    SearchViewController *screen = self.searchScreen;
    if (!screen) {
        return NO;
    }
    [screen setQueryText:query];
    [self debugPollSearchTable:screen query:query
                     lastCounts:nil stableRounds:0 roundsLeft:40
                     completion:completion];
    return YES;
}

- (void)debugPollSearchTable:(SearchViewController *)screen
                       query:(NSString *)query
                  lastCounts:(NSArray<NSNumber *> *)lastCounts
                stableRounds:(NSUInteger)stableRounds
                  roundsLeft:(NSUInteger)roundsLeft
                  completion:(void (^)(NSDictionary *result))completion {
    UITableView *table = screen.tableView;
    NSMutableArray<NSNumber *> *counts = [NSMutableArray array];
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        [counts addObject:@([table numberOfRowsInSection:section])];
    }
    NSUInteger stable = [counts isEqualToArray:lastCounts] ? stableRounds + 1 : 0;
    // Two quiet rounds, because a batch can land between any two of them.
    if ((stable >= 2 && !screen.isBuildingFileIndex) || roundsLeft == 0) {
        completion([self debugSearchResultForScreen:screen query:query counts:counts]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self debugPollSearchTable:screen query:query lastCounts:counts
                      stableRounds:stable roundsLeft:roundsLeft - 1
                        completion:completion];
    });
}

// Read off the CELLS, so what this reports is what the screen draws.
- (NSDictionary *)debugSearchResultForScreen:(SearchViewController *)screen
                                       query:(NSString *)query
                                      counts:(NSArray<NSNumber *> *)counts {
    UITableView *table = screen.tableView;
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    for (NSInteger section = 0; section < counts.count; section++) {
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
        for (NSInteger row = 0; row < counts[(NSUInteger)section].integerValue; row++) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:section];
            UITableViewCell *cell = [table.dataSource tableView:table cellForRowAtIndexPath:path];
            UIListContentConfiguration *content =
                    (UIListContentConfiguration *)cell.contentConfiguration;
            [rows addObject:@{@"text": content.text ?: @"",
                              @"secondaryText": content.secondaryText ?: @""}];
        }
        [sections addObject:@{
            @"header": [table.dataSource respondsToSelector:@selector(tableView:titleForHeaderInSection:)]
                    ? ([table.dataSource tableView:table titleForHeaderInSection:section] ?: @"")
                    : @"",
            @"rows": rows
        }];
    }
    return @{@"ok": @YES,
             @"query": query,
             // Tells an empty files section's "never ran" from "no matches".
             @"materiallyVisible": @(screen.isMateriallyVisible),
             @"filesWalkRunning": @(screen.isBuildingFileIndex),
             @"sections": sections};
}

- (BOOL)debugTapSearchFileAtIndex:(NSUInteger)index {
    SearchViewController *screen = self.searchScreen;
    if (!screen) {
        return NO;
    }
    UITableView *table = screen.tableView;
    NSInteger files = VibeDebugSearchFilesSection;
    if (files >= table.numberOfSections
            || index >= (NSUInteger)[table numberOfRowsInSection:files]) {
        return NO;
    }
    [screen tableView:table
            didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)index
                                                       inSection:files]];
    return YES;
}

// The screen's own opening path, which its row tap and Add actions take.
- (BOOL)debugOpenFavoriteAtIndex:(NSUInteger)index appending:(BOOL)appending {
    FavoritesViewController *favorites = self.favorites;
    NSArray<FavoriteFolder *> *rows = FavoritesStore.shared.favorites;
    if (!favorites || index >= rows.count) {
        return NO;
    }
    [favorites openFavorite:rows[index] appending:appending];
    return YES;
}

- (void)debugSetOutputRouteKind:(VibeOutputRouteKind)kind deviceName:(NSString *)name {
    [self.player debugSetOutputRouteKind:kind deviceName:name];
}

- (NSDictionary *)debugArtDictionary {
    return [self.player debugArtDictionary];
}

- (NSDictionary *)debugActionSummary {
    PlaybackController *playback = self.playback;
    return @{
        @"ok": @YES,
        @"state": VibeDebugPlayerStateName(playback.debugPlayer),
        @"index": @(playback.currentIndex),
        @"count": @(playback.playlist.count),
        @"position": @(playback.position),
        @"parked": @(playback.debugParked),
        @"playerPresentation": self.isPlayerExpanded ? @"full" : @"minimized",
    };
}

- (void)debugPlayPause {
    [self.playback playPause];
}

- (void)debugNext {
    [self.playback next];
}

- (void)debugPrevious {
    [self.playback previous];
}

- (void)debugPlayIndex:(NSUInteger)index {
    // What tapping a library row does; selectTrackAtIndex: range-checks.
    [self.playback selectTrackAtIndex:index];
}

- (void)debugSeekToSeconds:(NSTimeInterval)seconds {
    // A parked track has no player duration, and a scrub there opens the file
    // at the scrubbed position; the scrubber works in progress, so the track's
    // own duration stands in.
    NSTimeInterval duration = self.playback.duration;
    if (duration <= 0) {
        duration = self.playback.currentTrack.duration;
    }
    if (duration > 0) {
        [self.player debugSeekToProgress:(float)MAX(0.0, MIN(1.0, seconds / duration))];
    }
}

- (void)debugOpenPath:(NSString *)path {
    [self.playback debugOpenPath:path];
}

- (void)debugApplyEndOfTrackSetting {
    [self.playback applyTrackTransitionSettings];
}

- (void)debugAppendPath:(NSString *)path {
    [self.playback debugAppendPath:path];
}

- (AudioTrackMetadataCache *)debugMetadataCache {
    return self.playback.debugMetadataCache;
}

- (AudioWaveformCache *)debugWaveformCache {
    return [self.player debugWaveformCache];
}

#pragma mark - What the shared consistency checks read

- (AudioPlayer *)debugPlayer {
    return self.playback.debugPlayer;
}

- (NSUInteger)debugPlaylistCount {
    return self.playback.playlist.count;
}

- (NSUInteger)debugPlaylistCurrentIndex {
    return self.playback.currentIndex;
}

- (AudioTrack *)debugPlaylistCurrentTrack {
    return self.playback.currentTrack;
}

- (AudioTrack *)debugPlaylistTrackAtIndex:(NSUInteger)index {
    return [self.playback.playlist trackAtIndex:index];
}

- (AudioTrack *)debugDisplayedTrack {
    return self.playback.displayedTrack;
}

- (BOOL)debugIsLoading {
    return self.playback.screenState == VibePlayerScreenStateLoading;
}

// No pitch control on iOS; the same constant Now Playing publishes.
// Every Add ends in an append event, empty for nothing; rows lifted for one
// and still up long after are an Add that never came back.
- (NSUInteger)debugCheckPlatform:(NSMutableArray<NSDictionary *> *)violations {
    static const NSTimeInterval kUnsettledLiftSeconds = 30;
    for (NSNumber *age in self.liftedRowAges) {
        if (age.doubleValue > kUnsettledLiftSeconds) {
            [violations addObject:@{@"rule": @"lifted-rows-settle",
                                    @"detail": [NSString stringWithFormat:
                                            @"rows lifted for an Add %.0fs ago were never settled", age.doubleValue]}];
        }
    }
    return 1;
}

- (double)debugPlaybackRate {
    return 1.0;
}

@end

#endif
