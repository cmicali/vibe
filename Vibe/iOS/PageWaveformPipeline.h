//
//  PageWaveformPipeline.h
//  Vibe (iOS)
//
//  The track pager's waveform bookkeeping, between AudioWaveformCache and
//  PlayerViewController: the cache runs ONE load at a time (its contract),
//  and this object owns which page that load targets, the latest snapshot
//  per page for re-hydrating reloaded cells, and which pages hold their full
//  waveform. Deliveries carry no URL; the target index names their page, and
//  the cancel before every retarget is the race guard.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
@class AudioWaveformCache;
@class CodableAudioWaveform;
@class PageWaveformPipeline;

// All on the main thread, like the cache's own delegate deliveries.
@protocol PageWaveformPipelineDelegate <NSObject>

// A progress or final delivery for the target page; the snapshot is already
// recorded, so the receiver only paints.
- (void)pageWaveformPipeline:(PageWaveformPipeline *)pipeline
           didUpdateWaveform:(CodableAudioWaveform *)waveform
                    forIndex:(NSUInteger)index;

// The cache's URL-carrying deliveries, passed through untouched: they are
// valid for every playlist row owning the URL, current track or not.
- (void)pageWaveformPipeline:(PageWaveformPipeline *)pipeline
                didDetectBPM:(float)bpm
                      forURL:(NSURL *)url;
- (void)pageWaveformPipeline:(PageWaveformPipeline *)pipeline
                didDetectKey:(NSInteger)key
                      forURL:(NSURL *)url;

@end

@interface PageWaveformPipeline : NSObject

// Takes over the cache's delegate slot for its lifetime.
- (instancetype)initWithCache:(AudioWaveformCache *)cache
                     delegate:(id<PageWaveformPipelineDelegate>)delegate;

// The page the one load is pointed at; NSNotFound after a reset. Deliveries
// land on this index.
@property (nonatomic, readonly) NSUInteger targetIndex;

// Retargets the single load at a page. An index the pipeline is already
// pointed at is left ALONE — a load is in flight or has delivered, and
// restarting it on every cell reload would keep killing the decode so no
// waveform ever completes. A retargeted-back page with its full snapshot in
// hand needs no reload at all; hydration shows it.
- (void)requestIndex:(NSUInteger)index track:(nullable AudioTrack *)track;

// Snapshots exist to re-hydrate nearby pages instantly; distant ones reload
// from the disk cache in milliseconds, so the window stays small instead of
// growing one full waveform per track ever visited. The in-flight load's
// target is kept wherever it is.
- (void)pruneAroundIndex:(NSUInteger)index;

// Forgets everything (a playlist replacement): the target goes to NSNotFound,
// so a late delivery from the superseded load is dropped, deliberately
// without cancelling it — the next request does that.
- (void)reset;

// The latest snapshot for a page, partial or full; nil when none is held.
- (nullable CodableAudioWaveform *)snapshotAtIndex:(NSUInteger)index;

// YES once a page's full waveform has delivered (and until a prune or reset).
- (BOOL)isCompleteAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
