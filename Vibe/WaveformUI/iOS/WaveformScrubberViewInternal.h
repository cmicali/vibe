//
//  WaveformScrubberViewInternal.h
//  Vibe (iOS)
//
//  Private to WaveformScrubberView.mm and its Loading and Gestures
//  categories. ObjC++ only, since it brings in WaveformRenderer.h.
//

#import "WaveformScrubberView.h"
#import "AudioWaveform.h"
#import "WaveformRenderer.h"
#import "LoadingIndicator.h"

NS_ASSUME_NONNULL_BEGIN

@interface WaveformScrubberView () <UIScrollViewDelegate, UIGestureRecognizerDelegate> {
    // contentSize is the virtual width; insets of half a view park both ends
    // under the center. Everything that scrolls is a sublayer of ITS layer;
    // the loading indicator stays in self.layer.
    UIScrollView            *_scroll;
    // The renderer's tree at virtual size, geometryFlipped into the
    // renderers' y-up space. It draws only _renderWindow.
    CALayer                 *_rendererHost;
    WaveformRenderer        *_renderer;
    NSString                *_styleIdentifier;
    NSString                *_themeSignature;
    // The stretch of content the renderer last drew, in content points.
    CGRect                  _renderWindow;
    // Whether a request for deep zoom's blocks is out.
    BOOL                    _detailRequested;
    CGFloat                 _progress;
    NSUInteger              _progressTracker;
    LoadingIndicator *_loadingIndicator;
    // The span it was last placed across; see syncLoadingTrackToProgress.
    CGRect            _loadingTrackBounds;
    UIImpactFeedbackGenerator *_scrubHaptics;
    NSInteger               _lastTickBucket;
    CFTimeInterval          _lastTickTime;
    // So the seek commits once per gesture, not per delegate call.
    BOOL                    _seekPending;
    // Where the pending scrub began, so a pinch can tell a scrub from drift.
    CGFloat                 _scrubStartProgress;
    // The theme's playhead line, hidden until a theme asks for it: fixed at
    // center in self.layer, since it is the content that moves.
    CALayer                 *_playheadLine;
    CGFloat                 _visibleFraction;
    UIPinchGestureRecognizer *_pinch;
    BOOL                    _isPinching;
    CGFloat                 _pinchStartFraction;
    // The pinch-driven scrub's last centroid and its touch count; see
    // trackZoomGestureScrub:.
    CGFloat                 _zoomScrubLastX;
    NSUInteger              _zoomScrubTouches;
    // Backs playbackLoading. Named here so the categories can read it.
    BOOL                    _playbackLoading;
}

@property (nonatomic, strong, nullable) CodableAudioWaveform *waveform;

// The core (WaveformScrubberView.mm).
- (BOOL)isShowingCompleteWaveform:(CodableAudioWaveform *)waveform;
- (CGFloat)displayScale;
- (CGFloat)minimumVisibleFraction;
- (CGFloat)virtualWidth;
- (CGFloat)progressForContentOffset:(CGFloat)x;
- (void)parkContentOffsetAtProgress;
- (void)applyPlayedClip;
// Draws the stretch around what the view shows once it leaves the window
// last drawn, or at once when forced.
- (void)drawRendererWindowForcing:(BOOL)force;
- (NSUInteger)progressBucket;
- (void)resetWaveformContentState;

@end

// The rest of +Loading.mm. Its public half is in WaveformScrubberView.h.
@interface WaveformScrubberView (LoadingInternal)

- (void)layoutLoadingLayer;
- (void)syncLoadingTrackToProgress;
- (void)hideLoadingShimmer;

@end

@interface WaveformScrubberView (Gestures)

- (void)handleTap:(UITapGestureRecognizer *)tap;
- (void)handlePinch:(UIPinchGestureRecognizer *)pinch;
- (void)endZoomGesture;

@end

NS_ASSUME_NONNULL_END
