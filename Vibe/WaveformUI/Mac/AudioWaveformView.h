//
//  AudioWaveformView.h
//  Vibe
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioWaveformViewDelegate;
@class CodableAudioWaveform;

// A pure rendering surface: draws what it is handed and reports seeks.
// Loading and caching are MainPlayerController's AudioWaveformCache.
@interface AudioWaveformView : NSView

@property (nullable, weak) id <AudioWaveformViewDelegate> delegate;

@property CGFloat progress;

// setProgress:'s repaint step count, and the input MainPlayerController scales
// its UI tick by, so drive rate and draw resolution cannot drift apart.
@property (readonly) CGFloat devicePixelWidth;

// For the album_art theme; nil until one settles. The writer matches it
// against the current track first, and follows with refreshThemeColors.
@property (nullable, strong) NSColor *artworkThemeColor;

// Re-resolves the theme and repaints.
- (void)refreshThemeColors;

// Re-reads waveformNormalize and waveformGainDB and eases the bars to their
// new heights.
- (void)refreshWaveformLevels;

// A WaveformRendererRegistry key, never a display name.
- (void)setWaveformStyle:(NSString *)identifier;

// Clears the previous track's waveform ahead of a new load, and installs the
// persisted renderer style on first use.
- (void)prepareForWaveformLoad;

// A progressive or final snapshot, retained: the wrapper owns the C++ buffer
// the renderers read.
- (void)showWaveform:(CodableAudioWaveform *)waveform;

// Convert to FLAC progress: the bars between the previous fraction and this
// one dip to the midline and ease back. A smaller value just moves the front;
// every presentation reset zeroes it.
@property (nonatomic) double convertSweepFraction;

@end

@protocol AudioWaveformViewDelegate <NSObject>

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage;
// Every resolution of the theme: its settings, the appearance, the artwork
// color. The played side's color, at its resting alpha.
- (void)audioWaveformView:(AudioWaveformView *)waveformView didResolvePlayedColor:(NSColor *)color;

@end

NS_ASSUME_NONNULL_END
