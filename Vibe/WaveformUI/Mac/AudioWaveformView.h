//
//  AudioWaveformView.h
//  Vibe
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AudioWaveformViewDelegate;
@class CodableAudioWaveform;

// A pure rendering surface: it draws whatever waveform it is handed and
// reports seek clicks. Loading and caching live in AudioWaveformCache, which
// MainPlayerController owns. The controller asks the cache to load and routes
// the deliveries through TrackDisplayController's pass-throughs, which reset
// this view with prepareForWaveformLoad and hand results to showWaveform:.
@interface AudioWaveformView : NSView

@property (nullable, weak) id <AudioWaveformViewDelegate> delegate;

@property CGFloat progress;

// The drawing surface's width in device pixels. It is setProgress:'s repaint
// step count, and MainPlayerController's UI tick rate is scaled by the same
// number, so the rate the playhead is driven at and the resolution it is drawn
// at cannot drift apart.
@property (readonly) CGFloat devicePixelWidth;

// The current track's dominant art color for the album_art theme, nil when
// none has settled. MainPlayerController writes it (matched against the
// current track — a stale delivery must never land here) and follows with
// refreshThemeColors.
@property (nullable, strong) NSColor *artworkThemeColor;

// Re-resolves the waveform theme — settings, appearance, artworkThemeColor —
// and repaints the renderer after a stored theme or custom color changes, or
// after an artwork color settles.
- (void)refreshThemeColors;

// Re-reads AppSettings' waveformNormalize and waveformGainDB into the
// renderer and refills its bars from the waveform it already holds, easing
// them to their new heights.
- (void)refreshWaveformLevels;

// Styles are identified by the renderer's stable styleIdentifier
// (WaveformRendererRegistry), never its localized display name.
- (void)setWaveformStyle:(NSString *)identifier;

// Clears the previous track's waveform ahead of a new load, and installs the
// persisted renderer style on first use.
- (void)prepareForWaveformLoad;

// Renders a waveform snapshot: a progressive one mid-load, or the final or
// cache-hit waveform. It retains the snapshot, because the wrapper owns the
// C++ chunk buffer the renderers read.
- (void)showWaveform:(CodableAudioWaveform *)waveform;

// Convert to FLAC progress: the bars between the previous fraction and this
// one collapse to the midline and ease back — a brush moving through the
// waveform. A smaller value just moves the front back; prepareForWaveformLoad
// and the empty and loading states reset it.
@property (nonatomic) double convertSweepFraction;

// What the strip shows when there is no waveform — the loading indicator and
// the empty-state line — is AudioWaveformView+Loading.h, declared where it is
// implemented.
@end

@protocol AudioWaveformViewDelegate <NSObject>

- (void)audioWaveformView:(AudioWaveformView *)waveformView didSeek:(float)percentage;

@end

NS_ASSUME_NONNULL_END
