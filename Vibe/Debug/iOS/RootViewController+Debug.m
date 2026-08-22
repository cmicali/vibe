//
//  RootViewController+Debug.m
//  Vibe (iOS)
//
//  See RootViewController+Debug.h. It composes: the model's handles come from
//  PlaybackController (Debug), the chrome and the art window from
//  PlayerViewController (Debug), and the shell's own state — which tab, and
//  whether the card is up — from here.
//
//  The mac twin is Debug/Mac/Introspection/MainPlayerController+DebugPlayerSurface.m.
//

#import "RootViewController+Debug.h"

#if DEBUG

// The search screen's own section order; it owns the enum, and this is the one
// place outside it that has to name a section.
static const NSInteger VibeDebugSearchFilesSection = 1;

#import "PlaybackController+Debug.h"
#import "PlayerViewController+Debug.h"

#import "AppSettings.h"
#import "SettingsRules.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "LibraryViewController.h"
#import "SearchViewController.h"
#import "DebugCommonVerbs.h"
#import "PlaybackController.h"
#import "Playlist.h"

@implementation RootViewController (Debug)

- (NSDictionary *)debugStateDictionary {
    // The player, currentTrack and playlist blocks are the shared ones; the
    // two below are this app's own.
    NSMutableDictionary *state = VibeDebugCommonStateDictionary(self);
    PlaybackController *playback = self.playback;
    NSMutableDictionary *ui = [[self.player debugChromeDictionary] mutableCopy];
    ui[@"screenState"] = @(playback.screenState);
    ui[@"parked"] = @(playback.debugParked);
    ui[@"trackStartPending"] = @(playback.debugTrackStartPending);
    ui[@"error"] = playback.errorText ?: @"";
    // The model's answer beside the indicator's drawn one, so the publish path
    // is checkable end to end.
    ui[@"outputRoute"] = @{
        @"kind": @(playback.outputRouteKind),
        @"name": playback.outputRouteName ?: @"",
    };
    // The shell: which tab is up, whether the strip is showing, and whether
    // the card is up over both.
    ui[@"playerPresentation"] = self.isPlayerExpanded ? @"full" : @"minimized";
    ui[@"miniPlayerShown"] = @(self.isMiniPlayerShown);
    ui[@"selectedTab"] = self.selectedTabIdentifier;
    // The library's content-unavailable state stands exactly where the
    // player screen's open hint used to.
    ui[@"libraryEmpty"] = @(playback.playlist.count == 0);
    state[@"ui"] = ui;
    // No analyzeBPM/analyzeKey: BPM and key analysis are macOS-only, so those
    // settings do not exist here. A track's bpm/key still report its tags.
    state[@"settings"] = @{
        @"waveformStyle": AppSettings.sharedInstance.waveformStyle ?: @"",
        @"waveformTheme": AppSettings.sharedInstance.waveformTheme,
        @"folderOpenSort": VibeFolderOpenSortIdentifier(AppSettings.sharedInstance.folderOpenSort),
    };
    return state;
}

- (void)debugSetWaveformZoom:(CGFloat)fraction {
    [self.player debugSetWaveformZoom:fraction];
}

- (BOOL)debugTapFavoriteStar {
    // No library means the Playlist tab was never resolved, so its bar — and
    // the star on it — does not exist to tap.
    LibraryViewController *library = self.library;
    if (!library || !self.playback.folderURL) {
        return NO;
    }
    [library favoriteTapped];
    return YES;
}

// The files half answers off a walk and a background match, so there is no
// synchronous moment to read. Rather than guess a delay, this re-reads the
// table until its row counts stop moving — the same thing a human watching the
// list does — bounded so a stalled provider ends the command instead of the
// timeout.
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
             // Without this an empty files section reads as "no matches" when it
             // really means "the files half never ran".
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

- (BOOL)debugTapFavoriteAtIndex:(NSUInteger)index {
    FavoritesViewController *favorites = self.favorites;
    if (!favorites || index >= (NSUInteger)[favorites.tableView numberOfRowsInSection:0]) {
        return NO;
    }
    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)index inSection:0];
    [favorites tableView:favorites.tableView didSelectRowAtIndexPath:path];
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
    // Exactly what tapping a library row does; selectTrackAtIndex: range-checks.
    [self.playback selectTrackAtIndex:index];
}

- (void)debugSeekToSeconds:(NSTimeInterval)seconds {
    // The player's duration is 0 while it holds nothing — a parked track — and
    // that is precisely the case worth being able to drive: a scrub there
    // opens the file at the scrubbed position. Falling back to the track's own
    // duration is what the scrubber itself effectively does, since it works in
    // progress rather than seconds.
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

// No pitch control on iOS, so the varispeed never leaves 1.0 — the same
// constant the Now Playing publish sends.
- (double)debugPlaybackRate {
    return 1.0;
}

@end

#endif
