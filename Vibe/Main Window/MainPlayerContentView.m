//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "MainPlayerContentView.h"
#import "MainPlayerController.h" // declares the button action selectors
#import "GlyphButton.h"
#import "ArtworkImageView.h"
#import "BackgroundArtworkImageView.h"
#import "AudioWaveformView.h"
#import "NSView+DarkMode.h"
#import "Fonts.h"

// Design-time size; the controller resizes the view to the window's restored
// frame after adding it, which runs the same autoresizing pass a nib load
// used to.
static const CGFloat kDesignWidth  = 680;
static const CGFloat kDesignHeight = 350;

@implementation MainPlayerContentView {
    NSView *_playlistDimView;
}

- (instancetype)initWithTarget:(id)target {
    self = [super initWithFrame:NSMakeRect(0, 0, kDesignWidth, kDesignHeight)];
    if (self) {
        self.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        self.state = NSVisualEffectStateActive;
        self.wantsLayer = YES;
        self.autoresizingMask = NSViewMaxXMargin | NSViewHeightSizable;
        [self buildSubviewsWithTarget:target];
        [self updateMaterialForAppearance];
    }
    return self;
}

// The translucent behind-window material effectively shows whatever is behind
// the window, so a light appearance over a dark desktop still read as dark.
// Light mode pins the opaque standard window background instead; dark keeps
// the translucent blur.
- (void)updateMaterialForAppearance {
    BOOL dark = self.isDark;
    self.material = dark ? NSVisualEffectMaterialUnderWindowBackground
                         : NSVisualEffectMaterialWindowBackground;
    // Dark mode shows the material through the playlist; the light material is
    // near-white, so dim the playlist down to roughly the blurred-artwork
    // backdrop's tone (art baked on a 0.85 base). The wash is a plain view
    // under the scroll view (an NSClipView background doesn't composite
    // semi-transparent colors over the material) so it also covers the empty
    // area below the last row.
    _playlistDimView.layer.backgroundColor = dark ? NSColor.clearColor.CGColor
                                                  : [NSColor colorWithWhite:0 alpha:0.22].CGColor;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self updateMaterialForAppearance];
}

// One shadow recipe for every header label. Rasterization is opted out for
// fields whose content changes every second (re-rastering would cost more
// than it saves).
static void configureLabelShadow(NSTextField *field, BOOL rasterize) {
    field.wantsLayer = YES;
    field.layer.shadowColor = NSColor.blackColor.CGColor;
    field.layer.shadowRadius = 0.25;
    field.layer.shadowOpacity = 0.75;
    field.layer.shadowOffset = CGSizeMake(0, -1);
    field.layer.masksToBounds = NO;
    field.layer.shouldRasterize = rasterize;
    if (rasterize) {
        field.layer.rasterizationScale = NSScreen.mainScreen.backingScaleFactor;
    }
}

- (void)buildSubviewsWithTarget:(id)target {
    _backgroundAlbumArtImageView = [[BackgroundArtworkImageView alloc] initWithFrame:NSMakeRect(125, 200, 577, 150)];
    _backgroundAlbumArtImageView.wantsLayer = YES;
    _backgroundAlbumArtImageView.layer.masksToBounds = NO;
    // No shouldRasterize: it was only there to cache the (long removed) live
    // CIGaussianBlur filter output; the image is pre-blurred these days.
    _backgroundAlbumArtImageView.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_backgroundAlbumArtImageView];

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

    // Darkening gradient over the album art (dark at the bottom, fading out
    // upward — the default CAGradientLayer axis) so the transport buttons
    // overlaying the art's lower half read against bright covers.
    _albumArtGradientView = [[NSView alloc] initWithFrame:NSMakeRect(0, 200, 150, 150)];
    _albumArtGradientView.wantsLayer = YES;
    CAGradientLayer *artGradient = [[CAGradientLayer alloc] init];
    artGradient.colors = @[
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.85].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0.25].CGColor,
            (id)[NSColor colorWithRed:0 green:0 blue:0 alpha:0].CGColor
    ];
    _albumArtGradientView.layer = artGradient;
    _albumArtGradientView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_albumArtGradientView];

    _closeButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(5, 313, 32, 32)
                                                             glyph:GlyphButtonGlyphClose
                                                            action:@selector(closeApp:)
                                                            target:target];
    _closeButton.alphaValue = 0.5;
    _closeButton.glyphSize = 12; // the old button-close dot was a 12pt circle (24px @2x)
    _closeButton.glyphNormalColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:0.56];
    _closeButton.glyphHighlightColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:0.75];
    [self addSubview:_closeButton];

    // The outer two buttons are nudged toward the center one; the slight
    // frame overlap is fine (later siblings win hit testing).
    GlyphButton *playlistButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(4, 203, 50, 50)
                                                                            glyph:GlyphButtonGlyphPlaylist
                                                                           action:@selector(toggleSize:)
                                                                           target:target];
    [self addSubview:playlistButton];

    _playButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(50, 203, 50, 50)
                                                            glyph:GlyphButtonGlyphPlay
                                                           action:@selector(playPause:)
                                                           target:target];
    _playButton.enabled = NO;
    [self addSubview:_playButton];

    _nextButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(96, 203, 50, 50)
                                                            glyph:GlyphButtonGlyphSkipNext
                                                           action:@selector(next:)
                                                           target:target];
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
    _totalTimeTextField.font = [Fonts fontForNumbers:_totalTimeTextField.font.pointSize bold:YES];
    _totalTimeTextField.alignment = NSTextAlignmentRight;
    _totalTimeTextField.textColor = dimmedTextColor;
    _totalTimeTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_totalTimeTextField, YES);
    [self addSubview:_totalTimeTextField];

    _currentTimeTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(158, 207, 59, 16)];
    _currentTimeTextField.font = [Fonts fontForNumbers:_currentTimeTextField.font.pointSize bold:YES];
    _currentTimeTextField.textColor = dimmedTextColor;
    _currentTimeTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    // No rasterization: this field's content changes every second, so
    // rasterization would just force a re-raster on every update.
    configureLabelShadow(_currentTimeTextField, NO);
    [self addSubview:_currentTimeTextField];

    _playlistDimView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kDesignWidth, 200)];
    _playlistDimView.wantsLayer = YES;
    _playlistDimView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistDimView];

    [self addSubview:[self buildPlaylistScrollViewWithFrame:NSMakeRect(0, 0, kDesignWidth, 200)]];

    _fileMetadataTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(430, 325, 240, 16)];
    _fileMetadataTextField.font = [Fonts fontForNumbers:_totalTimeTextField.font.pointSize bold:NO];
    _fileMetadataTextField.alignment = NSTextAlignmentRight;
    _fileMetadataTextField.textColor = dimmedTextColor;
    _fileMetadataTextField.alphaValue = 0.5;
    _fileMetadataTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    configureLabelShadow(_fileMetadataTextField, YES);
    [self addSubview:_fileMetadataTextField];

    // BPM readout, directly below the codec line and styled to match.
    _bpmTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(430, 307, 240, 16)];
    _bpmTextField.font = [Fonts fontForNumbers:_totalTimeTextField.font.pointSize bold:NO];
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
    button.glyphSize = 26; // the replaced 2x PNGs drew their glyphs in a ~26pt box
    button.target = target;
    button.action = action;
    button.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    return button;
}

// Static text field configured like the nib's labels: no border/bezel/edit,
// clipping line break, transparent background.
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
