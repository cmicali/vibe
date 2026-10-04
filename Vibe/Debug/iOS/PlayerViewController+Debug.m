//
//  PlayerViewController+Debug.m
//  Vibe (iOS)
//

#import "PlayerViewController+Debug.h"

#if DEBUG

#import "PlayerViewControllerInternal.h"
#import "PlayerViewController+Delivery.h"
#import "PlayerViewController+Pager.h"
#import "PlaybackController+Debug.h"
#import "AudioPlayer.h"
#import "AudioFX.h"

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "AudioWaveformCache.h"
#import "PageWaveformCoordinator.h"
#import "FXPadView.h"
#import "TrackPageCell.h"
#import "WaveformScrubberView.h"
#import "NSURLUtil+Debug.h"
#import "UIImage+DominantColor.h"
#import <objc/runtime.h>

@interface PlayerViewController (DebugPager)
- (void)prefetchPageAtIndex:(NSUInteger)index;
@end

// Implemented by the classes themselves; only the dump reads them.
@interface WaveformScrubberView (Debug)
// The settled fast path is up.
@property (nonatomic, readonly) BOOL isShowingBakedWaveform;
- (void)beginZoomGesture;
- (void)endZoomGesture;
@property (nonatomic, readonly) BOOL isAnimatingWaveformArrival;
// Points past either end: positive past the start, negative past the end.
@property (nonatomic, readonly) CGFloat overscroll;
// {offset, min, max, contentWidth}: tells "resting at an end" from "pinned
// against one", which overscroll cannot.
@property (nonatomic, readonly) NSArray<NSNumber *> *scrollGeometry;
@end

@interface PageWaveformCoordinator (Debug)
// The latest snapshot's fraction loaded; 0 with none.
- (float)percentLoadedAtIndex:(NSUInteger)index;
@end

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
        @"isPinching": @([[_waveformView valueForKey:@"isPinching"] boolValue]),
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
            @"waveformPrepared": @(_preparedWaveforms[@(index)].isShowingBakedWaveform),
            @"waveformBaked": @(cell.waveformView.isShowingBakedWaveform),
            @"waveformBakeCurrent": @(cell.waveformView.isShowingBakedWaveform
                    && [[cell.waveformView valueForKey:@"bakedEpoch"]
                            isEqual:[cell.waveformView valueForKey:@"bakeEpoch"]]),
            @"waveformArriving": @(cell.waveformView.isAnimatingWaveformArrival),
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

- (void)debugCheckWaveformPreparation:(NSString *)scenario
                          completion:(void (^)(NSDictionary *))completion {
    if (!self.isPresented || _playback.isPlaying || _waveformCoordinator.isHeld || _pagerHoldViews.allObjects.count || _playlist.count < 2) {
        completion(@{@"error": @"Expand and pause a playlist with at least two cached waveforms"});
        return;
    }
    NSUInteger current = _playlist.currentIndex;
    NSUInteger neighbor = current + 1 < _playlist.count ? current + 1 : current - 1;
    WaveformScrubberView *prepared = _preparedWaveforms[@(neighbor)];
    if (!prepared.isShowingBakedWaveform) {
        completion(@{@"error": @"Wait for the neighboring waveform to be prepared"});
        return;
    }
    if ([scenario isEqualToString:@"widget"]) {
        [self requestWaveformForIndex:current];
        id publisher = [_playback valueForKey:@"widgetPublisher"];
        id offered = [publisher valueForKey:@"waveformTrack"];
        [self pageWaveformCoordinator:_waveformCoordinator
                   didUpdateWaveform:[_waveformCoordinator snapshotAtIndex:neighbor] forIndex:neighbor];
        BOOL kept = offered == _playlist.currentTrack && [publisher valueForKey:@"waveformTrack"] == offered;
        [self requestWaveformForIndex:current];
        completion(@{@"ok": @(kept), @"currentWidgetWaveformKept": @(kept)});
        return;
    }
    if ([scenario isEqualToString:@"interaction"]) {
        WaveformScrubberView *view = _waveformView;
        CGFloat originalZoom = view.visibleFraction;
        [view beginZoomGesture];
        view.visibleFraction = originalZoom > 0.5 ? originalZoom / 2 : originalZoom * 1.5;
        CGFloat cancelledZoom = view.visibleFraction;
        NSUInteger bakeRequest = [[view valueForKey:@"bakeRequest"] unsignedIntegerValue];
        [view setValue:@YES forKey:@"seekPending"];
        [self playback:_playback didChangeCurrentIndexFromIndex:current];
        BOOL cancelled = ![[view valueForKey:@"isPinching"] boolValue]
                && ![[view valueForKey:@"seekPending"] boolValue] && _pagesView.scrollEnabled;
        BOOL kept = view.isShowingBakedWaveform;
        BOOL zoomSettled = _waveformZoom == cancelledZoom;
        BOOL bakeRequested = [[view valueForKey:@"bakeRequest"] unsignedIntegerValue] > bakeRequest;
        [view setValue:@NO forKey:@"seekPending"];
        [view endZoomGesture];
        [self debugSetWaveformZoom:originalZoom];
        completion(@{@"ok": @(cancelled && kept && zoomSettled && bakeRequested),
                     @"gestureCancelled": @(cancelled), @"waveformKept": @(kept),
                     @"zoomSettled": @(zoomSettled), @"bakeRequested": @(bakeRequested)});
        return;
    }
    if ([scenario isEqualToString:@"loading"]) {
        [self playbackDidBeginLoading:_playback];
        BOOL visible = [_waveformView valueForKey:@"loadingIndicator"] != nil;
        BOOL kept = _waveformView.isShowingBakedWaveform;
        [_waveformView setLoadingProgress:-1];
        BOOL held = [_waveformView valueForKey:@"loadingIndicator"] != nil;
        TrackPageCell *livePage = _boundPage;
        TrackPageCell *returning = [[TrackPageCell alloc] initWithFrame:livePage.frame];
        NSIndexPath *path = [NSIndexPath indexPathForItem:(NSInteger)current inSection:0];
        [self collectionView:_pagesView willDisplayCell:returning forItemAtIndexPath:path];
        BOOL lateAppearanceLoading = returning.waveformView.playbackLoading;
        // The cell misses settlement, then appears again without reuse.
        returning.waveformView.playbackLoading = YES;
        [self playbackDidFinishLoading:_playback];
        [self collectionView:_pagesView willDisplayCell:returning forItemAtIndexPath:path];
        BOOL reappearanceCleared = !returning.waveformView.playbackLoading;
        [self bindChromeToCell:livePage];
        [returning.waveformView prepareForWaveformLoad];
        BOOL ended = [_waveformView valueForKey:@"loadingIndicator"] == nil;
        [self playbackDidBeginLoading:_playback];
        [self playback:_playback didChangeCurrentIndexFromIndex:current];
        BOOL cancelled = !_waveformView.playbackLoading
                && [_waveformView valueForKey:@"loadingIndicator"] == nil;
        completion(@{@"ok": @(visible && kept && held && ended && cancelled && lateAppearanceLoading && reappearanceCleared), @"loadingVisible": @(visible),
                     @"waveformKept": @(kept), @"loadingHeldUntilSettlement": @(held),
                     @"loadingEnded": @(ended), @"trackChangeClearedLoading": @(cancelled),
                     @"lateAppearanceLoading": @(lateAppearanceLoading), @"reappearanceCleared": @(reappearanceCleared)});
        return;
    }
    if ([scenario isEqualToString:@"work_inputs"]) {
        NSMutableDictionary *snapshots = [_waveformCoordinator valueForKey:@"snapshots"];
        NSMutableDictionary *fractions = [_waveformCoordinator valueForKey:@"percentLoaded"];
        NSDictionary *savedSnapshots = snapshots.copy, *savedFractions = fractions.copy;
        __block BOOL partialRefused = NO, missingRefused = NO;
        @try {
            fractions[@(current)] = @0.5;
            [self debugCheckWaveformPreparation:@"work" completion:^(NSDictionary *result) {
                partialRefused = result[@"error"] != nil && [fractions[@(current)] floatValue] == 0.5f;
            }];
            [snapshots removeObjectForKey:@(current)];
            [fractions removeObjectForKey:@(current)];
            [self debugCheckWaveformPreparation:@"work" completion:^(NSDictionary *result) {
                missingRefused = result[@"error"] != nil && !snapshots[@(current)] && !fractions[@(current)];
            }];
        }
        @finally {
            [snapshots setDictionary:savedSnapshots];
            [fractions setDictionary:savedFractions];
        }
        completion(@{@"ok": @(partialRefused && missingRefused),
                     @"partialRefusedWithoutMutation": @(partialRefused),
                     @"missingRefusedWithoutMutation": @(missingRefused)});
        return;
    }
    if ([scenario isEqualToString:@"work"]) {
        CodableAudioWaveform *waveform = [_waveformCoordinator snapshotAtIndex:current];
        if (!waveform || ![_waveformCoordinator isCompleteAtIndex:current]
                || _waveformCoordinator.targetIndex != current) {
            completion(@{@"error": @"Wait for the current waveform to finish loading"});
            return;
        }
        CFTimeInterval start = CACurrentMediaTime();
        for (NSUInteger i = 0; i < 1000; i++) {
            [(id<AudioWaveformCacheDelegate>)_waveformCoordinator audioWaveform:waveform
                    didLoadData:0.5 forTrack:_playlist.currentTrack];
        }
        double deliveryMS = (CACurrentMediaTime() - start) * 1000;
        [(id<AudioWaveformCacheDelegate>)_waveformCoordinator audioWaveform:waveform
                didLoadData:1 forTrack:_playlist.currentTrack];
        UIImage *placeholder = [UIImage imageNamed:@"record-bg"];
        BOOL placeholderColor = placeholder.vibeDominantColor != nil;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(64, 64)];
        UIImage *transparent = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [UIColor.clearColor setFill];
            UIRectFill(CGRectMake(0, 0, 64, 64));
        }];
        start = CACurrentMediaTime();
        for (NSUInteger i = 0; i < 10000; i++) (void)transparent.vibeDominantColor;
        double colorMS = (CACurrentMediaTime() - start) * 1000;
        BOOL memoizedNone = objc_getAssociatedObject(transparent, @selector(vibeDominantColor)) == NSNull.null;
        completion(@{@"ok": @(memoizedNone), @"partialDeliveriesMS": @(deliveryMS), @"transparentColorReadsMS": @(colorMS),
                     @"placeholderHasColor": @(placeholderColor), @"noneMemoized": @(memoizedNone)});
        return;
    }
    if ([scenario isEqualToString:@"refresh"]) {
        BOOL wasEnabled = [[NSURLUtil datalessDiagnostics][@"enabled"] boolValue];
        [NSURLUtil setDatalessDiagnosticsEnabled:YES];
        [self refreshWaveformWindow];
        NSUInteger probes = 0;
        for (NSDictionary *counts in [[NSURLUtil datalessDiagnostics][@"directories"] allValues]) {
            probes += [counts[@"local"] unsignedIntegerValue]
                    + [counts[@"dataless"] unsignedIntegerValue]
                    + [counts[@"statFailed"] unsignedIntegerValue];
        }
        [NSURLUtil setDatalessDiagnosticsEnabled:wasEnabled];
        completion(@{@"ok": @(probes == 0), @"filesystemProbes": @(probes)});
        return;
    }
    if ([scenario isEqualToString:@"transition"]) {
        if ([self cellAtIndex:neighbor]) {
            completion(@{@"error": @"Use a prepared neighbor with no live cell"});
            return;
        }
        // Next renders the new header before scrolling to its cell. Keep
        // this on one main turn, so an async bake cannot hide a lost handoff.
        Playlist *livePlaylist = _playlist;
        NSArray *order = [[livePlaylist valueForKey:@"playOrder"] copy] ?: @[];
        NSNumber *cursor = [livePlaylist valueForKey:@"playOrderCursor"];
        NSDictionary *effects = _playback.debugPlayer.fx.intentSnapshot[@"stages"];
        Playlist *previewPlaylist = [[Playlist alloc] init];
        [previewPlaylist replaceAllWithTracks:livePlaylist.tracks startingAtIndex:neighbor];
        BOOL retained = NO, immediate = NO, paletteMatched = NO;
        @try {
            // An unobserved cursor leaves playback, FX and shuffle history alone.
            _playlist = previewPlaylist;
            [self renderHeaderForTrack:_playlist.currentTrack];
            retained = _preparedWaveforms[@(neighbor)] == prepared;
            [self scrollToCurrentPageAnimated:NO];
            [_pagesView layoutIfNeeded];
            WaveformScrubberView *arriving = [self cellAtIndex:neighbor].waveformView;
            immediate = arriving.isShowingBakedWaveform && !arriving.isAnimatingWaveformArrival;
            paletteMatched = arriving.artworkThemeColor == prepared.artworkThemeColor
                    || [arriving.artworkThemeColor isEqual:prepared.artworkThemeColor];
        }
        @finally {
            _playlist = livePlaylist;
            [self renderHeaderForTrack:_playlist.currentTrack];
            [self scrollToCurrentPageAnimated:NO];
            [_pagesView layoutIfNeeded];
        }
        BOOL stateKept = [order isEqual:([livePlaylist valueForKey:@"playOrder"] ?: @[])]
                && [cursor isEqual:[livePlaylist valueForKey:@"playOrderCursor"]]
                && [effects isEqual:_playback.debugPlayer.fx.intentSnapshot[@"stages"]]
                && livePlaylist.currentIndex == current;
        completion(@{@"ok": @(retained && immediate && paletteMatched && stateKept), @"retainedUntilDisplay": @(retained),
                     @"immediateWaveform": @(immediate), @"paletteMatched": @(paletteMatched),
                     @"playbackStateKept": @(stateKept)});
        return;
    }
    if ([scenario isEqualToString:@"artwork"]) {
        AudioTrack *track = [_playlist trackAtIndex:neighbor];
        UIColor *color = track.cachedArt.vibeDominantColor;
        if (!color || [self cellAtIndex:neighbor]) {
            completion(@{@"error": @"Use a prepared offscreen neighbor with colored artwork"});
            return;
        }
        // Recreate the ordering: waveform ready, display-art decode still
        // pending. The production completion must refresh the hidden view.
        [track.metadata discardDecodedArt];
        prepared.artworkThemeColor = nil;
        [self prefetchPageAtIndex:neighbor];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            BOOL loaded = track.cachedArt != nil;
            BOOL matched = [self->_preparedWaveforms[@(neighbor)].artworkThemeColor isEqual:color];
            completion(@{@"ok": @(loaded && matched), @"artworkLoaded": @(loaded),
                         @"preparedPaletteUpdated": @(matched)});
        });
        return;
    }
    completion(@{@"error": @"Expected refresh, transition, artwork, widget, interaction, loading, work or work_inputs"});
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
