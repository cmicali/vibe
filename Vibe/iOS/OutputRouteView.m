//
//  OutputRouteView.m
//  Vibe (iOS)
//

#import "OutputRouteView.h"

#import <AVKit/AVKit.h>

#import "VibeStrings.h"

// The tap target, which stays comfortably large around a small glyph — the
// mini player's rule.
static const CGFloat kRouteGlyphPointSize = 15;
static const CGFloat kRouteContentSpacing = 5;
// What the control is worth touching at, whatever it draws: on the built-in
// speaker the content is one 17pt glyph, and a target that narrow is a miss.
static const CGFloat kRouteMinimumTapWidth = 44;
// Apple Music's relationship, and the reason there are two: at rest this is
// secondary chrome and sits at the same weight as the time labels either side
// of it (dark mode's secondary label is white at 0.6), while an off-device
// route brings it to full strength — the tint change IS the "audio is not
// coming out of this phone" signal, with the device name beside it.
static const CGFloat kRouteRestingAlpha = 0.6;
static const CGFloat kRouteActiveAlpha = 1.0;
// The touch-down dip, which the invisible picker underneath cannot draw for us.
static const CGFloat kRoutePressedAlpha = 0.35;

@interface OutputRouteView () <AVRoutePickerViewDelegate>
@end

@implementation OutputRouteView {
    // TRAP: this is the tap surface, not the glyph. AVRoutePickerView is the
    // only public way to raise the system picker — there is no programmatic
    // present, and reaching into its subviews for the button it draws would be
    // depending on AVKit's internals. So it fills the bounds with both tints
    // clear and our own icon and label ride on top, non-interactive.
    //
    // If a release ever draws chrome a clear tint cannot erase, or stops
    // extending its hit area to a stretched frame, the fallback is contained
    // here: drop _symbolView, size the picker to its intrinsic width in that
    // slot and keep the label beside it.
    AVRoutePickerView *_routePicker;
    UIStackView       *_content;
    UIImageView       *_symbolView;
    UILabel           *_nameLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self buildUI];
        [self setRouteKind:VibeOutputRouteKindNone deviceName:nil];
    }
    return self;
}

- (void)buildUI {
    _routePicker = [[AVRoutePickerView alloc] init];
    _routePicker.delegate = self;
    _routePicker.prioritizesVideoDevices = NO;
    _routePicker.tintColor = UIColor.clearColor;
    _routePicker.activeTintColor = UIColor.clearColor;
    _routePicker.translatesAutoresizingMaskIntoConstraints = NO;
    // It is stretched well past its intrinsic size on both axes, and its own
    // preference must not argue with the frame it is given.
    [_routePicker setContentHuggingPriority:UILayoutPriorityDefaultLow
                                    forAxis:UILayoutConstraintAxisHorizontal];
    [_routePicker setContentHuggingPriority:UILayoutPriorityDefaultLow
                                    forAxis:UILayoutConstraintAxisVertical];
    [_routePicker setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                  forAxis:UILayoutConstraintAxisHorizontal];
    [_routePicker setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                  forAxis:UILayoutConstraintAxisVertical];
    [self addSubview:_routePicker];

    _symbolView = [[UIImageView alloc] init];
    _symbolView.contentMode = UIViewContentModeScaleAspectFit;
    _symbolView.tintColor = UIColor.whiteColor;
    _symbolView.isAccessibilityElement = NO;
    [_symbolView setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                 forAxis:UILayoutConstraintAxisHorizontal];

    _nameLabel = [[UILabel alloc] init];
    _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _nameLabel.adjustsFontForContentSizeCategory = YES;
    _nameLabel.maximumContentSizeCategory = UIContentSizeCategoryExtraExtraExtraLarge;
    _nameLabel.textColor = UIColor.whiteColor;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _nameLabel.isAccessibilityElement = NO;

    _content = [[UIStackView alloc] initWithArrangedSubviews:@[_symbolView, _nameLabel]];
    UIStackView *content = _content;
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = kRouteContentSpacing;
    // The picker underneath is the whole control's tap surface, so nothing
    // drawn on top may swallow a touch.
    content.userInteractionEnabled = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:content];

    // Hug the content, but never below a finger's width: the hug is what sizes
    // the view, and the minimum is where the extra room around a lone glyph
    // comes from — the content stays centered in it, so what the eye measures
    // is the glyph against the middle of the time row, not the tap target.
    //
    // TRAP: the hug must sit BELOW the label's compression resistance. At or
    // above it the tie resolves toward the smaller view, and a device name
    // truncates to a couple of characters inside a control with room to spare.
    // The card's own width cap is required, so it still wins over both.
    NSLayoutConstraint *hug = [self.widthAnchor constraintEqualToAnchor:content.widthAnchor];
    hug.priority = UILayoutPriorityDefaultLow;

    // The picker draws no highlight we can see — its own glyph is the one being
    // dimmed, and that one is transparent — so the press state is ours. It
    // takes nothing from the touch: no delay, no cancel, so the picker still
    // receives every phase.
    UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                          action:@selector(pressed:)];
    press.minimumPressDuration = 0;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesBegan = NO;
    press.delaysTouchesEnded = NO;
    [self addGestureRecognizer:press];

    [NSLayoutConstraint activateConstraints:@[
        [_routePicker.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_routePicker.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_routePicker.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_routePicker.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

        [content.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [content.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [content.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor],
        [content.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor],
        [self.widthAnchor constraintGreaterThanOrEqualToConstant:kRouteMinimumTapWidth],
        hug,
    ]];
}

- (void)setRouteKind:(VibeOutputRouteKind)kind deviceName:(NSString *)name {
    _symbolName = [VibeOutputRouteSymbolName(kind) copy];
    _showsDeviceName = VibeOutputRouteShowsDeviceName(kind, name);

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration
            configurationWithPointSize:kRouteGlyphPointSize
                                weight:UIImageSymbolWeightMedium];
    _symbolView.image = [UIImage systemImageNamed:_symbolName withConfiguration:config];
    _nameLabel.text = _showsDeviceName ? name : nil;
    _nameLabel.hidden = !_showsDeviceName;
    // The name is drawn only off-device, so it is also what "active" means
    // here — one fact, not two that could disagree.
    _content.alpha = _showsDeviceName ? kRouteActiveAlpha : kRouteRestingAlpha;

    // The label says what tapping does, the value says where the audio is
    // going. Ours rather than whatever AVKit supplies: this is set before the
    // view is ever in a window, where the picker has no label to defer to, and
    // one wording across every route is what VoiceOver should hear.
    _routePicker.accessibilityLabel = STR_A11Y_PLAYER_OUTPUT_ROUTE;
    _routePicker.accessibilityValue = _showsDeviceName ? name : nil;
}

- (void)pressed:(UILongPressGestureRecognizer *)recognizer {
    BOOL down = recognizer.state == UIGestureRecognizerStateBegan
            || recognizer.state == UIGestureRecognizerStateChanged;
    CGFloat resting = _showsDeviceName ? kRouteActiveAlpha : kRouteRestingAlpha;
    [UIView animateWithDuration:down ? 0.08 : 0.25 animations:^{
        self->_content.alpha = down ? kRoutePressedAlpha : resting;
    }];
}

#pragma mark - AVRoutePickerViewDelegate

- (void)routePickerViewWillBeginPresentingRoutes:(AVRoutePickerView *)routePickerView {
    [self.delegate outputRouteView:self isPresentingRoutes:YES];
}

- (void)routePickerViewDidEndPresentingRoutes:(AVRoutePickerView *)routePickerView {
    [self.delegate outputRouteView:self isPresentingRoutes:NO];
}

@end
