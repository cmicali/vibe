//
//  MainPlayerContentView.m
//  Vibe
//

#import "MainPlayerContentView.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Window.h" // declares the button action selectors
#import "SymbolButton.h"
#import "DrawnControls.h"
#import "ArtworkImageView.h"
#import "AudioWaveformView.h"
#import "WaveformTheme.h"
#import "PlaylistTableView.h"
#import "PlaylistDropZoneView.h"
#import "NSView+DarkMode.h"
#import "Fonts.h"
#import "Formatters.h"
#import "MainWindowLayout.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "VibeStrings.h"

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
// The volume control's slider, and the gap either side of it; its side
// columns are measured (layoutVolumeControl).
static const CGFloat kVolumeSliderWidth = 100;
static const CGFloat kVolumeGap = 6;

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

// The slider is on and the theme puts it in the top-right corner, where it
// swaps with the codec and BPM lines on hover.
static BOOL VolumeAtTopRight(AppSettings *settings) {
    return settings.volumeControl && [settings.currentTheme.volumeLocation
            isEqualToString:SETTINGS_VALUE_VOLUME_LOCATION_TOP_RIGHT];
}

// Decorative: hit-transparent, so the art's drag-out and the buttons get the
// mouse.
@interface VibePassthroughView : NSView
@end

@implementation VibePassthroughView
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
@end

// Clicks on the empty header fall through to the window's background drag.
API_AVAILABLE(macos(26.0))
@interface VibePassthroughGlassView : NSGlassEffectView
@end

@implementation VibePassthroughGlassView
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
@end

@interface VibePassthroughFrostView : NSVisualEffectView
@end

@implementation VibePassthroughFrostView
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
@end

@implementation MainPlayerContentView {
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
    // An input to the hover fade, not a second writer of the same alpha.
    BOOL _trafficLightsShown;
    BOOL _dropHintShown;
    BOOL _volumeDragging;
    NSTextField *_dropHintTextField;
    NSTextField *_volumeLabel;
    NSTextField *_volumePercentLabel;
    NSDictionary *_volumePercentAttributes; // rebuilt with the theme's colors
    // Kept so a theme re-apply redraws the last requested state.
    BOOL _playShowsPause;
    BOOL _transportBackdropDark; // seeded dark for the factory placeholder
    BOOL _transportHasArtwork;
    // Measured at the text edge, reused on every geometry pass.
    CGFloat _codecTextWidth;
}

- (instancetype)initWithTarget:(id)target {
    self = [super initWithFrame:NSMakeRect(0, 0, kMainWindowContentWidth, kMainWindowDesignHeight)];
    if (self) {
        // A zero-filled ivar would silently lose the buttons.
        _trafficLightsShown = YES;
        _transportBackdropDark = YES;
        self.wantsLayer = YES;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self buildSubviewsWithTarget:target];
        [self updateMaterialForAppearance];
    }
    return self;
}

- (void)updateMaterialForAppearance {
    BOOL dark = self.isDark;
    // Both appearances: the light WindowBackground material is effectively
    // opaque paint.
    _playlistFrostView.material = NSVisualEffectMaterialUnderWindowBackground;
    [self applyPlaylistBackground];
    // A dark shadow under dark text reads as smudge.
    CGFloat shadowOpacity = dark ? kLabelShadowOpacityDark : 0.0;
    for (NSTextField *field in @[ _artistTextField, _titleTextField,
                                  _totalTimeTextField, _currentTimeTextField,
                                  _dropHintTextField, _volumeLabel, _volumePercentLabel,
                                  _fileMetadataTextField, _bpmTextField ]) {
        field.layer.shadowOpacity = shadowOpacity;
    }
    [self applyVolumeColors];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateMaterialForAppearance];
    if (self.appearanceChangedHandler) {
        self.appearanceChangedHandler();
    }
}

// Rasterizing layers pin their scale, so re-stamp it whenever the backing
// scale can change, or the text renders soft.
- (void)updateRasterizationScales {
    CGFloat scale = self.window.backingScaleFactor;
    if (scale <= 0) {
        scale = NSScreen.mainScreen.backingScaleFactor;
    }
    _albumArtImageView.layer.rasterizationScale = scale;
    for (NSTextField *field in @[ _artistTextField, _titleTextField,
                                  _totalTimeTextField, _dropHintTextField,
                                  _fileMetadataTextField, _bpmTextField, _volumeLabel ]) {
        field.layer.rasterizationScale = scale;
    }
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateRasterizationScales];
}

#pragma mark - The artist line's right edge

// The one frame that clears content, not geometry: the artist line ends where
// the codec line's text begins. Both inputs move: the geometry (resize, below)
// and the text (TrackDisplayController).
// TRAP: measure with the field's own font. The codec run's attributes carry
// no font (cornerTextAttributes), so -size measures it at the 12pt default and
// under a larger themed face the artist line runs under the codec text.
- (CGFloat)renderedCodecTextWidth {
    NSAttributedString *text = _fileMetadataTextField.attributedStringValue;
    NSFont *font = _fileMetadataTextField.font;
    if (text.length == 0 || !font) {
        return ceil(text.size.width);
    }
    NSMutableAttributedString *measured = [text mutableCopy];
    [measured enumerateAttribute:NSFontAttributeName
                         inRange:NSMakeRange(0, measured.length)
                         options:0
                      usingBlock:^(NSFont *run, NSRange range, BOOL *stop) {
        if (!run) {
            [measured addAttribute:NSFontAttributeName value:font range:range];
        }
    }];
    return ceil(measured.size.width);
}

// The text edge: measures the codec line once, then caps the artist line.
- (void)layoutArtistLineClearOfCodecLine {
    _codecTextWidth = [self renderedCodecTextWidth];
    [self capArtistLineAtCodecText];
}

// In the corner the line clears whichever of the codec text and the volume
// control reaches further left, so it never moves as the two swap on hover.
- (void)capArtistLineAtCodecText {
    CGFloat clearX = NSMaxX(_fileMetadataTextField.frame) - _codecTextWidth;
    if (VolumeAtTopRight(AppSettings.sharedInstance)) {
        clearX = MIN(clearX, NSMinX(_volumeControlView.frame));
    }
    clearX -= kCodecColumnGutter;
    NSRect frame = _artistTextField.frame;
    frame.size.width = MAX(0, clearX - NSMinX(frame));
    if (!NSEqualRects(frame, _artistTextField.frame)) {
        _artistTextField.frame = frame;
    }
}

// Every frame change, live drag included. Geometry only: the text is not
// re-measured per frame.
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self positionVolumeControl];
    [self capArtistLineAtCodecText];
}

#pragma mark - Hover reveal

// The tracking area is on the window's content view, so hovering the pitch
// panel keeps the buttons up too.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self updateRasterizationScales];
    if (_windowHoverArea) {
        [_windowHoverHost removeTrackingArea:_windowHoverArea];
        _windowHoverArea = nil;
        _windowHoverHost = nil;
    }
    NSView *host = self.window.contentView;
    if (!host) {
        return;
    }
    _windowHoverHost = host;
    _windowHoverArea = [[NSTrackingArea alloc]
            initWithRect:host.bounds
                 options:NSTrackingActiveAlways | NSTrackingInVisibleRect |
                         NSTrackingMouseEnteredAndExited
                   owner:self userInfo:nil];
    [host addTrackingArea:_windowHoverArea];
    // Entered and exited fire only on crossings; seed from the cursor.
    [self setControlsShown:[self isCursorOverWindow] animated:NO];
}

- (BOOL)isCursorOverWindow {
    NSView *host = _windowHoverHost;
    if (!host.window) {
        return NO;
    }
    NSPoint p = [host convertPoint:host.window.mouseLocationOutsideOfEventStream fromView:nil];
    return NSMouseInRect(p, host.bounds, host.isFlipped);
}

- (void)setTrafficLightsShown:(BOOL)shown {
    _trafficLightsShown = shown;
    // Hidden and alpha are decided in one place, the fade funnel.
    [self setControlsShown:[self isCursorOverWindow] animated:NO];
}

- (void)mouseEntered:(NSEvent *)event {
    [self setControlsShown:YES animated:YES];
}

- (void)mouseExited:(NSEvent *)event {
    [self setControlsShown:NO animated:YES];
}

// The one place button visibility is decided, so a hidden button never fades
// to full alpha behind its hidden flag.
static NSView *FadeTarget(NSView *view, BOOL animated) {
    return animated ? view.animator : view;
}

- (void)setControlsShown:(BOOL)shown animated:(BOOL)animated {
    shown = shown || _volumeDragging;
    CGFloat traffic   = (shown && _trafficLightsShown) ? 1.0 : 0.0;
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;
    BOOL transportShown = theme.showTransportButtons;
    CGFloat transport = (shown && transportShown) ? 1.0 : 0.0;
    // The volume control swaps with whatever shares its place: the corner
    // readouts, or the time row's drop hint.
    BOOL volumeShown = settings.volumeControl;
    BOOL corner = VolumeAtTopRight(settings);
    CGFloat volume = (shown && volumeShown) ? 1.0 : 0.0;
    CGFloat readouts = (shown && corner) ? 0.0 : 1.0;
    CGFloat hint = (shown && volumeShown && !corner) ? 0.0 : kDropHintAlpha;
    BOOL gradientEnabled = self.transportGradientEnabled;
    CGFloat gradient = gradientEnabled && (shown || ![theme.buttonGradient isEqualToString:SETTINGS_VALUE_BUTTON_GRADIENT_HOVER]) ? 1 : 0;
    _albumArtGradientView.hidden = !gradientEnabled;
    _playlistToggleButton.hidden = !transportShown;
    _playButton.hidden = !transportShown;
    _nextButton.hidden = !transportShown;
    _volumeControlView.hidden = !volumeShown;
    _dropHintTextField.hidden = !_dropHintShown;
    _closeButton.hidden = !_trafficLightsShown;
    _minimizeButton.hidden = !_trafficLightsShown;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = kControlFadeDur;
        FadeTarget(self->_closeButton, animated).alphaValue = traffic;
        FadeTarget(self->_minimizeButton, animated).alphaValue = traffic;
        FadeTarget(self->_playlistToggleButton, animated).alphaValue = transport;
        FadeTarget(self->_playButton, animated).alphaValue = transport;
        FadeTarget(self->_nextButton, animated).alphaValue = transport;
        FadeTarget(self->_volumeControlView, animated).alphaValue = volume;
        FadeTarget(self->_fileMetadataTextField, animated).alphaValue = readouts;
        FadeTarget(self->_bpmTextField, animated).alphaValue = readouts;
        FadeTarget(self->_dropHintTextField, animated).alphaValue = hint;
        FadeTarget(self->_albumArtGradientView, animated).alphaValue = gradient;
    }];
}

- (void)setDropHintShown:(BOOL)shown {
    if (shown == _dropHintShown) {
        return;
    }
    _dropHintShown = shown;
    [self setControlsShown:[self isCursorOverWindow] animated:NO];
}

- (void)applyVolumeControl {
    _volumeSlider.doubleValue = AppSettings.sharedInstance.volume;
    [self layoutVolumeControl]; // renders the percentage
    [self capArtistLineAtCodecText];
    [self applyVolumeColors];
    [self setControlsShown:[self isCursorOverWindow] animated:NO];
}

// TRAP: the pointer can leave the window mid-drag, and fading the control
// then leaves the knob in hand invisible, still setting the volume. The drag
// holds the hover open; the release re-decides it from the pointer. The hold
// rests on the slider sending its action once more at the mouse-up: nothing
// else clears it.
- (void)volumeSliderDidMove {
    [self renderVolumePercent];
    NSEventType type = NSApp.currentEvent.type;
    BOOL dragging = type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseDragged;
    if (dragging != _volumeDragging) {
        _volumeDragging = dragging;
        [self setControlsShown:[self isCursorOverWindow] animated:YES];
    }
}

- (BOOL)volumeDragging {
    return _volumeDragging;
}

- (void)renderVolumePercent {
    NSString *percent = [[Formatters sharedInstance] percentString:AppSettings.sharedInstance.volume];
    _volumePercentLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:percent
                                                                                 attributes:_volumePercentAttributes];
}

// The corner readouts' kerning, in the artist's color.
static NSDictionary *VolumeTextAttributes(NSTextAlignment alignment, NSColor *color) {
    NSMutableDictionary *attributes = [[Fonts infoTextAttributesAligned:alignment] mutableCopy];
    attributes[NSForegroundColorAttributeName] = color;
    return attributes;
}

// A column's width for a string as the label's own cell lays it out, which
// the bare string's size is not: the readouts' negative kern leaves that
// short, and a centered cell drops a last glyph it cannot fit.
static CGFloat LabelCellWidth(NSTextField *label, NSString *string, NSTextAlignment alignment) {
    NSTextFieldCell *cell = [label.cell copy];
    cell.attributedStringValue = [[NSAttributedString alloc] initWithString:string
            attributes:[Fonts infoTextAttributesAligned:alignment]];
    return ceil(cell.cellSize.width);
}

// Both side columns are the wider of "Vol" and "100%" in the current face, so
// neither clips and the slider sits at the control's center.
- (void)layoutVolumeControl {
    BOOL labels = AppSettings.sharedInstance.currentTheme.showVolumeLabels;
    CGFloat side = 0, gap = 0;
    [self applyVolumePercentStyle];
    if (labels) {
        NSString *full = [[Formatters sharedInstance] percentString:1.0];
        side = MAX(LabelCellWidth(_volumeLabel, STR_LABEL_VOLUME, NSTextAlignmentRight),
                   LabelCellWidth(_volumePercentLabel, full, self.volumePercentAlignment));
        gap = kVolumeGap;
    }
    CGFloat width = 2 * side + 2 * gap + kVolumeSliderWidth;
    NSRect frame = _volumeControlView.frame;
    frame.size.width = width;
    _volumeControlView.frame = frame;
    _volumeLabel.hidden = !labels;
    _volumePercentLabel.hidden = !labels;
    _volumeLabel.frame = NSMakeRect(0, 0, side, kSmallLabelHeight);
    _volumeSlider.frame = NSMakeRect(side + gap, 0, kVolumeSliderWidth, kSmallLabelHeight);
    _volumePercentLabel.frame = NSMakeRect(width - side, 0, side, kSmallLabelHeight);
    [self positionVolumeControl];
}

// In the time row the percentage hugs the slider; in the corner it is
// right-aligned on the total time's edge, like the time, so the two stack.
- (NSTextAlignment)volumePercentAlignment {
    return VolumeAtTopRight(AppSettings.sharedInstance) ? NSTextAlignmentRight : NSTextAlignmentLeft;
}

- (void)applyVolumePercentStyle {
    _volumePercentAttributes = VolumeTextAttributes(self.volumePercentAlignment,
            AppSettings.sharedInstance.currentTheme.resolvedArtistColor);
    [self renderVolumePercent];
}

// Placed from its neighbors, never by the mask: in the time row its margins
// are unequal, so AppKit's proportional share of a resize walks the control
// toward the elapsed time. In the corner it ends where the total time below
// does, and its bottom sits on the title's cap height — the frame's top
// carries the ascender's headroom — measured on the theme's face, not the
// refit one, so a long title does not move it.
- (void)positionVolumeControl {
    NSRect frame = _volumeControlView.frame;
    AppSettings *settings = AppSettings.sharedInstance;
    if (VolumeAtTopRight(settings)) {
        // A bare slider has no text inset of its own, so it ends at the ink.
        CGFloat inset = settings.currentTheme.showVolumeLabels ? 0 : kLabelInkInset;
        NSFont *title = [Fonts titleFont];
        frame.origin.x = NSMaxX(_totalTimeTextField.frame) - inset - frame.size.width;
        frame.origin.y = round(NSMaxY(_titleTextField.frame) - (title.ascender - title.capHeight));
    } else {
        CGFloat center = (NSMaxX(_currentTimeTextField.frame) + NSMinX(_totalTimeTextField.frame)) / 2;
        frame.origin.x = round(center - frame.size.width / 2);
        frame.origin.y = NSMinY(_currentTimeTextField.frame);
    }
    if (!NSEqualRects(frame, _volumeControlView.frame)) {
        _volumeControlView.frame = frame;
    }
}

// None (nil) is the system slider's. Waveform is the played color the
// waveform draws; Artwork is the album_art clamp of the art color, Mono's
// played color for no art or too gray a one; Custom is used exactly as picked.
- (NSColor *)volumeColorForChoice:(NSString *)choice base:(NSString *)base theme:(AppTheme *)theme {
    BOOL dark = self.isDark;
    NSColor *art = _waveformView.artworkThemeColor;
    if ([choice isEqualToString:SETTINGS_VALUE_VOLUME_WAVEFORM]) {
        return [[WaveformTheme themeForAppTheme:theme isDark:dark artworkColor:art].playedColor
                colorWithAlphaComponent:1.0];
    }
    if ([choice isEqualToString:SETTINGS_VALUE_WINDOW_TINT_ARTWORK]) {
        return [WaveformTheme legibleArtworkColor:art isDark:dark]
                ?: [[WaveformTheme monochromeThemeIsDark:dark].playedColor colorWithAlphaComponent:1.0];
    }
    if ([choice isEqualToString:SETTINGS_VALUE_WINDOW_TINT_CUSTOM]) {
        return [theme displayColorForBase:base dark:dark];
    }
    return nil;
}

// None's knob is the system's white pill. Same as bar, the knob's default, is
// the color the bar draws: under None that is the system accent, not the nil
// that means a white knob.
- (void)applyVolumeColors {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    NSColor *fill = [self volumeColorForChoice:theme.volumeBar base:kVibeThemeColorVolumeBar theme:theme];
    _volumeSlider.trackFillColor = fill;
    _volumeSlider.knobColor = [theme.volumeKnob isEqualToString:SETTINGS_VALUE_VOLUME_KNOB_BAR]
            ? (fill ?: NSColor.controlAccentColor)
            : [self volumeColorForChoice:theme.volumeKnob base:kVibeThemeColorVolumeKnob theme:theme];
}

// updateMaterialForAppearance sets the opacity. A field that changes every
// second opts out of rasterization.
static void configureLabelShadow(NSTextField *field, BOOL rasterize) {
    field.wantsLayer = YES;
    field.layer.shadowColor = NSColor.blackColor.CGColor;
    field.layer.shadowRadius = 0.25;
    field.layer.shadowOffset = CGSizeMake(0, -1);
    field.layer.masksToBounds = NO;
    field.layer.shouldRasterize = rasterize;
    if (rasterize) {
        field.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;
    }
}

#pragma mark - Subview construction

// The call order below IS the z-order.

- (void)buildSubviewsWithTarget:(id)target {
    [self buildHeaderBackdrop];
    [self buildAlbumArt];
    [self buildTransportControlsWithTarget:target];
    [self buildHeaderLabels];
    [self buildPlaylistPane];
    [self buildCornerReadouts];
    // Above the corner readouts, which keep catching clicks at zero alpha.
    [self buildVolumeControlWithTarget:target];
    [self applyThemedLabelFonts];
    [self applyThemedLabelColors];
    [self applyThemedTransportButtons];
    [self applyWindowBackgroundStyle];
}

// Hidden under clear rather than restyled Clear: a second Clear pane over the
// backdrop compounds into a visibly lighter band.
- (void)applyWindowBackgroundStyle {
    _backgroundGlassView.hidden = [AppSettings.sharedInstance.currentTheme.windowBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR];
}

- (void)buildHeaderBackdrop {
    NSRect headerPanelFrame = NSMakeRect(kArtSize, kPlaylistHeight, kHeaderPanelWidth, kHeaderHeight);
    if (@available(macOS 26.0, *)) {
        _backgroundGlassView = [[VibePassthroughGlassView alloc] initWithFrame:headerPanelFrame];
    }
    else {
        VibePassthroughFrostView *frost = [[VibePassthroughFrostView alloc] initWithFrame:headerPanelFrame];
        frost.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        frost.state = NSVisualEffectStateActive; // never dims, like the playlist frost
        frost.material = NSVisualEffectMaterialUnderWindowBackground;
        _backgroundGlassView = frost;
    }
    [MainPlayerContentView applyCornerRadius:0 toBackdrop:_backgroundGlassView];
    // Fixed height: see the playlist frost's trap.
    _backgroundGlassView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_backgroundGlassView];

    // Not the glass's tintColor, which AppKit drops while the window is
    // inactive.
    _headerTintView = [[VibePassthroughView alloc] initWithFrame:_backgroundGlassView.frame];
    _headerTintView.wantsLayer = YES;
    _headerTintView.autoresizingMask = _backgroundGlassView.autoresizingMask;
    [self addSubview:_headerTintView];

    _waveformView = [[AudioWaveformView alloc] initWithFrame:
            NSMakeRect(kHeaderContentX, kWaveformY, kHeaderContentWidth, kWaveformHeight)];
    _waveformView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_waveformView];
}

- (void)buildAlbumArt {
    _albumArtImageView = [[ArtworkImageView alloc] initWithFrame:
            NSMakeRect(0, kPlaylistHeight, kArtSize, kArtSize)];
    _albumArtImageView.image = AppSettings.sharedInstance.currentTheme.resolvedDefaultArtworkImage;
    _albumArtImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _albumArtImageView.refusesFirstResponder = YES;
    _albumArtImageView.focusRingType = NSFocusRingTypeNone;
    _albumArtImageView.wantsLayer = YES;
    _albumArtImageView.layer.shadowRadius = 6;
    _albumArtImageView.layer.shadowOpacity = 0.25;
    _albumArtImageView.layer.shadowOffset = CGSizeMake(4, 0);
    _albumArtImageView.layer.masksToBounds = NO;
    _albumArtImageView.layer.shouldRasterize = true;
    _albumArtImageView.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;
    _albumArtImageView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_albumArtImageView];

    // Darkens the art behind the transport row; visibility follows the
    // theme's buttonGradient (setControlsShown:animated:).
    _albumArtGradientView = [[VibePassthroughView alloc] initWithFrame:
            NSMakeRect(0, kPlaylistHeight, kArtSize, kArtSize)];
    CAGradientLayer *artGradient = [[CAGradientLayer alloc] init];
    artGradient.colors = @[
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.96].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.55].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0].CGColor
    ];
    artGradient.locations = @[@0.0, @0.35, @0.62];
    // Layer-hosting: the layer before wantsLayer, or the view ends up
    // layer-backed.
    _albumArtGradientView.layer = artGradient;
    _albumArtGradientView.identifier = @"buttonGradient";
    _albumArtGradientView.wantsLayer = YES;
    _albumArtGradientView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_albumArtGradientView];
}

// All five start at zero alpha; see setControlsShown:animated:.
- (void)buildTransportControlsWithTarget:(id)target {
    _closeButton = [MainPlayerContentView transportButtonWithFrame:
                            NSMakeRect(kCloseButtonX, kTrafficLightY, kTrafficLightSize, kTrafficLightSize)
                                                        symbolName:@"circle.fill"
                                                             label:STR_A11Y_WINDOW_CLOSE
                                                            action:@selector(closeApp:)
                                                            target:target];
    _closeButton.alphaValue = 0.0;
    _closeButton.symbolPointSize = kTrafficLightSymbolSize;
    _closeButton.symbolNormalColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:0.64];
    _closeButton.symbolHighlightColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:1.0];
    [self addSubview:_closeButton];

    _minimizeButton = [MainPlayerContentView transportButtonWithFrame:
                               NSMakeRect(kCloseButtonX + kTrafficLightSpacing, kTrafficLightY,
                                          kTrafficLightSize, kTrafficLightSize)
                                                           symbolName:@"circle.fill"
                                                                label:STR_A11Y_WINDOW_MINIMIZE
                                                               action:@selector(minimizeWindow:)
                                                               target:target];
    _minimizeButton.alphaValue = 0.0;
    _minimizeButton.symbolPointSize = kTrafficLightSymbolSize; // same dot as close
    _minimizeButton.symbolNormalColor = [NSColor colorWithSRGBRed:0.988 green:0.741 blue:0.180 alpha:0.64];
    _minimizeButton.symbolHighlightColor = [NSColor colorWithSRGBRed:0.988 green:0.741 blue:0.180 alpha:1.0];
    [self addSubview:_minimizeButton];

    _playlistToggleButton = [MainPlayerContentView transportButtonWithFrame:
                                     NSMakeRect(kTransportRowX, kTransportButtonY,
                                                kTransportButtonSize, kTransportButtonSize)
                                                                 symbolName:@"list.bullet"
                                                                      label:STR_A11Y_TOGGLE_PLAYLIST
                                                                     action:@selector(toggleSize:)
                                                                     target:target];
    _playlistToggleButton.alphaValue = 0.0;
    [self addSubview:_playlistToggleButton];

    _playButton = [MainPlayerContentView transportButtonWithFrame:
                           NSMakeRect(kTransportRowX + kTransportButtonSpacing, kTransportButtonY,
                                      kTransportButtonSize, kTransportButtonSize)
                                                       symbolName:@"play.fill"
                                                            label:STR_TRANSPORT_PLAY
                                                           action:@selector(playPause:)
                                                           target:target];
    _playButton.alphaValue = 0.0;
    _playButton.enabled = NO;
    [self addSubview:_playButton];

    _nextButton = [MainPlayerContentView transportButtonWithFrame:
                           NSMakeRect(kTransportRowX + 2 * kTransportButtonSpacing, kTransportButtonY,
                                      kTransportButtonSize, kTransportButtonSize)
                                                       symbolName:@"forward.end.fill"
                                                            label:STR_TRANSPORT_NEXT
                                                           action:@selector(next:)
                                                           target:target];
    _nextButton.alphaValue = 0.0;
    _nextButton.enabled = NO;
    [self addSubview:_nextButton];
}

- (void)buildHeaderLabels {
    NSColor *dimmedTextColor = [NSColor secondaryLabelColor];

    _artistTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kHeaderTextX, kArtistY, kArtistWidth, kArtistHeight)];
    // Truncating, not the clipping default: long artist tags are common, and
    // clipping cuts a glyph mid-stroke with no sign the string goes on.
    _artistTextField.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_artistTextField, YES);
    [self addSubview:_artistTextField];

    _titleTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kHeaderTextX, kTitleY, kTitleWidth, kTitleHeight)];
    _titleTextField.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_titleTextField, YES);
    [self addSubview:_titleTextField];

    _totalTimeTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kTotalTimeX, kTimeRowY, kTimeLabelWidth, kSmallLabelHeight)];
    _totalTimeTextField.alignment = NSTextAlignmentRight;
    _totalTimeTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_totalTimeTextField, YES);
    [self addSubview:_totalTimeTextField];

    _currentTimeTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kHeaderTextX, kTimeRowY, kTimeLabelWidth, kSmallLabelHeight)];

    // Left-anchored, unlike the right-aligned total time it pairs with.
    _currentTimeTextField.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    // Not rasterized: it changes every second.
    configureLabelShadow(_currentTimeTextField, NO);
    [self addSubview:_currentTimeTextField];

    _dropHintTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kDropHintX, kTimeRowY, kDropHintWidth, kSmallLabelHeight)];
    _dropHintTextField.font = [Fonts font:13];
    _dropHintTextField.alignment = NSTextAlignmentCenter;
    _dropHintTextField.textColor = dimmedTextColor;
    // The shortcut is a separate argument so a translation can move it in the sentence.
    _dropHintTextField.stringValue = [NSString stringWithFormat:STR_LABEL_DROP_HINT,
                                                                VibeNotLocalized(@"⌘O")];
    // Long translations ellipsize.
    _dropHintTextField.lineBreakMode = NSLineBreakByTruncatingTail;
    _dropHintTextField.maximumNumberOfLines = 1;
    _dropHintTextField.alphaValue = kDropHintAlpha;
    _dropHintTextField.hidden = YES;
    _dropHintTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_dropHintTextField, YES);
    [self addSubview:_dropHintTextField];
}

// One view, so the three fade and hide together; it starts at zero alpha,
// like the transport (setControlsShown:animated:). Sized by
// layoutVolumeControl and placed by positionVolumeControl, never the mask.
- (void)buildVolumeControlWithTarget:(id)target {
    _volumeControlView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 0, kSmallLabelHeight)];
    _volumeControlView.alphaValue = 0.0;
    [self addSubview:_volumeControlView];

    _volumeLabel = [MainPlayerContentView labelWithFrame:NSZeroRect];
    configureLabelShadow(_volumeLabel, YES);
    [_volumeControlView addSubview:_volumeLabel];

    _volumePercentLabel = [MainPlayerContentView labelWithFrame:NSZeroRect];
    // Not rasterized: it changes under a drag.
    configureLabelShadow(_volumePercentLabel, NO);
    [_volumeControlView addSubview:_volumePercentLabel];

    _volumeSlider = [[VibeSlider alloc] initWithFrame:NSZeroRect];
    _volumeSlider.doubleValue = AppSettings.sharedInstance.volume;
    _volumeSlider.accessibilityLabel = STR_A11Y_VOLUME;
    _volumeSlider.target = target;
    _volumeSlider.action = @selector(volumeChanged:);
    [_volumeControlView addSubview:_volumeSlider];
}

// Bottom to top: the frost, the background layer, the tint wash, the table,
// and the drop zone.
- (void)buildPlaylistPane {
    // Row text is unreadable over the window's Clear glass, so the playlist
    // gets its own frost. TRAP: an NSVisualEffectView, not an
    // NSGlassEffectView: a glass view stretched from design height to window
    // height fights the autoresizing (its SwiftUI hosting), and the window
    // silently refuses to grow past the design height. Under the scroll view,
    // since an NSClipView background does not composite translucent colors.
    _playlistFrostView = [[NSVisualEffectView alloc] initWithFrame:
            NSMakeRect(0, 0, kMainWindowContentWidth, kPlaylistHeight)];
    _playlistFrostView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _playlistFrostView.state = NSVisualEffectStateActive;
    _playlistFrostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistFrostView];

    // A sibling, never the frost's child: the solid style hides the frost and
    // keeps this as the whole background.
    _playlistDimView = [[NSView alloc] initWithFrame:_playlistFrostView.frame];
    _playlistDimView.wantsLayer = YES;
    _playlistDimView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistDimView];

    // The playlist's headerTintView.
    _playlistTintView = [[NSView alloc] initWithFrame:_playlistFrostView.frame];
    _playlistTintView.wantsLayer = YES;
    _playlistTintView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistTintView];

    NSScrollView *playlistScrollView = [PlaylistTableView scrollViewWithFrame:
            NSMakeRect(0, 0, kMainWindowContentWidth, kPlaylistHeight)];
    _playlistTableView = (PlaylistTableView *)playlistScrollView.documentView;
    [self addSubview:playlistScrollView];

    // Hit-transparent while neither presentation is up.
    _playlistDropZoneView = [[PlaylistDropZoneView alloc] initWithFrame:
            NSMakeRect(0, 0, kMainWindowContentWidth, kPlaylistHeight)];
    _playlistDropZoneView.hidden = YES;
    _playlistDropZoneView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistDropZoneView];
}

// One visual pair: a font, an alignment and a dimming rule.
- (void)buildCornerReadouts {
    _fileMetadataTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kCodecLabelX, kCodecLabelY, kCodecLabelWidth, kSmallLabelHeight)];
    _fileMetadataTextField.alignment = NSTextAlignmentRight;
    // Full alpha: a field alpha would dim the inline FX symbols too, so the
    // text dims in its color (cornerTextAttributes).
    _fileMetadataTextField.alphaValue = 1.0;
    _fileMetadataTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_fileMetadataTextField, YES);
    [self addSubview:_fileMetadataTextField];

    _bpmTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kCodecLabelX, kBPMLabelY, kCodecLabelWidth, kSmallLabelHeight)];
    _bpmTextField.alignment = NSTextAlignmentRight;
    _bpmTextField.alphaValue = 1.0;
    _bpmTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_bpmTextField, YES);
    [self addSubview:_bpmTextField];
}

+ (SymbolButton *)transportButtonWithFrame:(NSRect)frame
                                symbolName:(NSString *)symbolName
                                     label:(NSString *)label
                                    action:(SEL)action
                                    target:(id)target {
    SymbolButton *button = [[SymbolButton alloc] initWithFrame:frame];
    button.symbolName = symbolName;
    button.symbolPointSize = kTransportSymbolSize;
    button.accessibilityLabel = label;
    button.target = target;
    button.action = action;
    button.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    return button;
}

- (void)applyThemedLabelFonts {
    _artistTextField.font = [Fonts artistFont];
    _titleTextField.font = [Fonts titleFont];
    _totalTimeTextField.font = [Fonts infoFontBold:YES];
    _currentTimeTextField.font = [Fonts infoFontBold:YES];
    _fileMetadataTextField.font = [Fonts infoFontBold:NO];
    _bpmTextField.font = [Fonts infoFontBold:NO];
    _volumeLabel.font = [Fonts infoFontBold:NO];
    _volumePercentLabel.font = [Fonts infoFontBold:NO];
    [self layoutVolumeControl];
    // A font change moves the codec line's measure too.
    [self layoutArtistLineClearOfCodecLine];
}

- (void)applyThemedLabelColors {
    // The corner readouts' color rides their attributed strings; the drop hint
    // stays unthemed.
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    _titleTextField.textColor = theme.resolvedTitleColor;
    _artistTextField.textColor = theme.resolvedArtistColor;
    _totalTimeTextField.textColor = theme.resolvedTimeColor;
    _currentTimeTextField.textColor = theme.resolvedTimeColor;
    _volumeLabel.attributedStringValue = [[NSAttributedString alloc] initWithString:STR_LABEL_VOLUME
            attributes:VolumeTextAttributes(NSTextAlignmentRight, theme.resolvedArtistColor)];
    [self applyVolumePercentStyle];
}

// A glyph this macOS has, else the factory one, as Fonts falls back from an
// uninstalled face: a button drawing nothing is never the answer.
static NSString *ResolvedGlyph(NSString *glyph, NSString *factory) {
    // Fixed within a run, and the probe allocates an image.
    static NSMutableDictionary<NSString *, NSNumber *> *known;
    if (!known) {
        known = [NSMutableDictionary dictionary];
    }
    NSNumber *has = known[glyph];
    if (has == nil) {
        has = @([NSImage imageWithSystemSymbolName:glyph accessibilityDescription:nil] != nil);
        known[glyph] = has;
    }
    return has.boolValue ? glyph : factory;
}

static void ApplyThemeToButton(SymbolButton *button, AppTheme *theme, NSString *imageKey,
                               NSString *glyph, NSString *factoryGlyph,
                               NSString *colorBase, BOOL dark) {
    button.image = [theme buttonImageForKey:imageKey];
    button.symbolName = ResolvedGlyph(glyph, factoryGlyph);
    [button setSymbolColorsFromRestingColor:[theme displayColorForBase:colorBase dark:dark]];
}

- (BOOL)transportGradientEnabled {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    return theme.showTransportButtons
            && ![theme.buttonGradient isEqualToString:SETTINGS_VALUE_BUTTON_GRADIENT_NONE]
            && (![theme.buttonGradient isEqualToString:SETTINGS_VALUE_BUTTON_GRADIENT_ARTWORK] || _transportHasArtwork);
}

// An enabled gradient is under every visible button, so it reads dark;
// otherwise the image's lower band decides.
- (BOOL)transportBackdropIsDark {
    return self.transportGradientEnabled || _transportBackdropDark;
}

- (void)applyThemedTransportButtons {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL dark = self.transportBackdropIsDark;
    ApplyThemeToButton(_playlistToggleButton, theme,
                       dark ? kVibeThemeImagePlaylistButtonDark : kVibeThemeImagePlaylistButtonLight,
                       theme.playlistButtonGlyph, kVibeThemePlaylistButtonGlyphDefault,
                       kVibeThemeColorPlaylistButton, dark);
    ApplyThemeToButton(_nextButton, theme,
                       dark ? kVibeThemeImageNextButtonDark : kVibeThemeImageNextButtonLight,
                       theme.nextButtonGlyph, kVibeThemeNextButtonGlyphDefault,
                       kVibeThemeColorNextButton, dark);
    [self dressPlayButton];
    [self setControlsShown:[self isCursorOverWindow] animated:NO];
}

- (void)setTransportBackdropDark:(BOOL)dark hasArtwork:(BOOL)hasArtwork {
    if (_transportBackdropDark == dark && _transportHasArtwork == hasArtwork) {
        return;
    }
    _transportBackdropDark = dark;
    _transportHasArtwork = hasArtwork;
    [self applyThemedTransportButtons];
}

// Each image slot falls back to its own glyph, so a theme with only a play
// image still shows a pause glyph while playing.
- (void)setPlayButtonShowsPause:(BOOL)showsPause {
    // updateUI asks on every transport event.
    if (showsPause == _playShowsPause) {
        return;
    }
    _playShowsPause = showsPause;
    [self dressPlayButton];
}

- (void)dressPlayButton {
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL dark = self.transportBackdropIsDark, pause = _playShowsPause;
    NSString *imageKey = pause ? (dark ? kVibeThemeImagePauseButtonDark : kVibeThemeImagePauseButtonLight)
                               : (dark ? kVibeThemeImagePlayButtonDark : kVibeThemeImagePlayButtonLight);
    ApplyThemeToButton(_playButton, theme, imageKey,
                       pause ? theme.pauseButtonGlyph : theme.playButtonGlyph,
                       pause ? kVibeThemePauseButtonGlyphDefault : kVibeThemePlayButtonGlyphDefault,
                       kVibeThemeColorPlayButton, dark);
}

// The glass style's unthemed lift: clear in dark, a white wash in light that
// lifts row contrast while letting the blur through.
+ (NSColor *)defaultPlaylistBackgroundColorForDark:(BOOL)dark {
    return dark ? NSColor.clearColor : [NSColor colorWithWhite:1 alpha:0.35];
}

- (void)applyPlaylistBackground {
    BOOL dark = self.isDark;
    AppTheme *theme = AppSettings.sharedInstance.currentTheme;
    BOOL solid = [theme.playlistBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_SOLID];
    BOOL clear = [theme.playlistBackgroundStyle
            isEqualToString:SETTINGS_VALUE_WINDOW_BACKGROUND_CLEAR];
    // Solid: no blur, the theme's color. Glass: the unthemed lift (a themed
    // color over glass is the tint wash above). Clear: neither.
    _playlistFrostView.hidden = solid || clear;
    NSColor *background = solid
            ? [theme displayColorForBase:kVibeThemeColorPlaylistBackground dark:dark]
            : clear ? NSColor.clearColor
                    : [MainPlayerContentView defaultPlaylistBackgroundColorForDark:dark];
    _playlistDimView.layer.backgroundColor = background.CGColor;
}

+ (void)applyCornerRadius:(CGFloat)radius toBackdrop:(NSView *)backdrop {
    if (@available(macOS 26.0, *)) {
        if ([backdrop isKindOfClass:NSGlassEffectView.class]) {
            ((NSGlassEffectView *)backdrop).cornerRadius = radius;
            return;
        }
    }
    if ([backdrop isKindOfClass:NSVisualEffectView.class]) {
        ((NSVisualEffectView *)backdrop).maskImage =
                [MainPlayerContentView frostCornerMaskWithRadius:radius];
    }
}

// Cap-inset so the corners never scale. A layer cornerRadius clips an
// NSVisualEffectView's tint but not its blur.
+ (NSImage *)frostCornerMaskWithRadius:(CGFloat)radius {
    NSSize size = NSMakeSize(radius * 2 + 1, radius * 2 + 1);
    NSImage *mask = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [NSColor.blackColor set];
        [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
        return YES;
    }];
    mask.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
    mask.resizingMode = NSImageResizingModeStretch;
    return mask;
}

+ (NSTextField *)labelWithFrame:(NSRect)frame {
    NSTextField *field = [[NSTextField alloc] initWithFrame:frame];
    field.editable = NO;
    field.selectable = NO;
    field.bordered = NO;
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeNone;
    field.lineBreakMode = NSLineBreakByClipping;
    field.cell.scrollable = NO;
    return field;
}

@end
