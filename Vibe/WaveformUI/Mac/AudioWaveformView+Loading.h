//
//  AudioWaveformView+Loading.h
//  Vibe
//
//  What the strip shows with no waveform: LoadingIndicator's waveform style
//  while a slow open is pending, and the static placeholder line when nothing
//  is loaded.
//

#import "AudioWaveformView.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioWaveformView (Loading)

- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;
@property (readonly, getter=isLoadingIndicatorShown) BOOL loadingIndicatorShown;
// Negative reverts to indeterminate. No-op unless the indicator is up.
- (void)setLoadingProgress:(float)fraction;

// Cleared by prepareForWaveformLoad and showLoadingIndicator.
- (void)showEmptyPlaceholder;
- (void)hideEmptyPlaceholder;

// The view proper's resize and appearance hooks; none builds anything.
- (void)layoutLoadingLayer;
- (void)layoutPlaceholderLayer;
- (void)updatePlaceholderColor;
- (void)updateLoadingColors;

@end

NS_ASSUME_NONNULL_END
