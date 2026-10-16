//
//  WaveformScrubberView.h
//  Vibe (iOS)
//
//  The iOS counterpart of WaveformView: the same registry, renderers,
//  morph engine and waveform data, hosted in a UIView. DJ semantics: the
//  play position is fixed at the view's horizontal center and the zoomed
//  waveform scrolls beneath it. A drag moves the content 1:1 and seeks when
//  its coast ends. Both ends spring back. A tap seeks to the tapped point
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

// YES through a scrub's drag, coast and bounce. A pinch counts only when it
// has a pending seek. Pure zoom keeps following playback.
@property (nonatomic, readonly) BOOL isScrubbing;

// Whether there is waveform data to manipulate; an unloaded scrubber stays
// page-swipe surface.
@property (nonatomic, readonly, getter=isScrubbingEnabled) BOOL scrubbingEnabled;

// So the pager can require it to fail; the inner scroll view owns it.
@property (nonatomic, readonly) UIPanGestureRecognizer *scrubPanRecognizer;

// Likewise.
@property (nonatomic, readonly) UIPinchGestureRecognizer *zoomPinchRecognizer;

// The fraction of the track visible across the view (1.0: the whole track).
// The user's REQUEST, held only to the design range; the geometry's floor is
// effectiveVisibleFraction's, so a layout that cannot afford this depth
// shallows the picture without rewriting it. Persist THIS one.
@property (nonatomic) CGFloat visibleFraction;

// The request clamped to the deepest zoom the waveform can draw
// (WaveformZoomMath.h).
@property (nonatomic, readonly) CGFloat effectiveVisibleFraction;

// Rebuilds only when the persisted style differs from the one on screen; the
// owner fans it out, since a reused cell keeps its last renderer.
- (void)syncWaveformStyle;

// Likewise for the theme, custom colors and the playhead line.
- (void)syncWaveformTheme;

// THIS page's dominant art color for album_art; nil resolves to Mono. Per view
// because each pager page is a different track. Setting it re-resolves the
// palette.
@property (nonatomic, strong, nullable) UIColor *artworkThemeColor;

// Ends a track's gesture without discarding its cached pixels or seeking.
- (void)cancelInteraction;

// A slow playback open keeps the indicator until settlement, even over a
// drawn waveform.
@property (nonatomic) BOOL playbackLoading;

// Fresh deliveries use showWaveform:, and the renderer eases each one in: the
// first grows from the midline, a streaming load's newest stretch rises, and
// the complete one eases to Normalize's heights. A prepared page passes
// animated:NO and lands at once.
- (void)prepareForWaveformLoad;
- (void)showWaveform:(CodableAudioWaveform *)waveform;
- (void)showWaveform:(CodableAudioWaveform *)waveform animated:(BOOL)animated;

@end

// WaveformScrubberView+Loading.mm.
@interface WaveformScrubberView (Loading)

- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;
// The fill can outlive the shimmer, over a disk-cached waveform that landed
// mid-download. Negative removes it; the owner clears it when the open lands
// or fails.
- (void)setLoadingProgress:(float)fraction;

@end

NS_ASSUME_NONNULL_END
