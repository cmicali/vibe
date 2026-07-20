//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "MainPlayerContentView.h"
#import "MainPlayerController.h" // declares the button action selectors
#import "GlyphButton.h"
#import "ArtworkImageView.h"
#import "AudioWaveformView.h"
#import "NSView+DarkMode.h"
#import "Fonts.h"
#import "Constants.h"

// Design-time size; the controller resizes the view to the window's restored
// frame after adding it, and the autoresizing pass lays subviews out at the
// real size. The width is the shared kMainWindowContentWidth (Constants.h) —
// the view must lay out at exactly the window's content width.
static const CGFloat kDesignHeight = 350;

// All the window's buttons sit hidden and fade in only while the cursor is
// over the window. The reveal is pure show/hide (full opacity); each button's
// resting dimness vs. hover brightness lives in its glyph colors, so a hovered
// traffic-light dot can reach full saturation like the real macOS controls.
static const CFTimeInterval kControlFadeDur = 0.2;

// Shared point size for the small numeric labels (time readouts, codec line,
// BPM line).
static const CGFloat kNumericLabelFontSize = 13;

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
    GlyphButton *_playlistToggleButton;
    NSTrackingArea *_windowHoverArea;
    __weak NSView *_windowHoverHost;
}

- (instancetype)initWithTarget:(id)target {
    self = [super initWithFrame:NSMakeRect(0, 0, kMainWindowContentWidth, kDesignHeight)];
    if (self) {
        self.wantsLayer = YES;
        self.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
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

// One shadow recipe for every header label; the opacity itself is
// appearance-driven (updateMaterialForAppearance): dark text on the light
// glass needs no shadow, light text on dark glass gets a strong one.
// Rasterization is opted out for fields whose content changes every second
// (re-rastering would cost more than it saves).
static const CGFloat kLabelShadowOpacityDark = 0.9;

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
    _backgroundGlassView = [[VibePassthroughGlassView alloc] initWithFrame:NSMakeRect(125, 200, 577, 150)];
    _backgroundGlassView.cornerRadius = kMainWindowCornerRadius;
    _backgroundGlassView.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_backgroundGlassView];

    // The art-color tint over the glass. NOT the glass's tintColor: AppKit
    // kills that outright while the window is inactive, and the design calls
    // for half strength instead (ArtworkDisplayController drives the color
    // and the active/inactive dimming).
    _headerTintView = [[VibePassthroughView alloc] initWithFrame:_backgroundGlassView.frame];
    _headerTintView.wantsLayer = YES;
    _headerTintView.layer.cornerRadius = kMainWindowCornerRadius;
    _headerTintView.layer.masksToBounds = YES;
    _headerTintView.autoresizingMask = _backgroundGlassView.autoresizingMask;
    [self addSubview:_headerTintView];

    _waveformView = [[AudioWaveformView alloc] initWithFrame:NSMakeRect(158, 215, 512, 86)];
    _waveformView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_waveformView];

    _albumArtImageView = [[ArtworkImageView alloc] initWithFrame:NSMakeRect(0, 200, 150, 150)];
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
    _albumArtGradientView = [[VibePassthroughView alloc] initWithFrame:NSMakeRect(0, 200, 150, 150)];
    CAGradientLayer *artGradient = [[CAGradientLayer alloc] init];
    artGradient.colors = @[
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.85].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.25].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0].CGColor
    ];
    artGradient.locations = @[@0.0, @0.3, @0.5];
    // Layer-hosting contract: assign the layer BEFORE wantsLayer, or AppKit
    // creates its own backing layer first and the view is layer-backed.
    _albumArtGradientView.layer = artGradient;
    _albumArtGradientView.wantsLayer = YES;
    _albumArtGradientView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_albumArtGradientView];

    // Traffic-light dots sized/spaced like the real macOS controls (13pt
    // circles on 23pt centers) and left-aligned with the playlist icon's left
    // edge below (its glyph starts ~18.5pt in). They start hidden and fade in
    // on window hover (setControlsShown:animated:).
    _closeButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(9, 313, 32, 32)
                                                             glyph:GlyphButtonGlyphClose
                                                            action:@selector(closeApp:)
                                                            target:target];
    _closeButton.alphaValue = 0.0;
    _closeButton.glyphSize = 13;
    // Dim at rest; lights up to full salmon on hover.
    _closeButton.glyphNormalColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:0.64];
    _closeButton.glyphHighlightColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:1.0];
    [self addSubview:_closeButton];

    _minimizeButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(32, 313, 32, 32)
                                                                glyph:GlyphButtonGlyphMinimize
                                                               action:@selector(minimizeWindow:)
                                                               target:target];
    _minimizeButton.alphaValue = 0.0;
    _minimizeButton.glyphSize = 13; // same dot as close
    // Dim at rest; lights up to full yellow on hover.
    _minimizeButton.glyphNormalColor = [NSColor colorWithSRGBRed:0.988 green:0.741 blue:0.180 alpha:0.64];
    _minimizeButton.glyphHighlightColor = [NSColor colorWithSRGBRed:0.988 green:0.741 blue:0.180 alpha:1.0];
    [self addSubview:_minimizeButton];

    // The outer two buttons are nudged toward the center one; the slight
    // frame overlap is fine (later siblings win hit testing). All three fade
    // in with the traffic lights on window hover.
    _playlistToggleButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(4, 203, 50, 50)
                                                                      glyph:GlyphButtonGlyphPlaylist
                                                                     action:@selector(toggleSize:)
                                                                     target:target];
    _playlistToggleButton.alphaValue = 0.0;
    [self addSubview:_playlistToggleButton];

    _playButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(50, 203, 50, 50)
                                                            glyph:GlyphButtonGlyphPlay
                                                           action:@selector(playPause:)
                                                           target:target];
    _playButton.alphaValue = 0.0;
    _playButton.enabled = NO;
    [self addSubview:_playButton];

    _nextButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(96, 203, 50, 50)
                                                            glyph:GlyphButtonGlyphSkipNext
                                                           action:@selector(next:)
                                                           target:target];
    _nextButton.alphaValue = 0.0;
    _nextButton.enabled = NO;
    [self addSubview:_nextButton];

    NSColor *dimmedTextColor = [NSColor secondaryLabelColor];

    _artistTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(158, 293, 512, 48)];
    _artistTextField.font = [Fonts font:16];
    _artistTextField.textColor = dimmedTextColor;
    _artistTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_artistTextField, YES);
    [self addSubview:_artistTextField];

    // Narrower than the artist line: the title shrinks-to-fit within this
    // width (MainPlayerController setTitleLabelText:), and capping it here
    // keeps even the longest titles clear of the codec/BPM labels in the
    // top-right corner.
    _titleTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(158, 292, 415, 30)];
    _titleTextField.font = [Fonts font:23];
    _titleTextField.textColor = [NSColor labelColor];
    _titleTextField.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    configureLabelShadow(_titleTextField, YES);
    [self addSubview:_titleTextField];

    _totalTimeTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(611, 207, 59, 16)];
    _totalTimeTextField.font = [Fonts fontForNumbers:kNumericLabelFontSize bold:YES];
    _totalTimeTextField.alignment = NSTextAlignmentRight;
    _totalTimeTextField.textColor = dimmedTextColor;
    _totalTimeTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_totalTimeTextField, YES);
    [self addSubview:_totalTimeTextField];

    _currentTimeTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(158, 207, 59, 16)];
    _currentTimeTextField.font = [Fonts fontForNumbers:kNumericLabelFontSize bold:YES];
    _currentTimeTextField.textColor = dimmedTextColor;
    _currentTimeTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    // No rasterization: this field's content changes every second, so
    // rasterization would just force a re-raster on every update.
    configureLabelShadow(_currentTimeTextField, NO);
    [self addSubview:_currentTimeTextField];

    // Empty-state hint, spanning the gap between the two time labels so the
    // text centers on the waveform's midline.
    _dropHintTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(217, 207, 394, 16)];
    _dropHintTextField.font = [Fonts font:13];
    _dropHintTextField.alignment = NSTextAlignmentCenter;
    _dropHintTextField.textColor = dimmedTextColor;
    _dropHintTextField.stringValue = @"Drop a file or press ⌘O";
    // Half strength like the rest of the empty state.
    _dropHintTextField.alphaValue = 0.5;
    _dropHintTextField.hidden = YES;
    _dropHintTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
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
    _playlistFrostView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kMainWindowContentWidth, 200)];
    _playlistFrostView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _playlistFrostView.state = NSVisualEffectStateActive;
    _playlistFrostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistFrostView];

    _playlistDimView = [[NSView alloc] initWithFrame:_playlistFrostView.bounds];
    _playlistDimView.wantsLayer = YES;
    _playlistDimView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_playlistFrostView addSubview:_playlistDimView];

    [self addSubview:[self buildPlaylistScrollViewWithFrame:NSMakeRect(0, 0, kMainWindowContentWidth, 200)]];

    _fileMetadataTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(430, 325, 240, 16)];
    _fileMetadataTextField.font = [Fonts fontForNumbers:kNumericLabelFontSize bold:NO];
    _fileMetadataTextField.alignment = NSTextAlignmentRight;
    _fileMetadataTextField.textColor = dimmedTextColor;
    _fileMetadataTextField.alphaValue = 0.5;
    _fileMetadataTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_fileMetadataTextField, YES);
    [self addSubview:_fileMetadataTextField];

    // BPM readout, directly below the codec line and styled to match.
    _bpmTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(430, 307, 240, 16)];
    _bpmTextField.font = [Fonts fontForNumbers:kNumericLabelFontSize bold:NO];
    _bpmTextField.alignment = NSTextAlignmentRight;
    _bpmTextField.textColor = dimmedTextColor;
    _bpmTextField.alphaValue = 0.5;
    _bpmTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_bpmTextField, YES);
    [self addSubview:_bpmTextField];
}

- (NSScrollView *)buildPlaylistScrollViewWithFrame:(NSRect)frame {
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height)];
    table.rowHeight = 28;
    table.headerView = nil;
    table.allowsMultipleSelection = NO;
    table.allowsColumnReordering = NO;
    table.allowsColumnResizing = NO;
    table.allowsExpansionToolTips = YES;
    table.backgroundColor = [NSColor clearColor];
    table.focusRingType = NSFocusRingTypeNone;
    table.intercellSpacing = NSMakeSize(0, 0);
    table.columnAutoresizingStyle = NSTableViewSequentialColumnAutoresizingStyle;
    // Type-select would swallow plain keystrokes (jump to the first row
    // starting with that letter) before the menu sees them, breaking the
    // unmodified transport key equivalents (Space/B/N) whenever the table
    // has focus.
    table.allowsTypeSelect = NO;
    // Opt out of the macOS 11+ inset look; we want the selection highlight
    // and row content flush with the scroll view's left/right edges.
    table.style = NSTableViewStyleFullWidth;

    struct {
        NSString *identifier;
        CGFloat width, minWidth, maxWidth;
    } columns[] = {
            {@"numColumn",     32,  32,  32},
            {@"artColumn",     48,  48,  48},
            {@"titleColumn",  552, 100, 10000},
            {@"lengthColumn",  48,  48,  48},
    };
    for (size_t i = 0; i < sizeof(columns) / sizeof(columns[0]); i++) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:columns[i].identifier];
        column.width = columns[i].width;
        column.minWidth = columns[i].minWidth;
        column.maxWidth = columns[i].maxWidth;
        column.resizingMask = NSTableColumnAutoresizingMask;
        [table addTableColumn:column];
    }

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.autohidesScrollers = YES;
    scrollView.usesPredominantAxisScrolling = NO;
    scrollView.horizontalScrollElasticity = NSScrollElasticityNone;
    scrollView.verticalLineScroll = 28;
    scrollView.horizontalLineScroll = 28;
    scrollView.automaticallyAdjustsContentInsets = NO;
    scrollView.contentInsets = NSEdgeInsetsZero;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.documentView = table;
    [table sizeToFit];

    _playlistTableView = table;
    return scrollView;
}

// Shared config for the borderless icon buttons (close/playlist/play/next):
// GlyphButton already draws a momentary, white-tinted glyph with a ~100ms
// highlight fade; only the glyph, action, and resizing behavior vary.
+ (GlyphButton *)transportButtonWithFrame:(NSRect)frame glyph:(GlyphButtonGlyph)glyph action:(SEL)action target:(id)target {
    GlyphButton *button = [[GlyphButton alloc] initWithFrame:frame];
    button.glyph = glyph;
    button.glyphSize = 26;
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
