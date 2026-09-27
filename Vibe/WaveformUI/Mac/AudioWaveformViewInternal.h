//
//  AudioWaveformViewInternal.h
//  Vibe
//
//  Private to AudioWaveformView.mm and its loading category.
//

#import "AudioWaveformView.h"
#import "AudioWaveform.h"
#import "AudioWaveformRenderer.h"
#import "LoadingIndicator.h"

NS_ASSUME_NONNULL_BEGIN


@interface AudioWaveformView () {
    // Owned by the loading category; nil when not showing.
    LoadingIndicator*           _loadingIndicator;
    CALayer*                    _placeholderLayer;

    AudioWaveformRenderer*      _currentWaveformRenderer;
}

// Strong: the wrapper owns the C++ AudioWaveform whose raw pointer the
// renderers hold.
@property (nonatomic, strong, nullable) CodableAudioWaveform* waveform;

- (void)resetWaveformContentState;
- (void)drawWaveform;
- (void)hideHoverIndicator;

@end

NS_ASSUME_NONNULL_END
