//
//  WaveformViewInternal.h
//  Vibe
//
//  Private to WaveformView.mm and its loading category.
//

#import "WaveformView.h"
#import "AudioWaveform.h"
#import "WaveformRenderer.h"
#import "LoadingIndicator.h"

NS_ASSUME_NONNULL_BEGIN


@interface WaveformView () {
    // Owned by the loading category; nil when not showing.
    LoadingIndicator*           _loadingIndicator;
    CALayer*                    _placeholderLayer;

    WaveformRenderer*           _currentWaveformRenderer;
}

// Strong: the wrapper owns the C++ AudioWaveform whose raw pointer the
// renderers hold.
@property (nonatomic, strong, nullable) CodableAudioWaveform* waveform;

- (void)resetWaveformContentState;
- (void)drawWaveform;
- (void)hideHoverIndicator;

@end

NS_ASSUME_NONNULL_END
