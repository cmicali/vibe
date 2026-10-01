//
//  TrackPageCell.m
//  Vibe (iOS)
//

#import "TrackPageCell.h"
#import "FXPadView.h"
#import "Formatters.h"
#import "OutputRouteView.h"
#import "SettingsRules.h"
#import "UIImage+Blur.h"
#import "UIImage+DominantColor.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"

static const CGFloat kCellWaveformHeight = 180;
static const CGFloat kCellWaveformHeightLandscape = 120;

// Portrait is four bands and only the ART band moves: the grabber strip under
// the safe top, the art band (the leftover height), the fixed LABEL band, and
// one chain off the SAFE BOTTOM — waveform, time row, transport, action bar —
// which puts the waveform at the same y on every page.
static const CGFloat kCellTopBandHeight = 36;
// The art's two caps: the WIDTH fraction binds on a tall screen, the BAND on a
// short one.
static const CGFloat kCellArtWidthFraction = 0.645;
static const CGFloat kCellArtBandFill = 0.94;
static const CGFloat kCellLabelGap = 6;
static const CGFloat kCellLabelBandPadding = 10;
static const CGFloat kCellWaveformTransportGap = 28;

// Portrait: with audio effects on, the FX pad's circle and, a gap to its
// right, the route capsule over the rest of the width; off, the route capsule
// alone. Landscape: the same two, one in each bottom corner.
static const CGFloat kCellActionBarHeight = 56;
static const CGFloat kCellActionBarInset = 20;
static const CGFloat kCellActionBarGap = 12;
// Portrait: the route control keeps this far inside the capsule's ends, where
// a long device name truncates.
static const CGFloat kCellActionBarContentInset = 16;
static const CGFloat kCellActionBarTransportGap = 16;
// A tint, not a live-blurring effect view: the backdrop never changes.
static const CGFloat kCellActionBarFillAlpha = 0.12;

// The scrubber reserves headroom around its envelope, and the eye measures
// from the drawn waveform, so portrait pulls the time row UP into the view
// and landscape measures its time band from the same line.
static const CGFloat kCellTimeWaveformOverlap = 12;
static const CGFloat kArtCornerRadius = 12;
// Apple Music's rendered glyph sizes, in far larger tap targets.
static const CGFloat kCellGlyphPointSize = 34;
static const CGFloat kCellSideGlyphPointSize = 23;
static const CGFloat kTransportButtonSide = 66;
static const CGFloat kTransportButtonGap = 41;
// Shuffle and repeat: smaller glyphs in narrower targets. Their gaps give way
// before the three's, and the three's before the edges or the route name.
static const CGFloat kCellFlankGlyphPointSize = 19;
static const CGFloat kTransportFlankButtonSide = 44;
static const CGFloat kTransportFlankMinGap = 8;
static const CGFloat kTransportMinGap = 16;
static const CGFloat kTransportEdgeInset = 16;
static const CGFloat kTransportDisabledAlpha = 0.5;

static const CGFloat kCellTitlePointSize = 22;
static const CGFloat kCellArtistPointSize = 16;
// Landscape's header has the width portrait's centered band lacks.
static const CGFloat kCellHeaderFontScaleLandscape = 1.34;
static const CGFloat kCellHeaderGapLandscape = 16;
static const CGFloat kCellArtHeightFractionLandscape = 0.38;
static const CGFloat kCellTopInsetLandscape = 12;
// The waveform sits this far above center, leaving the time row room under it.
static const CGFloat kCellTimeRowShiftLandscape = 4;
// Landscape's side margin where the safe area supplies none (iPad).
static const CGFloat kCellEdgeInsetLandscape = 20;
static const CGFloat kCellBottomInsetLandscape = 16;
// Landscape's route pill hugs its content up to this; portrait's fills its
// capsule. The inset is small so a lone glyph's pill is the pad's circle.
static const CGFloat kCellRouteMaxWidthLandscape = 160;
static const CGFloat kCellRouteContentInsetLandscape = 6;
static const CGFloat kCellTimeGap = 12;

static void VibeConfigureTimeLabel(UILabel *label) {
    label.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
            scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:16
                                                               weight:UIFontWeightRegular]];
    label.adjustsFontForContentSizeCategory = YES;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisVertical];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = STR_LABEL_TIME_UNKNOWN;
    label.translatesAutoresizingMaskIntoConstraints = NO;
}

// TRAP: the shadow path is restated from the card's OWN layout pass. The
// contentView's constraints size the card, so a label-band change resizes it
// without the cell's layoutSubviews running, and a path set there leaves a
// stale halo until a swipe recycles the cell.
@interface TrackPageArtCardView : UIView
@end

@implementation TrackPageTimeControl {
    UILabel *_label;
    NSString *_text;
    NSTextAlignment _textAlignment;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _label = [[UILabel alloc] init];
        VibeConfigureTimeLabel(_label);
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_label.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor],
        ]];
        self.isAccessibilityElement = YES;
        self.accessibilityLabel = STR_SETTINGS_SECTION_TIME;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        self.text = STR_LABEL_TIME_UNKNOWN;
        __weak TrackPageTimeControl *weakSelf = self;
        [self registerForTraitChanges:@[UITraitPreferredContentSizeCategory.class]
                          withHandler:^(id<UITraitEnvironment> environment,
                                        UITraitCollection *previous) {
            [weakSelf invalidateIntrinsicContentSize];
        }];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    CGSize labelSize = _label.intrinsicContentSize;
    return CGSizeMake(MAX(44, labelSize.width), MAX(44, labelSize.height));
}

- (NSString *)text {
    return _text;
}

// The tick writes it three times a second, and an unchanged write would still
// invalidate the layout.
- (void)setText:(NSString *)text {
    if (text == _text || [text isEqualToString:_text]) {
        return;
    }
    _text = [text copy];
    _label.text = text;
    self.accessibilityValue = text;
    [self invalidateIntrinsicContentSize];
}

- (NSTextAlignment)textAlignment {
    return _textAlignment;
}

- (void)setTextAlignment:(NSTextAlignment)textAlignment {
    _textAlignment = textAlignment;
    _label.textAlignment = textAlignment;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    _label.alpha = highlighted ? 0.55 : 1;
}
@end

@implementation TrackPageActionBarView
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2;
}
@end

@implementation TrackPageArtCardView
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                                       cornerRadius:kArtCornerRadius].CGPath;
}
@end

@implementation TrackPageCell {
    // Blurred ONCE into an image (UIImage+Blur), not a UIVisualEffectView,
    // whose live filter re-blurs every frame of a swipe.
    UIImageView        *_backdropView;
    UIView             *_artCard;         // the shadow; the image view clips
    UIImageView        *_artCardView;
    UILabel            *_artistLabel;
    UILabel            *_titleLabel;
    UILabel            *_fileInfoLabel;

    // Portrait: the label band is nailed to its worst case so a long title
    // cannot move the art. layoutSubviews restates these on the scaled fonts.
    NSLayoutConstraint *_labelBandHeight;
    NSLayoutConstraint *_artistHeight;
    NSLayoutConstraint *_fileInfoHeight;
    // Zeroed with the height when there is no codec line.
    NSLayoutConstraint *_fileInfoTop;
    // Landscape: the info label's first line tops out with the artist's, by
    // cap height, since the two fonts differ.
    NSLayoutConstraint *_fileInfoCapTopLandscape;

    // Landscape's right time follows the route pill under it: centered over a
    // lone glyph, right-aligned with the device name when there is one.
    NSLayoutConstraint *_remainingCenteredOnRoute;
    NSLayoutConstraint *_remainingTrailingOnRoute;

    // Joined on one line in portrait, stacked in landscape as on the mac.
    NSString           *_fileInfo;
    NSString           *_tempoInfo;

    // The route capsule's leading edge when the FX pad is shown: a gap past
    // the pad's circle, required, outranking the full-width leading edge the
    // portrait set holds at a lower priority. Active only in portrait, where
    // that set is.
    NSLayoutConstraint *_actionBarLeadingAfterPad;
    BOOL               _fxPadShown;
    // What hiding the shuffle and repeat buttons zeroes.
    BOOL                _shuffleRepeatShown;
    NSLayoutConstraint *_shuffleWidth;
    NSLayoutConstraint *_repeatWidth;
    NSLayoutConstraint *_outerGapWanted;
    NSLayoutConstraint *_outerGapMin;

    // Swapped on the cell's own aspect, so a rotation mid-reuse cannot
    // strand a cell.
    NSArray<NSLayoutConstraint *> *_portraitConstraints;
    NSArray<NSLayoutConstraint *> *_landscapeConstraints;
    BOOL               _landscapeActive;
    BOOL               _layoutApplied;
}

+ (NSString *)reuseIdentifier {
    return @"TrackPageCell";
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        UIView *content = self.contentView;

        _backdropView = [[UIImageView alloc] init];
        _backdropView.contentMode = UIViewContentModeScaleAspectFill;
        _backdropView.clipsToBounds = YES;
        // The bake is a few dozen pixels magnified to the whole screen.
        _backdropView.layer.magnificationFilter = kCAFilterTrilinear;
        _backdropView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_backdropView];

        _artCard = [[TrackPageArtCardView alloc] init];
        _artCard.layer.shadowColor = UIColor.blackColor.CGColor;
        _artCard.layer.shadowOpacity = 0.35;
        _artCard.layer.shadowRadius = 24;
        _artCard.layer.shadowOffset = CGSizeMake(0, 10);
        _artCard.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_artCard];

        _artCardView = [[UIImageView alloc] init];
        _artCardView.contentMode = UIViewContentModeScaleAspectFill;
        _artCardView.clipsToBounds = YES;
        // At the default 750 the art's intrinsic size ties with the card's
        // width preference and stretches the card.
        [_artCardView setContentCompressionResistancePriority:1
                forAxis:UILayoutConstraintAxisHorizontal];
        [_artCardView setContentCompressionResistancePriority:1
                forAxis:UILayoutConstraintAxisVertical];
        [_artCardView setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
        [_artCardView setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
        _artCardView.layer.cornerRadius = kArtCornerRadius;
        _artCardView.layer.cornerCurve = kCACornerCurveContinuous;
        _artCardView.translatesAutoresizingMaskIntoConstraints = NO;
        [_artCard addSubview:_artCardView];

        // Dynamic Type squeezes the art, never the text. All three shrink to
        // fit rather than truncate: the band's height is fixed.
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.6;
        [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisVertical];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_titleLabel];

        _artistLabel = [[UILabel alloc] init];
        _artistLabel.adjustsFontForContentSizeCategory = YES;
        _artistLabel.adjustsFontSizeToFitWidth = YES;
        _artistLabel.minimumScaleFactor = 0.7;
        [_artistLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                      forAxis:UILayoutConstraintAxisVertical];
        _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_artistLabel];

        _fileInfoLabel = [[UILabel alloc] init];
        _fileInfoLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
                scaledFontForFont:[UIFont systemFontOfSize:14.5]];
        _fileInfoLabel.adjustsFontForContentSizeCategory = YES;
        _fileInfoLabel.adjustsFontSizeToFitWidth = YES;
        _fileInfoLabel.minimumScaleFactor = 0.7;
        _fileInfoLabel.textColor = [UIColor secondaryLabelColor];
        [_fileInfoLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                        forAxis:UILayoutConstraintAxisVertical];
        _fileInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_fileInfoLabel];

        _waveformView = [[WaveformScrubberView alloc] initWithFrame:CGRectZero];
        _waveformView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_waveformView];

        _elapsedLabel = [self makeTimeLabel];
        [content addSubview:_elapsedLabel];
        _remainingTimeControl = [[TrackPageTimeControl alloc] initWithFrame:CGRectZero];
        _remainingTimeControl.textAlignment = NSTextAlignmentRight;
        _remainingTimeControl.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_remainingTimeControl];

        _transportView = [[UIView alloc] init];
        _transportView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_transportView];

        // Behind the route control, not around it: each layout places the
        // two independently.
        _actionBar = [[TrackPageActionBarView alloc] init];
        _actionBar.backgroundColor = [UIColor colorWithWhite:1
                                                       alpha:kCellActionBarFillAlpha];
        _actionBar.layer.cornerCurve = kCACornerCurveContinuous;
        _actionBar.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_actionBar];

        _routeView = [[OutputRouteView alloc] initWithFrame:CGRectZero];
        _routeView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_routeView];

        // The FX pad, last so its expanded square draws over everything it
        // covers — the transport, the waveform, the times.
        _fxPadView = [[FXPadView alloc] initWithFrame:CGRectZero];
        _fxPadView.backgroundColor = _actionBar.backgroundColor;
        _fxPadView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_fxPadView];

        _shuffleButton = [self makeTransportButton];
        _shuffleButton.accessibilityLabel = STR_TRANSPORT_SHUFFLE;
        _previousButton = [self makeTransportButton];
        _previousButton.accessibilityLabel = STR_TRANSPORT_PREVIOUS;
        [self setGlyph:@"backward.end.fill" onButton:_previousButton
             pointSize:kCellSideGlyphPointSize];
        _playPauseButton = [self makeTransportButton];
        _nextButton = [self makeTransportButton];
        _nextButton.accessibilityLabel = STR_TRANSPORT_NEXT;
        [self setGlyph:@"forward.end.fill" onButton:_nextButton
             pointSize:kCellSideGlyphPointSize];
        _repeatButton = [self makeTransportButton];
        _shuffleWidth = [_shuffleButton.widthAnchor constraintEqualToConstant:kTransportFlankButtonSide];
        _repeatWidth = [_repeatButton.widthAnchor constraintEqualToConstant:kTransportFlankButtonSide];
        [self setGlyphPlaying:NO];
        [self setShuffleEnabled:NO repeatMode:VibeRepeatModeOff];

        // Landscape: the artist (750) truncates before the codec line.
        [_fileInfoLabel setContentCompressionResistancePriority:760
                forAxis:UILayoutConstraintAxisHorizontal];

        [NSLayoutConstraint activateConstraints:@[
            [_backdropView.topAnchor constraintEqualToAnchor:content.topAnchor],
            [_backdropView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [_backdropView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_backdropView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

            [_artCardView.topAnchor constraintEqualToAnchor:_artCard.topAnchor],
            [_artCardView.bottomAnchor constraintEqualToAnchor:_artCard.bottomAnchor],
            [_artCardView.leadingAnchor constraintEqualToAnchor:_artCard.leadingAnchor],
            [_artCardView.trailingAnchor constraintEqualToAnchor:_artCard.trailingAnchor],
            [_artCard.widthAnchor constraintEqualToAnchor:_artCard.heightAnchor],

            [_transportView.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
            [_transportView.heightAnchor constraintEqualToConstant:kTransportButtonSide],
            [_routeView.heightAnchor constraintEqualToConstant:44],
            [_routeView.centerYAnchor constraintEqualToAnchor:_actionBar.centerYAnchor],
            [_actionBar.heightAnchor constraintEqualToConstant:kCellActionBarHeight],
            [_fxPadView.widthAnchor constraintEqualToConstant:kCellActionBarHeight],
            [_fxPadView.heightAnchor constraintEqualToConstant:kCellActionBarHeight],
            [_waveformView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_waveformView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [_remainingTimeControl.bottomAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor],
            [_elapsedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_remainingTimeControl.leadingAnchor
                                                                   constant:-kCellTimeGap],
            [_remainingTimeControl.widthAnchor constraintGreaterThanOrEqualToConstant:44],
            [_remainingTimeControl.heightAnchor constraintGreaterThanOrEqualToConstant:44],
            [_shuffleButton.leadingAnchor constraintEqualToAnchor:_transportView.leadingAnchor],
            [_repeatButton.trailingAnchor constraintEqualToAnchor:_transportView.trailingAnchor],
            _shuffleWidth,
            _repeatWidth,
            [_previousButton.widthAnchor constraintEqualToConstant:kTransportButtonSide],
            [_playPauseButton.widthAnchor constraintEqualToConstant:kTransportButtonSide],
            [_nextButton.widthAnchor constraintEqualToConstant:kTransportButtonSide],
        ]];
        [NSLayoutConstraint activateConstraints:[self transportGapConstraints]];

        _portraitConstraints = [self buildPortraitConstraints];
        _landscapeConstraints = [self buildLandscapeConstraints];
        _fxPadShown = YES;
        _shuffleRepeatShown = YES;
    }
    return self;
}

// Four gaps as layout guides, so each pair can be held equal: the three stay
// centered and the row symmetric while the gaps give. Below the route view's
// compression resistance, so in landscape the row closes up before the
// device name truncates.
- (NSArray<NSLayoutConstraint *> *)transportGapConstraints {
    NSArray<UIView *> *row = @[_shuffleButton, _previousButton, _playPauseButton,
                               _nextButton, _repeatButton];
    NSMutableArray<UILayoutGuide *> *gaps = [NSMutableArray array];
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];
    for (NSUInteger i = 0; i + 1 < row.count; i++) {
        UILayoutGuide *gap = [[UILayoutGuide alloc] init];
        [_transportView addLayoutGuide:gap];
        [gaps addObject:gap];
        [constraints addObjectsFromArray:@[
            [gap.leadingAnchor constraintEqualToAnchor:row[i].trailingAnchor],
            [gap.trailingAnchor constraintEqualToAnchor:row[i + 1].leadingAnchor],
            [gap.heightAnchor constraintEqualToConstant:0],
            [gap.topAnchor constraintEqualToAnchor:_transportView.topAnchor],
        ]];
    }
    // Outer pair: the flanks' gaps; inner pair: the three's.
    UILayoutGuide *outer = gaps[0];
    UILayoutGuide *inner = gaps[1];
    _outerGapWanted = [outer.widthAnchor constraintEqualToConstant:kTransportButtonGap];
    _outerGapWanted.priority = UILayoutPriorityDefaultHigh - 20;
    _outerGapMin = [outer.widthAnchor constraintGreaterThanOrEqualToConstant:kTransportFlankMinGap];
    NSLayoutConstraint *innerWanted = [inner.widthAnchor constraintEqualToConstant:kTransportButtonGap];
    innerWanted.priority = UILayoutPriorityDefaultHigh - 10;
    [constraints addObjectsFromArray:@[
        [gaps[3].widthAnchor constraintEqualToAnchor:outer.widthAnchor],
        [gaps[2].widthAnchor constraintEqualToAnchor:inner.widthAnchor],
        _outerGapWanted,
        innerWanted,
        _outerGapMin,
        [inner.widthAnchor constraintGreaterThanOrEqualToConstant:kTransportMinGap],
    ]];
    return constraints;
}

// The shadow follows the glyph's alpha, so it can have no shadowPath; without
// one it renders offscreen every frame, so it is rasterized instead.
- (UIButton *)makeTransportButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = [UIColor labelColor];
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.5;
    button.layer.shadowRadius = 8;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.layer.shouldRasterize = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [_transportView addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:_transportView.topAnchor],
        [button.bottomAnchor constraintEqualToAnchor:_transportView.bottomAnchor],
    ]];
    return button;
}

static UIImage *TransportGlyph(NSString *symbol, CGFloat pointSize) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration
            configurationWithPointSize:pointSize
                                weight:UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:symbol withConfiguration:config];
}

// The disabled and off looks, drawn; see setNextEnabled:.
static UIImage *DimmedGlyph(UIImage *glyph) {
    return [[glyph imageWithTintColor:[UIColor.labelColor colorWithAlphaComponent:kTransportDisabledAlpha]
                        renderingMode:UIImageRenderingModeAlwaysOriginal]
            imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (void)setGlyph:(NSString *)symbol onButton:(UIButton *)button pointSize:(CGFloat)pointSize {
    UIImage *glyph = TransportGlyph(symbol, pointSize);
    [button setImage:glyph forState:UIControlStateNormal];
    [button setImage:DimmedGlyph(glyph) forState:UIControlStateDisabled];
}

- (NSArray<NSLayoutConstraint *> *)buildPortraitConstraints {
    UIView *content = self.contentView;
    UILayoutGuide *safe = content.safeAreaLayoutGuide;

    UILayoutGuide *artBand = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:artBand];
    // The labels ride centered in the band, so a one-line title does not
    // leave a gap under it.
    UILayoutGuide *labelBand = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:labelBand];
    UILayoutGuide *labels = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:labels];
    _actionBarLeadingAfterPad = [_actionBar.leadingAnchor constraintEqualToAnchor:_fxPadView.trailingAnchor
                                                                          constant:kCellActionBarGap];
    NSLayoutConstraint *actionBarLeadingFull = [_actionBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                                                        constant:kCellActionBarInset];
    actionBarLeadingFull.priority = UILayoutPriorityDefaultHigh;

    // The single-line labels keep their line reserved, so a missing artist
    // lays out like a present one.
    _labelBandHeight = [labelBand.heightAnchor constraintEqualToConstant:0];
    _artistHeight = [_artistLabel.heightAnchor constraintEqualToConstant:0];
    _fileInfoHeight = [_fileInfoLabel.heightAnchor constraintEqualToConstant:0];
    _fileInfoTop = [_fileInfoLabel.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor
                                                            constant:kCellLabelGap];

    // Takes what the caps allow; gives at accessibility sizes.
    NSLayoutConstraint *artFill =
            [_artCard.widthAnchor constraintEqualToAnchor:safe.widthAnchor
                                               multiplier:kCellArtWidthFraction];
    artFill.priority = UILayoutPriorityDefaultHigh;

    // Gives on a window too short for the chain (the minimum iPad one is 20pt
    // short). Required, every edge to the safe bottom being an equality, the
    // solver would give the art a NEGATIVE height.
    NSLayoutConstraint *topBand = [artBand.topAnchor
            constraintEqualToAnchor:safe.topAnchor
                           constant:kCellTopBandHeight];
    topBand.priority = UILayoutPriorityRequired - 1;

    return @[
        actionBarLeadingFull,
        topBand,
        [artBand.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor],
        [_artCard.heightAnchor constraintGreaterThanOrEqualToConstant:0],
        [artBand.bottomAnchor constraintEqualToAnchor:labelBand.topAnchor],
        [_artCard.centerYAnchor constraintEqualToAnchor:artBand.centerYAnchor],
        [_artCard.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_artCard.heightAnchor constraintLessThanOrEqualToAnchor:artBand.heightAnchor
                                                      multiplier:kCellArtBandFill],
        [_artCard.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor
                                                    multiplier:kCellArtWidthFraction],
        artFill,

        [labelBand.bottomAnchor constraintEqualToAnchor:_waveformView.topAnchor],
        _labelBandHeight,
        [labels.topAnchor constraintEqualToAnchor:_titleLabel.topAnchor],
        [labels.bottomAnchor constraintEqualToAnchor:_fileInfoLabel.bottomAnchor],
        [labels.centerYAnchor constraintEqualToAnchor:labelBand.centerYAnchor],

        [_titleLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:20],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],
        _artistHeight,
        _fileInfoHeight,
        [_artistLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor
                                               constant:kCellLabelGap],
        [_artistLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_artistLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:20],
        [_artistLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],
        _fileInfoTop,
        [_fileInfoLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_fileInfoLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:20],
        [_fileInfoLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],

        [_waveformView.heightAnchor constraintEqualToConstant:kCellWaveformHeight],
        // A chain off the SAFE BOTTOM, so the waveform sits at the same y on
        // every page. The time row hangs off the waveform, so tightening it
        // cannot push the waveform down.
        [_actionBar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_actionBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                                  constant:-kCellActionBarInset],
        // TRAP: the route view IS the tap surface, so it spans the capsule.
        // Hugging its content, a lone glyph left a 44pt target in the middle
        // of a capsule that reads as one button. The name truncates inside.
        [_routeView.leadingAnchor constraintEqualToAnchor:_actionBar.leadingAnchor
                                                 constant:kCellActionBarContentInset],
        [_routeView.trailingAnchor constraintEqualToAnchor:_actionBar.trailingAnchor
                                                  constant:-kCellActionBarContentInset],
        // The pad's circle, at the bar's leading end.
        [_fxPadView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_fxPadView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                 constant:kCellActionBarInset],

        [_transportView.bottomAnchor constraintEqualToAnchor:_actionBar.topAnchor
                                                    constant:-kCellActionBarTransportGap],
        [_transportView.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor
                                                                  constant:kTransportEdgeInset],
        [_waveformView.bottomAnchor constraintEqualToAnchor:_transportView.topAnchor
                                                   constant:-kCellWaveformTransportGap],
        [_elapsedLabel.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor
                                                constant:-kCellTimeWaveformOverlap],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_remainingTimeControl.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
    ];
}

// The mac main window, transplanted: the header in the top-leading corner,
// the transport along the bottom between the two pills, and the waveform with
// its time row centered in what is left between them.
- (NSArray<NSLayoutConstraint *> *)buildLandscapeConstraints {
    UIView *content = self.contentView;
    UILayoutGuide *safe = content.safeAreaLayoutGuide;

    UILayoutGuide *middle = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:middle];
    // Between the drawn waveform and the pills; the time row centers in it.
    UILayoutGuide *timeBand = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:timeBand];
    UILayoutGuide *names = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:names];

    // One column edge per side: the art and the FX pad share the leading one,
    // the info label and the route pill the trailing one. It is the safe
    // area's side, which on a phone is already a
    // margin and clears the island; a window with no side insets (iPad) falls
    // back to the edge inset.
    UILayoutGuide *column = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:column];
    NSLayoutConstraint *columnLeading = [column.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor];
    columnLeading.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *columnTrailing = [column.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor];
    columnTrailing.priority = UILayoutPriorityDefaultHigh;

    _remainingCenteredOnRoute = [_remainingTimeControl.centerXAnchor
            constraintEqualToAnchor:_actionBar.centerXAnchor];
    // The route view hugs its content once that passes the tap minimum, which
    // a glyph and a name always do, so its edge is the name's.
    _remainingTrailingOnRoute = [_remainingTimeControl.trailingAnchor
            constraintEqualToAnchor:_routeView.trailingAnchor];

    _fileInfoCapTopLandscape = [_fileInfoLabel.topAnchor constraintEqualToAnchor:_artistLabel.topAnchor];

    return @[
        columnLeading,
        columnTrailing,
        [column.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor
                                                          constant:kCellEdgeInsetLandscape],
        [column.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor
                                                        constant:-kCellEdgeInsetLandscape],
        [_artCard.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [_artCard.topAnchor constraintEqualToAnchor:safe.topAnchor
                                           constant:kCellTopInsetLandscape],
        [_artCard.heightAnchor constraintEqualToAnchor:content.heightAnchor
                                             multiplier:kCellArtHeightFractionLandscape],

        // The names center on the art; the info label hangs off the artist.
        [names.topAnchor constraintEqualToAnchor:_artistLabel.topAnchor],
        [names.bottomAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor],
        [names.centerYAnchor constraintEqualToAnchor:_artCard.centerYAnchor],
        [_artistLabel.leadingAnchor constraintEqualToAnchor:_artCard.trailingAnchor
                                                   constant:kCellHeaderGapLandscape],
        [_artistLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_fileInfoLabel.leadingAnchor
                                                              constant:-12],
        [_titleLabel.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor constant:2],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_artCard.trailingAnchor
                                                  constant:kCellHeaderGapLandscape],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_fileInfoLabel.leadingAnchor
                                                             constant:-12],
        _fileInfoCapTopLandscape,
        [_fileInfoLabel.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],

        [_fxPadView.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [_fxPadView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                                constant:-kCellBottomInsetLandscape],

        // The pill hugs the route view, which stays the whole tap surface: a
        // lone glyph at its 44pt minimum makes the pill the pad's circle.
        [_actionBar.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [_actionBar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                                constant:-kCellBottomInsetLandscape],
        [_actionBar.leadingAnchor constraintGreaterThanOrEqualToAnchor:_transportView.trailingAnchor
                                                              constant:kCellActionBarGap],
        [_routeView.leadingAnchor constraintEqualToAnchor:_actionBar.leadingAnchor
                                                 constant:kCellRouteContentInsetLandscape],
        [_routeView.trailingAnchor constraintEqualToAnchor:_actionBar.trailingAnchor
                                                  constant:-kCellRouteContentInsetLandscape],
        [_routeView.widthAnchor constraintLessThanOrEqualToConstant:kCellRouteMaxWidthLandscape],

        [_transportView.centerYAnchor constraintEqualToAnchor:_actionBar.centerYAnchor],
        [_transportView.leadingAnchor constraintGreaterThanOrEqualToAnchor:_fxPadView.trailingAnchor
                                                                  constant:kCellActionBarGap],

        [middle.topAnchor constraintEqualToAnchor:_artCard.bottomAnchor],
        [middle.bottomAnchor constraintEqualToAnchor:_transportView.topAnchor],
        [timeBand.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor
                                           constant:-kCellTimeWaveformOverlap],
        [timeBand.bottomAnchor constraintEqualToAnchor:_actionBar.topAnchor],
        [_waveformView.centerYAnchor constraintEqualToAnchor:middle.centerYAnchor
                                                    constant:-kCellTimeRowShiftLandscape],
        [_waveformView.heightAnchor constraintEqualToConstant:kCellWaveformHeightLandscape],
        [_elapsedLabel.centerYAnchor constraintEqualToAnchor:timeBand.centerYAnchor],
        [_elapsedLabel.centerXAnchor constraintEqualToAnchor:_fxPadView.centerXAnchor],
    ];
}

- (void)applyLayoutForBounds:(CGRect)bounds {
    BOOL landscape = bounds.size.width > bounds.size.height;
    if (_layoutApplied && landscape == _landscapeActive) {
        return;
    }
    // Signposts the swap, not the test that usually declines it.
    VibeSignpostBegin(cell_constraints);
    _layoutApplied = YES;
    _landscapeActive = landscape;
    if (landscape) {
        [NSLayoutConstraint deactivateConstraints:_portraitConstraints];
        [NSLayoutConstraint activateConstraints:_landscapeConstraints];
    }
    else {
        [NSLayoutConstraint deactivateConstraints:_landscapeConstraints];
        [NSLayoutConstraint activateConstraints:_portraitConstraints];
    }
    [self applyActionBarSplit];
    [self applyRouteTimeAlignment];

    NSTextAlignment alignment = landscape ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    _titleLabel.textAlignment = alignment;
    _artistLabel.textAlignment = alignment;
    _fileInfoLabel.textAlignment = landscape ? NSTextAlignmentRight : NSTextAlignmentCenter;
    CGFloat fontScale = landscape ? kCellHeaderFontScaleLandscape : 1;
    _titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2]
            scaledFontForFont:[UIFont boldSystemFontOfSize:kCellTitlePointSize * fontScale]];
    _artistLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCallout]
            scaledFontForFont:[UIFont systemFontOfSize:kCellArtistPointSize * fontScale]];
    _titleLabel.numberOfLines = landscape ? 1 : 2;
    _fileInfoLabel.numberOfLines = landscape ? 2 : 1;
    [self applyFileInfoText];
    VibeSignpostEnd(cell_constraints);
}

// The split is portrait's: landscape's pills sit apart. A pad hidden mid-hold
// releases.
- (void)applyActionBarSplit {
    if (!_layoutApplied) {
        return; // the first applyLayoutForBounds: activates a set, then this
    }
    _actionBarLeadingAfterPad.active = _fxPadShown && !_landscapeActive;
    BOOL padHidden = !_fxPadShown;
    if (padHidden != _fxPadView.hidden) {
        if (padHidden) {
            [_fxPadView cancelInteraction];
        }
        _fxPadView.hidden = padHidden;
    }
}

- (void)applyRouteTimeAlignment {
    BOOL centered = _landscapeActive && !_routeView.showsDeviceName;
    BOOL trailing = _landscapeActive && _routeView.showsDeviceName;
    if (_remainingCenteredOnRoute.active == centered && _remainingTrailingOnRoute.active == trailing) {
        return;
    }
    // Off before on: both at once over-constrain the control.
    _remainingCenteredOnRoute.active = NO;
    _remainingTrailingOnRoute.active = NO;
    _remainingCenteredOnRoute.active = centered;
    _remainingTrailingOnRoute.active = trailing;
    // The control is wider than a short time, so the text must follow.
    _remainingTimeControl.textAlignment = centered ? NSTextAlignmentCenter : NSTextAlignmentRight;
}

- (void)setOutputRouteKind:(VibeOutputRouteKind)kind deviceName:(NSString *)name {
    [_routeView setRouteKind:kind deviceName:name];
    [self applyRouteTimeAlignment];
}

- (void)setShuffleRepeatShown:(BOOL)shown {
    if (_shuffleRepeatShown == shown) {
        return;
    }
    _shuffleRepeatShown = shown;
    _shuffleButton.hidden = !shown;
    _repeatButton.hidden = !shown;
    _shuffleWidth.constant = shown ? kTransportFlankButtonSide : 0;
    _repeatWidth.constant = shown ? kTransportFlankButtonSide : 0;
    _outerGapWanted.constant = shown ? kTransportButtonGap : 0;
    _outerGapMin.constant = shown ? kTransportFlankMinGap : 0;
    [self setNeedsLayout];
}

- (void)setFXPadShown:(BOOL)shown {
    if (_fxPadShown == shown) {
        return;
    }
    _fxPadShown = shown;
    [self applyActionBarSplit];
    [self setNeedsLayout];
}

// On the fonts the labels draw at now; Dynamic Type rescales them. The band is
// the worst case. The codec line alone can leave it, line and gap, when the
// setting is off or there is no readout yet — one setting for every page, so
// the waveform's y still agrees across the pager.
- (void)updateHeaderMetrics {
    UIFont *artistFont = _artistLabel.font;
    UIFont *infoFont = _fileInfoLabel.font;
    // Landscape's one metric; the rest are portrait's band.
    CGFloat capTop = (artistFont.ascender - artistFont.capHeight)
            - (infoFont.ascender - infoFont.capHeight);
    if (_fileInfoCapTopLandscape.constant != capTop) {
        _fileInfoCapTopLandscape.constant = capTop;
    }
    CGFloat artist = ceil(artistFont.lineHeight);
    BOOL showFileInfo = !_fileInfoLabel.hidden;
    CGFloat fileInfo = showFileInfo ? ceil(infoFont.lineHeight) : 0;
    CGFloat fileInfoGap = showFileInfo ? kCellLabelGap : 0;
    CGFloat band = ceil(_titleLabel.font.lineHeight * 2) + kCellLabelGap + artist
            + fileInfoGap + fileInfo + 2 * kCellLabelBandPadding;
    if (_labelBandHeight.constant == band && _artistHeight.constant == artist
            && _fileInfoHeight.constant == fileInfo && _fileInfoTop.constant == fileInfoGap) {
        return;
    }
    _labelBandHeight.constant = band;
    _artistHeight.constant = artist;
    _fileInfoHeight.constant = fileInfo;
    _fileInfoTop.constant = fileInfoGap;
}

- (void)layoutSubviews {
    VibeSignpostBegin(cell_layout);
    [self applyLayoutForBounds:self.bounds];
    [self updateHeaderMetrics];
    [super layoutSubviews];
    // The default 1 draws the cached glyphs soft.
    CGFloat scale = self.traitCollection.displayScale;
    _previousButton.layer.rasterizationScale = scale;
    _playPauseButton.layer.rasterizationScale = scale;
    _nextButton.layer.rasterizationScale = scale;
    VibeSignpostEnd(cell_layout);
}

- (UILabel *)makeTimeLabel {
    UILabel *label = [[UILabel alloc] init];
    VibeConfigureTimeLabel(label);
    return label;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // TRAP: a page recycled under a held pad — a track ending mid-hold scrolls
    // the outgoing page away — must release, or the effects stay engaged and
    // the pager stays locked (the scrubber's release trap, Player/AGENTS.md).
    [_fxPadView cancelInteraction];
    [_waveformView prepareForWaveformLoad];
    _elapsedLabel.text = STR_LABEL_TIME_UNKNOWN;
    _remainingTimeControl.text = STR_LABEL_TIME_UNKNOWN;
    [self setGlyphPlaying:NO];
    [self setNextEnabled:YES];
}

- (void)setGlyphPlaying:(BOOL)playing {
    [self setGlyph:(playing ? @"pause.fill" : @"play.fill")
          onButton:_playPauseButton
         pointSize:kCellGlyphPointSize];
    _playPauseButton.accessibilityLabel = playing ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;
}

// TRAP: a system button dims its own template image when disabled, so an alpha
// on top compounds. setGlyph:onButton:pointSize: installs a pre-tinted
// AlwaysOriginal disabled image carrying the alpha.
- (void)setNextEnabled:(BOOL)enabled {
    _nextButton.enabled = enabled;
    _nextButton.accessibilityTraits = enabled
            ? UIAccessibilityTraitButton
            : (UIAccessibilityTraitButton | UIAccessibilityTraitNotEnabled);
}

- (void)setShuffleEnabled:(BOOL)shuffleEnabled repeatMode:(VibeRepeatMode)repeatMode {
    [self setFlankGlyph:@"shuffle" active:shuffleEnabled onButton:_shuffleButton];
    [self setFlankGlyph:VibeRepeatModeSymbolName(repeatMode) active:repeatMode != VibeRepeatModeOff
               onButton:_repeatButton];
    _repeatButton.accessibilityLabel = VibeRepeatModeTitle(repeatMode);
}

// Off is drawn dimmed, as the disabled look is.
- (void)setFlankGlyph:(NSString *)symbol active:(BOOL)active onButton:(UIButton *)button {
    UIImage *glyph = TransportGlyph(symbol, kCellFlankGlyphPointSize);
    [button setImage:(active ? glyph : DimmedGlyph(glyph)) forState:UIControlStateNormal];
    button.accessibilityTraits = active
            ? (UIAccessibilityTraitButton | UIAccessibilityTraitSelected)
            : UIAccessibilityTraitButton;
}

// The codec line and the tempo line: the mac's two lines in landscape, one
// joined line in portrait, whose band reserves a single line for them.
- (void)applyFileInfoText {
    BOOL stacked = _landscapeActive && _fileInfo.length > 0 && _tempoInfo.length > 0;
    NSString *line = stacked
            ? [NSString stringWithFormat:@"%@\n%@", _fileInfo, _tempoInfo]
            : [[Formatters sharedInstance] infoLineFromFields:@[_fileInfo ?: @"", _tempoInfo ?: @""]];
    _fileInfoLabel.text = line;
    // Hidden, not blank: the band reserves a visible label's line.
    BOOL hideFileInfo = line.length == 0;
    if (hideFileInfo != _fileInfoLabel.hidden) {
        _fileInfoLabel.hidden = hideFileInfo;
        [self setNeedsLayout];
    }
}

- (void)configureWithTitle:(NSString *)title
                titleColor:(UIColor *)titleColor
                    artist:(NSString *)artist
               artistColor:(UIColor *)artistColor
                  fileInfo:(nullable NSString *)fileInfo
                 tempoInfo:(nullable NSString *)tempoInfo
                       art:(UIImage *)art {
    _titleLabel.text = title;
    _titleLabel.textColor = titleColor;
    _artistLabel.text = artist;
    _artistLabel.textColor = artistColor;
    _fileInfo = [fileInfo copy];
    _tempoInfo = [tempoInfo copy];
    [self applyFileInfoText];
    _artCardView.image = art;
    // album_art's color rides the art install, so it cannot belong to another
    // track however the delivery raced.
    _waveformView.artworkThemeColor = art.vibeDominantColor;
    UIImage *backdrop = [art vibeBlurredBackdrop];
    _backdropView.image = backdrop;
    // Opaque, so the render server skips everything behind the page; the bake
    // has no alpha and aspect-fill covers the bounds. Only with an image: an
    // opaque view with no contents draws undefined pixels.
    _backdropView.opaque = (backdrop != nil);
}

@end
