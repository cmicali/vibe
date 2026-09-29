//
//  MainPlayerContentView.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

@class SymbolButton;
@class VibeSlider;
@class ArtworkImageView;
@class AudioWaveformView;
@class PlaylistTableView;
@class PlaylistDropZoneView;

NS_ASSUME_NONNULL_BEGIN

// The main window's body: it builds the views and exposes them for the
// controller to drive. Transparent; the controller's window backdrop is the
// background. Actions go to `target`. Only the pitch-panel reveal pins its
// resizable mask, for the animation (MainPlayerController+Window).
@interface MainPlayerContentView : NSView

- (instancetype)initWithTarget:(id)target;

// Glass takes a layer radius; the pre-26 frost a regenerated mask.
+ (void)applyCornerRadius:(CGFloat)radius toBackdrop:(NSView *)backdrop;

// The header glass panel is hidden under the theme's clear window background.
- (void)applyWindowBackgroundStyle;

// Split so a color drag does not reset fonts, which forces a title re-fit.
- (void)applyThemedLabelFonts;
- (void)applyThemedLabelColors;

// The TransportButtons live effect's body.
- (void)applyThemedTransportButtons;

// The buttons' Dark/Light pair is keyed by what is UNDER them, not by the
// appearance; a visible gradient is dark whatever the art. hasArtwork tells a
// track's cover from the theme's default.
- (void)setTransportBackdropDark:(BOOL)dark hasArtwork:(BOOL)hasArtwork;

// The controller's updateUI is the one caller.
- (void)setPlayButtonShowsPause:(BOOL)showsPause;

// The background under the rows: the glass lift, the solid cover, or none
// under clear. Also runs on every appearance change.
- (void)applyPlaylistBackground;

// Fires after the view's own appearance updates, for state owned elsewhere.
@property (nonatomic, copy, nullable) void (^appearanceChangedHandler)(void);

@property (readonly) SymbolButton *playButton;
@property (readonly) SymbolButton *nextButton;

- (void)setTrafficLightsShown:(BOOL)shown;
// The empty state's hint, in the time row's gap, where the volume control
// swaps with it on hover.
- (void)setDropHintShown:(BOOL)shown;
// The Volume live effect's body: the slider's position and percentage,
// whether the hover reveals them (AppSettings.volumeControl), and the theme's
// tint, labels and corner.
- (void)applyVolumeControl;
// The slider's own action, every tick of a drag and once at the release: the
// percentage, and the hover held open while the knob is in hand.
- (void)volumeSliderDidMove;
// The slider's fill and knob from the theme's volumeBar and volumeKnob.
// Every resolution of the waveform's theme calls it, so a waveform edit and
// an art color reach it.
- (void)applyVolumeColors;

// Plain views the artwork controller washes: the glass's own tintColor is
// dropped while the window is inactive.
@property (readonly) NSView *headerTintView;
@property (readonly) NSView *playlistTintView;
@property (readonly) ArtworkImageView *albumArtImageView;
@property (readonly) AudioWaveformView *waveformView;

@property (readonly) NSTextField *artistTextField;
@property (readonly) NSTextField *titleTextField;
@property (readonly) NSTextField *totalTimeTextField;
@property (readonly) NSTextField *currentTimeTextField;
// "Vol", the slider and the percentage, which fade and hide as one.
@property (readonly) NSView *volumeControlView;
@property (readonly) VibeSlider *volumeSlider;
@property (readonly) NSTextField *fileMetadataTextField;
@property (readonly) NSTextField *bpmTextField;

@property (readonly) PlaylistTableView *playlistTableView;
// Built hidden; the controller drives it from updateUI and forwards the
// window's drag-over events.
@property (readonly) PlaylistDropZoneView *playlistDropZoneView;

// Truncates the artist line clear of the codec line's text. The view re-caps
// on resize itself; TrackDisplayController calls this on every text change.
- (void)layoutArtistLineClearOfCodecLine;

@end

NS_ASSUME_NONNULL_END
