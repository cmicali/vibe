//
//  WaveformView.h
//  Vibe
//

#import <AppKit/AppKit.h>
#import "WaveformTheme.h"

NS_ASSUME_NONNULL_BEGIN

@protocol WaveformViewDelegate;
@class CodableAudioWaveform;

// A pure rendering surface: draws what it is handed and reports seeks.
// Loading and caching are MainPlayerController's AudioWaveformCache.
@interface WaveformView : NSView

@property (nullable, weak) id <WaveformViewDelegate> delegate;

@property CGFloat progress;

// setProgress:'s repaint step count, and the input MainPlayerController scales
// its UI tick by, so drive rate and draw resolution cannot drift apart.
@property (readonly) CGFloat devicePixelWidth;

// For the album_art theme; nil until one settles. The writer matches it
// against the current track first, and follows with refreshThemeColors.
@property (nullable, strong) NSColor *artworkThemeColor;

// Resolves the theme on every resolution: the style change, the appearance
// flip, refreshThemeColors. Installed once by the shell.
@property (nonatomic, copy, nullable) WaveformThemeProvider themeProvider;

// Re-resolves the theme and repaints.
- (void)refreshThemeColors;

// The renderer's geometry and level mapping, pushed by the shell
// (MainPlayerController.applyWaveformSettings) and never read from a store.
// Each lands on the next setWaveformStyle:, which draws: the bars ease to
// the new heights.
@property (nonatomic) CGFloat barDensity;
@property (nonatomic) CGFloat barWidthScale;
@property (nonatomic) BOOL centered;
@property (nonatomic) BOOL normalizesLevels;
@property (nonatomic) float gainDB;

// A drag from the seek band scrubs and seeks on release. Otherwise it
// moves the window. Read once per mouse-down.
@property (nonatomic) BOOL dragSeeks;

// A WaveformRendererRegistry key, never a display name. Also the one draw
// for the pushed properties above, so the shell sets it last.
- (void)setWaveformStyle:(NSString *)identifier;

// Clears the previous track's waveform ahead of a new load.
- (void)prepareForWaveformLoad;

// A progressive or final snapshot, retained: the wrapper owns the C++ buffer
// the renderers read.
- (void)showWaveform:(CodableAudioWaveform *)waveform;

// Convert to FLAC progress: the bars between the previous fraction and this
// one dip to the midline and ease back. A smaller value just moves the front;
// every presentation reset zeroes it.
@property (nonatomic) double convertSweepFraction;

@end

@protocol WaveformViewDelegate <NSObject>

- (void)waveformView:(WaveformView *)waveformView didSeek:(float)percentage;
// Every resolution of the theme: its settings, the appearance, the artwork
// color.
- (void)waveformViewDidResolveTheme:(WaveformView *)waveformView;

@end

NS_ASSUME_NONNULL_END
