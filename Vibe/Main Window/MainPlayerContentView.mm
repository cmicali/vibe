//
// Created by Christopher Micali on 7/12/26.
// Copyright (c) 2026 Christopher Micali. All rights reserved.
//

#import "MainPlayerContentView.h"
#import "MainPlayerController.h" // declares the button action selectors
#import "SYFlatButton.h"
#import "ArtworkImageView.h"
#import "BackgroundArtworkImageView.h"
#import "AudioWaveformView.h"
#import "NSView+DarkMode.h"

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

- (void)buildSubviewsWithTarget:(id)target {
    _backgroundAlbumArtImageView = [[BackgroundArtworkImageView alloc] initWithFrame:NSMakeRect(125, 200, 577, 150)];
    _backgroundAlbumArtImageView.wantsLayer = YES;
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
    _albumArtImageView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_albumArtImageView];

    _albumArtGradientView = [[NSView alloc] initWithFrame:NSMakeRect(0, 200, 150, 150)];
    _albumArtGradientView.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [self addSubview:_albumArtGradientView];

    _closeButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(5, 313, 32, 32)
                                                             image:@"button-close"
                                                            action:@selector(closeApp:)
                                                            target:target];
    _closeButton.alphaValue = 0.5;
    _closeButton.imageNormalColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:0.75];
    _closeButton.imageHighlightColor = [NSColor colorWithSRGBRed:0.945 green:0.420 blue:0.357 alpha:1];
    [self addSubview:_closeButton];

    SYFlatButton *playlistButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(0, 202, 50, 50)
                                                                             image:@"button-hamburger"
                                                                            action:@selector(toggleSize:)
                                                                            target:target];
    [self addSubview:playlistButton];

    _playButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(50, 203, 50, 50)
                                                            image:@"button-play"
                                                           action:@selector(playPause:)
                                                           target:target];
    _playButton.enabled = NO;
    [self addSubview:_playButton];

    _nextButton = [MainPlayerContentView transportButtonWithFrame:NSMakeRect(100, 203, 50, 50)
                                                            image:@"button-skip-next"
                                                           action:@selector(next:)
                                                           target:target];
    _nextButton.enabled = NO;
    [self addSubview:_nextButton];

    NSColor *dimmedTextColor = [NSColor secondaryLabelColor];

    _artistTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(158, 293, 512, 48)];
    _artistTextField.font = [NSFont fontWithName:@"HelveticaNeue-Medium" size:16];
    _artistTextField.textColor = dimmedTextColor;
    _artistTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_artistTextField];

    _titleTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(158, 292, 512, 30)];
    _titleTextField.font = [NSFont fontWithName:@"HelveticaNeue-Medium" size:23];
    _titleTextField.textColor = [NSColor labelColor];
    _titleTextField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [self addSubview:_titleTextField];

    _totalTimeTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(611, 207, 59, 16)];
    _totalTimeTextField.alignment = NSTextAlignmentRight;
    _totalTimeTextField.textColor = dimmedTextColor;
    _totalTimeTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self addSubview:_totalTimeTextField];

    _currentTimeTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(158, 207, 59, 16)];
    _currentTimeTextField.textColor = dimmedTextColor;
    _currentTimeTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self addSubview:_currentTimeTextField];

    _playlistDimView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kDesignWidth, 200)];
    _playlistDimView.wantsLayer = YES;
    _playlistDimView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_playlistDimView];

    [self addSubview:[self buildPlaylistScrollViewWithFrame:NSMakeRect(0, 0, kDesignWidth, 200)]];

    _fileMetadataTextField = [MainPlayerContentView labelWithFrame:NSMakeRect(430, 325, 240, 16)];
    _fileMetadataTextField.alignment = NSTextAlignmentRight;
    _fileMetadataTextField.textColor = dimmedTextColor;
    _fileMetadataTextField.alphaValue = 0.5;
    _fileMetadataTextField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self addSubview:_fileMetadataTextField];
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
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scrollView.documentView = table;

    _playlistTableView = table;
    return scrollView;
}

// Shared config for the borderless icon buttons (close/playlist/play/next):
// shadowless square bezel, icon only, ~100ms highlight fade, all border and
// background states transparent, white icon tinting unless overridden.
+ (SYFlatButton *)transportButtonWithFrame:(NSRect)frame image:(NSString *)imageName action:(SEL)action target:(id)target {
    SYFlatButton *button = [[SYFlatButton alloc] initWithFrame:frame];
    [button setButtonType:NSButtonTypeMomentaryPushIn];
    button.bezelStyle = NSBezelStyleShadowlessSquare;
    button.image = [NSImage imageNamed:imageName];
    button.imagePosition = NSImageOnly;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.momentary = YES;
    button.onAnimateDuration = 0.1;
    button.offAnimateDuration = 0.1;
    button.borderNormalColor = [NSColor clearColor];
    button.borderHighlightColor = [NSColor clearColor];
    button.borderDisabledColor = [NSColor clearColor];
    button.backgroundNormalColor = [NSColor clearColor];
    button.backgroundHighlightColor = [NSColor clearColor];
    button.backgroundDisabledColor = [NSColor clearColor];
    button.imageNormalColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:0.74];
    button.imageHighlightColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:1];
    button.imageDisabledColor = [NSColor colorWithDisplayP3Red:1 green:1 blue:1 alpha:0.25];
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
