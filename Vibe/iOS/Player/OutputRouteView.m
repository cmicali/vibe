//
//  OutputRouteView.m
//  Vibe (iOS)
//

#import "OutputRouteView.h"

#import <AVKit/AVKit.h>

#import "VibeStrings.h"

static const CGFloat kRouteGlyphPointSize = 23;
static const CGFloat kRouteContentSpacing = 5;
// On the built-in speaker the content is a lone glyph, too narrow to hit.
static const CGFloat kRouteMinimumTapWidth = 44;
// At rest, the time labels' secondary weight; off-device, full strength — the
// tint change IS the "not coming out of this phone" signal.
static const CGFloat kRouteRestingAlpha = 0.6;
static const CGFloat kRouteActiveAlpha = 1.0;
// The invisible picker underneath cannot draw a press state.
static const CGFloat kRoutePressedAlpha = 0.35;

@interface OutputRouteView () <AVRoutePickerViewDelegate>
@end

@implementation OutputRouteView {
    // TRAP: this is the tap surface, not the glyph. AVRoutePickerView is the
    // only public way to raise the picker, so it fills the bounds with both
    // tints clear under our non-interactive icon and label. If a release draws
    // chrome a clear tint cannot erase, or stops hit-testing a stretched frame,
    // drop _symbolView and size the picker to its intrinsic width instead.
    AVRoutePickerView   *_routePicker;
    UIStackView         *_content;
    UIImageView         *_symbolView;
    UILabel             *_nameLabel;

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
    // Stretched past its intrinsic size on both axes.
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
    content.userInteractionEnabled = NO;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:content];

    // Hug the content, never below a finger's width, content centered.
    // TRAP: the hug must sit BELOW the label's compression resistance; at or
    // above it a device name truncates to a few characters with room to spare.
    // The page's width cap is required and wins over both.
    NSLayoutConstraint *hug = [self.widthAnchor constraintEqualToAnchor:content.widthAnchor];
    hug.priority = UILayoutPriorityDefaultLow;

    // Takes nothing from the touch, so the picker still gets every phase.
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
    _symbolName = [VibeOutputRouteSymbolName(kind, name) copy];
    _showsDeviceName = VibeOutputRouteShowsDeviceName(kind, name);

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration
            configurationWithPointSize:kRouteGlyphPointSize
                                weight:UIImageSymbolWeightMedium];
    _symbolView.image = [UIImage systemImageNamed:_symbolName withConfiguration:config];
    _nameLabel.text = _showsDeviceName ? name : nil;
    _nameLabel.hidden = !_showsDeviceName;
    _content.alpha = _showsDeviceName ? kRouteActiveAlpha : kRouteRestingAlpha;

    // Ours, not AVKit's: one wording across every route.
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
