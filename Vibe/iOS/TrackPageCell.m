//
//  TrackPageCell.m
//  Vibe (iOS)
//

#import "TrackPageCell.h"
#import "UIImage+Blur.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"

// The waveform strip, per orientation.
static const CGFloat kCellWaveformHeight = 180;
static const CGFloat kCellWaveformHeightLandscape = 120;

// What both layouts leave below themselves. It used to be the glass bottom
// bar's slice of the safe area; the card has no bar now — the playlist and
// the search field are the shell's — so it is an ordinary bottom margin.
static const CGFloat kCellBottomMargin = 16;

// Portrait is four bands, and only one of them moves:
//
//   1. a fixed strip under the safe top, holding the grabber pill the card's
//      own chrome draws (kCellTopBandHeight),
//   2. the ART band — everything left over, so it is the one that grows with
//      the screen; the card sits centered in it at kCellArtBandFill, leaving
//      the rest as padding all round,
//   3. the LABEL band, fixed because the header labels are given exact
//      line-count heights,
//   4. the waveform, time row and transport row, one chain off the SAFE
//      BOTTOM — which is what puts the waveform at the same y on every page.
static const CGFloat kCellTopBandHeight = 36;       // safe top → art band
static const CGFloat kCellArtBandFill = 0.8;        // art : its band — the rest is padding
static const CGFloat kCellLabelGap = 6;             // one gap for both label seams
static const CGFloat kCellLabelBandPadding = 10;    // label band's own top and bottom inset
static const CGFloat kCellWaveformTransportGap = 32;  // waveform ↔ transport row, the time row between them

// The scrubber reserves headroom above and below its envelope, so the time row
// is pulled UP into the bottom of the view: the edge the eye measures against
// is the drawn waveform, not the view's frame.
static const CGFloat kCellTimeWaveformOverlap = 12;
static const CGFloat kArtCornerRadius = 12;
static const CGFloat kCellGlyphPointSize = 41;      // play/pause
static const CGFloat kCellSideGlyphPointSize = 28;  // previous/next
static const CGFloat kTransportButtonSide = 66;     // the tap target, not the glyph
static const CGFloat kTransportButtonGap = 20;
static const CGFloat kTransportDisabledAlpha = 0.5;

// Landscape: the mac main window's arrangement — a small square art card
// top-left, artist over title beside it with the codec line in the top-right
// corner, and the full-width waveform + time row bottom-anchored.
static const CGFloat kCellHeaderGapLandscape = 16;   // art trailing → header text leading
static const CGFloat kCellArtHeightFractionLandscape = 1.0 / 3.0;
// The waveform is a third shorter here and the transport rides the time row's
// centerline, so portrait's pull-up would put a glyph over the envelope.
static const CGFloat kCellTimeWaveformGapLandscape = 3;

// The art card restates its shadow path from ITS OWN layout pass.
//
// TRAP: doing it in the cell's layoutSubviews is not enough. The constraints
// that size the card belong to the contentView, so a later pass — the header
// metrics landing, Dynamic Type, anything that moves the label band — resizes
// the card without the cell's layoutSubviews running again, and the shadow
// stays drawn at the previous, larger size. On screen that is a wide dark halo
// around the art that vanishes the moment a swipe recycles the cell.
@interface VibeArtCardView : UIView
@end

@implementation VibeTimeLabel
@end

@implementation VibeTransportRowView
@end

@implementation VibeArtCardView
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
        _artCard = [[VibeArtCardView alloc] init];
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

        // Title over artist over the codec line, centered under the art,
        // Apple Music style. All Dynamic Type: the fonts scale with the
        // user's text size, and the vertical chain squeezes the art card —
        // never the text — when they grow. All three shrink to fit their
        // width rather than truncate: the header block's height is fixed, so
        // a long title has nowhere to grow into.
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2]
                scaledFontForFont:[UIFont boldSystemFontOfSize:28]];
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
        _artistLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
                scaledFontForFont:[UIFont boldSystemFontOfSize:20]];
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
        _remainingLabel = (VibeTimeLabel *)[self makeTimeLabelOfClass:VibeTimeLabel.class];
        _remainingLabel.textAlignment = NSTextAlignmentRight;
        // The tap target is the label's own bounds, which at the default text
        // size is a short strip — but it sits in the card's bottom corner with
        // nothing else near it, and widening it would eat into the screen tap.
        _remainingLabel.userInteractionEnabled = YES;
        _remainingLabelTap = [[UITapGestureRecognizer alloc] init];
        [_remainingLabel addGestureRecognizer:_remainingLabelTap];
        [content addSubview:_remainingLabel];

        // The transport: previous, play/pause, next, in one row the controller
        // fades as a unit. It is a plain container rather than a stack view so
        // the buttons keep their oversized tap targets while the glyphs inside
        // stay small — the mini player's rule, and Apple Music's.
        _transportView = [[VibeTransportRowView alloc] init];
        _transportView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_transportView];

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
            [_previousButton.leadingAnchor constraintEqualToAnchor:_transportView.leadingAnchor],
            [_playPauseButton.leadingAnchor constraintEqualToAnchor:_previousButton.trailingAnchor
                                                           constant:kTransportButtonGap],
            [_nextButton.leadingAnchor constraintEqualToAnchor:_playPauseButton.trailingAnchor
                                                      constant:kTransportButtonGap],
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

    // As big as its band allows, leaving the padding all round. The two
    // required caps bound it on each axis; this makes it take what it can,
    // and it is the one that gives at oversized accessibility text.
    NSLayoutConstraint *artFill =
            [_artCard.heightAnchor constraintEqualToAnchor:artBand.heightAnchor
                                                multiplier:kCellArtBandFill];
    artFill.priority = UILayoutPriorityDefaultHigh;

    return @[
        [artBand.topAnchor constraintEqualToAnchor:safe.topAnchor
                                          constant:kCellTopBandHeight],
        [artBand.bottomAnchor constraintEqualToAnchor:labelBand.topAnchor],
        [_artCard.centerYAnchor constraintEqualToAnchor:artBand.centerYAnchor],
        [_artCard.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_artCard.heightAnchor constraintLessThanOrEqualToAnchor:artBand.heightAnchor
                                                      multiplier:kCellArtBandFill],
        [_artCard.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor
                                                    multiplier:kCellArtBandFill],
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
        [_fileInfoLabel.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor
                                                 constant:kCellLabelGap],
        [_fileInfoLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_fileInfoLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:20],
        [_fileInfoLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],

        [_waveformView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_waveformView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_waveformView.heightAnchor constraintEqualToConstant:kCellWaveformHeight],
        // The bottom chain, and the reason it is a chain: transport row and
        // waveform both hang off the SAFE BOTTOM, so the waveform sits at the
        // same y on every page. Anything above it — a two-line title, a
        // missing artist — moves the art, never this. The time row hangs off
        // the waveform rather than sitting between the two, so tightening it
        // against the waveform cannot push the waveform down.
        [_transportView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                    constant:-kCellBottomMargin],
        [_waveformView.bottomAnchor constraintEqualToAnchor:_transportView.topAnchor
                                                   constant:-kCellWaveformTransportGap],
        [_elapsedLabel.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor
                                                constant:-kCellTimeWaveformOverlap],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_elapsedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:content.centerXAnchor
                                                            constant:-6],
        [_remainingLabel.bottomAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor],
        [_remainingLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_remainingLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.centerXAnchor
                                                            constant:6],
    ];
}

// The mac main window, transplanted: a small square art card top-left,
// artist over title left-aligned beside it, the codec line right-aligned in
// the top corner, the waveform across the whole width with the time row
// beneath it, clear of the glass bar.
- (NSArray<NSLayoutConstraint *> *)buildLandscapeConstraints {
    UIView *content = self.contentView;
    UILayoutGuide *safe = content.safeAreaLayoutGuide;

    return @[
        [_artCard.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_artCard.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
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
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor
                                                             constant:-16],
        [_fileInfoLabel.topAnchor constraintEqualToAnchor:_artistLabel.topAnchor],
        [_fileInfoLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

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
        [_remainingLabel.bottomAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor],
        [_remainingLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_remainingLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.centerXAnchor
                                                            constant:6],

        // Landscape has the height for no more than one row down here, so the
        // transport rides the time row's centerline, between the two times —
        // there is width to spare for it where portrait has none.
        [_transportView.centerYAnchor constraintEqualToAnchor:_elapsedLabel.centerYAnchor],
    ];
}

// Swaps the constraint sets and the styling that rides with them: portrait
// centers text under the rounded floating card, landscape left-aligns the
// header beside the flush square art, mac-style.
- (void)applyLayoutForBounds:(CGRect)bounds {
    BOOL landscape = bounds.size.width > bounds.size.height;
    if (_layoutApplied && landscape == _landscapeActive) {
        return;
    }
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
    NSTextAlignment alignment = landscape ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    _titleLabel.textAlignment = alignment;
    _artistLabel.textAlignment = alignment;
    _fileInfoLabel.textAlignment = landscape ? NSTextAlignmentRight : NSTextAlignmentCenter;
    // The mac title is one line; the portrait card gives it two. Both shrink
    // to fit rather than truncate.
    _titleLabel.numberOfLines = landscape ? 1 : 2;
}

// The portrait label band's reserved height and its two single-line labels',
// restated on the fonts the labels are currently drawing at — Dynamic Type
// rescales them under us. The band is the worst case, a two-line title, so the
// art band above it never moves.
- (void)updateHeaderMetrics {
    CGFloat artist = ceil(_artistLabel.font.lineHeight);
    CGFloat fileInfo = ceil(_fileInfoLabel.font.lineHeight);
    CGFloat band = ceil(_titleLabel.font.lineHeight * 2) + kCellLabelGap + artist
            + kCellLabelGap + fileInfo + 2 * kCellLabelBandPadding;
    if (_labelBandHeight.constant == band && _artistHeight.constant == artist
            && _fileInfoHeight.constant == fileInfo) {
        return;
    }
    _labelBandHeight.constant = band;
    _artistHeight.constant = artist;
    _fileInfoHeight.constant = fileInfo;
}

- (void)layoutSubviews {
    [self applyLayoutForBounds:self.bounds];
    [self updateHeaderMetrics];
    [super layoutSubviews];
    // Left at the default 1 the cached glyphs would draw soft on every Retina
    // display.
    CGFloat scale = self.traitCollection.displayScale;
    _previousButton.layer.rasterizationScale = scale;
    _playPauseButton.layer.rasterizationScale = scale;
    _nextButton.layer.rasterizationScale = scale;
}

- (UILabel *)makeTimeLabel {
    return [self makeTimeLabelOfClass:UILabel.class];
}

// The right label is a VibeTimeLabel so the screen tap can decline it by class;
// the left one has no tap and stays a plain UILabel.
- (UILabel *)makeTimeLabelOfClass:(Class)labelClass {
    UILabel *label = [[labelClass alloc] init];
    // Monospaced digits so the ticking text does not shimmy, scaled with the
    // user's text size off the subheadline curve.
    label.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
            scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:16
                                                               weight:UIFontWeightRegular]];
    label.adjustsFontForContentSizeCategory = YES;
    // At accessibility sizes both times cannot fit full-size on one line;
    // each owns its half and shrinks to fit rather than fighting the other
    // (a required-constraint clash silently crushed one to zero width).
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.5;
    // Required, not the 750 default: the art card's full-width preference is
    // ALSO 750, and the tie resolved by crushing this label to zero height
    // at accessibility sizes. The card must always be the one that gives.
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisVertical];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = STR_LABEL_TIME_UNKNOWN;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

// A recycled cell must never show the previous track's waveform, times, or
// glyph state — the new page's load repopulates the first two, and the
// controller re-stamps the glyph's visibility when it configures the cell.
- (void)prepareForReuse {
    [super prepareForReuse];
    [_waveformView prepareForWaveformLoad];
    _elapsedLabel.text = STR_LABEL_TIME_UNKNOWN;
    _remainingLabel.text = STR_LABEL_TIME_UNKNOWN;
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
// Swallowing the tap is VibeTransportRowView's job, not this one's: a
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
                  fileInfo:(NSString *)fileInfo
                       art:(UIImage *)art {
    _titleLabel.text = title;
    _titleLabel.textColor = titleColor;
    _artistLabel.text = artist;
    _artistLabel.textColor = artistColor;
    _fileInfoLabel.text = fileInfo;
    // The card takes the artwork itself; the backdrop takes its baked blur,
    // which UIImage+Blur memoizes on the artwork, so a page reconfigured for
    // the same track pays nothing.
    _artCardView.image = art;
    _backdropView.image = [art vibeBlurredBackdrop];
}

@end
