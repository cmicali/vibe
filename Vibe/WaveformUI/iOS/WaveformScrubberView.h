//
//  WaveformScrubberView.h
//  Vibe (iOS)
//
//  The iOS counterpart of AudioWaveformView: the same registry, renderers,
//  morph engine and waveform data, hosted in a UIView. DJ semantics: the
//  play position is fixed at the view's horizontal center and the zoomed
//  waveform scrolls beneath it; a drag moves the content 1:1 and seeks on
//  release, both ends give and spring back, a tap nudges to the tapped point
//  in the visible window, and a pinch changes the zoom about the playhead.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class CodableAudioWaveform;
@class WaveformScrubberView;

@protocol WaveformScrubberViewDelegate <NSObject>

- (void)waveformScrubberView:(WaveformScrubberView *)view didSeek:(float)percentage;

// A direct-manipulation gesture on the waveform — a scrub or a zoom pinch —
// is starting or has finished. The owner must stop any ANCESTOR scroll view
// from scrolling for the duration: UIKit chains an inner scroll view's
// overscroll to an enclosing one, so while the pager can still scroll the way
// the finger is going, the scrubber clamps at its end instead of bouncing.
// Declining the pager's gesture is not enough — the chaining is decided from
// geometry, not from which recognizer won.
- (void)waveformScrubberView:(WaveformScrubberView *)view didChangeScrubbing:(BOOL)scrubbing;

// Where the scrub currently sits, delivered as the content moves under the
// finger. The owner renders it as the time the release will land on: the
// playhead itself never moves, so the labels are the only place a scrub's
// target is legible. Sent per frame of scroll — a receiver that formats must
// guard on the value it actually displays.
- (void)waveformScrubberView:(WaveformScrubberView *)view
          didScrubToProgress:(CGFloat)progress;

// The user pinched to a new zoom, delivered on release rather than per frame.
// The owner shares one zoom across every page — a swipe must not change it —
// and persists it; see Vibe/iOS/CLAUDE.md. The value is the REQUEST, which is
// what must be stored: see visibleFraction.
- (void)waveformScrubberView:(WaveformScrubberView *)view
    didChangeVisibleFraction:(CGFloat)fraction;

@end

@interface WaveformScrubberView : UIView

@property (nullable, weak) id<WaveformScrubberViewDelegate> delegate;

// The playhead as a 0-1 fraction. Repaints are gated per device pixel of the
// virtual (scrolled) axis, so a timer can write it unconditionally.
@property (nonatomic) CGFloat progress;

// YES while a scrub drag is in flight. The owner suppresses timer-driven
// progress writes so the playhead does not fight the finger.
@property (nonatomic, readonly) BOOL isScrubbing;

// YES while the settled envelope bitmap is standing in for the live renderer
// tree (the scroll/scrub fast path). Diagnostic; surfaced in dump_state.
@property (nonatomic, readonly) BOOL isShowingBakedWaveform;

// How far the content is pulled past either end, in view points: positive past
// the start, negative past the end, 0 in range. Diagnostic; surfaced in
// dump_state, which is the only way to assert the band from outside.
@property (nonatomic, readonly) CGFloat overscroll;

// Scroll geometry for the debug dump: {offset, min, max, contentWidth}.
// `overscroll` alone cannot tell "resting at an end" from "pinned against one
// and refusing to give", which is exactly the distinction the edge bugs turned
// on; these four numbers can.
@property (nonatomic, readonly) NSArray<NSNumber *> *scrollGeometry;

// The scrub pan, so the pager can require it to fail. Owned by an inner scroll
// view, hence not reachable through the view's own gestureRecognizers.
@property (nonatomic, readonly) UIPanGestureRecognizer *scrubPanRecognizer;

// The zoom pinch, so the pager can require it to fail as well.
@property (nonatomic, readonly) UIPinchGestureRecognizer *zoomPinchRecognizer;

// The DJ zoom level: the fraction of the track visible across the view, from
// 1.0 (the whole track spans the view) down to a close-up. This is the user's
// REQUEST, held only to the absolute design range — NOT necessarily what is
// drawn. The geometry's own floor is applied by effectiveVisibleFraction, so a
// layout that cannot afford this depth shallows the picture without rewriting
// what the user asked for, and rotating back restores it.
//
// Persist THIS one. Persisting the effective value would let a launch in one
// orientation permanently shallow a zoom the other could have drawn.
@property (nonatomic) CGFloat visibleFraction;

// What the view actually draws at: the request clamped against what this
// geometry's settled bitmap can hold (WaveformZoomMath.h). Diagnostic as well
// as internal — the two differing is the only outside sign the clamp ran.
@property (nonatomic, readonly) CGFloat effectiveVisibleFraction;

// Same contract as the mac view: reset ahead of a load (installing the
// persisted style on first use), then hand snapshots to showWaveform:.
- (void)prepareForWaveformLoad;
- (void)showWaveform:(CodableAudioWaveform *)waveform;

// The same delivery WITHOUT the growing-bars morph: the bars land on the new
// shape in one rebuild and the envelope bakes at once, instead of easing over
// ~0.2s and baking 0.6s after the last delivery. For a page the user is not
// watching — a pager cell scrolling into view, or one re-hydrated from a
// snapshot it has already shown — where the ease is invisible but its 60 Hz
// full-view path rebuilds land squarely on the scroll's frame budget.
- (void)showWaveform:(CodableAudioWaveform *)waveform animated:(BOOL)animated;

// The shimmer for a slow file open (an undownloaded cloud placeholder), and
// the static midline for the no-track empty state.
- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;
// Determinate download progress: the midline fills to fraction, under the
// shimmer while one is up, or over a shown waveform (a disk-cached waveform
// can arrive while the audio file is still materializing). Negative removes
// the fill; the owner clears it when the open lands or fails.
- (void)setLoadingProgress:(float)fraction;
- (void)showEmptyPlaceholder;

@end

NS_ASSUME_NONNULL_END
