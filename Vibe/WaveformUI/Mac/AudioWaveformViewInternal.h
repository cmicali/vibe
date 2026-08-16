//
//  AudioWaveformViewInternal.h
//  Vibe
//
//  The private surface shared between AudioWaveformView.mm and its loading
//  category: the waveform handle and the layers
//  the loading and empty presentations own (the midline metrics they share
//  with iOS are in WaveformMidline.h). Do not use it outside the view's
//  implementation files; everything else goes through AudioWaveformView.h.
//

#import "AudioWaveformView.h"
#import "AudioWaveform.h"
#import "AudioWaveformRenderer.h"
// kVibeMidlineHeight and the midline palette, shared with the iOS scrubber.
#import "WaveformMidline.h"
#import "WaveformLoadingIndicator.h"

NS_ASSUME_NONNULL_BEGIN


@interface AudioWaveformView () {
    // The loading and empty presentations, owned by
    // AudioWaveformView+Loading.mm. The view proper only re-lays them out on a
    // resize and re-colours them on an appearance change.
    //
    // The loading control is the object shared with the iOS scrubber; nil when
    // no load is showing. It owns its own layers, its determinate fill and the
    // sweep's traps — see WaveformLoadingIndicator.
    WaveformLoadingIndicator*   _loadingIndicator;
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
