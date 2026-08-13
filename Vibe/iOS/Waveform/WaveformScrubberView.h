//
//  WaveformScrubberView.h
//  Vibe (iOS)
//
//  The iOS counterpart of AudioWaveformView: the same registry, renderers,
//  morph engine and waveform data, hosted in a UIView. DJ semantics: the
//  play position is fixed at the view's horizontal center and the zoomed
//  waveform scrolls beneath it; a drag moves the content 1:1 and seeks on
//  release, a tap nudges to the tapped point in the visible window.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class CodableAudioWaveform;
@class WaveformScrubberView;

@protocol WaveformScrubberViewDelegate <NSObject>

- (void)waveformScrubberView:(WaveformScrubberView *)view didSeek:(float)percentage;

@end

@interface WaveformScrubberView : UIView

@property (nullable, weak) id<WaveformScrubberViewDelegate> delegate;

// The playhead as a 0-1 fraction. Repaints are gated per device pixel of the
// virtual (scrolled) axis, so a timer can write it unconditionally.
@property (nonatomic) CGFloat progress;

// YES while a scrub drag is in flight. The owner suppresses timer-driven
// progress writes so the playhead does not fight the finger.
@property (nonatomic, readonly) BOOL isScrubbing;

// YES while the settled envelope bitmap is standing in for the live renderer
// tree (the scroll/scrub fast path). Diagnostic; surfaced in dump_state.
@property (nonatomic, readonly) BOOL isShowingBakedWaveform;

// Same contract as the mac view: reset ahead of a load (installing the
// persisted style on first use), then hand snapshots to showWaveform:.
- (void)prepareForWaveformLoad;
- (void)showWaveform:(CodableAudioWaveform *)waveform;

// The shimmer for a slow file open (an undownloaded cloud placeholder), and
// the static midline for the no-track empty state.
- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;
// Determinate download progress: the midline fills to fraction, under the
// shimmer while one is up, or over a shown waveform (a disk-cached waveform
// can arrive while the audio file is still materializing). Negative removes
// the fill; the owner clears it when the open lands or fails.
- (void)setLoadingProgress:(float)fraction;
- (void)showEmptyPlaceholder;

@end

NS_ASSUME_NONNULL_END
