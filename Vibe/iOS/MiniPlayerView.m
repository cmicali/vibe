//
//  MiniPlayerView.m
//  Vibe (iOS)
//
//  See MiniPlayerView.h.
//

#import "MiniPlayerView.h"

#import "AudioTrack.h"
#import "VibeStrings.h"

// TRAP: the strip is 48pt and THAT IS NOT NEGOTIABLE. UITabAccessory frames
// its content view at a fixed system height — an intrinsicContentSize is
// ignored, and an explicit height constraint is ignored too, without even
// logging a conflict, because UIKit never asks Auto Layout to size it. So
// everything here is drawn to 48pt. A taller strip means giving up the
// accessory — and with it the Liquid Glass, the collapse-inline behavior and
// the automatic safe-area inset for the tab children — for a hand-rolled view
// above the tab bar.
//
// There is deliberately NO playhead bar. One fits in 48pt only by taking a
// slice off the top and pushing the artwork and labels down into what is left,
// which is what made the strip look cramped; Apple Music's mini player draws
// none either.
static const CGFloat kArtSide = 38;
// The tap target, which stays comfortably large; kGlyphPointSize is what the
// eye reads, and Apple Music's mini transport is a small glyph in a big
// target. Sizing the button instead is what made ours look like buttons.
static const CGFloat kControlSide = 44;
static const CGFloat kGlyphPointSize = 19;

@interface MiniPlayerView () <UIGestureRecognizerDelegate>
@end

@implementation MiniPlayerView {
    UIImageView *_artView;
    UILabel     *_titleLabel;
    UILabel     *_artistLabel;
    UIButton    *_expandButton;
    UIButton    *_playPauseButton;
    UIButton    *_nextButton;
    BOOL        _playing;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self build];
    }
    return self;
}

- (void)build {
    self.backgroundColor = UIColor.clearColor;

    _expandButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _expandButton.accessibilityLabel = STR_A11Y_MINIPLAYER_EXPAND;
    [_expandButton addTarget:self action:@selector(expandTapped)
            forControlEvents:UIControlEventTouchUpInside];
    _expandButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_expandButton];

    _artView = [[UIImageView alloc] init];
    _artView.contentMode = UIViewContentModeScaleAspectFill;
    _artView.clipsToBounds = YES;
    _artView.isAccessibilityElement = NO;
    _artView.layer.cornerRadius = 6;
    _artView.layer.cornerCurve = kCACornerCurveContinuous;
    _artView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_artView];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.isAccessibilityElement = NO;
    _titleLabel.maximumContentSizeCategory = UIContentSizeCategoryExtraExtraExtraLarge;
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _artistLabel = [[UILabel alloc] init];
    _artistLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _artistLabel.adjustsFontForContentSizeCategory = YES;
    _artistLabel.isAccessibilityElement = NO;
    _artistLabel.maximumContentSizeCategory = UIContentSizeCategoryExtraExtraExtraLarge;
    _artistLabel.textColor = UIColor.secondaryLabelColor;
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _artistLabel]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.alignment = UIStackViewAlignmentLeading;
    // Negative, because a UILabel's height carries its font's leading: at 0 the
    // two lines already sit further apart than Apple Music's, which run almost
    // touching. This pulls them back toward the strip's centre.
    labels.spacing = -3;
    labels.userInteractionEnabled = NO;
    labels.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:labels];

    // play.fill, to match _playing starting NO: setPlaying: is a no-op on the
    // value it already holds, so a mismatched initial glyph would survive the
    // first render.
    _playPauseButton = [self controlWithSymbol:@"play.fill" action:@selector(playPauseTapped)];
    _playPauseButton.accessibilityLabel = STR_TRANSPORT_PLAY;
    // forward.end.fill, the glyph MainPlayerContentView draws on the mac: one
    // transport vocabulary across both apps.
    _nextButton = [self controlWithSymbol:@"forward.end.fill" action:@selector(nextTapped)];
    _nextButton.accessibilityLabel = STR_TRANSPORT_NEXT;

    // Swipe up remains a convenience beside the real expand button.
    UISwipeGestureRecognizer *swipe =
            [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(expandTapped)];
    swipe.direction = UISwipeGestureRecognizerDirectionUp;
    swipe.delegate = self;
    [self addGestureRecognizer:swipe];

    // TRAP: the row's give, and it has to be one of these rather than nothing.
    // The strip is pinned to the edges of UIKit's accessory container, and the
    // container reports a width of ZERO on at least one pass on device — but
    // not in the simulator, so this never shows up here. The rest of the row is
    // required and needs 162pt (12 + art + 10 + 6 + two 44pt controls + 8), so
    // at zero UIKit has to break something and logs the whole conflict. Below
    // required, the left block simply slides off and that pass costs nothing.
    NSLayoutConstraint *artLeading =
            [_artView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12];
    artLeading.priority = UILayoutPriorityRequired - 1;

    [NSLayoutConstraint activateConstraints:@[
        artLeading,
        [_artView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_artView.widthAnchor constraintEqualToConstant:kArtSide],
        [_artView.heightAnchor constraintEqualToConstant:kArtSide],

        [_expandButton.leadingAnchor constraintEqualToAnchor:_artView.leadingAnchor],
        [_expandButton.trailingAnchor constraintEqualToAnchor:_playPauseButton.leadingAnchor],
        [_expandButton.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_expandButton.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

        [labels.leadingAnchor constraintEqualToAnchor:_artView.trailingAnchor constant:10],
        [labels.centerYAnchor constraintEqualToAnchor:_artView.centerYAnchor],
        [labels.trailingAnchor constraintLessThanOrEqualToAnchor:_playPauseButton.leadingAnchor constant:-6],

        [_nextButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [_nextButton.centerYAnchor constraintEqualToAnchor:_artView.centerYAnchor],
        [_nextButton.widthAnchor constraintEqualToConstant:kControlSide],
        [_nextButton.heightAnchor constraintEqualToConstant:kControlSide],

        [_playPauseButton.trailingAnchor constraintEqualToAnchor:_nextButton.leadingAnchor],
        [_playPauseButton.centerYAnchor constraintEqualToAnchor:_artView.centerYAnchor],
        [_playPauseButton.widthAnchor constraintEqualToConstant:kControlSide],
        [_playPauseButton.heightAnchor constraintEqualToConstant:kControlSide],
    ]];

    // Collapsed inline beside the tab bar there is no room for two lines; the
    // trait is set by UIKit on everything inside a bottomAccessory.
    __weak MiniPlayerView *weakSelf = self;
    [self registerForTraitChanges:@[UITraitTabAccessoryEnvironment.class,
                                    UITraitPreferredContentSizeCategory.class]
                      withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previous) {
        [weakSelf applyAccessoryEnvironment];
    }];
    [self applyAccessoryEnvironment];
}

- (UIButton *)controlWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.image = [UIImage systemImageNamed:symbol
                            withConfiguration:[UIImageSymbolConfiguration
                                    configurationWithPointSize:kGlyphPointSize]];
    config.baseForegroundColor = UIColor.labelColor;
    config.contentInsets = NSDirectionalEdgeInsetsZero;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:button];
    return button;
}

- (void)applyAccessoryEnvironment {
    BOOL inline_ = self.traitCollection.tabAccessoryEnvironment == UITabAccessoryEnvironmentInline;
    BOOL accessibilitySize = UIContentSizeCategoryIsAccessibilityCategory(
            self.traitCollection.preferredContentSizeCategory);
    _artistLabel.hidden = inline_ || accessibilitySize || _artistLabel.text.length == 0;
}

#pragma mark - Rendering

- (void)renderTrack:(AudioTrack *)track {
    _titleLabel.text = track.displayTitle ?: @"";
    // A nil displayArtist means there is no second line to draw, not an empty
    // one — the cross-directory rule that AudioTrack is the single home of.
    NSString *artist = track.displayArtist;
    _artistLabel.text = artist ?: @"";
    _artView.image = track.cachedThumbnail ?: [UIImage imageNamed:@"record-bg"];
    _expandButton.accessibilityValue = track.displayTitle;
    [self applyAccessoryEnvironment];
}

- (void)setPlaying:(BOOL)playing {
    if (_playing == playing) {
        return;
    }
    _playing = playing;
    UIButtonConfiguration *config = _playPauseButton.configuration;
    config.image = [UIImage systemImageNamed:(playing ? @"pause.fill" : @"play.fill")
                           withConfiguration:[UIImageSymbolConfiguration
                                   configurationWithPointSize:kGlyphPointSize]];
    _playPauseButton.configuration = config;
    _playPauseButton.accessibilityLabel = playing ? STR_TRANSPORT_PAUSE : STR_TRANSPORT_PLAY;
}

#pragma mark - Actions

- (void)expandTapped {
    [self.delegate miniPlayerViewDidRequestExpand:self];
}

- (void)playPauseTapped {
    [self.delegate miniPlayerViewDidTapPlayPause:self];
}

- (void)nextTapped {
    [self.delegate miniPlayerViewDidTapNext:self];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view && view != self; view = view.superview) {
        if (view == _expandButton) {
            return YES;
        }
        if ([view isKindOfClass:UIControl.class]) {
            return NO;
        }
    }
    return YES;
}

@end
