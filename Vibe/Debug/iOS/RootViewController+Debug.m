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

@implementation RootViewController (Debug)

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
- (double)debugPlaybackRate {
    return 1.0;
}

@end

#endif
