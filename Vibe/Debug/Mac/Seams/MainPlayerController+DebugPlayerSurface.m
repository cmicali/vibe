//
//  MainPlayerController+DebugPlayerSurface.m
//  Vibe
//
//  Thin forwards onto the controller's existing surface.
//

#import "DebugInternal.h"
#import "MainPlayerController+Settings.h"
#import "MainPlayerController+Playlist.h"
#import "AppDelegate+Debug.h"
#import "OpenRequestCoordinator.h"
#import "OpenRequestCoordinator+Debug.h"
#import "WaveformView+Debug.h"
#import "PlaylistTableView.h"

#if DEBUG

@implementation MainPlayerController (DebugPlayerSurface)

- (NSDictionary *)debugStateDictionary {
    return VibeStateDictionary(self);
}

- (NSDictionary *)debugActionSummary {
    return VibeActionSummaryDictionary(self);
}

- (void)debugPlayPause {
    [self playPause:nil];
}

- (void)debugNext {
    [self next:nil];
}

- (void)debugPrevious {
    [self previous:nil];
}

- (void)debugPlayIndex:(NSUInteger)index {
    // A row double-click minus the hit-testing.
    if (index >= self.playlistController.count) {
        return;
    }
    self.playlistController.currentIndex = index;
    [self.playlistController play];
}

- (void)debugSeekToSeconds:(NSTimeInterval)seconds {
    [self.audioPlayer seekToPosition:seconds];
    // So the verb's reply already describes the new position.
    [self debugRefreshUI];
}

- (void)debugOpenPath:(NSString *)path {
    // Expands and plays directly, bypassing AppDelegate's open funnel (no
    // burst coalescing, no supersession). file_drag_drop and append exercise
    // the funnel.
    [FolderWalk expandAndFilterList:@[[NSURL fileURLWithPath:path]]
                           sortedBy:AppSettings.sharedInstance.folderOpenSort
                         completion:^(NSArray<VibePlaylistEntry *> *entries, NSUInteger folderCount) {
        NSArray<AudioTrack *> *rows = [AudioTrack rowsForEntries:entries];
        run_on_main_thread({
            if (rows.count > 0) {
                [self play:rows];
            }
        });
    }];
}

- (void)debugAppendPath:(NSString *)path {
    // The real deliberate-open funnel, which the shared `open` verb bypasses
    // so it can serve both shells.
    AppDelegate *delegate = (AppDelegate *)NSApp.delegate;
    if (![delegate isKindOfClass:AppDelegate.class]) {
        LogWarn(@"debugAppendPath: the app delegate is not ready");
        return;
    }
    [delegate openDroppedURLs:@[[NSURL fileURLWithPath:path]] appending:YES];
}

- (void)debugOpenLink:(NSString *)link completion:(void (^)(NSURL *, NSError *))completion {
    AppDelegate *delegate = (AppDelegate *)NSApp.delegate;
    if (![delegate isKindOfClass:AppDelegate.class]) {
        LogWarn(@"debugOpenLink: the app delegate is not ready");
        completion(nil, [NSError errorWithDomain:NSPOSIXErrorDomain code:EAGAIN userInfo:nil]);
        return;
    }
    [delegate openLinkString:link completion:completion];
}

- (AudioTrackMetadataCache *)debugMetadataCache {
    return self.metadataCache;
}

- (AudioWaveformCache *)debugWaveformCache {
    return self.waveformCache;
}

#pragma mark - What the shared consistency checks read

- (AudioPlayer *)debugPlayer {
    return self.audioPlayer;
}

- (NSUInteger)debugPlaylistCount {
    return self.playlistController.count;
}

- (NSUInteger)debugPlaylistCurrentIndex {
    return self.playlistController.currentIndex;
}

- (AudioTrack *)debugPlaylistCurrentTrack {
    return self.playlistController.currentTrack;
}

- (AudioTrack *)debugPlaylistTrackAtIndex:(NSUInteger)index {
    return [self.playlistController trackAtIndex:index];
}

- (AudioTrack *)debugDisplayedTrack {
    return [self displayedTrack];
}

- (BOOL)debugIsLoading {
    return [self displayState] == TrackDisplayStateLoading;
}

- (double)debugPlaybackRate {
    return self.playbackRate;
}

- (void)debugApplyEndOfTrackSetting {
    [self applySettingsLiveEffects:VibeSettingsLiveEffectEndOfTrack];
}

- (NSUInteger)debugCheckPlatform:(NSMutableArray<NSDictionary *> *)violations {
    return VibeDebugCheckMac(violations, self);
}

// Views recurse through the view tree and layers through the layer tree, so a
// layer-backed subview's layer is counted once, as a sublayer of its
// superview's.
static void VibeCountViews(NSView *view, NSUInteger *views, NSUInteger *trackingAreas) {
    (*views)++;
    *trackingAreas += view.trackingAreas.count;
    for (NSView *sub in view.subviews) {
        VibeCountViews(sub, views, trackingAreas);
    }
}

- (NSDictionary *)debugHealthUI {
    // TRAP: NSApp.windows includes closed windows the app keeps for reuse
    // (AppDelegate's settingsWindowController, the shared NSColorPanel), so
    // counting their views makes one visit to Settings read as a permanent
    // leak. Views, layers and tracking areas count VISIBLE windows only;
    // `windows` stays over NSApp.windows so stranded windows still show.
    NSUInteger views = 0, trackingAreas = 0, layers = 0, visibleWindows = 0;
    for (NSWindow *window in NSApp.windows) {
        NSView *content = window.contentView;
        if (!content || !window.isVisible) {
            continue;
        }
        visibleWindows++;
        VibeCountViews(content, &views, &trackingAreas);
        if (content.layer) {
            layers += VibeDebugLayerCount(content.layer);
        }
    }
    return @{
        @"windows": @(NSApp.windows.count),
        @"visibleWindows": @(visibleWindows),
        @"views": @(views),
        @"layers": @(layers),
        @"trackingAreas": @(trackingAreas),
    };
}

- (NSDictionary *)debugHealthApp {
    return @{
        @"tableRows": @(self.playlistTableView.numberOfRows),
        @"canUndo": @(self.window.undoManager.canUndo),
        @"canRedo": @(self.window.undoManager.canRedo),
    };
}

- (NSDictionary<NSString *, NSNumber *> *)debugPendingCounts {
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
    out[@"openResultsBuffered"] = @([OpenRequestCoordinator.sharedCoordinator debugBufferedResultCount]);
    AppDelegate *appDelegate = (AppDelegate *)NSApp.delegate;
    if ([appDelegate isKindOfClass:AppDelegate.class]) {
        out[@"openBurstQueued"] = @([appDelegate debugQueuedOpenCount]);
    }
    out[@"waveformEasing"] = @([self.waveformView debugWaveformEasing] ? 1 : 0);
    return out;
}

- (void)debugCloseFile {
    [self closeFile:nil];
}

- (void)debugSetWaveformLoading:(BOOL)shown fraction:(float)fraction {
    if (!shown) {
        [self.trackDisplay hideWaveformLoadingIndicator];
        return;
    }
    [self.trackDisplay showWaveformLoadingIndicator];
    [self.trackDisplay setWaveformLoadingProgress:fraction];
}

@end

#endif
