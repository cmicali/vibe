//
//  MainPlayerController+DebugPlayerSurface.m
//  Vibe
//
//  Thin forwards onto the controller's existing surface.
//

#import "DebugInternal.h"
#import "MainPlayerController+Settings.h"

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
    [NSURLUtil expandAndFilterList:@[[NSURL fileURLWithPath:path]]
                          sortedBy:AppSettings.sharedInstance.folderOpenSort
                        completion:^(NSArray<AudioTrack *> *expanded, NSUInteger folderCount) {
        if (expanded.count > 0) {
            [self play:expanded];
        }
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

@end

#endif
