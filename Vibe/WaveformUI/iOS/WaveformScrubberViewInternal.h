//
//  WaveformScrubberViewInternal.h
//  Vibe (iOS)
//
//  Private to WaveformScrubberView.mm and its Bitmap, Loading and Gestures
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
    // The renderer only samples for the bake and is never shown: its layers
    // live here, hidden, at virtual size so its bar counts match the bitmap's.
    CALayer                 *_rendererHost;
    WaveformRenderer        *_renderer;
    // The palette a style without a fast bake is drawn in: the renderer's,
    // minus the playhead line, which this view draws itself.
    WaveformTheme           *_bakeTheme;
    NSString                *_styleIdentifier;
    NSString                *_themeSignature;
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
    // The one picture, anchored at the midline, which the arrival grows from.
    // It is made of segments, each a stretch of the track drawn as the played
    // image up to the playhead over the unplayed one: one for the whole track,
    // three while a newly decoded stretch grows in (newSegmentFrom:to:).
    CALayer                 *_bakedHost;
    id                      _bakedPlayedImage;
    id                      _bakedUnplayedImage;
    float                   _bakedUnplayedOpacity;
    // Whether the standing bake drew a complete waveform.
    BOOL                    _bakedComplete;
    BOOL                    _animatesArrival;
    // How far the standing bitmap's decode reached, and the segment of the
    // newest stretch while it grows in.
    CGFloat                 _bakedDecodedFraction;
    CALayer                 *_revealLayer;
    // The theme's playhead line, hidden until a theme asks for it: fixed at
    // center in self.layer, since it is the content that moves.
    CALayer                 *_playheadLine;
    // Two ways to be stale. Every schedule bumps the request, so only the
    // newest pending timer bakes. A change of meaning — a reset, a palette, a
    // style, a scale — bumps the epoch, which a finished bake must match to
    // install; a bake overtaken by a newer streaming delivery still lands.
    NSUInteger              _bakeRequest;
    NSUInteger              _bakeEpoch;
    // One bake at a time; a request during one is rescheduled on completion.
    BOOL                    _bakeInFlight;
    BOOL                    _bakeWanted;
    // For the rate limit; 0 bakes at once.
    CFTimeInterval          _lastBakeAt;
    // When this load's first delivery came; 0 before it.
    CFTimeInterval          _firstDeliveryAt;
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
- (CGRect)virtualBounds;
- (void)installRendererIfNeeded;
- (CGFloat)progressForContentOffset:(CGFloat)x;
- (void)applyScrollAndProgress;
- (void)parkContentOffsetAtProgress;
- (void)applyPlayedClip;
- (NSUInteger)progressBucket;
- (void)resetWaveformContentState;

@end

// The rest of +Bitmap.mm. Its public half is in WaveformScrubberView.h.
@interface WaveformScrubberView (BitmapInternal)

- (void)removeBakedWaveform;
- (void)scheduleEnvelopeBakeAfter:(NSTimeInterval)delay;
- (void)placeBakedLayer:(CALayer *)host;
- (void)finishRevealOf:(nullable CALayer *)reveal;

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
