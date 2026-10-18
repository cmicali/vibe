//
//  MainPlayerContentView.m
//  Vibe
//

#import "MainPlayerContentViewInternal.h"
#import "SymbolButton.h"
#import "DrawnControls.h"
#import "ArtworkImageView.h"
#import "WaveformView.h"
#import "PlaylistDropZoneView.h"
#import "PlaylistTableView.h"
#import "VolumeControlView.h"
#import "TransportMath.h"
#import "NSView+DarkMode.h"
#import "Fonts.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "VibeStrings.h"

#pragma mark - Layout

@implementation MainPlayerContentView

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
                                  _dropHintTextField, _volumeControlView.label,
                                  _volumeControlView.percentLabel,
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
                                  _fileMetadataTextField, _bpmTextField,
                                  _volumeControlView.label ]) {
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

- (void)setCodecSpinnerShown:(BOOL)shown {
    if (shown == _codecSpinnerShown) {
        return;
    }
    _codecSpinnerShown = shown;
    [self layoutCodecSpinner];
    [self capArtistLineAtCodecText];
    if (shown) {
        [_codecSpinner startAnimation:nil];
    }
    else {
        [_codecSpinner stopAnimation:nil];
    }
}

// The spinner ends at the column's ink edge, centered on the codec text's cap
// height. While it shows, the codec field narrows so its text ends a gap
// before it. The BPM field keeps the column's full width, so it is the edge.
- (void)layoutCodecSpinner {
    NSFont *font = _fileMetadataTextField.font;
    CGFloat side = round(font.pointSize);
    NSRect column = _bpmTextField.frame;
    NSRect field = _fileMetadataTextField.frame;
    field.size.width = NSWidth(column) - (_codecSpinnerShown ? side + kCodecSpinnerGap : 0);
    _fileMetadataTextField.frame = field;
    CGFloat baseline = NSMaxY(field) - _fileMetadataTextField.firstBaselineOffsetFromTop;
    _codecSpinner.frame = NSMakeRect(NSMaxX(column) - kLabelInkInset - side,
                                     round(baseline + font.capHeight / 2 - side / 2), side, side);
}

// In the corner the line clears whichever of the codec text and the volume
// control reaches further left, so it never moves as the two swap on hover.
- (void)capArtistLineAtCodecText {
    CGFloat clearX = NSMaxX(_fileMetadataTextField.frame) - _codecTextWidth;
    if (VolumeControlView.atTopRight) {
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

static BOOL CursorIsIn(NSView *view, NSRect rect) {
    if (!view.window) {
        return NO;
    }
    NSPoint p = [view convertPoint:view.window.mouseLocationOutsideOfEventStream fromView:nil];
    return NSMouseInRect(p, rect, view.isFlipped);
}

- (BOOL)isCursorOverWindow {
    return CursorIsIn(_windowHoverHost, _windowHoverHost.bounds);
}

- (void)setTrafficLightsShown:(BOOL)shown {
    _trafficLightsShown = shown;
    // Hidden and alpha are decided in one place, the fade funnel.
    [self setControlsShown:[self isCursorOverWindow] animated:NO];
}

// The window's area says whether the pointer is in the window. The volume
// area only re-runs the funnel. There is no volume area while the control is
// off, and nil must not match an event with no area (set_controls_hover's).
- (void)mouseEntered:(NSEvent *)event {
    BOOL volumeArea = _volumeHoverArea && event.trackingArea == _volumeHoverArea;
    [self setControlsShown:volumeArea ? [self isCursorOverWindow] : YES animated:YES];
}

- (void)mouseExited:(NSEvent *)event {
    BOOL volumeArea = _volumeHoverArea && event.trackingArea == _volumeHoverArea;
    [self setControlsShown:volumeArea ? [self isCursorOverWindow] : NO animated:YES];
}

// The one place button visibility is decided, so a hidden button never fades
// to full alpha behind its hidden flag.
static NSView *FadeTarget(NSView *view, BOOL animated) {
    return animated ? view.animator : view;
}

- (void)setControlsShown:(BOOL)shown animated:(BOOL)animated {
    CGFloat traffic   = (shown && _trafficLightsShown) ? 1.0 : 0.0;
    AppSettings *settings = AppSettings.sharedInstance;
    AppTheme *theme = settings.currentTheme;
    BOOL transportShown = theme.showTransportButtons;
    CGFloat transport = (shown && transportShown) ? 1.0 : 0.0;
    // The volume control swaps with whatever shares its place: the corner
    // readouts, or the time row's drop hint.
    BOOL volumeShown = settings.volumeControl;
    BOOL corner = VolumeControlView.atTopRight;
    BOOL volumeUp = volumeShown
            && ([settings.volumeVisibility isEqualToString:SETTINGS_VALUE_VOLUME_VISIBILITY_ALWAYS]
                || _volumeDragging || CursorIsIn(self, _volumeHoverArea.rect));
    CGFloat volume = volumeUp ? 1.0 : 0.0;
    CGFloat readouts = (volumeUp && corner) ? 0.0 : 1.0;
    CGFloat hint = (volumeUp && !corner) ? 0.0 : kDropHintAlpha;
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
        FadeTarget(self->_codecSpinner, animated).alphaValue = readouts;
        FadeTarget(self->_bpmTextField, animated).alphaValue = readouts;
        FadeTarget(self->_dropHintTextField, animated).alphaValue = hint;
        FadeTarget(self->_albumArtGradientView, animated).alphaValue = gradient;
    }];
}

- (void)setOpenShortcut:(NSString *)shortcut {
    // The shortcut is a separate argument so a translation can move it in the sentence.
    _dropHintTextField.stringValue = shortcut
            ? [NSString stringWithFormat:STR_LABEL_DROP_HINT, shortcut]
            : STR_LABEL_DROP_HINT_NO_SHORTCUT;
    _playlistDropZoneView.openShortcut = shortcut;
}

- (void)setDropHintShown:(BOOL)shown {
    if (shown == _dropHintShown) {
        return;
    }
    _dropHintShown = shown;
    [self setControlsShown:[self isCursorOverWindow] animated:NO];
}

- (void)applyVolumeControl {
    _volumeControlView.slider.doubleValue = AppSettings.sharedInstance.volume;
    [self layoutVolumeControl]; // renders the percentage
    [self capArtistLineAtCodecText];
    [self applyVolumeColors];
    [self setControlsShown:[self isCursorOverWindow] animated:NO];
}

// TRAP: the pointer can leave the control's hover mid-drag, and fading the
// control then leaves the knob in hand invisible, still setting the volume.
// The drag holds its hover open; the release re-decides it from the pointer.
// The hold rests on the slider sending its action once more at the mouse-up:
// nothing else clears it.
- (void)volumeSliderDidMove {
    [_volumeControlView renderPercent];
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

// Only the drag's own mouse-up may clear its hold, so nothing else moves the
// knob in hand.
- (void)moveVolumeBySteps:(double)steps {
    if (AppSettings.sharedInstance.volumeControl && !_volumeDragging) {
        [_volumeControlView.slider moveBySteps:steps];
    }
}

// A scroll anywhere outside the playlist moves the volume, while the control
// hides as well as while it shows. The rows' scroll view takes a scroll over
// them first, and one it passes back up must not move the volume. Collapsed,
// the scroll view is zero high, so nothing is over it.
- (void)scrollWheel:(NSEvent *)event {
    NSScrollView *playlist = _playlistTableView.enclosingScrollView;
    if (!AppSettings.sharedInstance.volumeControl
            || NSMouseInRect([playlist convertPoint:event.locationInWindow fromView:nil],
                             playlist.bounds, playlist.isFlipped)) {
        [super scrollWheel:event];
    }
    // A trackpad's coast after the fingers lift would keep turning it.
    else if (event.momentumPhase == NSEventPhaseNone) {
        [self moveVolumeBySteps:VibeVolumeScrollSteps(event.scrollingDeltaY, event.hasPreciseScrollingDeltas,
                                                      event.isDirectionInvertedFromDevice)];
    }
}

// Sized by the control itself, then placed from its neighbors.
- (void)layoutVolumeControl {
    [_volumeControlView layoutColumns];
    [self positionVolumeControl];
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
    if (VolumeControlView.atTopRight) {
        // A bare slider has no text inset of its own, so it ends at the ink.
        CGFloat inset = settings.showVolumeLabels ? 0 : kLabelInkInset;
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
    [self placeVolumeHoverArea];
}

// The area is clipped to this view. Past the window's edge, leaving the window
// would not hide the slider. Past the right edge, it would cover the pitch
// panel. There is no area when the slider is off or always shown.
- (void)placeVolumeHoverArea {
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *visibility = settings.volumeVisibility;
    NSRect rect = NSZeroRect;
    if (settings.volumeControl && ![visibility isEqualToString:SETTINGS_VALUE_VOLUME_VISIBILITY_ALWAYS]) {
        rect = _volumeControlView.frame;
        if ([visibility isEqualToString:SETTINGS_VALUE_VOLUME_VISIBILITY_HOVER_CLOSE]) {
            rect = NSInsetRect(rect, -kVolumeHoverOutsetX, -kVolumeHoverOutsetY);
        }
        rect = NSIntersectionRect(rect, self.bounds);
    }
    if (NSEqualRects(rect, _volumeHoverArea.rect)) {
        return;
    }
    if (_volumeHoverArea) {
        [self removeTrackingArea:_volumeHoverArea];
        _volumeHoverArea = nil;
    }
    if (NSIsEmptyRect(rect)) {
        return;
    }
    _volumeHoverArea = [[NSTrackingArea alloc]
            initWithRect:rect
                 options:NSTrackingActiveAlways | NSTrackingMouseEnteredAndExited
                   owner:self userInfo:nil];
    [self addTrackingArea:_volumeHoverArea];
}

- (void)applyVolumeColors {
    [_volumeControlView applyColorsDark:self.isDark artworkColor:_waveformView.artworkThemeColor];
}

@end
