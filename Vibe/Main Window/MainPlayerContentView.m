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
#import "NSView+DarkMode.h"
#import "Fonts.h"
#import "Constants.h"

// Design-time size; the controller resizes the view to the window's restored
// frame after adding it, and the autoresizing pass lays subviews out at the
// real size. Both axes are flexible at runtime (the window is user-resizable),
// so every frame below is authored at kMainWindowContentWidth × kDesignHeight
// and carries the mask that says how it stretches from there.
static const CGFloat kDesignHeight = 350;

#pragma mark - Layout

// All subview frames are absolute; the numbers live here, not inline in
// buildSubviewsWithTarget:. Edge-reaching values are derived from
// kMainWindowContentWidth (the design width — a wider window stretches them
// via the autoresizing masks); the one deliberate overhang is named
// (kHeaderPanelRightBleed). Two bands split at kPlaylistHeight: the header
// above, the playlist below.

// The header band is the whole window in the small (playlist-collapsed) layout.
static const CGFloat kHeaderHeight = kMainWindowSmallHeight;
static const CGFloat kPlaylistHeight = kDesignHeight - kHeaderHeight;

static const CGFloat kArtSize = kHeaderHeight; // square, fills the header band

// Header glass: starts behind the art's right edge (the art shadows onto it)
// and deliberately bleeds past the window's right edge — the glass rounds ALL
// its corners, and the window shape clipping the right-side arcs off-screen is
// what keeps the header's right edge square. Bleed must be ≥ the radius.
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

// The title is narrower than the artist line: it shrinks-to-fit within
// kTitleWidth (setTitleLabelText:), staying clear of the codec/BPM labels.
static const CGFloat kArtistY = 293;
static const CGFloat kArtistHeight = 48;
static const CGFloat kTitleY = 292;
static const CGFloat kTitleWidth = 415;
static const CGFloat kTitleHeight = 30;

// Time row: elapsed left, total right, the empty-state hint spanning the gap.
static const CGFloat kSmallLabelHeight = 16;
static const CGFloat kTimeRowY = 207;
static const CGFloat kTimeLabelWidth = 59;
static const CGFloat kTotalTimeX = kHeaderContentMaxX - kTimeLabelWidth;
static const CGFloat kDropHintX = kHeaderContentX + kTimeLabelWidth;
static const CGFloat kDropHintWidth = kTotalTimeX - kDropHintX;

// Codec line, BPM line directly beneath it; both right-aligned.
static const CGFloat kCodecLabelWidth = 240;
static const CGFloat kCodecLabelX = kHeaderContentMaxX - kCodecLabelWidth;
static const CGFloat kCodecLabelY = 325;
static const CGFloat kBPMLabelY = 307;

// Traffic lights: 13pt dots on 23pt centers like the real macOS controls,
// left-aligned with the playlist icon below.
static const CGFloat kTrafficLightSize = 32;
static const CGFloat kTrafficLightSymbolSize = 13;
static const CGFloat kTrafficLightY = 313;
static const CGFloat kCloseButtonX = 9;
static const CGFloat kTrafficLightSpacing = 23;

// Transport row: spacing tighter than the button size overlaps the frames —
// fine, later siblings win hit testing.
static const CGFloat kTransportButtonSize = 50;
static const CGFloat kTransportButtonY = 203;
static const CGFloat kTransportRowX = 4;
static const CGFloat kTransportButtonSpacing = 46;
// Symbol point size inside those frames. SF Symbol glyphs draw at roughly 0.8x
// their point size, so this runs larger than the icon's actual height.
static const CGFloat kTransportSymbolSize = 31;

// All the window's buttons sit hidden and fade in only while the cursor is
// over the window. The reveal is pure show/hide (full opacity); each button's
// resting dimness vs. hover brightness lives in its symbol colors, so a hovered
// traffic-light dot can reach full saturation like the real macOS controls.
static const CFTimeInterval kControlFadeDur = 0.2;

// Shared point size for the small numeric labels (time readouts, codec line,
// BPM line).
static const CGFloat kNumericLabelFontSize = 13;

// One shadow recipe for every header label; the opacity itself is
// appearance-driven (updateMaterialForAppearance): dark text on the light
// glass needs no shadow, light text on dark glass gets a strong one.
static const CGFloat kLabelShadowOpacityDark = 0.9;

// Purely decorative overlay: returns nil from hitTest so the views it covers
// (the album art's drag-out, the transport buttons) still receive mouse events.
@interface VibePassthroughView : NSView
@end

@implementation VibePassthroughView
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
@end

// Same passthrough treatment for the header's glass panel: clicks on the
// empty header must fall through to the window (drag-to-move), and the
// waveform view above it does its own hit handling.
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
    // Self-contained buttons (actions wired at build, hover fade internal) —
    // not exposed in the header; the controller never drives them.
    SymbolButton *_closeButton;
    SymbolButton *_minimizeButton;
    SymbolButton *_playlistToggleButton;
    NSTrackingArea *_windowHoverArea;
    __weak NSView *_windowHoverHost;
}

- (instancetype)initWithTarget:(id)target {
    self = [super initWithFrame:NSMakeRect(0, 0, kMainWindowContentWidth, kDesignHeight)];
    if (self) {
        self.wantsLayer = YES;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self buildSubviewsWithTarget:target];
        [self updateMaterialForAppearance];
    }
    return self;
}

// The window's glass backdrop adapts to appearance on its own; only the
// playlist frost is appearance-dependent here.
- (void)updateMaterialForAppearance {
    BOOL dark = self.isDark;
    // Both modes use the translucent under-window material so the playlist
    // keeps reading as glass (the light-mode WindowBackground material is
    // effectively opaque paint). Dark needs no help; light gets a white wash
    // — brightening, not dimming — which lifts row contrast for the dark
    // text while letting the blur through.
    _playlistFrostView.material = NSVisualEffectMaterialUnderWindowBackground;
    _playlistDimView.layer.backgroundColor = dark ? NSColor.clearColor.CGColor
                                                  : [NSColor colorWithWhite:1 alpha:0.35].CGColor;
    // Header-label shadows: readability lift for light text on dark glass;
    // dark text on the bright light material needs none (and a dark shadow
    // under dark text just reads as smudge).
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

#pragma mark - Hover reveal

// The buttons (traffic lights + transport) fade in only while the cursor is
// over the window. Tracking is attached to the window's content view (which
// also spans the pitch panel) rather than this 680-wide player body, so
// hovering any part of the window keeps them visible.
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
    // Entered/exited only fire on boundary crossings, so seed the initial
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

// Applies the shared shadow recipe (kLabelShadowOpacityDark, set by
// updateMaterialForAppearance). Rasterization is opted out for fields whose
// content changes every second — re-rastering would cost more than it saves.
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
    // Glass panel behind the waveform/header: plain glass over the window
    // backdrop, tinted to the current track's dominant art color by
    // ArtworkDisplayController. Corner radius follows the window's top-right.
    _backgroundGlassView = [[VibePassthroughGlassView alloc] initWithFrame:
            NSMakeRect(kHeaderPanelX, kPlaylistHeight, kHeaderPanelWidth, kHeaderHeight)];
    _backgroundGlassView.cornerRadius = kMainWindowCornerRadius;
    // Width-flexible so the bleed stays past the (moving) right edge. Height
    // must NOT be flexible — see the playlist frost's note below.
    _backgroundGlassView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_backgroundGlassView];

    // The art-color tint over the glass. NOT the glass's tintColor: AppKit
    // kills that outright while the window is inactive, and the wash must
    // not change with key state (ArtworkDisplayController drives the color).
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

    // Darkening gradient over the album art — strong at the bottom for the
    // transport buttons, clear from the middle up — so the button row reads
    // against bright covers. Always visible (it doesn't join the hover fade).
    _albumArtGradientView = [[VibePassthroughView alloc] initWithFrame:
            NSMakeRect(0, kPlaylistHeight, kArtSize, kArtSize)];
    CAGradientLayer *artGradient = [[CAGradientLayer alloc] init];
    artGradient.colors = @[
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.96].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.55].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0].CGColor
    ];
    artGradient.locations = @[@0.0, @0.35, @0.62];
    // Layer-hosting contract: assign the layer BEFORE wantsLayer, or AppKit
    // creates its own backing layer first and the view is layer-backed.
    _albumArtGradientView.layer = artGradient;
    _albumArtGradientView.wantsLayer = YES;
    _albumArtGradientView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_albumArtGradientView];

    // Hidden until window hover (setControlsShown:animated:).
    _closeButton = [MainPlayerContentView transportButtonWithFrame:
                            NSMakeRect(kCloseButtonX, kTrafficLightY, kTrafficLightSize, kTrafficLightSize)
                                                        symbolName:@"circle.fill"
                                                             label:@"Close"
                                                            action:@selector(closeApp:)
                                                            target:target];
    _closeButton.alphaValue = 0.0;
    _closeButton.symbolPointSize = kTrafficLightSymbolSize;
    // Dim at rest; lights up to full salmon on hover.
    _closeButton.symbolNormalColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:0.64];
    _closeButton.symbolHighlightColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:1.0];
    [self addSubview:_closeButton];

    _minimizeButton = [MainPlayerContentView transportButtonWithFrame:
                               NSMakeRect(kCloseButtonX + kTrafficLightSpacing, kTrafficLightY,
                                          kTrafficLightSize, kTrafficLightSize)
                                                           symbolName:@"circle.fill"
                                                                label:@"Minimize"
                                                               action:@selector(minimizeWindow:)
                                                               target:target];
    _minimizeButton.alphaValue = 0.0;
    _minimizeButton.symbolPointSize = kTrafficLightSymbolSize; // same dot as close
    // Dim at rest; lights up to full yellow on hover.
    _minimizeButton.symbolNormalColor = [NSColor colorWithSRGBRed:0.988 green:0.741 blue:0.180 alpha:0.64];
    _minimizeButton.symbolHighlightColor = [NSColor colorWithSRGBRed:0.988 green:0.741 blue:0.180 alpha:1.0];
    [self addSubview:_minimizeButton];

    // Fade in with the traffic lights on window hover.
    _playlistToggleButton = [MainPlayerContentView transportButtonWithFrame:
                                     NSMakeRect(kTransportRowX, kTransportButtonY,
                                                kTransportButtonSize, kTransportButtonSize)
                                                                 symbolName:@"list.bullet"
                                                                      label:@"Toggle Playlist"
                                                                     action:@selector(toggleSize:)
                                                                     target:target];
    _playlistToggleButton.alphaValue = 0.0;
    [self addSubview:_playlistToggleButton];

    _playButton = [MainPlayerContentView transportButtonWithFrame:
                           NSMakeRect(kTransportRowX + kTransportButtonSpacing, kTransportButtonY,
                                      kTransportButtonSize, kTransportButtonSize)
                                                       symbolName:@"play.fill"
                                                            label:@"Play"
                                                           action:@selector(playPause:)
                                                           target:target];
    _playButton.alphaValue = 0.0;
    _playButton.enabled = NO;
    [self addSubview:_playButton];

    _nextButton = [MainPlayerContentView transportButtonWithFrame:
                           NSMakeRect(kTransportRowX + 2 * kTransportButtonSpacing, kTransportButtonY,
                                      kTransportButtonSize, kTransportButtonSize)
                                                       symbolName:@"forward.end.fill"
                                                            label:@"Next Track"
                                                           action:@selector(next:)
                                                           target:target];
    _nextButton.alphaValue = 0.0;
    _nextButton.enabled = NO;
    [self addSubview:_nextButton];

    NSColor *dimmedTextColor = [NSColor secondaryLabelColor];

    _artistTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kHeaderContentX, kArtistY, kHeaderContentWidth, kArtistHeight)];
    _artistTextField.font = [Fonts font:16];
    _artistTextField.textColor = dimmedTextColor;
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
    // No rasterization: this field's content changes every second, so
    // rasterization would just force a re-raster on every update.
    configureLabelShadow(_currentTimeTextField, NO);
    [self addSubview:_currentTimeTextField];

    // Empty-state hint, spanning the gap between the two time labels.
    _dropHintTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kDropHintX, kTimeRowY, kDropHintWidth, kSmallLabelHeight)];
    _dropHintTextField.font = [Fonts font:13];
    _dropHintTextField.alignment = NSTextAlignmentCenter;
    _dropHintTextField.textColor = dimmedTextColor;
    _dropHintTextField.stringValue = @"Drop a file or press ⌘O";
    // Half strength like the rest of the empty state.
    _dropHintTextField.alphaValue = 0.5;
    _dropHintTextField.hidden = YES;
    // Spans the gap between the two time labels, so it takes the extra width.
    _dropHintTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_dropHintTextField, YES);
    [self addSubview:_dropHintTextField];

    // Frosted backdrop under the playlist: the window's Clear glass is too
    // transparent to read row text over, so this panel frosts just the
    // playlist region. An NSVisualEffectView, NOT an NSGlassEffectView: the
    // glass view's SwiftUI hosting internals fight the window's autoresizing
    // when HeightSizable (the window refuses to expand past the design
    // height). Sits under the scroll view (an NSClipView background doesn't
    // composite semi-transparent colors over a backdrop) so it also covers
    // the empty area below the last row; the light-mode dim wash rides
    // inside it.
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

    // The table (columns, row metrics, cell construction) is entirely
    // PlaylistTableView's; only the frame is placed here.
    NSScrollView *playlistScrollView = [PlaylistTableView scrollViewWithFrame:
            NSMakeRect(0, 0, kMainWindowContentWidth, kPlaylistHeight)];
    _playlistTableView = (PlaylistTableView *)playlistScrollView.documentView;
    [self addSubview:playlistScrollView];

    _fileMetadataTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kCodecLabelX, kCodecLabelY, kCodecLabelWidth, kSmallLabelHeight)];
    _fileMetadataTextField.font = [Fonts fontForNumbers:kNumericLabelFontSize bold:NO];
    _fileMetadataTextField.alignment = NSTextAlignmentRight;
    _fileMetadataTextField.textColor = dimmedTextColor;
    _fileMetadataTextField.alphaValue = 0.5;
    _fileMetadataTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_fileMetadataTextField, YES);
    [self addSubview:_fileMetadataTextField];

    // BPM readout, directly below the codec line and styled to match.
    _bpmTextField = [MainPlayerContentView labelWithFrame:
            NSMakeRect(kCodecLabelX, kBPMLabelY, kCodecLabelWidth, kSmallLabelHeight)];
    _bpmTextField.font = [Fonts fontForNumbers:kNumericLabelFontSize bold:NO];
    _bpmTextField.alignment = NSTextAlignmentRight;
    _bpmTextField.textColor = dimmedTextColor;
    _bpmTextField.alphaValue = 0.5;
    _bpmTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_bpmTextField, YES);
    [self addSubview:_bpmTextField];
}

// Shared config for the borderless icon buttons (close/playlist/play/next):
// SymbolButton already draws a momentary, white-tinted SF Symbol with a ~100ms
// highlight fade; only the symbol, action, and resizing behavior vary.
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

// Borderless, non-editable static label with a transparent background.
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
