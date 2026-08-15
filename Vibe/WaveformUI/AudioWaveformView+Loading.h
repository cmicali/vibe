//
//  AudioWaveformView+Loading.h
//  Vibe
//
//  What the waveform strip shows when there is no waveform: the loading
//  indicator while a file opens and decodes, and the flat placeholder line
//  when nothing is loaded at all.
//
//  Three CALayers make up the loading state, back to front — an inert track
//  line, a determinate fill over it once a download fraction is known, and a
//  shimmer band sweeping the span that is not yet filled. All three share the
//  waveform's own midline height and its unplayed-bar alpha, so the real
//  waveform arriving over them is the same weight and brightness rather than a
//  step change. Nothing here draws bars; the renderers own those.
//

#import "AudioWaveformView.h"

NS_ASSUME_NONNULL_BEGIN

@interface AudioWaveformView (Loading)

// An indeterminate shimmer across the waveform area while a slow file open is
// pending, as when a cloud placeholder is downloading.
- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;
// Determinate download progress while the loading indicator shows: the
// midline fills to fraction beneath the shimmer. Negative reverts to
// indeterminate. No-op unless the loading indicator is up.
- (void)setLoadingProgress:(float)fraction;

// The no-track empty state: a static full-width line on the waveform midline.
// prepareForWaveformLoad and showLoadingIndicator clear it when a track
// arrives.
- (void)showEmptyPlaceholder;
- (void)hideEmptyPlaceholder;

// Re-lays the layers out after a frame change, and re-colours them after an
// appearance change. The view proper calls these; neither builds anything.
- (void)layoutLoadingLayer;
- (void)layoutPlaceholderLayer;
- (void)updatePlaceholderColor;
- (void)updateLoadingColors;

@end

NS_ASSUME_NONNULL_END
