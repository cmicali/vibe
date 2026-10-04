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
#import "NSURLUtil+Debug.h"
#import "UIImage+DominantColor.h"

@interface PlayerViewController (DebugPager)
- (void)prefetchPageAtIndex:(NSUInteger)index;
@end

// Implemented by the classes themselves; only the dump reads them.
@interface WaveformScrubberView (Debug)
// The settled fast path is up.
@property (nonatomic, readonly) BOOL isShowingBakedWaveform;
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
    if (!self.isPresented || _playback.isPlaying || _waveformCoordinator.isHeld || _playlist.count < 2) {
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
        _playlist.currentIndex = neighbor;
        [self renderHeaderForTrack:_playlist.currentTrack];
        BOOL retained = _preparedWaveforms[@(neighbor)] == prepared;
        [self scrollToCurrentPageAnimated:NO];
        [_pagesView layoutIfNeeded];
        WaveformScrubberView *arriving = [self cellAtIndex:neighbor].waveformView;
        BOOL immediate = arriving.isShowingBakedWaveform && !arriving.isAnimatingWaveformArrival;
        _playlist.currentIndex = current;
        [self renderHeaderForTrack:_playlist.currentTrack];
        [self scrollToCurrentPageAnimated:NO];
        [_pagesView layoutIfNeeded];
        completion(@{@"ok": @(retained && immediate), @"retainedUntilDisplay": @(retained),
                     @"immediateWaveform": @(immediate)});
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
    completion(@{@"error": @"Expected refresh, transition or artwork"});
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
