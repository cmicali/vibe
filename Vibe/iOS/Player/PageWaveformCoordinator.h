//
//  PageWaveformCoordinator.h
//  Vibe (iOS)
//
//  Between AudioWaveformCache, which runs ONE load at a time, and the pager:
//  which page that load targets, and the latest snapshot per page with the
//  fraction loaded it was delivered with, 1 for a complete page. The cancel before a retarget is NOT the race guard — a decode
//  can outlive it — so deliveries are matched on the URL they were loaded for.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class AudioTrack;
@class AudioWaveformCache;
@class CodableAudioWaveform;
@class PageWaveformCoordinator;

// Main thread.
@protocol PageWaveformCoordinatorDelegate <NSObject>

// The snapshot is already recorded; the receiver only paints.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
           didUpdateWaveform:(CodableAudioWaveform *)waveform
                    forIndex:(NSUInteger)index;

// The target is already cleared, so a later request retries.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
      didFailWaveformForIndex:(NSUInteger)index;

// A tempo for `track`, forwarded as delivered: matched by what it sounds, not
// page, since a track can occupy several rows, and never held — the model
// stamps it and the delay taps follow at once; a page repaints only when the
// tempo it shows changed, through the metadata event. No key: key detection
// is macOS-only.
- (void)pageWaveformCoordinator:(PageWaveformCoordinator *)pipeline
              didDetectBPM:(float)bpm
                  forTrack:(AudioTrack *)track;

@end

@interface PageWaveformCoordinator : NSObject

// Takes over the cache's delegate slot for its lifetime.
- (instancetype)initWithCache:(AudioWaveformCache *)cache
                     delegate:(id<PageWaveformCoordinatorDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// NSNotFound after a reset or a failure.
@property (nonatomic, readonly) NSUInteger targetIndex;

// The pager's frame-budget hold. Held, deliveries are RECORDED but not
// forwarded (each repaint tears a scrubber's bake down), failures are
// deferred, and requests are DROPPED (each cancels the one load, so a swipe
// across N pages finishes no decode). Releasing forwards what arrived; the
// caller re-requests the page it settled on.
@property (nonatomic, getter=isHeld) BOOL held;

// A page already targeted with the same FILE is left ALONE, or every cell
// reload kills the decode. A page with its full snapshot in hand is not
// reloaded.
- (void)requestIndex:(NSUInteger)index track:(nullable AudioTrack *)track;

// Cache-only neighbor preparation; never retargets the active decode. A read
// already pending for the same track is not repeated; a miss is remembered by
// nothing, so the next prefetch asks again.
- (void)prefetchIndex:(NSUInteger)index track:(AudioTrack *)track;

// Distant pages reload from the disk cache in milliseconds, so the window
// stays small. The target is kept wherever it is.
- (void)pruneAroundIndex:(NSUInteger)index;

// For a playlist replacement: a late delivery is dropped; the next request
// cancels the load.
- (void)reset;

// Partial or full.
- (nullable CodableAudioWaveform *)snapshotAtIndex:(NSUInteger)index;

// Until a prune or reset.
- (BOOL)isCompleteAtIndex:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
