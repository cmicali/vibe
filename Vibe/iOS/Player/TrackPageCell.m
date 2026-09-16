//
//  TrackPageCell.m
//  Vibe (iOS)
//

#import "TrackPageCell.h"
#import "OutputRouteView.h"
#import "UIImage+Blur.h"
#import "UIImage+DominantColor.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"

// The waveform strip, per orientation.
static const CGFloat kCellWaveformHeight = 180;
static const CGFloat kCellWaveformHeightLandscape = 120;

// Landscape's bottom margin. Portrait has the action bar down there instead,
// which sits flush against the safe area and defines its own edge.
static const CGFloat kCellBottomMargin = 16;

// Portrait is four bands, and only one of them moves:
//
//   1. a fixed strip under the safe top, holding the grabber pill the card's
//      own chrome draws (kCellTopBandHeight),
//   2. the ART band — everything left over, so it is the one that grows with
//      the screen; the card takes what its two caps allow and rides centered
//      in it, leaving the rest as padding all round,
//   3. the LABEL band, fixed because the header labels are given exact
//      line-count heights,
//   4. the waveform, time row, transport row and action bar, one chain off the
//      SAFE BOTTOM — which is what puts the waveform at the same y on every
//      page.
static const CGFloat kCellTopBandHeight = 36;       // safe top → art band
// The art's two caps. The WIDTH one is Apple Music's proportion — its card is
// 259pt across a 402pt screen — and on a screen tall enough it is the one that
// binds, which is what makes the art the same fraction of the width whatever
// the height. The BAND one takes over on a short screen, and leaves the rest of
// the band as padding above and below.
static const CGFloat kCellArtWidthFraction = 0.645;
static const CGFloat kCellArtBandFill = 0.94;
static const CGFloat kCellLabelGap = 6;             // one gap for both label seams
static const CGFloat kCellLabelBandPadding = 10;    // label band's own top and bottom inset
static const CGFloat kCellWaveformTransportGap = 28;  // waveform ↔ transport row, the time row between them

// The action bar: a capsule off the safe bottom, Pocket Casts' proportions —
// 56pt tall inside a 20pt side inset, its corner radius half its height. The
// route control is the only thing in it so far and rides its center.
static const CGFloat kCellActionBarHeight = 56;
static const CGFloat kCellActionBarInset = 20;
static const CGFloat kCellActionBarTransportGap = 16;
// White over the backdrop, which UIImage+Blur has already darkened, rather than
// a live-blurring effect view: the bar sits over a picture that never changes.
static const CGFloat kCellActionBarFillAlpha = 0.12;

// The scrubber reserves headroom above and below its envelope, so the time row
// is pulled UP into the bottom of the view: the edge the eye measures against
// is the drawn waveform, not the view's frame.
static const CGFloat kCellTimeWaveformOverlap = 12;
static const CGFloat kArtCornerRadius = 12;
// Apple Music's transport, measured off it and then asked of OUR glyphs: its
// play triangle is 35pt tall and its side pair 23pt, which is what these point
// sizes render backward.end.fill and play.fill at. The tap targets stay far
// larger than either.
static const CGFloat kCellGlyphPointSize = 34;      // play/pause
static const CGFloat kCellSideGlyphPointSize = 23;  // previous/next
static const CGFloat kTransportButtonSide = 66;     // the tap target, not the glyph
// Apple Music spaces its three glyph centers 107pt apart, which at this tap
// target is the portrait gap. Landscape keeps the narrow one: the row rides the
// time row's centerline there, between two labels bounded only against the
// middle of the screen, so a wider row would run into a long readout.
static const CGFloat kTransportButtonGap = 41;
static const CGFloat kTransportButtonGapLandscape = 20;
static const CGFloat kTransportDisabledAlpha = 0.5;

// Landscape: the mac main window's arrangement — a small square art card
// top-left, artist over title beside it with the codec line in the top-right
// corner, and the full-width waveform + time row bottom-anchored.
static const CGFloat kCellHeaderGapLandscape = 16;   // art trailing → header text leading
static const CGFloat kCellArtHeightFractionLandscape = 1.0 / 3.0;
// The waveform is a third shorter here and the transport rides the time row's
// centerline, so portrait's pull-up would put a glyph over the envelope.
static const CGFloat kCellTimeWaveformGapLandscape = 3;
// The route indicator's cap. Landscape puts it on the codec line, where a long
// device name has to stop short of the label beside it; portrait has the whole
// action bar to itself and can afford more. Its glyph is sized the same way:
// Pocket Casts' 23pt-tall icon in the bar, a codec-line-sized one in the corner.
static const CGFloat kCellRouteMaxWidth = 220;
static const CGFloat kCellRouteMaxWidthLandscape = 160;
static const CGFloat kCellRouteGlyphPointSize = 23;
static const CGFloat kCellRouteGlyphPointSizeLandscape = 15;
static const CGFloat kCellRouteGap = 10;
// Portrait's time row, which no longer has the route indicator in its middle.
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

// The art card restates its shadow path from ITS OWN layout pass.
//
// TRAP: doing it in the cell's layoutSubviews is not enough. The constraints
// that size the card belong to the contentView, so a later pass — the header
// metrics landing, Dynamic Type, anything that moves the label band — resizes
// the card without the cell's layoutSubviews running again, and the shadow
// stays drawn at the previous, larger size. On screen that is a wide dark halo
// around the art that vanishes the moment a swipe recycles the cell.
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
    // The page's backdrop: the artwork blurred and darkened ONCE, into an
    // ordinary image (UIImage+Blur), rather than an art view under a
    // full-screen UIVisualEffectView. The effect view's blur is a live
    // backdrop filter — recomputed every frame anything behind it moves, which
    // during a swipe is two full-screen blurs per frame — and it was recomputing
    // a picture that never changes.
    UIImageView        *_backdropView;
    UIView             *_artCard;         // shadow host; the image view clips
    UIImageView        *_artCardView;
    UILabel            *_artistLabel;
    UILabel            *_titleLabel;
    UILabel            *_fileInfoLabel;

    // Portrait only: the label band's height is nailed to what its labels can
    // ever need — a two-line title, one line each below — so a long title
    // cannot push the band's edges, and with them the art, up or down. The
    // labels themselves size to their content and ride centered in it. The
    // constants follow the scaled fonts; layoutSubviews restates them.
    NSLayoutConstraint *_labelBandHeight;
    NSLayoutConstraint *_artistHeight;
    NSLayoutConstraint *_fileInfoHeight;
    // Zeroed along with the height when there is no codec line to draw — the
    // gap alone would otherwise stay in the band as slack under the artist.
    NSLayoutConstraint *_fileInfoTop;

    // Constants the two layouts disagree about, on constraints that are active
    // in both. The transport's gap and the route indicator's width cap are the
    // whole list; everything else is in one set or the other.
    NSLayoutConstraint *_playPauseGap;
    NSLayoutConstraint *_nextGap;
    NSLayoutConstraint *_routeMaxWidth;

    // The orientation-specific constraint sets; layoutSubviews swaps them on
    // the cell's own aspect, so a rotation mid-reuse can never strand a cell
    // in the wrong arrangement.
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
        // The bake is a few dozen pixels across and is magnified to the whole
        // screen; trilinear keeps that magnification smooth instead of faceted.
        _backdropView.layer.magnificationFilter = kCAFilterTrilinear;
        _backdropView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_backdropView];

        // The Apple Music now-playing card: rounded art on a large soft
        // shadow. The shadow lives on the container (masksToBounds off), the
        // corner clip on the image view inside.
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
        // The decoded art's intrinsic size must not push the card around:
        // at the default 750 it ties with the card's width preference and
        // stretches the card past it. The card's constraints own the size.
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

        // Title over artist over the codec line, centered under the art. The
        // pair is Pocket Casts' — a 22pt bold title over a 16pt regular artist,
        // six points apart. All Dynamic Type: the fonts scale with the
        // user's text size, and the vertical chain squeezes the art card —
        // never the text — when they grow. All three shrink to fit their
        // width rather than truncate: the header block's height is fixed, so
        // a long title has nowhere to grow into.
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

        // The transport: previous, play/pause, next, in one row the controller
        // fades as a unit. It is a plain container rather than a stack view so
        // the buttons keep their oversized tap targets while the glyphs inside
        // stay small — the mini player's rule, and Apple Music's.
        _transportView = [[TrackPageTransportView alloc] init];
        _transportView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_transportView];

        // The action bar, and the route control that rides its center. The bar
        // is behind the control rather than around it because landscape has no
        // bar and the control still has to go somewhere — so each layout places
        // the two independently, and only portrait's set positions the bar.
        _actionBar = [[TrackPageActionBarView alloc] init];
        _actionBar.backgroundColor = [UIColor colorWithWhite:1
                                                       alpha:kCellActionBarFillAlpha];
        _actionBar.layer.cornerCurve = kCACornerCurveContinuous;
        _actionBar.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_actionBar];

        // Where the audio is going. It rides the page for the same reason the
        // transport does.
        _routeView = [[OutputRouteView alloc] initWithFrame:CGRectZero];
        _routeView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_routeView];

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

        // The codec line must survive beside the artist line in landscape;
        // the artist is the one that truncates (its default 750 loses to
        // this), while the required edge bounds still let the codec line
        // itself truncate rather than overflow.
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
            // The tap target, as everywhere else on this screen: a small glyph
            // in a finger-sized box. It clears the transport row above it in
            // both layouts — check the frames if either moves.
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
    }
    return self;
}

// One transport button: a large tap target around a small glyph, legible on
// arbitrary art.
//
// The shadow follows the glyph's alpha, so it cannot be given a shadowPath — a
// rect would put a block behind the triangle. Without one the layer re-renders
// offscreen every composited frame, so cache the result instead: it changes
// only when the glyph does, and the fade between states applies to the cached
// bitmap.
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
    // See setNextEnabled: — the disabled look is drawn here, at exactly the
    // alpha asked for, instead of being left to the button's own adjustment.
    [button setImage:[[glyph imageWithTintColor:
                    [UIColor.labelColor colorWithAlphaComponent:kTransportDisabledAlpha]
                                  renderingMode:UIImageRenderingModeAlwaysOriginal]
                     imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal]
            forState:UIControlStateDisabled];
}

- (NSArray<NSLayoutConstraint *> *)buildPortraitConstraints {
    UIView *content = self.contentView;
    UILayoutGuide *safe = content.safeAreaLayoutGuide;

    // The art band: what the fixed strip at the top and the label band below
    // leave over, so it is the band the screen's height lands in.
    UILayoutGuide *artBand = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:artBand];
    // The label band, fixed at what its labels can ever need, and the three
    // labels riding centered in it — so a one-line title sits in the middle of
    // the band rather than at the top of a two-line box with the slack showing
    // as a gap under it.
    UILayoutGuide *labelBand = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:labelBand];
    UILayoutGuide *labels = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:labels];

    // layoutSubviews keeps these on the scaled fonts. The two single-line
    // labels keep their line reserved so a track with no artist lays out like
    // one that has it.
    _labelBandHeight = [labelBand.heightAnchor constraintEqualToConstant:0];
    _artistHeight = [_artistLabel.heightAnchor constraintEqualToConstant:0];
    _fileInfoHeight = [_fileInfoLabel.heightAnchor constraintEqualToConstant:0];
    _fileInfoTop = [_fileInfoLabel.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor
                                                            constant:kCellLabelGap];

    // As big as its caps allow, leaving the padding all round. The two required
    // caps bound it on each axis; this makes it take what it can, and it is the
    // one that gives at oversized accessibility text.
    NSLayoutConstraint *artFill =
            [_artCard.widthAnchor constraintEqualToAnchor:safe.widthAnchor
                                               multiplier:kCellArtWidthFraction];
    artFill.priority = UILayoutPriorityDefaultHigh;

    // The strip under the safe top is what gives on a window too short for the
    // whole chain — the minimum iPad one, 320x480, is 20pt short of it. Below
    // required, so the art collapses to nothing instead of to a NEGATIVE size:
    // every other edge down to the safe bottom is an equality, and with none of
    // them breakable the solver would happily hand the card a negative height
    // and draw its shadow around nothing.
    NSLayoutConstraint *topBand = [artBand.topAnchor
            constraintEqualToAnchor:safe.topAnchor
                           constant:kCellTopBandHeight];
    topBand.priority = UILayoutPriorityRequired - 1;

    return @[
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
        // The bottom chain, and the reason it is a chain: the action bar hangs
        // off the SAFE BOTTOM and everything above it off the bar, so the
        // waveform sits at the same y on every page. Anything above it — a
        // two-line title, a missing artist — moves the art, never this. The
        // time row hangs off the waveform rather than sitting between waveform
        // and transport, so tightening it cannot push the waveform down.
        [_actionBar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [_actionBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                 constant:kCellActionBarInset],
        [_actionBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                                  constant:-kCellActionBarInset],
        [_actionBar.heightAnchor constraintEqualToConstant:kCellActionBarHeight],
        [_routeView.centerXAnchor constraintEqualToAnchor:_actionBar.centerXAnchor],
        [_routeView.centerYAnchor constraintEqualToAnchor:_actionBar.centerYAnchor],

        [_transportView.bottomAnchor constraintEqualToAnchor:_actionBar.topAnchor
                                                    constant:-kCellActionBarTransportGap],
        [_waveformView.bottomAnchor constraintEqualToAnchor:_transportView.topAnchor
                                                   constant:-kCellWaveformTransportGap],
        [_elapsedLabel.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor
                                                constant:-kCellTimeWaveformOverlap],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_remainingTimeControl.bottomAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor],
        [_remainingTimeControl.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        // Nothing sits between the two times now that the route indicator is in
        // the bar, so they are bounded against each other.
        [_elapsedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_remainingTimeControl.leadingAnchor
                                                               constant:-kCellTimeGap],
    ];
}

// The mac main window, transplanted: a small square art card top-left, artist
// over title left-aligned beside it, the codec line right-aligned beside the
// route indicator in the top corner, and the waveform across the whole width
// with the time row beneath it, clear of the glass bar.
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

        // The transport rides the time row's centerline down there, so the
        // indicator cannot have the middle of it: it takes the top-trailing
        // corner instead, on the codec line, which is bounded against it above.
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

        // Landscape has the height for no more than one row down here, so the
        // transport rides the time row's centerline, between the two times —
        // there is width to spare for it where portrait has none.
        [_transportView.centerYAnchor constraintEqualToAnchor:_elapsedLabel.centerYAnchor],
    ];
}

// Swaps the constraint sets, the constants the two share, and the styling that
// rides with them: portrait centers text under the rounded floating card and
// ends in the action bar, landscape left-aligns the header beside the flush
// square art, mac-style, with no bar and the route control in the corner.
- (void)applyLayoutForBounds:(CGRect)bounds {
    BOOL landscape = bounds.size.width > bounds.size.height;
    if (_layoutApplied && landscape == _landscapeActive) {
        return;
    }
    // Only the swap itself, not the test that usually declines it: this is
    // ~55 constraints deactivated and reactivated, and the question is what one
    // rotation costs, not how often layoutSubviews asks.
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
    // The constants on the constraints both sets share, and the bar landscape
    // has no room for — its own placement is in the portrait set alone, so
    // hiding it is all landscape has to do.
    _playPauseGap.constant = landscape ? kTransportButtonGapLandscape : kTransportButtonGap;
    _nextGap.constant = _playPauseGap.constant;
    _routeMaxWidth.constant = landscape ? kCellRouteMaxWidthLandscape : kCellRouteMaxWidth;
    _routeView.glyphPointSize = landscape ? kCellRouteGlyphPointSizeLandscape
                                          : kCellRouteGlyphPointSize;
    _actionBar.hidden = landscape;

    NSTextAlignment alignment = landscape ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    _titleLabel.textAlignment = alignment;
    _artistLabel.textAlignment = alignment;
    _fileInfoLabel.textAlignment = landscape ? NSTextAlignmentRight : NSTextAlignmentCenter;
    // The mac title is one line; the portrait card gives it two. Both shrink
    // to fit rather than truncate.
    _titleLabel.numberOfLines = landscape ? 1 : 2;
    VibeSignpostEnd(cell_constraints);
}

// The portrait label band's reserved height and its two single-line labels',
// restated on the fonts the labels are currently drawing at — Dynamic Type
// rescales them under us. The band is the worst case, a two-line title, so the
// art band above it never moves.
//
// The codec line is the one thing that can leave the band entirely, when the
// setting is off or a track has no readout yet: it gives up its line AND the
// gap above it, so the band tightens by the whole row rather than leaving its
// height behind as slack. Every page is drawing the same setting, so the
// waveform still sits at the same y across the pager.
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
    // Left at the default 1 the cached glyphs would draw soft on every Retina
    // display.
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

// A recycled cell must never show the previous track's waveform, times, or
// glyph state — the new page's load repopulates the first two, and the
// controller re-stamps the glyph's visibility when it configures the cell.
- (void)prepareForReuse {
    [super prepareForReuse];
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

// `enabled`, and the dimming spelled out rather than left to the button.
//
// TRAP: a system-type button dims its own template image for the disabled
// state, so an alpha on top compounds — the glyph measured 52/255 over the
// card's backdrop instead of the half it asks for. The disabled image is
// therefore installed pre-tinted and AlwaysOriginal, which opts out of the
// tinting the adjustment rides on, and carries the alpha itself.
//
// Swallowing the tap is TrackPageTransportView's job, not this one's: a
// disabled button is not handed back by hit-testing at all, so the row has to
// decline the touch on its behalf.
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
    // Hidden rather than blank: the band reserves this label's line, and an
    // empty one would hold it open. Nil is both "the setting is off" and "no
    // metadata yet", and neither has a row to draw.
    BOOL hideFileInfo = fileInfo.length == 0;
    if (hideFileInfo != _fileInfoLabel.hidden) {
        _fileInfoLabel.hidden = hideFileInfo;
        [self setNeedsLayout];
    }
    // The card takes the artwork itself; the backdrop takes its baked blur,
    // which UIImage+Blur memoizes on the artwork, so a page reconfigured for
    // the same track pays nothing.
    _artCardView.image = art;
    // The album_art waveform theme's color rides the art install, exactly as it
    // does on the mac: the color is derived from the image this page was just
    // handed, so it cannot belong to another track however the delivery raced.
    // Memoized on the image, and the setter no-ops when the color has not moved.
    _waveformView.artworkThemeColor = art.vibeDominantColor;
    UIImage *backdrop = [art vibeBlurredBackdrop];
    _backdropView.image = backdrop;
    // Opaque, so the render server can stop at this layer instead of drawing
    // everything a full-bleed page covers — the pager's own record-bg
    // backgroundView and the whole tab hierarchy behind the card. The bake
    // carries no alpha channel (UIImage+Blur renders AlphaNoneSkipFirst) and
    // aspect-fill always covers the bounds, so the claim is honest.
    //
    // Tied to the image actually arriving rather than set once at init: an
    // opaque view with no contents draws undefined pixels, not nothing.
    _backdropView.opaque = (backdrop != nil);
}

@end
