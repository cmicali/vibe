//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "MainPlayerContentView.h"
#import "MainPlayerController.h" // declares the button action selectors
#import "SymbolButton.h"
#import "ArtworkImageView.h"
#import "AudioWaveformView.h"
#import "PlaylistTableView.h"
#import "PlaylistDropZoneView.h"
#import "NSView+DarkMode.h"
#import "Fonts.h"
#import "Constants.h"
#import "Strings.h"

// The design-time size, kMainWindowContentWidth by kMainWindowDesignHeight
// from Constants.h, which is what the window opens at too. The controller
// resizes the view to the window's restored frame after adding it, and the
// autoresizing pass lays the subviews out at the real size. Both axes are
// flexible at runtime, since the window is user-resizable, so every frame
// below is authored at the design size and carries a mask saying how it
// stretches from there.

#pragma mark - Layout

// All subview frames are absolute, and the numbers live here rather than
// inline in buildSubviewsWithTarget:. Edge-reaching values derive from
// kMainWindowContentWidth, the design width, and the autoresizing masks
// stretch them in a wider window. The one deliberate overhang has a name,
// kHeaderPanelRightBleed. Two bands split at kPlaylistHeight: the header
// above, the playlist below.

// The header band is the whole window in the small, playlist-collapsed layout.
static const CGFloat kHeaderHeight = kMainWindowSmallHeight;
static const CGFloat kPlaylistHeight = kMainWindowDesignHeight - kHeaderHeight;

static const CGFloat kArtSize = kHeaderHeight; // square, fills the header band

// The header glass starts behind the art's right edge, where the art shadows
// onto it, and deliberately bleeds past the window's right edge. The glass
// rounds all its corners, and the window shape clipping the right-side arcs
// off-screen is what keeps the header's right edge square. The bleed must be
// at least the radius.
static const CGFloat kHeaderPanelRightBleed = kMainWindowCornerRadius + 2;
static const CGFloat kHeaderPanelX = kArtSize - 25;
static const CGFloat kHeaderPanelWidth =
        kMainWindowContentWidth + kHeaderPanelRightBleed - kHeaderPanelX;

// Shared left edge / right margin for everything right of the art.
static const CGFloat kHeaderContentX = kArtSize + 8;
static const CGFloat kHeaderContentRightMargin = 10;
static const CGFloat kHeaderContentWidth =
        kMainWindowContentWidth - kHeaderContentX - kHeaderContentRightMargin;
static const CGFloat kHeaderContentMaxX = kMainWindowContentWidth - kHeaderContentRightMargin;

static const CGFloat kWaveformY = 215;
static const CGFloat kWaveformHeight = 86;

// The codec line, with the BPM line directly beneath it. Both are
// right-aligned. They are declared before the title and artist lines, which
// size themselves to stay clear of this corner.
static const CGFloat kCodecLabelWidth = 240;
static const CGFloat kCodecLabelX = kHeaderContentMaxX - kCodecLabelWidth;
static const CGFloat kCodecLabelY = 325;
static const CGFloat kBPMLabelY = 307;

// Neither header text line may run under that corner: they share one pane of
// glass with it, so an overrun draws text over text rather than sliding behind
// anything. The two stop at a different x, because they sit at a different
// height. The title clears only the BPM line, the lower and far shorter of the
// pair, and shrinks to fit within kTitleWidth, in setTitleLabelText:. The
// artist line sits at the codec line's own height, so it truncates with an
// ellipsis at that label's edge, kCodecColumnGutter clear of it.
//
// kArtistWidth reserves the codec label's whole column, which is the worst case
// — a long codec string behind three FX symbols. Because that is rare and the
// column is wide, the width is re-capped against the line's real text in
// layoutArtistLineClearOfCodecLine, and this static value serves as the frame
// the autoresizing pass starts from.
static const CGFloat kCodecColumnGutter = 12;
static const CGFloat kArtistY = 293;
static const CGFloat kArtistWidth = kCodecLabelX - kCodecColumnGutter - kHeaderContentX;
static const CGFloat kArtistHeight = 48;
static const CGFloat kTitleY = 292;
static const CGFloat kTitleWidth = 415;
static const CGFloat kTitleHeight = 30;

// The time row: elapsed on the left, total on the right, and the empty-state
// hint spanning the gap.
static const CGFloat kSmallLabelHeight = 16;
static const CGFloat kTimeRowY = 207;
static const CGFloat kTimeLabelWidth = 59;
static const CGFloat kTotalTimeX = kHeaderContentMaxX - kTimeLabelWidth;
static const CGFloat kDropHintX = kHeaderContentX + kTimeLabelWidth;
static const CGFloat kDropHintWidth = kTotalTimeX - kDropHintX;

// The traffic lights: 13pt dots on 23pt centers, like the real macOS
// controls, left-aligned with the playlist icon below.
static const CGFloat kTrafficLightSize = 32;
static const CGFloat kTrafficLightSymbolSize = 13;
static const CGFloat kTrafficLightY = 313;
static const CGFloat kCloseButtonX = 9;
static const CGFloat kTrafficLightSpacing = 23;

// The transport row. Spacing tighter than the button size overlaps the frames,
// which is fine, because later siblings win hit testing. The row sits over the
// album art's bottom edge, and ArtworkImageView refuses drag-out mouse-downs
// within the art's bottom kArtworkTransportExclusionHeight, so presses here
// read as buttons.
static const CGFloat kTransportButtonSize = 50;
static const CGFloat kTransportButtonY = 203;
static const CGFloat kTransportRowX = 4;
static const CGFloat kTransportButtonSpacing = 46;
// The symbol point size inside those frames. SF Symbol glyphs draw at roughly
// 0.8 times their point size, so this runs larger than the icon's real height.
static const CGFloat kTransportSymbolSize = 31;

// All the window's buttons sit hidden and fade in only while the cursor is
// over the window. The reveal is a pure show and hide at full opacity, and
// each button's resting dimness against its hover brightness lives in its
// symbol colors, so a hovered traffic-light dot can reach full saturation like
// the real macOS controls.
static const CFTimeInterval kControlFadeDur = 0.2;

// The shared point size for the small numeric labels: the time readouts, the
// codec line and the BPM line.
static const CGFloat kNumericLabelFontSize = 13;

// One shadow recipe for every header label. The opacity itself is driven by
// the appearance, in updateMaterialForAppearance: dark text on the light glass
// needs no shadow, and light text on dark glass gets a strong one.
static const CGFloat kLabelShadowOpacityDark = 0.9;

// A purely decorative overlay. It returns nil from hitTest, so the views it
// covers — the album art's drag-out and the transport buttons — still receive
// mouse events.
@interface VibePassthroughView : NSView
@end

@implementation VibePassthroughView
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
@end

// The same passthrough treatment for the header's glass panel. Clicks on the
// empty header must fall through to the window, so it can be dragged to move,
// and the waveform view above it does its own hit handling.
@interface VibePassthroughGlassView : NSGlassEffectView
@end

@implementation VibePassthroughGlassView
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
@end

@implementation MainPlayerContentView {
    VibePassthroughView *_albumArtGradientView; // decorative darkening over the art; internal-only (no controller outlet)
    NSGlassEffectView *_backgroundGlassView;    // header glass; its tint rides in headerTintView
    NSVisualEffectView *_playlistFrostView;
    NSView *_playlistDimView;
    // Self-contained buttons, with their actions wired at build and their
    // hover fade internal. They are not exposed in the header, because the
    // controller never drives them.
    SymbolButton *_closeButton;
    SymbolButton *_minimizeButton;
    SymbolButton *_playlistToggleButton;
    NSTrackingArea *_windowHoverArea;
    __weak NSView *_windowHoverHost;
}

- (instancetype)initWithTarget:(id)target {
    self = [super initWithFrame:NSMakeRect(0, 0, kMainWindowContentWidth, kMainWindowDesignHeight)];
    if (self) {
        self.wantsLayer = YES;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self buildSubviewsWithTarget:target];
        [self updateMaterialForAppearance];
    }
    return self;
}

// The window's glass backdrop adapts to the appearance on its own. Only the
// playlist frost is appearance-dependent here.
- (void)updateMaterialForAppearance {
    BOOL dark = self.isDark;
    // Both modes use the translucent under-window material, so that the
    // playlist keeps reading as glass; the light-mode WindowBackground
    // material is effectively opaque paint. Dark mode needs no help. Light
    // mode gets a white wash, brightening rather than dimming, which lifts row
    // contrast for the dark text while letting the blur through.
    _playlistFrostView.material = NSVisualEffectMaterialUnderWindowBackground;
    _playlistDimView.layer.backgroundColor = dark ? NSColor.clearColor.CGColor
                                                  : [NSColor colorWithWhite:1 alpha:0.35].CGColor;
    // The header-label shadows lift readability for light text on dark glass.
    // Dark text on the bright light material needs none, and a dark shadow
    // under dark text reads simply as smudge.
    CGFloat shadowOpacity = dark ? kLabelShadowOpacityDark : 0.0;
    for (NSTextField *field in @[ _artistTextField, _titleTextField,
                                  _totalTimeTextField, _currentTimeTextField,
                                  _dropHintTextField,
                                  _fileMetadataTextField, _bpmTextField ]) {
        field.layer.shadowOpacity = shadowOpacity;
    }
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateMaterialForAppearance];
    if (self.appearanceChangedHandler) {
        self.appearanceChangedHandler();
    }
}

#pragma mark - The artist line's right edge

// The one frame the autoresizing pass cannot place, because what it has to
// clear is content rather than geometry: the artist line ends where the codec
// line's *text* begins, and that text is right-aligned inside a label whose
// column is sized for the worst case. Reserving the whole column costs the
// artist line most of its width in a narrow window and a third of it at the
// design width, for a codec string that is usually far shorter — so cap it
// against what the line actually renders. The frame is authored at the
// worst-case reservation (kArtistWidth), which is what this falls back to.
//
// Both inputs move: the geometry on every resize, hooked below, and the text on
// every codec and FX change, hooked by TrackDisplayController.
- (void)layoutArtistLineClearOfCodecLine {
    CGFloat codecTextWidth = ceil(_fileMetadataTextField.attributedStringValue.size.width);
    CGFloat clearX = NSMaxX(_fileMetadataTextField.frame) - codecTextWidth - kCodecColumnGutter;
    NSRect frame = _artistTextField.frame;
    frame.size.width = MAX(0, clearX - NSMinX(frame));
    if (!NSEqualRects(frame, _artistTextField.frame)) {
        _artistTextField.frame = frame;
    }
}

// Runs on every frame change, live drag included, which the resize
// notifications the controller listens to do not cover.
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self layoutArtistLineClearOfCodecLine];
}

#pragma mark - Hover reveal

// The buttons, both the traffic lights and the transport row, fade in only
// while the cursor is over the window. The tracking area is attached to the
// window's content view, which also spans the pitch panel, rather than to this
// 680-wide player body, so hovering any part of the window keeps them visible.
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
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
    // Entered and exited fire only on boundary crossings, so seed the initial
    // state from where the cursor actually is right now.
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

- (void)mouseEntered:(NSEvent *)event {
    [self setControlsShown:YES animated:YES];
}

- (void)mouseExited:(NSEvent *)event {
    [self setControlsShown:NO animated:YES];
}

- (void)setControlsShown:(BOOL)shown animated:(BOOL)animated {
    CGFloat traffic   = shown ? 1.0 : 0.0;
    CGFloat transport = shown ? 1.0 : 0.0;
    if (animated) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = kControlFadeDur;
            self->_closeButton.animator.alphaValue = traffic;
            self->_minimizeButton.animator.alphaValue = traffic;
            self->_playlistToggleButton.animator.alphaValue = transport;
            self->_playButton.animator.alphaValue = transport;
            self->_nextButton.animator.alphaValue = transport;
        }];
    } else {
        _closeButton.alphaValue = traffic;
        _minimizeButton.alphaValue = traffic;
        _playlistToggleButton.alphaValue = transport;
        _playButton.alphaValue = transport;
        _nextButton.alphaValue = transport;
    }
}

// Applies the shared shadow recipe, kLabelShadowOpacityDark, which
// updateMaterialForAppearance sets. Fields whose content changes every second
// opt out of rasterization, because re-rastering would cost more than it saves.
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

- (void)buildSubviewsWithTarget:(id)target {
    // The glass panel behind the waveform and header: plain glass over the
    // window backdrop, which ArtworkDisplayController tints to the current
    // track's dominant art color. Its corner radius follows the window's
    // top-right.
    _backgroundGlassView = [[VibePassthroughGlassView alloc] initWithFrame:
            NSMakeRect(kHeaderPanelX, kPlaylistHeight, kHeaderPanelWidth, kHeaderHeight)];
    _backgroundGlassView.cornerRadius = kMainWindowCornerRadius;
    // Width-flexible, so the bleed stays past the moving right edge. The
    // height must not be flexible; see the playlist frost's note below.
    _backgroundGlassView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_backgroundGlassView];

    // The art-color tint over the glass. It is not the glass's tintColor,
    // because AppKit kills that outright while the window is inactive, and the
    // wash must not change with key state. ArtworkDisplayController drives the
    // color.
    _headerTintView = [[VibePassthroughView alloc] initWithFrame:_backgroundGlassView.frame];
    _headerTintView.wantsLayer = YES;
    _headerTintView.layer.cornerRadius = kMainWindowCornerRadius;
    _headerTintView.layer.masksToBounds = YES;
    _headerTintView.autoresizingMask = _backgroundGlassView.autoresizingMask;
    [self addSubview:_headerTintView];

    _waveformView = [[AudioWaveformView alloc] initWithFrame:
            NSMakeRect(kHeaderContentX, kWaveformY, kHeaderContentWidth, kWaveformHeight)];
    _waveformView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_waveformView];

    _albumArtImageView = [[ArtworkImageView alloc] initWithFrame:
            NSMakeRect(0, kPlaylistHeight, kArtSize, kArtSize)];
    _albumArtImageView.image = [NSImage imageNamed:@"record-bg"];
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

    // A darkening gradient over the album art: strong at the bottom, behind
    // the transport buttons, and clear from the middle up, so that the button
    // row reads against bright covers. It is always visible and does not join
    // the hover fade.
    _albumArtGradientView = [[VibePassthroughView alloc] initWithFrame:
            NSMakeRect(0, kPlaylistHeight, kArtSize, kArtSize)];
    CAGradientLayer *artGradient = [[CAGradientLayer alloc] init];
    artGradient.colors = @[
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.96].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.55].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0].CGColor
    ];
    artGradient.locations = @[@0.0, @0.35, @0.62];
    // The layer-hosting contract: assign the layer before wantsLayer, or
    // AppKit creates its own backing layer first and the view ends up
    // layer-backed.
    _albumArtGradientView.layer = artGradient;
    _albumArtGradientView.wantsLayer = YES;
    _albumArtGradientView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_albumArtGradientView];

    // Hidden until the window is hovered; see setControlsShown:animated:.
    _closeButton = [MainPlayerContentView transportButtonWithFrame:
                            NSMakeRect(kCloseButtonX, kTrafficLightY, kTrafficLightSize, kTrafficLightSize)
                                                        symbolName:@"circle.fill"
                                                             label:STR_A11Y_WINDOW_CLOSE
                                                            action:@selector(closeApp:)
                                                            target:target];
    _closeButton.alphaValue = 0.0;
    _closeButton.symbolPointSize = kTrafficLightSymbolSize;
    // Dim at rest, lighting up to full salmon on hover.
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
    // Dim at rest, lighting up to full yellow on hover.
    _minimizeButton.symbolNormalColor = [NSColor colorWithSRGBRed:0.988 green:0.741 blue:0.180 alpha:0.64];
    _minimizeButton.symbolHighlightColor = [NSColor colorWithSRGBRed:0.988 green:0.741 blue:0.180 alpha:1.0];
    [self addSubview:_minimizeButton];

    // Fades in with the traffic lights when the window is hovered.
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

    NSColor *dimmedTextColor = [NSColor secondaryLabelColor];

    _artistTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kHeaderContentX, kArtistY, kArtistWidth, kArtistHeight)];
    _artistTextField.font = [Fonts font:16];
    _artistTextField.textColor = dimmedTextColor;
    // Truncating, not the shared clipping default: this line takes whatever a
    // file's artist tag holds, and long ones are common. Clipping cut a glyph
    // mid-stroke at the label's edge and gave no sign the string went on.
    _artistTextField.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_artistTextField, YES);
    [self addSubview:_artistTextField];

    _titleTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kHeaderContentX, kTitleY, kTitleWidth, kTitleHeight)];
    _titleTextField.font = [Fonts font:23];
    _titleTextField.textColor = [NSColor labelColor];
    _titleTextField.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_titleTextField, YES);
    [self addSubview:_titleTextField];

    _totalTimeTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kTotalTimeX, kTimeRowY, kTimeLabelWidth, kSmallLabelHeight)];
    _totalTimeTextField.font = [Fonts fontForNumbers:kNumericLabelFontSize bold:YES];
    _totalTimeTextField.alignment = NSTextAlignmentRight;
    _totalTimeTextField.textColor = dimmedTextColor;
    _totalTimeTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_totalTimeTextField, YES);
    [self addSubview:_totalTimeTextField];

    _currentTimeTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kHeaderContentX, kTimeRowY, kTimeLabelWidth, kSmallLabelHeight)];
    _currentTimeTextField.font = [Fonts fontForNumbers:kNumericLabelFontSize bold:YES];
    _currentTimeTextField.textColor = dimmedTextColor;
    // Left-anchored, unlike the right-aligned total time it pairs with.
    _currentTimeTextField.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    // No rasterization. This field's content changes every second, so
    // rasterizing would merely force a re-raster on every update.
    configureLabelShadow(_currentTimeTextField, NO);
    [self addSubview:_currentTimeTextField];

    // The empty-state hint, spanning the gap between the two time labels.
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
    // At half strength, like the rest of the empty state.
    _dropHintTextField.alphaValue = 0.5;
    _dropHintTextField.hidden = YES;
    // It spans the gap between the two time labels, so it takes the extra
    // width.
    _dropHintTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_dropHintTextField, YES);
    [self addSubview:_dropHintTextField];

    // The frosted backdrop under the playlist. The window's Clear glass is too
    // transparent to read row text over, so this panel frosts the playlist
    // region alone. It is an NSVisualEffectView rather than an
    // NSGlassEffectView, because the glass view's SwiftUI hosting internals
    // fight the window's autoresizing when HeightSizable, and the window then
    // refuses to expand past the design height. It sits under the scroll view,
    // since an NSClipView background does not composite semi-transparent
    // colors over a backdrop, so it also covers the empty area below the last
    // row. The light-mode dim wash rides inside it.
    _playlistFrostView = [[NSVisualEffectView alloc] initWithFrame:
            NSMakeRect(0, 0, kMainWindowContentWidth, kPlaylistHeight)];
    _playlistFrostView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _playlistFrostView.state = NSVisualEffectStateActive;
    _playlistFrostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistFrostView];

    _playlistDimView = [[NSView alloc] initWithFrame:_playlistFrostView.bounds];
    _playlistDimView.wantsLayer = YES;
    _playlistDimView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_playlistFrostView addSubview:_playlistDimView];

    // The table — its columns, row metrics and cell construction — belongs
    // entirely to PlaylistTableView. Only the frame is placed here.
    NSScrollView *playlistScrollView = [PlaylistTableView scrollViewWithFrame:
            NSMakeRect(0, 0, kMainWindowContentWidth, kPlaylistHeight)];
    _playlistTableView = (PlaylistTableView *)playlistScrollView.documentView;
    [self addSubview:playlistScrollView];

    // Above the table. The empty-state well takes the clicks, and the
    // drag-over wells, with their blur, composite over the rows. When neither
    // presentation is up, the zone is hit-transparent.
    _playlistDropZoneView = [[PlaylistDropZoneView alloc] initWithFrame:
            NSMakeRect(0, 0, kMainWindowContentWidth, kPlaylistHeight)];
    _playlistDropZoneView.hidden = YES;
    _playlistDropZoneView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistDropZoneView];

    _fileMetadataTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kCodecLabelX, kCodecLabelY, kCodecLabelWidth, kSmallLabelHeight)];
    _fileMetadataTextField.font = [Fonts fontForNumbers:kNumericLabelFontSize bold:NO];
    _fileMetadataTextField.alignment = NSTextAlignmentRight;
    _fileMetadataTextField.textColor = dimmedTextColor;
    // Full alpha, unlike the BPM label below, because this field also carries
    // the inline FX symbols, which read at the time labels' full strength
    // while the codec text stays half-strength. A field-wide 0.5 would dim
    // both, so the text's own dimming rides in its foreground color instead;
    // see TrackDisplayController's codecTextAttributes.
    _fileMetadataTextField.alphaValue = 1.0;
    _fileMetadataTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_fileMetadataTextField, YES);
    [self addSubview:_fileMetadataTextField];

    // The BPM readout, directly below the codec line and styled to match.
    _bpmTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kCodecLabelX, kBPMLabelY, kCodecLabelWidth, kSmallLabelHeight)];
    _bpmTextField.font = [Fonts fontForNumbers:kNumericLabelFontSize bold:NO];
    _bpmTextField.alignment = NSTextAlignmentRight;
    _bpmTextField.textColor = dimmedTextColor;
    // Matches the codec label above it, with full alpha and the dimming in the
    // text color. The two are one visual pair, and drift apart otherwise.
    _bpmTextField.alphaValue = 1.0;
    _bpmTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_bpmTextField, YES);
    [self addSubview:_bpmTextField];
}

// The shared configuration for the borderless icon buttons: close, playlist,
// play and next. SymbolButton already draws a momentary, white-tinted SF
// Symbol with a highlight fade of about 100ms, so only the symbol, the action
// and the resizing behavior vary.
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

// A borderless, non-editable static label with a transparent background.
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
