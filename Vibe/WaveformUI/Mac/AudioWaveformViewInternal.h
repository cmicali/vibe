//
//  AudioWaveformViewInternal.h
//  Vibe
//
//  The private surface shared between AudioWaveformView.mm and its loading
//  category: the shared midline metrics, the waveform handle, and the layers
//  the loading and empty presentations own. Do not use it outside the view's
//  implementation files; everything else goes through AudioWaveformView.h.
//

#import "AudioWaveformView.h"
#import "AudioWaveform.h"
#import "AudioWaveformRenderer.h"

NS_ASSUME_NONNULL_BEGIN

// The weight of every non-waveform midline: the loading indicator's three
// layers — track, filled head and shimmer band — and the empty state's static
// line. They are one element in different states, so they share a height and
// cannot drift apart. A whole point keeps the line on device pixels at any
// backing scale: a half-point height would centre at a half pixel and render
// soft, which on a hairline reads as a dimmer line rather than a thinner one.
static const CGFloat kMidlineHeight = 1;

// What an unplayed waveform bar is actually worth on screen: the renderer
// family's 0.5 gradient top under its 0.75 layer opacity. The loading shimmer
// peaks here so the waveform arriving over it is the same brightness rather
// than a step down from a brighter placeholder.
static const CGFloat kUnplayedWaveformAlpha = 0.375;

@interface AudioWaveformView () {
    // The loading and empty presentations, owned by
    // AudioWaveformView+Loading.mm. The view proper only re-lays them out on a
    // resize and re-colours them on an appearance change.
    CAGradientLayer*            _loadingLayer;
    // The determinate download fill beneath the shimmer; nil while progress
    // is unknown. Same presentation as the iOS scrubber's.
    CAGradientLayer*            _loadingProgressLayer;
    CALayer*                    _loadingTrackLayer;
    // Clips the shimmer to the span it is allowed to sweep. The band slides
    // in from before that span and out past its end, and the view's own
    // layer does not mask, so without this it draws over the artwork on one
    // side and out to the window edge on the other.
    CALayer*                    _loadingShimmerClip;
    // The last reported download fraction, or -1 while indeterminate. It sets
    // how much of the track is filled and, from that, where the shimmer is
    // allowed to sweep.
    float                       _loadingProgress;
    // When the last fraction landed, so the fill can be eased over roughly the
    // interval the next one is expected to take. See setLoadingProgress:.
    CFAbsoluteTime              _lastLoadingProgressAt;
    CALayer*                    _placeholderLayer;

    // The live renderer, which the loading presentation reads only to know
    // whether there is anything to redraw under it.
    AudioWaveformRenderer*      _currentWaveformRenderer;
}

// A strong reference to the wrapper. It owns the underlying C++ AudioWaveform,
// so holding it keeps the raw pointer handed to the renderers valid.
@property (nonatomic, strong, nullable) CodableAudioWaveform* waveform;

// The renderer's own reset and redraw, which the loading and empty
// presentations run before taking over the view.
- (void)resetWaveformContentState;
- (void)drawWaveform;
- (void)hideHoverIndicator;

@end

NS_ASSUME_NONNULL_END
