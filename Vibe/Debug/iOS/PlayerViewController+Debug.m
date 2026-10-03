//
//  PlayerViewController+Debug.m
//  Vibe (iOS)
//

#import "PlayerViewController+Debug.h"

#if DEBUG

#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Delivery.h"
#import "PlayerViewController+Pager.h"

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioWaveformCache.h"
#import "PageWaveformCoordinator.h"
#import "FXPadView.h"
#import "TrackPageCell.h"
#import "WaveformScrubberView.h"

@implementation PlayerViewController (Debug)

- (NSDictionary *)debugChromeDictionary {
    return @{
        @"elapsed": _elapsedLabel.text ?: @"",
        @"remaining": _remainingTimeControl.text ?: @"",
        @"transportShown": @(_transportView.alpha > 0),
        @"routeShown": @(_routeView.alpha > 0 && !_routeView.hidden),
        @"routeSymbol": _routeView.symbolName ?: @"",
        @"routeNameShown": @(_routeView.showsDeviceName),
        // Freezes the playhead while set; beside waveformBaked it says why a
        // waveform is still.
        @"routePickerUp": @(_routePickerPresenting),
        // The pad as drawn: whether the setting shows it, and whether a
        // finger holds it (which also holds the pager).
        @"fxPadShown": @(_fxPadView && !_fxPadView.hidden),
        @"fxPadEngaged": @([_pagerHoldViews.allObjects indexOfObjectPassingTest:
                ^BOOL(UIView *view, NSUInteger index, BOOL *stop) {
            return [view isKindOfClass:[FXPadView class]];
        }] != NSNotFound),
        @"waveformProgress": @(_waveformView.progress),
        @"waveformOverscroll": @(_waveformView.overscroll),
        @"waveformScrollGeom": _waveformView.scrollGeometry ?: @[],
        @"waveformBaked": @(_waveformView.isShowingBakedWaveform),
        @"isScrubbing": @(_waveformView.isScrubbing),
        // The request is persisted and survives rotation; the effective one
        // is drawn. Differing means this geometry could not afford the depth.
        @"waveformZoomRequested": @(_waveformZoom),
        @"waveformZoomEffective": @(_waveformView.effectiveVisibleFraction),
        @"sceneActive": @(_sceneActive),
    };
}

- (void)debugSetOutputRouteKind:(VibeOutputRouteKind)kind deviceName:(NSString *)name {
    [_boundPage setOutputRouteKind:kind deviceName:name];
}

- (NSDictionary *)debugArtDictionary {
    NSRange window = [self artWindow];
    NSMutableArray *pages = [NSMutableArray array];
    for (NSUInteger index = 0; index < _playlist.count; index++) {
        AudioTrack *track = [_playlist trackAtIndex:index];
        AudioTrackMetadata *metadata = track.metadata;
        TrackPageCell *cell = [self cellAtIndex:index];
        [pages addObject:@{
            @"index": @(index),
            @"title": track.displayTitle ?: @"",
            @"metadata": @(metadata != nil),
            @"art": @(track.cachedArt != nil),
            @"needsLoad": @(metadata.artNeedsLoad),
            @"loading": @(metadata.artLoadPending),
            @"inWindow": @(NSLocationInRange(index, window)),
            @"cellUp": @(cell != nil),
            // A page not current must rest at 0 (Player/AGENTS.md).
            @"waveformProgress": cell ? @(cell.waveformView.progress) : [NSNull null],
            // The page's waveform data: null before any delivery.
            @"waveformFilled": [_waveformCoordinator snapshotAtIndex:index]
                    ? @([_waveformCoordinator percentLoadedAtIndex:index]) : NSNull.null,
            @"waveformComplete": @([_waveformCoordinator isCompleteAtIndex:index]),
        }];
    }
    NSMutableArray<NSNumber *> *held = [NSMutableArray array];
    [_artHeldPages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        [held addObject:@(index)];
    }];
    return @{
        @"currentIndex": @(_playlist.currentIndex),
        @"waveformTarget": _waveformCoordinator.targetIndex == NSNotFound ? NSNull.null
                                                                         : @(_waveformCoordinator.targetIndex),
        @"window": @{@"location": @(window.location), @"length": @(window.length)},
        @"held": held,
        @"pages": pages,
    };
}

- (void)debugSeekToProgress:(float)progress {
    [self waveformScrubberView:_waveformView didSeek:progress];
}

- (void)debugSetWaveformZoom:(CGFloat)fraction {
    if (!_waveformView) {
        return;     // no page bound: nothing to clamp the value against
    }
    // The setter first, so the callback, and the persisted value, see it held
    // to the absolute range.
    _waveformView.visibleFraction = fraction;
    [self waveformScrubberView:_waveformView
      didChangeVisibleFraction:_waveformView.visibleFraction];
}

- (AudioWaveformCache *)debugWaveformCache {
    return _waveformCache;
}

@end

#endif
