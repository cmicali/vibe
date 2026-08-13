//
//  TrackPageCell.m
//  Vibe (iOS)
//

#import "TrackPageCell.h"
#import "TrackPageGeometry.h"
#import "VibeStrings.h"
#import "WaveformScrubberView.h"

// Portrait: two stacked boxes — art + header labels, then waveform + time
// labels — separated by kCellBoxGap and centered as one unit in the area
// between the safe top and the overlay's glass bar. The waveform heights and
// bar clearance live in TrackPageGeometry.h, shared with the chrome that
// mirrors them.
static const CGFloat kCellBoxGap = 32;              // padding between the two boxes
static const CGFloat kCellArtTopPadding = 16;       // pushes art + labels down inside the group; taken back out of kCellBoxGap so the waveform box stays put
static const CGFloat kCellTimeWaveformGap = 3;
static const CGFloat kArtCornerRadius = 12;
static const CGFloat kCellGlyphPointSize = 41;

// Landscape: the mac main window's arrangement — a small square art card
// top-left, artist over title beside it with the codec line in the top-right
// corner, and the full-width waveform + time row bottom-anchored above the
// glass bar.
static const CGFloat kCellHeaderGapLandscape = 16;   // art trailing → header text leading
static const CGFloat kCellArtHeightFractionLandscape = 1.0 / 3.0;

@implementation TrackPageCell {
    UIImageView        *_artView;
    UIVisualEffectView *_blurView;
    UIView             *_artCard;         // shadow host; the image view clips
    UIImageView        *_artCardView;
    UILabel            *_artistLabel;
    UILabel            *_titleLabel;
    UILabel            *_fileInfoLabel;

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

        _artView = [[UIImageView alloc] init];
        _artView.contentMode = UIViewContentModeScaleAspectFill;
        _artView.clipsToBounds = YES;
        _artView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_artView];

        _blurView = [[UIVisualEffectView alloc] initWithEffect:
                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
        _blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_blurView];

        // The Apple Music now-playing card: rounded art on a large soft
        // shadow. The shadow lives on the container (masksToBounds off), the
        // corner clip on the image view inside.
        _artCard = [[UIView alloc] init];
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
        // never the text — when they grow.
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleTitle2]
                scaledFontForFont:[UIFont boldSystemFontOfSize:31]];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.numberOfLines = 2;
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisVertical];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_titleLabel];

        _artistLabel = [[UILabel alloc] init];
        _artistLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline]
                scaledFontForFont:[UIFont boldSystemFontOfSize:22]];
        _artistLabel.adjustsFontForContentSizeCategory = YES;
        _artistLabel.textAlignment = NSTextAlignmentCenter;
        [_artistLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                      forAxis:UILayoutConstraintAxisVertical];
        _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_artistLabel];

        _fileInfoLabel = [[UILabel alloc] init];
        _fileInfoLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
                scaledFontForFont:[UIFont systemFontOfSize:16]];
        _fileInfoLabel.adjustsFontForContentSizeCategory = YES;
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
        _remainingLabel = [self makeTimeLabel];
        _remainingLabel.textAlignment = NSTextAlignmentRight;
        [content addSubview:_remainingLabel];

        // The paused-state play glyph, centered between the time labels. The
        // owning controller wires the action and drives its visibility; the
        // shadow keeps it legible on arbitrary art.
        _playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _playPauseButton.tintColor = [UIColor labelColor];
        _playPauseButton.layer.shadowColor = UIColor.blackColor.CGColor;
        _playPauseButton.layer.shadowOpacity = 0.5;
        _playPauseButton.layer.shadowRadius = 8;
        _playPauseButton.layer.shadowOffset = CGSizeMake(0, 2);
        _playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:_playPauseButton];
        [self setGlyphPlaying:NO];

        // The codec line must survive beside the artist line in landscape;
        // the artist is the one that truncates (its default 750 loses to
        // this), while the required edge bounds still let the codec line
        // itself truncate rather than overflow.
        [_fileInfoLabel setContentCompressionResistancePriority:760
                forAxis:UILayoutConstraintAxisHorizontal];

        [NSLayoutConstraint activateConstraints:@[
            [_artView.topAnchor constraintEqualToAnchor:content.topAnchor],
            [_artView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [_artView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_artView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [_blurView.topAnchor constraintEqualToAnchor:content.topAnchor],
            [_blurView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [_blurView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [_blurView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

            [_artCardView.topAnchor constraintEqualToAnchor:_artCard.topAnchor],
            [_artCardView.bottomAnchor constraintEqualToAnchor:_artCard.bottomAnchor],
            [_artCardView.leadingAnchor constraintEqualToAnchor:_artCard.leadingAnchor],
            [_artCardView.trailingAnchor constraintEqualToAnchor:_artCard.trailingAnchor],
            [_artCard.widthAnchor constraintEqualToAnchor:_artCard.heightAnchor],

            [_playPauseButton.centerYAnchor constraintEqualToAnchor:_elapsedLabel.centerYAnchor],
            [_playPauseButton.widthAnchor constraintGreaterThanOrEqualToConstant:66],
            [_playPauseButton.heightAnchor constraintGreaterThanOrEqualToConstant:66],
        ]];

        _portraitConstraints = [self buildPortraitConstraints];
        _landscapeConstraints = [self buildLandscapeConstraints];
    }
    return self;
}

- (NSArray<NSLayoutConstraint *> *)buildPortraitConstraints {
    UIView *content = self.contentView;
    UILayoutGuide *safe = content.safeAreaLayoutGuide;

    // The area between the safe top and the glass bar, and the two-box
    // stack centered in it. Centering yields (priority below required)
    // when accessibility text needs the room.
    UILayoutGuide *band = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:band];
    UILayoutGuide *group = [[UILayoutGuide alloc] init];
    [content addLayoutGuide:group];
    NSLayoutConstraint *groupCentered =
            [group.centerYAnchor constraintEqualToAnchor:band.centerYAnchor];
    groupCentered.priority = UILayoutPriorityDefaultHigh;

    // As wide as the margins allow — unless the label chain below needs
    // the room (large accessibility text), in which case the card is the
    // one that gives.
    NSLayoutConstraint *artFullWidth =
            [_artCard.widthAnchor constraintEqualToAnchor:safe.widthAnchor
                                               multiplier:0.85 constant:-41];
    artFullWidth.priority = UILayoutPriorityDefaultHigh;

    return @[
        // The whole stack — art box over waveform box — floats centered
        // between the safe top and the glass bar; the required edge
        // bounds still win at oversized accessibility text, shrinking
        // the square card — never the text.
        [band.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [band.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                          constant:-kTrackPageBottomBarClearance],
        [_artCard.topAnchor constraintEqualToAnchor:group.topAnchor
                                           constant:kCellArtTopPadding],
        [group.bottomAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor],
        groupCentered,
        [_artCard.topAnchor constraintGreaterThanOrEqualToAnchor:band.topAnchor constant:12],
        [_artCard.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_artCard.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-48],
        artFullWidth,

        [_titleLabel.topAnchor constraintEqualToAnchor:_artCard.bottomAnchor constant:20],
        [_titleLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:20],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],
        [_artistLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
        [_artistLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_artistLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:20],
        [_artistLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],
        [_fileInfoLabel.topAnchor constraintEqualToAnchor:_artistLabel.bottomAnchor constant:6],
        [_fileInfoLabel.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [_fileInfoLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:20],
        [_fileInfoLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-20],

        [_waveformView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_waveformView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_waveformView.heightAnchor constraintEqualToConstant:kTrackPageWaveformHeight],
        // The waveform box hangs off the art box across the configurable
        // gap, and the stack's required bottom bound keeps the time
        // labels clear of the glass bar at any text size.
        [_waveformView.topAnchor constraintEqualToAnchor:_fileInfoLabel.bottomAnchor
                                                constant:kCellBoxGap - kCellArtTopPadding],
        [_elapsedLabel.topAnchor constraintEqualToAnchor:_waveformView.bottomAnchor
                                                constant:kCellTimeWaveformGap],
        [_elapsedLabel.bottomAnchor constraintLessThanOrEqualToAnchor:band.bottomAnchor
                                                             constant:-12],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_elapsedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:content.centerXAnchor
                                                            constant:-6],
        [_remainingLabel.bottomAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor],
        [_remainingLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_remainingLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.centerXAnchor
                                                            constant:6],

        [_playPauseButton.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
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
        [_waveformView.heightAnchor constraintEqualToConstant:kTrackPageWaveformHeightLandscape],
        [_waveformView.bottomAnchor constraintEqualToAnchor:_elapsedLabel.topAnchor
                                                   constant:-kCellTimeWaveformGap],
        [_elapsedLabel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor
                                                   constant:-(kTrackPageBottomBarClearance + 12)],
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_elapsedLabel.trailingAnchor constraintLessThanOrEqualToAnchor:content.centerXAnchor
                                                            constant:-6],
        [_remainingLabel.bottomAnchor constraintEqualToAnchor:_elapsedLabel.bottomAnchor],
        [_remainingLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_remainingLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.centerXAnchor
                                                            constant:6],

        [_playPauseButton.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
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
    // The mac title is one shrink-to-fit line; the portrait card gives it two.
    _titleLabel.numberOfLines = landscape ? 1 : 2;
    _titleLabel.adjustsFontSizeToFitWidth = landscape;
    _titleLabel.minimumScaleFactor = landscape ? 0.6 : 1.0;
}

- (void)layoutSubviews {
    [self applyLayoutForBounds:self.bounds];
    [super layoutSubviews];
    _artCard.layer.shadowPath = [UIBezierPath
            bezierPathWithRoundedRect:_artCard.bounds
                         cornerRadius:kArtCornerRadius].CGPath;
}

- (UILabel *)makeTimeLabel {
    UILabel *label = [[UILabel alloc] init];
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
}

- (void)setGlyphPlaying:(BOOL)playing {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration
            configurationWithPointSize:kCellGlyphPointSize
                                weight:UIImageSymbolWeightMedium];
    [_playPauseButton setImage:[UIImage systemImageNamed:(playing ? @"pause.fill"
                                                                  : @"play.fill")
                                       withConfiguration:config]
                      forState:UIControlStateNormal];
    _playPauseButton.accessibilityLabel = playing ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;
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
    _artView.image = art;
    _artCardView.image = art;
}

@end
