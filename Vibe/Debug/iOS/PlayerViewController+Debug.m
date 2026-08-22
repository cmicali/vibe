//
//  PlayerViewController+Debug.m
//  Vibe (iOS)
//
//  See PlayerViewController+Debug.h.
//

#import "PlayerViewController+Debug.h"

#if DEBUG

#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Delivery.h"   // the scrubber's didSeek: path
#import "PlayerViewController+Pager.h"      // the art window, for dump_art

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioWaveformCache.h"
#import "TrackPageCell.h"
#import "WaveformScrubberView.h"

@implementation PlayerViewController (Debug)

- (NSDictionary *)debugChromeDictionary {
    return @{
        @"elapsed": _elapsedLabel.text ?: @"",
        @"remaining": _remainingTimeControl.text ?: @"",
        @"transportShown": @(_transportView.alpha > 0),
        @"routeShown": @(_routeView.alpha > 0),
        @"routeSymbol": _routeView.symbolName ?: @"",
        @"routeNameShown": @(_routeView.showsDeviceName),
        // The flag that freezes the playhead if it ever sticks; with
        // waveformBaked it says which of the two ways a still waveform means.
        @"routePickerUp": @(_routePickerPresenting),
        @"waveformProgress": @(_waveformView.progress),
        @"waveformOverscroll": @(_waveformView.overscroll),
        @"waveformScrollGeom": _waveformView.scrollGeometry ?: @[],
        @"waveformBaked": @(_waveformView.isShowingBakedWaveform),
        @"isScrubbing": @(_waveformView.isScrubbing),
        // Both, deliberately: the request is what is persisted and what a
        // rotation must not touch, the effective one is what is drawn, and
        // telling them apart is the only way to check the clamp from outside.
        // Equal is the ordinary case; differing means this geometry could not
        // afford the depth the user asked for.
        @"waveformZoomRequested": @(_waveformZoom),
        @"waveformZoomEffective": @(_waveformView.effectiveVisibleFraction),
        @"sceneActive": @(_sceneActive),
    };
}

- (void)debugSetOutputRouteKind:(VibeOutputRouteKind)kind deviceName:(NSString *)name {
    [_routeView setRouteKind:kind deviceName:name];
}

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
            @"loading": @(metadata.artLoadPending),
            @"inWindow": @(NSLocationInRange(index, window)),
            @"cellUp": @([self cellAtIndex:index] != nil),
        }];
    }
    NSMutableArray<NSNumber *> *held = [NSMutableArray array];
    [_artHeldPages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [held addObject:@(index)];
    }];
    return @{
        @"currentIndex": @(_playlist.currentIndex),
        @"window": @{@"location": @(window.location), @"length": @(window.length)},
        @"held": held,
        @"pages": pages,
    };
}

- (void)debugSeekToProgress:(float)progress {
    [self waveformScrubberView:_waveformView didSeek:progress];
}

// Through the same delegate callback a released pinch takes, so the fan-out
// across pages and the persistence behave exactly as a real gesture's.
- (void)debugSetWaveformZoom:(CGFloat)fraction {
    if (!_waveformView) {
        return;     // no page bound: nothing to clamp the value against
    }
    // Via the view's setter first, so what reaches the callback — and so the
    // persisted value — is already held to the absolute range.
    _waveformView.visibleFraction = fraction;
    [self waveformScrubberView:_waveformView
      didChangeVisibleFraction:_waveformView.visibleFraction];
}

- (AudioWaveformCache *)debugWaveformCache {
    return _waveformCache;
}

@end

#endif
