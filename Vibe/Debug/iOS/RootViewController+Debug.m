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
#import "BrowserViewController.h"
#import "FavoritesStore.h"
#import "LibraryViewController.h"
#import "SearchViewController.h"
#import "DebugCommonVerbs.h"
#import "PlaybackController.h"
#import "AudioFX.h"
#import "Playlist.h"

// A display link on the main run loop for `seconds` (0: until replaced),
// riding whatever rate the app's own work earns: the probes measure, they
// must not ask.
static CADisplayLink *VibeDebugDisplayLink(id target, SEL selector) {
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:target selector:selector];
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return link;
}

// The layout probe's series: one sample per display-link frame between
// sample_layout_anchors and its end, read by dump_layout_samples.
static NSMutableArray<NSDictionary *> *sLayoutSamples;
static CADisplayLink *sLayoutSampler;
static CFTimeInterval sLayoutSamplingEndsAt;

static NSArray<NSNumber *> *VibeRectArray(CGRect rect) {
    return @[@(rect.origin.x), @(rect.origin.y), @(rect.size.width), @(rect.size.height)];
}

static NSArray<NSNumber *> *VibeInsetsArray(UIEdgeInsets insets) {
    return @[@(insets.top), @(insets.left), @(insets.bottom), @(insets.right)];
}

// The frame-rate probe: a display link counting the frames the app is
// granted and how often one ran long. The answer to "is this 60 or 120, and
// does it hitch" that the simulator cannot give. Class-level: it needs no
// root, and a phone starts it from a launch flag before there is one.
static CADisplayLink *sFrameProbe;
static CFTimeInterval sFrameProbeStartedAt;
static CFTimeInterval sFrameProbeLastAt;
static CFTimeInterval sFrameProbeEndsAt;
static CFTimeInterval sFrameProbeWorstInterval;
static NSUInteger sFrameProbeFrames;
static NSUInteger sFrameProbeHitches;

static void VibeFrameProbeResetWindow(CFTimeInterval now) {
    sFrameProbeStartedAt = now;
    sFrameProbeLastAt = 0;
    sFrameProbeWorstInterval = 0;
    sFrameProbeFrames = 0;
    sFrameProbeHitches = 0;
}

@implementation RootViewController (Debug)

+ (void)debugBeginFrameProbeForSeconds:(NSTimeInterval)seconds {
    [sFrameProbe invalidate];
    CFTimeInterval now = CACurrentMediaTime();
    VibeFrameProbeResetWindow(now);
    sFrameProbeEndsAt = seconds > 0 ? now + seconds : 0;
    sFrameProbe = VibeDebugDisplayLink(self, @selector(debugProbeFrame:));
}

+ (void)debugProbeFrame:(CADisplayLink *)link {
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
    // The continuous probe — the launch flag's — logs a window every five
    // seconds, which --log-stderr relays off a phone.
    if (sFrameProbeEndsAt == 0 && now - sFrameProbeStartedAt >= 5) {
        NSDictionary *report = [self debugFrameProbeReport];
        LogInfo(@"Frame probe: %@ Hz over %@ s, %@ hitches, worst %@ ms",
                report[@"averageHz"], report[@"seconds"], report[@"hitches"], report[@"worstIntervalMs"]);
        VibeFrameProbeResetWindow(now);
    }
    else if (sFrameProbeEndsAt > 0 && now >= sFrameProbeEndsAt) {
        [link invalidate];
        sFrameProbe = nil;
    }
}

+ (NSDictionary *)debugFrameProbeReport {
    CFTimeInterval seconds = (sFrameProbeLastAt ?: CACurrentMediaTime()) - sFrameProbeStartedAt;
    double hz = seconds > 0 && sFrameProbeFrames > 1 ? (sFrameProbeFrames - 1) / seconds : 0;
    // 120 only when the app may draw at it: an iPhone caps an app at 60
    // without CADisableMinimumFrameDurationOnPhone.
    UIScreen *screen = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            screen = ((UIWindowScene *)scene).screen;
            break;
        }
    }
    return @{@"frames": @(sFrameProbeFrames),
             @"seconds": @(round(seconds * 100) / 100),
             @"averageHz": @(round(hz * 10) / 10),
             @"hitches": @(sFrameProbeHitches),
             @"worstIntervalMs": @(round(sFrameProbeWorstInterval * 10000) / 10),
             @"maximumHz": @(screen ? screen.maximumFramesPerSecond : 0)};
}

// Where the selected tab's chrome and first row sit in the window, with the
// insets the layout is laid out against, read from the LIVE views: under a
// moving card none of them may move, since what scales is a snapshot.
- (NSDictionary *)debugLayoutAnchors {
    NSMutableDictionary *anchors = [NSMutableDictionary dictionary];
    UINavigationController *navigation = (UINavigationController *)self.tabs.selectedViewController;
    UIViewController *top = navigation.topViewController;
    UINavigationBar *bar = navigation.navigationBar;
    if (bar.window) {
        anchors[@"navigationBar"] = VibeRectArray([bar convertRect:bar.bounds toView:nil]);
    }
    UITableView *table = [top isKindOfClass:UITableViewController.class]
            ? ((UITableViewController *)top).tableView : nil;
    UITableViewCell *firstRow = table.visibleCells.firstObject;
    if (firstRow) {
        anchors[@"firstRow"] = VibeRectArray([firstRow convertRect:firstRow.bounds toView:nil]);
        anchors[@"contentOffsetY"] = @(table.contentOffset.y);
        // The large title's collapse shows here before anywhere else.
        anchors[@"adjustedContentInset"] = VibeInsetsArray(table.adjustedContentInset);
    }
    UITabBar *tabBar = self.tabs.tabBar;
    if (tabBar.window) {
        anchors[@"tabBar"] = VibeRectArray([tabBar convertRect:tabBar.bounds toView:nil]);
    }
    UIView *strip = self.miniPlayerView;
    if (strip.window) {
        anchors[@"strip"] = VibeRectArray([strip convertRect:strip.bounds toView:nil]);
    }
    anchors[@"tabsSafeAreaInsets"] = VibeInsetsArray(self.tabs.view.safeAreaInsets);
    anchors[@"topSafeAreaInsets"] = VibeInsetsArray(top.view.safeAreaInsets);
    anchors[@"tabsHidden"] = @(self.tabs.view.hidden);
    anchors[@"backdropScale"] = @(self.backdropSnapshot ? self.backdropSnapshot.transform.a : 1);
    anchors[@"cardOffset"] = @(self.player.view.transform.ty);
    anchors[@"time"] = @(CACurrentMediaTime());
    return anchors;
}

- (void)debugBeginLayoutSamplingForSeconds:(NSTimeInterval)seconds {
    [sLayoutSampler invalidate];
    sLayoutSamples = [NSMutableArray array];
    sLayoutSamplingEndsAt = CACurrentMediaTime() + seconds;
    sLayoutSampler = VibeDebugDisplayLink(self, @selector(debugSampleLayout:));
}

- (void)debugSampleLayout:(CADisplayLink *)link {
    [sLayoutSamples addObject:[self debugLayoutAnchors]];
    if (CACurrentMediaTime() >= sLayoutSamplingEndsAt) {
        [link invalidate];
        sLayoutSampler = nil;
    }
}

- (NSDictionary *)debugLayoutSamples {
    return @{@"samples": [sLayoutSamples copy] ?: @[]};
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
    ui[@"openSlow"] = @(playback.currentOpenSlow);
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
        // The stored choice; null draws the style's default.
        @"waveformPlayheadLine": AppSettings.sharedInstance.waveformPlayheadLine ?: (id)NSNull.null,
        @"waveformCentered": @(AppSettings.sharedInstance.waveformCentered),
        @"widgetWaveformCentered": @(AppSettings.sharedInstance.widgetWaveformCentered),
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

- (void)debugOpenLink:(NSString *)link completion:(void (^)(NSURL *, NSError *))completion {
    [BrowserViewController openLinkString:link replacingPlaylistOf:self.playback from:self completion:completion];
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

// Every Add ends in a settle event; rows lifted for one and still up long
// after are an Add that never came back. The bound is past one Dropbox
// listing wait (FolderSession's kDropboxListingTimeout), the slowest thing
// an Add legitimately waits on.
- (NSUInteger)debugCheckPlatform:(NSMutableArray<NSDictionary *> *)violations {
    static const NSTimeInterval kUnsettledLiftSeconds = 30;
    CFTimeInterval now = CACurrentMediaTime();
    for (NSNumber *liftedAt in self.liftedRowTimes) {
        CFTimeInterval age = now - liftedAt.doubleValue;
        if (age > kUnsettledLiftSeconds) {
            [violations addObject:@{@"rule": @"lifted-rows-settle",
                                    @"detail": [NSString stringWithFormat:
                                            @"rows lifted for an Add %.0fs ago were never settled", age]}];
        }
    }
    return 1;
}

// No pitch control on iOS; the same constant Now Playing publishes.
- (double)debugPlaybackRate {
    return 1.0;
}

@end

#endif
