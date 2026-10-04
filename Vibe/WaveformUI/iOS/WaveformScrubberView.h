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

// Fresh deliveries use showWaveform:; prepared pages pass animated:NO. The
// view otherwise decides the entrance from its own state: the
// first bitmap grows from the midline, the complete one grows from a partial
// one's heights to its own, and a streaming load's partials swap at a steady pace.
- (void)prepareForWaveformLoad;
- (void)showWaveform:(CodableAudioWaveform *)waveform;
- (void)showWaveform:(CodableAudioWaveform *)waveform animated:(BOOL)animated;

// Copies the prepared bitmap only when waveform, geometry and appearance
// still match. The receiver keeps its own layers and gestures.
- (BOOL)showPreparedWaveform:(CodableAudioWaveform *)waveform
                  fromView:(nullable WaveformScrubberView *)view;

// Ends a track's gesture without discarding its cached pixels or seeking.
- (void)cancelInteraction;

// A slow playback open keeps the indicator until settlement, even over cached pixels.
@property (nonatomic) BOOL playbackLoading;

- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;
// The fill can outlive the shimmer, over a disk-cached waveform that landed
// mid-download. Negative removes it; the owner clears it when the open lands
// or fails.
- (void)setLoadingProgress:(float)fraction;

@end

NS_ASSUME_NONNULL_END
