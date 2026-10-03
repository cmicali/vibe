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

// A scrub or zoom pinch is starting or has finished. The owner must stop any
// ANCESTOR scroll view scrolling for the duration: UIKit chains overscroll to
// an enclosing scroll view by geometry, not by which recognizer won, so the
// scrubber would clamp at its end instead of bouncing.
- (void)waveformScrubberView:(WaveformScrubberView *)view didChangeScrubbing:(BOOL)scrubbing;

// Where the scrub sits, per frame of scroll: the time the release will land
// on. A receiver that formats must guard on the value it displays.
- (void)waveformScrubberView:(WaveformScrubberView *)view
          didScrubToProgress:(CGFloat)progress;

// On release, not per frame. The value is the REQUEST, which is what the owner
// persists and shares across pages (Vibe/iOS/Player/AGENTS.md).
- (void)waveformScrubberView:(WaveformScrubberView *)view
    didChangeVisibleFraction:(CGFloat)fraction;

@end

@interface WaveformScrubberView : UIView

@property (nullable, weak) id<WaveformScrubberViewDelegate> delegate;

// Repaints are gated per device pixel, so a timer can write it unconditionally.
@property (nonatomic) CGFloat progress;

// YES through a scrub's drag, coast and bounce and a live pinch; the owner
// suppresses timer progress writes meanwhile.
@property (nonatomic, readonly) BOOL isScrubbing;

// Whether there is waveform data to manipulate; an unloaded scrubber stays
// page-swipe surface.
@property (nonatomic, readonly, getter=isScrubbingEnabled) BOOL scrubbingEnabled;

// The settled fast path is up. Diagnostic (dump_state).
@property (nonatomic, readonly) BOOL isShowingBakedWaveform;

// Points past either end: positive past the start, negative past the end.
// Diagnostic (dump_state).
@property (nonatomic, readonly) CGFloat overscroll;

// {offset, min, max, contentWidth}, for the debug dump: tells "resting at an
// end" from "pinned against one", which overscroll cannot.
@property (nonatomic, readonly) NSArray<NSNumber *> *scrollGeometry;

// So the pager can require it to fail; the inner scroll view owns it.
@property (nonatomic, readonly) UIPanGestureRecognizer *scrubPanRecognizer;

// Likewise.
@property (nonatomic, readonly) UIPinchGestureRecognizer *zoomPinchRecognizer;

// The fraction of the track visible across the view (1.0: the whole track).
// The user's REQUEST, held only to the design range; the geometry's floor is
// effectiveVisibleFraction's, so a layout that cannot afford this depth
// shallows the picture without rewriting it. Persist THIS one.
@property (nonatomic) CGFloat visibleFraction;

// The request clamped to what this geometry's bake can hold
// (WaveformZoomMath.h).
@property (nonatomic, readonly) CGFloat effectiveVisibleFraction;

// Rebuilds only when the persisted style differs from the one on screen; the
// owner fans it out, since a reused cell keeps its last renderer.
- (void)syncWaveformStyle;

// Likewise for the theme, custom colors and the playhead line; re-bakes, since
// the bitmap holds the old palette.
- (void)syncWaveformTheme;

// THIS page's dominant art color for album_art; nil resolves to Mono. Per view
// because each pager page is a different track. Setting it re-resolves the
// palette.
@property (nonatomic, strong, nullable) UIColor *artworkThemeColor;

// The mac view's contract.
- (void)prepareForWaveformLoad;
- (void)showWaveform:(CodableAudioWaveform *)waveform;

// animated:NO lands the bars in one rebuild, keeps the bake up and
// rate-limits the re-bake: for a page nobody is watching, whose ease would
// only spend the scroll's frame budget, and for every PARTIAL streaming
// delivery (~10 a second), which would otherwise keep the whole load on the
// live tree. animated:YES is for the delivery that COMPLETES the waveform;
// only one onto an empty view actually eases.
- (void)showWaveform:(CodableAudioWaveform *)waveform animated:(BOOL)animated;

// A gesture is moving this view: lands any morph and bakes at once, since a
// moving live tree costs the render server its mask every frame. The view's
// own scrub and pinch call it; the owner calls it for a page swipe.
- (void)bakeNowForGesture;

- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;
// The fill can outlive the shimmer, over a disk-cached waveform that landed
// mid-download. Negative removes it; the owner clears it when the open lands
// or fails.
- (void)setLoadingProgress:(float)fraction;

@end

NS_ASSUME_NONNULL_END
