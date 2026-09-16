//
//  PageWaveformCoordinator.h
//  Vibe (iOS)
//
//  The track pager's waveform bookkeeping, between AudioWaveformCache and
//  PlayerViewController: the cache runs ONE load at a time (its contract),
//  and this object owns which page that load targets, the latest snapshot
//  per page for re-hydrating reloaded cells, and which pages hold their full
//  waveform. The cancel before a retarget is NOT the race guard — a decode can
//  outlive it — so deliveries are matched on the URL they were loaded for
//  (_targetURL, recorded beside _targetIndex) and dropped on the value.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
@class AudioWaveformCache;
@class CodableAudioWaveform;
@class PageWaveformCoordinator;

// All on the main thread, like the cache's own delegate deliveries.
@protocol PageWaveformCoordinatorDelegate <NSObject>

// A progress or final delivery for the target page; the snapshot is already
// recorded, so the receiver only paints.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
           didUpdateWaveform:(CodableAudioWaveform *)waveform
                    forIndex:(NSUInteger)index;

// The target page's load ended without a complete waveform. The receiver
// settles its loading UI; the coordinator has already cleared the target so
// a later request for the same page starts a fresh attempt.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
      didFailWaveformForIndex:(NSUInteger)index;

// The cache's BPM and key deliveries are deliberately NOT forwarded: tempo
// and key analysis are macOS-only (the analysis provider is unset here, see
// AudioWaveformLoader), so nothing on this platform can fire them. A track's
// bpm and key still resolve from its tags.

@end

@interface PageWaveformCoordinator : NSObject

// Takes over the cache's delegate slot for its lifetime.
- (instancetype)initWithCache:(AudioWaveformCache *)cache
                     delegate:(id<PageWaveformCoordinatorDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// The page the one load is pointed at; NSNotFound after a reset. Deliveries
// land on this index.
@property (nonatomic, readonly) NSUInteger targetIndex;

// The pager's scroll hold. Held, deliveries are still RECORDED but not
// forwarded, failures are deferred, and requests are dropped rather than
// issued; releasing forwards whatever arrived meanwhile, and the settle path
// asks for the page it landed on. Both halves are there because a swipe is the
// one moment the main thread has nothing to spare:
//
//   - a delivery repaints a scrubber, which tears its baked envelope down and
//     restarts the morph's 60 Hz full-view path rebuilds — and a decode
//     delivers about ten times a second, so the bake never re-lands and the
//     expensive live tree is what the whole swipe composites;
//   - a request cancels the ONE load the cache runs, so a swipe across N pages
//     cancels N decodes and none of them ever finish — which is why the
//     stutter is worst on an uncached folder and clears up once everything is
//     on disk.
//
// The cost is that a page pulled into view mid-drag no longer starts its own
// decode for the preview; it shows the snapshot it has, or the loading line.
@property (nonatomic, getter=isHeld) BOOL held;

// Retargets the single load at a page. A page it is already pointed at, still
// holding the same FILE, is left ALONE — a load is in flight or has delivered,
// and restarting it on every cell reload would keep killing the decode so no
// waveform ever completes. The file is part of that test, not just the index:
// the same page can come to hold a different track. A retargeted-back page
// with its full snapshot in hand needs no reload at all; hydration shows it.
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
