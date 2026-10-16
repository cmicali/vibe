//
//  WaveformScrubberView+Gestures.mm
//  Vibe (iOS)
//
//  The touch scrub, the tap and the pinch to zoom.
//

#import "WaveformScrubberViewInternal.h"
#import "WaveformZoomMath.h"

// One rigid tick per point of scrub travel, so a slow scrub ratchets
// continuously; well under full intensity because it fires many times a
// second.
static const CGFloat kScrubTickSpacing = 1.0;
static const CGFloat kScrubTickIntensity = 0.55;

// TRAP: the spacing above is a distance, not a rate. A fast scrub crosses it
// every frame, and sustained over-requesting takes the Taptic Engine out for
// seconds past the gesture. This ceiling keeps a fast scrub a ratchet.
static const CFTimeInterval kScrubTickMinInterval = 1.0 / 28.0;

// How far a pinch's fingers may wander before the gesture counts as a scrub.
static const CGFloat kZoomScrubSlop = 12.0;

@implementation WaveformScrubberView (Gestures)

#pragma mark - Touch scrubbing

// UIKit's direct manipulation; the seek commits once the content stops. A
// cancelled drag just stops; the next progress push restores the position.
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (_isPinching) {
        // The pan still moves the offset under a pinch; park it rather than
        // reading a position out of it, or the waveform slides off center.
        [self parkContentOffsetAtProgress];
        [self applyPlayedClip];
        [self drawRendererWindowForcing:NO];
        return;
    }
    if (self.isScrubbing) {
        _progress = MAX(0.0, MIN(1.0, [self progressForContentOffset:scrollView.contentOffset.x]));
        _progressTracker = [self progressBucket];
        [self.delegate waveformScrubberView:self didScrubToProgress:_progress];
        [self emitScrubTickIfNeeded];
    }
    [self applyPlayedClip];
    [self drawRendererWindowForcing:NO];
}

// Shared with the pinch's scrub, so a gesture changing hands keeps its ratchet.
- (void)emitScrubTickIfNeeded {
    NSInteger bucket = [self tickBucket];
    if (bucket == _lastTickBucket) {
        return;
    }
    _lastTickBucket = bucket;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastTickTime >= kScrubTickMinInterval) {
        _lastTickTime = now;
        [_scrubHaptics impactOccurredWithIntensity:kScrubTickIntensity];
        [_scrubHaptics prepare];
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (_isPinching) {
        // The pinch's own fingers can start the pan late; the pinch owns the
        // gesture, and decides for itself whether it scrubs.
        return;
    }
    [self.delegate waveformScrubberView:self didChangeScrubbing:YES];
    // A drag that catches a coast continues that scrub.
    if (!_seekPending) {
        _scrubStartProgress = _progress;
    }
    _seekPending = YES;
    [self beginScrubFeedback];
    _lastTickTime = 0;
}

// Shared with the pinch's scrub, which starts past its slop.
- (void)beginScrubFeedback {
    if (!_scrubHaptics) {
        _scrubHaptics = [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleRigid];
    }
    [_scrubHaptics prepare];
    _lastTickBucket = [self tickBucket];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) {
        [self endScrub];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self endScrub];
}

// TRAP: a scrub seeks only when its gesture ends — here, or endZoomGesture for
// a pinch. A seek to 1.0 mid-gesture finishes the track and auto-advances
// with the finger still down, and isDecelerating is YES during a drag, so no
// "still moving" test separates a coast from a finger.
- (void)endScrub {
    if (_isPinching) {
        // TRAP: the pan dies mid-gesture on a touch-count change. Finishing
        // here would seek where the finger no longer is and release the pager
        // under a live drag; endZoomGesture settles all of it.
        return;
    }
    [self commitScrubSeek];
    _scrubHaptics = nil;
    [self.delegate waveformScrubberView:self didChangeScrubbing:NO];
}

- (void)commitScrubSeek {
    if (!_seekPending) {
        return;
    }
    _seekPending = NO;
    [self.delegate waveformScrubberView:self didSeek:(float)MAX(0.0, MIN(1.0, _progress))];
}

- (NSInteger)tickBucket {
    return (NSInteger)floor(_progress * [self virtualWidth] / kScrubTickSpacing);
}

// The scroll's bounds origin IS the content offset, so a location in its
// space is already a content x.
- (void)handleTap:(UITapGestureRecognizer *)tap {
    if (!self.waveform || tap.state != UIGestureRecognizerStateEnded) {
        return;
    }
    CGFloat virtualWidth = [self virtualWidth];
    if (virtualWidth <= 0) {
        return;
    }
    CGFloat p = [tap locationInView:_scroll].x / virtualWidth;
    // Stop a coast, or it commits a second seek over this one; stopping does
    // not reliably call scrollViewDidEndDecelerating:, so release the pager
    // hold here.
    BOOL wasScrubbing = self.isScrubbing || _seekPending;
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    _seekPending = NO;
    _scrubHaptics = nil;
    if (wasScrubbing) {
        [self.delegate waveformScrubberView:self didChangeScrubbing:NO];
    }
    [self.delegate waveformScrubberView:self didSeek:(float)MAX(0.0, MIN(1.0, p))];
}

#pragma mark - Pinch to zoom

// Zoom anchors at the playhead for free: re-parking the offset after a width
// change opens the picture about the center. The fraction is written LIVE, so
// every reader of virtualWidth stays correct, and each frame draws again.

// TRAP: without this a pinch cannot START during a scrub: the scroll's pan has
// already recognized, and by default one gesture belongs to one recognizer.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return recognizer == _pinch && other == _scroll.panGestureRecognizer;
}

- (void)handlePinch:(UIPinchGestureRecognizer *)pinch {
    switch (pinch.state) {
        case UIGestureRecognizerStateBegan:
            if (self.waveform) {
                [self beginZoomGesture];
            }
            break;
        case UIGestureRecognizerStateChanged:
            if (_isPinching) {
                if (pinch.numberOfTouches >= 2 && pinch.scale > 0) {
                    // Pinch open is zoom IN. Clamped to the EFFECTIVE floor, so
                    // the gesture stops where the picture does.
                    self.visibleFraction = VibeWaveformClampVisibleFraction(
                            _pinchStartFraction / pinch.scale, [self minimumVisibleFraction]);
                }
                [self trackZoomGestureScrub:pinch];
                [self parkContentOffsetAtProgress];
            }
            break;
        default:
            if (_isPinching) {
                [self endZoomGesture];
            }
            break;
    }
}

// TRAP: UIScrollView's pan ENDS on any touch-count change, and an ended
// recognizer cannot begin again for a touch already down, while the pinch
// stays in Changed with one finger left. So from its first frame the pinch
// carries the gesture, and this moves the track under the remaining finger.
// Only ONE touch scrubs; with two the centroid is the zoom's anchor.
- (void)trackZoomGestureScrub:(UIPinchGestureRecognizer *)pinch {
    CGFloat x = [pinch locationInView:self].x;
    NSUInteger touches = pinch.numberOfTouches;
    CGFloat virtualWidth = [self virtualWidth];
    // Re-anchor on a touch-count change, or the 2->1 centroid jump scrubs.
    if (touches == 1 && touches == _zoomScrubTouches && virtualWidth > 0) {
        // TRAP: the finger left behind as a pinch lifts always wobbles, and
        // any movement here seeks. Until the slop, the last x stays the
        // anchor; past it the scrub starts where the finger is.
        if (!_seekPending) {
            if (fabs(x - _zoomScrubLastX) < kZoomScrubSlop) {
                return;
            }
            _seekPending = YES;
            _zoomScrubLastX = x;
            [self beginScrubFeedback];
        }
        CGFloat delta = (x - _zoomScrubLastX) / virtualWidth;
        CGFloat next = MAX(0.0, MIN(1.0, _progress - delta));
        if (next != _progress) {
            _progress = next;
            _progressTracker = [self progressBucket];
            [self.delegate waveformScrubberView:self didScrubToProgress:_progress];
            [self emitScrubTickIfNeeded];
        }
    }
    _zoomScrubLastX = x;
    _zoomScrubTouches = touches;
}

- (void)beginZoomGesture {
    _isPinching = YES;
    _pinchStartFraction = _visibleFraction;
    _zoomScrubLastX = [_pinch locationInView:self].x;
    _zoomScrubTouches = _pinch.numberOfTouches;
    // Stop a coast. A real scrub's pending seek commits on lift; the drift of
    // two fingers landing is no scrub and hands the position back to playback.
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    if (_seekPending
            && fabs(_progress - _scrubStartProgress) * [self virtualWidth] < kZoomScrubSlop) {
        _seekPending = NO;
        _progress = _scrubStartProgress;
        _progressTracker = [self progressBucket];
    }
    [self.delegate waveformScrubberView:self didChangeScrubbing:YES];
}

- (void)endZoomGesture {
    // Stop a coast the dying pan started, while the flag still routes its
    // scroll to the park: let run, scrollViewDidScroll: would read a position
    // out of it that no seek follows.
    [_scroll setContentOffset:_scroll.contentOffset animated:NO];
    _isPinching = NO;
    [self parkContentOffsetAtProgress];
    // The margins the pinch went without.
    [self drawRendererWindowForcing:YES];
    // The whole gesture's end; endScrub declined all of this.
    [self commitScrubSeek];
    _scrubHaptics = nil;
    [self.delegate waveformScrubberView:self didChangeScrubbing:NO];
    [self.delegate waveformScrubberView:self didChangeVisibleFraction:_visibleFraction];
}

@end
