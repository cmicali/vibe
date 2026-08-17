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
#import "WaveformScrubberView.h"

@implementation PlayerViewController (Debug)

- (NSDictionary *)debugChromeDictionary {
    return @{
        @"elapsed": _elapsedLabel.text ?: @"",
        @"remaining": _remainingLabel.text ?: @"",
        @"transportShown": @(_transportView.alpha > 0),
        @"waveformProgress": @(_waveformView.progress),
        @"waveformOverscroll": @(_waveformView.overscroll),
        @"waveformScrollGeom": _waveformView.scrollGeometry ?: @[],
        @"waveformBaked": @(_waveformView.isShowingBakedWaveform),
        @"isScrubbing": @(_waveformView.isScrubbing),
        @"foreground": @(_foreground),
    };
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
            @"loading": @(metadata.artLoadDispatched),
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

- (AudioWaveformCache *)debugWaveformCache {
    return _waveformCache;
}

@end

#endif
