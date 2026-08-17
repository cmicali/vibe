//
//  MainPlayerController+DebugPlayerSurface.m
//  Vibe
//
//  See MainPlayerController+DebugPlayerSurface.h — thin forwards onto the
//  controller's existing surface, and nothing else.
//

#import "DebugInternal.h"

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
    // What a double-click on a row does, minus the hit-testing: set the row,
    // then play it.
    if (index >= self.playlistController.count) {
        return;
    }
    self.playlistController.currentIndex = index;
    [self.playlistController play];
}

- (void)debugSeekToSeconds:(NSTimeInterval)seconds {
    [self.audioPlayer seekToPosition:seconds];
    // The tick would land it eventually; refreshing here means the reply the
    // verb writes already describes the new position.
    [self debugRefreshUI];
}

- (void)debugOpenPath:(NSString *)path {
    // The same expand, filter and play pipeline as a Finder open or a file
    // drop: a directory is walked and unsupported files are dropped.
    [NSURLUtil expandAndFilterList:@[[NSURL fileURLWithPath:path]]
                        completion:^(NSArray<NSURL *> *expanded, NSUInteger folderCount) {
        if (expanded.count > 0) {
            [self play:expanded];
        }
    }];
}

- (AudioTrackMetadataCache *)debugMetadataCache {
    return self.metadataCache;
}

- (AudioWaveformCache *)debugWaveformCache {
    return self.waveformCache;
}

#pragma mark - What the shared invariant checks read

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

- (NSUInteger)debugAppendPlatformInvariants:(NSMutableArray<NSDictionary *> *)violations {
    return VibeDebugAppendMacInvariants(violations, self);
}

@end

#endif
