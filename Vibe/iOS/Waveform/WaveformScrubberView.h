//
//  WaveformScrubberView.h
//  Vibe (iOS)
//
//  The iOS counterpart of AudioWaveformView: the same registry, renderers,
//  morph engine and waveform data, hosted in a UIView with touch scrubbing
//  instead of mouse seek. SoundCloud semantics: drag lights the column under
//  the finger and seeks on release; a tap seeks immediately.
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

// The playhead as a 0-1 fraction. Repaints are gated per device pixel, so a
// 3 Hz timer can write it unconditionally.
@property (nonatomic) CGFloat progress;

// YES while a scrub drag is in flight. The owner suppresses timer-driven
// progress writes so the playhead does not fight the finger.
@property (nonatomic, readonly) BOOL isScrubbing;

// Same contract as the mac view: reset ahead of a load (installing the
// persisted style on first use), then hand snapshots to showWaveform:.
- (void)prepareForWaveformLoad;
- (void)showWaveform:(CodableAudioWaveform *)waveform;

// The shimmer for a slow file open (an undownloaded cloud placeholder), and
// the static midline for the no-track empty state.
- (void)showLoadingIndicator;
- (void)hideLoadingIndicator;
- (void)showEmptyPlaceholder;

@end

NS_ASSUME_NONNULL_END
