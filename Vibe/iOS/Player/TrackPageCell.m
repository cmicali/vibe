//
//  TrackPageCell.m
//  Vibe (iOS)
//

#import "TrackPageCell.h"
#import "FXPadView.h"
#import "OutputRouteView.h"
#import "UIImage+Blur.h"
#import "UIImage+DominantColor.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"

static const CGFloat kCellWaveformHeight = 180;
static const CGFloat kCellWaveformHeightLandscape = 120;

// Landscape only; portrait's action bar sits on the safe bottom.
static const CGFloat kCellBottomMargin = 16;

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

// With audio effects on, the FX pad's circle and, a gap to its right, the
// route capsule over the rest of the width; off, the route capsule alone.
static const CGFloat kCellActionBarHeight = 56;
static const CGFloat kCellActionBarInset = 20;
static const CGFloat kCellActionBarGap = 12;
// The route control keeps this far inside the capsule's ends, where a long
// device name truncates.
static const CGFloat kCellActionBarContentInset = 16;
static const CGFloat kCellActionBarTransportGap = 16;
// The pad grows toward the safe edges and stops this short of them.
static const CGFloat kCellFXPadMargin = 16;
// A tint, not a live-blurring effect view: the backdrop never changes.
static const CGFloat kCellActionBarFillAlpha = 0.12;

// The scrubber reserves headroom around its envelope, and the eye measures
// from the drawn waveform, so the time row is pulled UP into the view.
static const CGFloat kCellTimeWaveformOverlap = 12;
static const CGFloat kArtCornerRadius = 12;
// Apple Music's rendered glyph sizes, in far larger tap targets.
static const CGFloat kCellGlyphPointSize = 34;
static const CGFloat kCellSideGlyphPointSize = 23;
static const CGFloat kTransportButtonSide = 66;
// Landscape's row sits between the two time labels, so it stays narrow.
static const CGFloat kTransportButtonGap = 41;
static const CGFloat kTransportButtonGapLandscape = 20;
static const CGFloat kTransportDisabledAlpha = 0.5;

static const CGFloat kCellHeaderGapLandscape = 16;
static const CGFloat kCellArtHeightFractionLandscape = 1.0 / 3.0;
// No pull-up: the transport rides the time row, and would sit on the envelope.
static const CGFloat kCellTimeWaveformGapLandscape = 3;
// Landscape's route view shares the codec line, so it is capped tighter.
static const CGFloat kCellRouteMaxWidth = 220;
static const CGFloat kCellRouteMaxWidthLandscape = 160;
static const CGFloat kCellRouteGlyphPointSize = 23;
static const CGFloat kCellRouteGlyphPointSizeLandscape = 15;
static const CGFloat kCellRouteGap = 10;
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

- (void)setText:(NSString *)text {
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

@implementation TrackPageTransportView
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

    // Active in both layouts, with different constants.
    NSLayoutConstraint *_playPauseGap;
    NSLayoutConstraint *_nextGap;
    NSLayoutConstraint *_routeMaxWidth;
    // The route capsule's leading edge when the FX pad is shown: a gap past
    // the pad's circle, required, outranking the full-width leading edge the
    // portrait set holds at a lower priority. Active only in portrait, where
    // that set is.
    NSLayoutConstraint *_actionBarLeadingAfterPad;
    BOOL               _fxPadShown;

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
        _titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2]
                scaledFontForFont:[UIFont boldSystemFontOfSize:22]];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.6;
        _titleLabel.numberOfLines = 2;
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisVertical];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_titleLabel];

        _artistLabel = [[UILabel alloc] init];
        _artistLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCallout]
                scaledFontForFont:[UIFont systemFontOfSize:16]];
        _artistLabel.adjustsFontForContentSizeCategory = YES;
        _artistLabel.adjustsFontSizeToFitWidth = YES;
        _artistLabel.minimumScaleFactor = 0.7;
        _artistLabel.textAlignment = NSTextAlignmentCenter;
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
        _fileInfoLabel.textAlignment = NSTextAlignmentCenter;
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

        _transportView = [[TrackPageTransportView alloc] init];
        _transportView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_transportView];

        // Behind the route control, not around it: landscape has no bar, so
        // each layout places the two independently.
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

        _previousButton = [self makeTransportButton];
        _previousButton.accessibilityLabel = STR_TRANSPORT_PREVIOUS;
        [self setGlyph:@"backward.end.fill" onButton:_previousButton
             pointSize:kCellSideGlyphPointSize];
        _playPauseButton = [self makeTransportButton];
        _nextButton = [self makeTransportButton];
        _nextButton.accessibilityLabel = STR_TRANSPORT_NEXT;
        [self setGlyph:@"forward.end.fill" onButton:_nextButton
             pointSize:kCellSideGlyphPointSize];
        [self setGlyphPlaying:NO];

        // Landscape: the artist (750) truncates before the codec line.
        [_fileInfoLabel setContentCompressionResistancePriority:760
                forAxis:UILayoutConstraintAxisHorizontal];

        _playPauseGap = [_playPauseButton.leadingAnchor
                constraintEqualToAnchor:_previousButton.trailingAnchor
                               constant:kTransportButtonGap];
        _nextGap = [_nextButton.leadingAnchor
                constraintEqualToAnchor:_playPauseButton.trailingAnchor
                               constant:kTransportButtonGap];
        _routeMaxWidth = [_routeView.widthAnchor
                constraintLessThanOrEqualToConstant:kCellRouteMaxWidth];

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
            _routeMaxWidth,
            // Clears the transport row in both layouts; check the frames if
            // either moves.
            [_routeView.heightAnchor constraintEqualToConstant:44],
            [_remainingTimeControl.widthAnchor constraintGreaterThanOrEqualToConstant:44],
            [_remainingTimeControl.heightAnchor constraintGreaterThanOrEqualToConstant:44],
            [_previousButton.leadingAnchor constraintEqualToAnchor:_transportView.leadingAnchor],
            _playPauseGap,
            _nextGap,
            [_nextButton.trailingAnchor constraintEqualToAnchor:_transportView.trailingAnchor],
        ]];

        _portraitConstraints = [self buildPortraitConstraints];
        _landscapeConstraints = [self buildLandscapeConstraints];
        _fxPadShown = YES;
    }
    return self;
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
        [button.widthAnchor constraintEqualToConstant:kTransportButtonSide],
    ]];
    return button;
}

- (void)setGlyph:(NSString *)symbol onButton:(UIButton *)button pointSize:(CGFloat)pointSize {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration
            configurationWithPointSize:pointSize
                                weight:UIImageSymbolWeightMedium];
    UIImage *glyph = [UIImage systemImageNamed:symbol withConfiguration:config];
    [button setImage:glyph forState:UIControlStateNormal];
    // The disabled look, drawn; see setNextEnabled:.
    [button setImage:[[glyph imageWithTintColor:
                    [UIColor.labelColor colorWithAlphaComponent:kTransportDisabledAlpha]
                                  renderingMode:UIImageRenderingModeAlwaysOriginal]
                     imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
            forState:UIControlStateDisabled];
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

        [_waveformView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_waveformView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_waveformView.heightAnchor constraintEqualToConstant:kCellWaveformHeight],
        // A chain off the SAFE BOTTOM, so the waveform sits at the same y on
        // every page. The time row hangs off the waveform, so tightening it
        // cannot push the waveform down.
        [_actionBar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_actionBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                                  constant:-kCellActionBarInset],
        [_actionBar.heightAnchor constraintEqualToConstant:kCellActionBarHeight],
        [_routeView.centerXAnchor constraintEqualToAnchor:_actionBar.centerXAnchor],
        [_routeView.centerYAnchor constraintEqualToAnchor:_actionBar.centerYAnchor],
        // Required, so the device name gives (it truncates) rather than the
        // capsule: the width cap alone is wider than a narrow capsule.
        [_routeView.leadingAnchor constraintGreaterThanOrEqualToAnchor:_actionBar.leadingAnchor
                                                              constant:kCellActionBarContentInset],
        [_routeView.trailingAnchor constraintLessThanOrEqualToAnchor:_actionBar.trailingAnchor
                                                            constant:-kCellActionBarContentInset],
        // The pad's circle, at the bar's leading end.
        [_fxPadView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_fxPadView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                 constant:kCellActionBarInset],
        [_fxPadView.widthAnchor constraintEqualToConstant:kCellActionBarHeight],
        [_fxPadView.heightAnchor constraintEqualToConstant:kCellActionBarHeight],

        [_transportView.bottomAnchor constraintEqualToAnchor:_actionBar.topAnchor
                                                    constant:-kCellActionBarTransportGap],
        [_waveformView.bottomAnchor constraintEqualToAnchor:_transportView.topAnchor
                                                   constant:-kCellWaveformTransportGap],
        [_elapsedLabel.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor
                                                constant:-kCellTimeWaveformOverlap],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_remainingTimeControl.bottomAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor],
        [_remainingTimeControl.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_elapsedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_remainingTimeControl.leadingAnchor
                                                               constant:-kCellTimeGap],
    ];
}

// The mac main window, transplanted.
- (NSArray<NSLayoutConstraint *> *)buildLandscapeConstraints {
    UIView *content = self.contentView;
    UILayoutGuide *safe = content.safeAreaLayoutGuide;

    return @[
        [_artCard.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_artCard.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [_artCard.heightAnchor constraintEqualToAnchor:content.heightAnchor
                                             multiplier:kCellArtHeightFractionLandscape],

        [_artistLabel.topAnchor constraintEqualToAnchor:_artCard.topAnchor constant:2],
        [_artistLabel.leadingAnchor constraintEqualToAnchor:_artCard.trailingAnchor
                                                   constant:kCellHeaderGapLandscape],
        [_artistLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_fileInfoLabel.leadingAnchor
                                                              constant:-12],
        [_titleLabel.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor constant:2],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_artCard.trailingAnchor
                                                  constant:kCellHeaderGapLandscape],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_routeView.leadingAnchor
                                                             constant:-kCellRouteGap],
        [_fileInfoLabel.topAnchor constraintEqualToAnchor:_artistLabel.topAnchor],
        [_fileInfoLabel.trailingAnchor constraintEqualToAnchor:_routeView.leadingAnchor
                                                      constant:-kCellRouteGap],

        // The transport holds the bottom row, so the route view takes the
        // top-trailing corner.
        [_routeView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_routeView.centerYAnchor constraintEqualToAnchor:_fileInfoLabel.centerYAnchor],

        [_waveformView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_waveformView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_waveformView.heightAnchor constraintEqualToConstant:kCellWaveformHeightLandscape],
        [_waveformView.bottomAnchor constraintEqualToAnchor:_elapsedLabel.topAnchor
                                                   constant:-kCellTimeWaveformGapLandscape],
        [_elapsedLabel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                   constant:-(kCellBottomMargin + 12)],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_elapsedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:content.centerXAnchor
                                                            constant:-6],
        [_remainingTimeControl.bottomAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor],
        [_remainingTimeControl.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_remainingTimeControl.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.centerXAnchor
                                                                 constant:6],

        // One row of height here, so the transport rides the time row.
        [_transportView.centerYAnchor constraintEqualToAnchor:_elapsedLabel.centerYAnchor],
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
    // The bar's placement is in the portrait set alone, so landscape hides it.
    _playPauseGap.constant = landscape ? kTransportButtonGapLandscape : kTransportButtonGap;
    _nextGap.constant = _playPauseGap.constant;
    _routeMaxWidth.constant = landscape ? kCellRouteMaxWidthLandscape : kCellRouteMaxWidth;
    _routeView.glyphPointSize = landscape ? kCellRouteGlyphPointSizeLandscape
                                          : kCellRouteGlyphPointSize;
    _actionBar.hidden = landscape;
    [self applyActionBarSplit];

    NSTextAlignment alignment = landscape ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    _titleLabel.textAlignment = alignment;
    _artistLabel.textAlignment = alignment;
    _fileInfoLabel.textAlignment = landscape ? NSTextAlignmentRight : NSTextAlignmentCenter;
    _titleLabel.numberOfLines = landscape ? 1 : 2;
    VibeSignpostEnd(cell_constraints);
}

// Only in portrait: landscape has no bar. A pad hidden mid-hold releases.
- (void)applyActionBarSplit {
    if (!_layoutApplied) {
        return; // the first applyLayoutForBounds: activates a set, then this
    }
    BOOL split = _fxPadShown && !_landscapeActive;
    _actionBarLeadingAfterPad.active = split;
    BOOL padHidden = !split;
    if (padHidden != _fxPadView.hidden) {
        if (padHidden) {
            [_fxPadView cancelInteraction];
        }
        _fxPadView.hidden = padHidden;
    }
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
    CGFloat artist = ceil(_artistLabel.font.lineHeight);
    BOOL showFileInfo = !_fileInfoLabel.hidden;
    CGFloat fileInfo = showFileInfo ? ceil(_fileInfoLabel.font.lineHeight) : 0;
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
    // The room the pad may grow into from its circle's corner: to the safe
    // trailing edge and up to the safe top, a margin short.
    UIView *content = self.contentView;
    CGRect safe = UIEdgeInsetsInsetRect(content.bounds, content.safeAreaInsets);
    CGRect pad = _fxPadView.frame;
    _fxPadView.padExtent = CGSizeMake(CGRectGetMaxX(safe) - kCellFXPadMargin - CGRectGetMinX(pad),
                                      CGRectGetMaxY(pad) - CGRectGetMinY(safe) - kCellFXPadMargin);
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
    // the pager stays locked (the scrubber's release trap, Player/CLAUDE.md).
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
// AlwaysOriginal disabled image carrying the alpha. Swallowing the tap is
// TrackPageTransportView's job.
- (void)setNextEnabled:(BOOL)enabled {
    _nextButton.enabled = enabled;
    _nextButton.accessibilityTraits = enabled
            ? UIAccessibilityTraitButton
            : (UIAccessibilityTraitButton | UIAccessibilityTraitNotEnabled);
}

- (void)configureWithTitle:(NSString *)title
                titleColor:(UIColor *)titleColor
                    artist:(NSString *)artist
               artistColor:(UIColor *)artistColor
                  fileInfo:(nullable NSString *)fileInfo
                       art:(UIImage *)art {
    _titleLabel.text = title;
    _titleLabel.textColor = titleColor;
    _artistLabel.text = artist;
    _artistLabel.textColor = artistColor;
    _fileInfoLabel.text = fileInfo;
    // Hidden, not blank: the band reserves a visible label's line.
    BOOL hideFileInfo = fileInfo.length == 0;
    if (hideFileInfo != _fileInfoLabel.hidden) {
        _fileInfoLabel.hidden = hideFileInfo;
        [self setNeedsLayout];
    }
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
