//
//  PlayerViewController+Debug.m
//  Vibe (iOS)
//
//  See PlayerViewController+Debug.h. It reads the screen's private state
//  through PlayerViewControllerInternal.h, the same production surface the
//  controller's own categories share — the dependency runs this way round, so
//  no shipping file carries a declaration for a tool that does not ship.
//
//  The mac twin is Debug/Mac/Introspection/MainPlayerController+DebugPlayerSurface.m.
//

#import "PlayerViewController+Debug.h"

#if DEBUG

#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Delivery.h"   // the scrubber's didSeek: path
#import "PlayerViewController+Pager.h"      // the art window, for dump_art

#import "AppSettings.h"
#import "DebugCommonVerbs.h"
#import "AudioPlayer.h"
#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioTrackMetadataCache.h"
#import "AudioWaveformCache.h"
#import "MusicalKey.h"
#import "WaveformScrubberView.h"

@implementation PlayerViewController (Debug)

- (NSDictionary *)debugStateDictionary {
    // The player, currentTrack and playlist blocks are the shared ones; only
    // the two below are this screen's own.
    NSMutableDictionary *state = VibeDebugCommonStateDictionary(self);
    state[@"ui"] = @{
        @"elapsed": _elapsedLabel.text ?: @"",
        @"remaining": _remainingLabel.text ?: @"",
        @"emptyHintShown": @(!_emptyHintLabel.isHidden),
        @"transportShown": @(_playPauseButton.alpha > 0),
        @"waveformProgress": @(_waveformView.progress),
        @"waveformBaked": @(_waveformView.isShowingBakedWaveform),
        @"isScrubbing": @(_waveformView.isScrubbing),
        @"screenState": @([self screenState]),
        @"parked": @(_parked),
        @"trackStartPending": @(_trackStartPending),
        @"foreground": @(_foreground),
        @"error": _errorText ?: @"",
    };
    // No analyzeBPM/analyzeKey: BPM and key analysis are macOS-only, so those
    // settings do not exist here. A track's bpm/key still report its tags.
    state[@"settings"] = @{
        @"waveformStyle": Settings.waveformStyle ?: @"",
    };
    return state;
}

// The pager's art window and what each page has in hand. The whole point of
// the window is that a page arrives with its art already decoded, and nothing
// on screen distinguishes "not loaded yet" from "this track has no art" — both
// are the vinyl placeholder — so the only way to tell whether the prefetch is
// keeping up is to ask.
- (NSDictionary *)debugArtDictionary {
    NSRange window = [self artWindow];
    NSMutableArray *pages = [NSMutableArray array];
    for (NSUInteger index = 0; index < _playlist.count; index++) {
        AudioTrack *track = [_playlist trackAtIndex:index];
        AudioTrackMetadata *metadata = track.metadata;
        [pages addObject:@{
            @"index": @(index),
            @"title": track.displayTitle ?: @"",
            @"metadata": @(metadata != nil),
            @"art": @(track.cachedArt != nil),
            @"needsLoad": @(metadata.artNeedsLoad),
            @"loading": @(metadata.artLoadDispatched),
            @"inWindow": @(NSLocationInRange(index, window)),
            @"cellUp": @([self cellAtIndex:index] != nil),
        }];
    }
    return @{
        @"currentIndex": @(_playlist.currentIndex),
        @"window": @{@"location": @(window.location), @"length": @(window.length)},
        @"held": _artHeldPages.count ? [self debugIndexList:_artHeldPages] : @[],
        @"pages": pages,
    };
}

- (NSArray<NSNumber *> *)debugIndexList:(NSIndexSet *)indexes {
    NSMutableArray<NSNumber *> *list = [NSMutableArray array];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [list addObject:@(index)];
    }];
    return list;
}

- (NSDictionary *)debugActionSummary {
    return @{
        @"ok": @YES,
        @"state": VibeDebugPlayerStateName(_player),
        @"index": @(_playlist.currentIndex),
        @"count": @(_playlist.count),
        @"position": @(_player.position),
        @"parked": @(_parked),
    };
}

- (void)debugPlayPause {
    [self playPauseTapped];
}

- (void)debugNext {
    [self nextTapped];
}

- (void)debugPrevious {
    if ([_playlist previous]) {
        [self playCurrentTrack];
    }
}

- (void)debugSeekToSeconds:(NSTimeInterval)seconds {
    NSTimeInterval duration = _player.duration;
    if (duration > 0) {
        float p = (float)MAX(0.0, MIN(1.0, seconds / duration));
        [self waveformScrubberView:_waveformView didSeek:p];
    }
}

- (void)debugOpenPath:(NSString *)path {
    [_folderSession openExternalURL:[NSURL fileURLWithPath:path] openInPlace:YES];
}

- (AudioTrackMetadataCache *)debugMetadataCache {
    return _metadataCache;
}

- (AudioWaveformCache *)debugWaveformCache {
    return _waveformCache;
}

#pragma mark - What the shared invariant checks read

- (AudioPlayer *)debugPlayer {
    return _player;
}

- (NSUInteger)debugPlaylistCount {
    return _playlist.count;
}

- (NSUInteger)debugPlaylistCurrentIndex {
    return _playlist.currentIndex;
}

- (AudioTrack *)debugPlaylistCurrentTrack {
    return _playlist.currentTrack;
}

- (AudioTrack *)debugPlaylistTrackAtIndex:(NSUInteger)index {
    return [_playlist trackAtIndex:index];
}

- (AudioTrack *)debugDisplayedTrack {
    return [self displayedTrack];
}

- (BOOL)debugIsLoading {
    return [self screenState] == VibePlayerScreenStateLoading;
}

// No pitch control on iOS, so the varispeed never leaves 1.0 — the same
// constant the Now Playing publish sends.
- (double)debugPlaybackRate {
    return 1.0;
}

@end

#endif
