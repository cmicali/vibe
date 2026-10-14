//
//  MainPlayerContentViewInternal.h
//  Vibe
//
//  The private surface MainPlayerContentView.m and its +Construction category
//  share: the layout block, the ivars the build writes, and the methods each
//  side calls on the other.
//

#import "MainPlayerContentView.h"
#import "MainWindowLayout.h"

#pragma mark - Layout

// Every frame is authored at the design size (kMainWindowContentWidth by
// kMainWindowDesignHeight), and its mask says how it stretches to the user's
// window. Two bands split at kPlaylistHeight: header above, playlist below.

// The header band is the whole window in the small, playlist-collapsed layout.
static const CGFloat kHeaderHeight = kMainWindowSmallHeight;
static const CGFloat kPlaylistHeight = kMainWindowDesignHeight - kHeaderHeight;

static const CGFloat kArtSize = kHeaderHeight; // square, fills the header band

// Keep glass and tint out of transparent artwork. The window owns the outer
// corners; this panel meets the artwork at a straight edge.
static const CGFloat kHeaderPanelWidth = kMainWindowContentWidth - kArtSize;

// Shared left edge / right margin for everything right of the art.
static const CGFloat kHeaderContentX = kArtSize + 8;
static const CGFloat kHeaderContentRightMargin = 10;
static const CGFloat kHeaderContentWidth =
        kMainWindowContentWidth - kHeaderContentX - kHeaderContentRightMargin;
static const CGFloat kHeaderContentMaxX = kMainWindowContentWidth - kHeaderContentRightMargin;

// An NSTextField draws its text ~2pt inside its frame, so header text frames
// push outward by this to align the ink with the waveform's edges.
static const CGFloat kLabelInkInset = 2;
static const CGFloat kHeaderTextX = kHeaderContentX - kLabelInkInset;
static const CGFloat kHeaderTextMaxX = kHeaderContentMaxX + kLabelInkInset;

static const CGFloat kWaveformY = 215;
static const CGFloat kWaveformHeight = 86;

// The codec line and the BPM line beneath it, right-aligned. The title and
// artist lines size themselves clear of this corner.
static const CGFloat kCodecLabelWidth = 240;
static const CGFloat kCodecLabelX = kHeaderTextMaxX - kCodecLabelWidth;
static const CGFloat kCodecLabelY = 325;
static const CGFloat kBPMLabelY = 307;

// An overrun would draw text over text. The title clears only the shorter BPM
// line and shrinks to fit kTitleWidth; the artist line, at the codec line's
// height, truncates kCodecColumnGutter clear of its text. kArtistWidth
// reserves the codec column's worst case, re-capped against the real text in
// layoutArtistLineClearOfCodecLine.
static const CGFloat kCodecColumnGutter = 12;
// Between the codec text and Buffering…'s spinner after it.
static const CGFloat kCodecSpinnerGap = 5;
static const CGFloat kArtistY = 293;
static const CGFloat kArtistWidth = kCodecLabelX - kCodecColumnGutter - kHeaderTextX;
static const CGFloat kArtistHeight = 48;
static const CGFloat kTitleY = 292;
// Plus the ink inset the x moved left by, so the right cap stays put.
static const CGFloat kTitleWidth = 415 + kLabelInkInset;
static const CGFloat kTitleHeight = 30;

// The time row: elapsed on the left, total on the right, and the empty-state
// hint spanning the gap.
static const CGFloat kSmallLabelHeight = 16;
static const CGFloat kTimeRowY = 207;
static const CGFloat kTimeLabelWidth = 59;
static const CGFloat kTotalTimeX = kHeaderTextMaxX - kTimeLabelWidth;
static const CGFloat kDropHintX = kHeaderContentX + kTimeLabelWidth;
static const CGFloat kDropHintWidth = kTotalTimeX - kDropHintX;
// How far the close hover area reaches past the slider. In the top-right
// corner, the window edges clip it to the corner above the waveform.
static const CGFloat kVolumeHoverOutsetX = 100;
static const CGFloat kVolumeHoverOutsetY = 18;

// The traffic lights: 13pt dots on 23pt centers, like the real macOS
// controls, left-aligned with the playlist icon below.
static const CGFloat kTrafficLightSize = 32;
static const CGFloat kTrafficLightSymbolSize = 13;
static const CGFloat kTrafficLightY = 313;
static const CGFloat kCloseButtonX = 9;
static const CGFloat kTrafficLightSpacing = 23;

// Overlapping frames are fine: later siblings win hit testing. The row sits in
// the art's kArtworkTransportExclusionHeight, where drag-out is refused.
static const CGFloat kTransportButtonSize = 50;
static const CGFloat kTransportButtonY = 203;
static const CGFloat kTransportRowX = 4;
static const CGFloat kTransportButtonSpacing = 46;
// Glyphs draw at roughly 0.8 times their point size.
static const CGFloat kTransportSymbolSize = 31;

// The hover reveal fades to full opacity; each button's resting dimness lives
// in its symbol colors, so a hovered dot reaches full saturation.
static const CFTimeInterval kControlFadeDur = 0.2;
// Like the rest of the empty state.
static const CGFloat kDropHintAlpha = 0.5;

// Light text on dark glass only; dark text needs no shadow.
static const CGFloat kLabelShadowOpacityDark = 0.9;

// Decorative: hit-transparent, so the art's drag-out and the buttons get the
// mouse.
@interface VibePassthroughView : NSView
@end

@interface MainPlayerContentView () {
    VibePassthroughView *_albumArtGradientView;
    NSView *_backgroundGlassView;               // header glass (frost before macOS 26)
    NSVisualEffectView *_playlistFrostView;
    NSView *_playlistDimView;                   // the background layer (applyPlaylistBackground)
    // The controller never drives these.
    SymbolButton *_closeButton;
    SymbolButton *_minimizeButton;
    SymbolButton *_playlistToggleButton;
    NSTrackingArea *_windowHoverArea;
    __weak NSView *_windowHoverHost;
    NSTrackingArea *_volumeHoverArea;
    // An input to the hover fade, not a second writer of the same alpha.
    BOOL _trafficLightsShown;
    BOOL _dropHintShown;
    BOOL _volumeDragging;
    NSTextField *_dropHintTextField;
    // Kept so a theme re-apply redraws the last requested state.
    BOOL _playShowsPause;
    BOOL _transportBackdropDark; // seeded dark for the factory placeholder
    BOOL _transportHasArtwork;
    // Measured at the text edge, reused on every geometry pass.
    CGFloat _codecTextWidth;
    // Buffering…'s spinner, at the codec line's right end.
    NSProgressIndicator *_codecSpinner;
    BOOL _codecSpinnerShown;
    // The header's readonly properties synthesize onto these. They are
    // declared here so the category can assign them.
    SymbolButton *_playButton;
    SymbolButton *_nextButton;
    NSView *_headerTintView;
    NSView *_playlistTintView;
    ArtworkImageView *_albumArtImageView;
    WaveformView *_waveformView;
    NSTextField *_artistTextField;
    NSTextField *_titleTextField;
    NSTextField *_totalTimeTextField;
    NSTextField *_currentTimeTextField;
    VolumeControlView *_volumeControlView;
    NSTextField *_fileMetadataTextField;
    NSTextField *_bpmTextField;
    PlaylistTableView *_playlistTableView;
    PlaylistDropZoneView *_playlistDropZoneView;
}

- (BOOL)isCursorOverWindow;
- (void)setControlsShown:(BOOL)shown animated:(BOOL)animated;
- (void)layoutVolumeControl;
- (void)positionVolumeControl;
- (void)layoutCodecSpinner;

@end

// The build's private half; the public half is in MainPlayerContentView.h.
@interface MainPlayerContentView (ConstructionInternal)

- (void)buildSubviewsWithTarget:(id)target;
- (BOOL)transportGradientEnabled;

@end
