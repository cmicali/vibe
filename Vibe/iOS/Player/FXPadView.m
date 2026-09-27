//
//  FXPadView.m
//  Vibe (iOS)
//

#import "FXPadView.h"

#import "AudioFXMath.h"
#import "VibeStrings.h"

// The pad's side at most; the cell's extent caps it on a small window.
static const CGFloat kFXPadSide = 260;
static const CGFloat kFXPadCornerRadius = 20;
// The pill's and the captions' weight at rest, the route control's own.
static const CGFloat kFXPadRestingAlpha = 0.6;
// The circle under the finger, and the fingertip it stands for.
static const CGFloat kFXPadCursorDiameter = 44;
static const CGFloat kFXPadCursorFillAlpha = 0.3;
static const CGFloat kFXPadCursorStrokeAlpha = 0.8;
// The shortest span a press may leave to an edge; a press this close to the
// right end of the capsule still gets a usable axis, since below it the
// mapping would jump.
static const CGFloat kFXPadMinimumSpan = 60;
static const CGFloat kFXPadCaptionInset = 10;
static const NSTimeInterval kFXPadExpandDuration = 0.22;
static const NSTimeInterval kFXPadCollapseDuration = 0.18;

@implementation FXPadView {
    UILabel                     *_pillLabel;
    // The pad, its captions and the cursor: subviews laid out past this
    // view's bounds while expanded, drawn because nothing up the tree clips,
    // and never touched because they take no interaction. The recognizer on
    // this view owns the finger from the press, wherever it goes.
    UIView                      *_padView;
    UILabel                     *_verticalCaption;
    UILabel                     *_horizontalCaption;
    UIView                      *_cursorView;
    UILongPressGestureRecognizer *_press;
    // The press point, the origin of both axes, and the pad's square while
    // expanded, both in this view's coordinates.
    CGPoint                      _origin;
    CGRect                       _padFrame;
    // Whether the last reported x was past the delay's onset, for the tick
    // on crossing it.
    BOOL                         _pastDelayOnset;
    UIImpactFeedbackGenerator   *_engageHaptics;
    UISelectionFeedbackGenerator *_onsetHaptics;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self buildUI];
    }
    return self;
}

- (void)buildUI {
    // The fill is the owner's, the action bar's own (TrackPageCell).
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = STR_A11Y_PLAYER_FX_PAD;
    self.accessibilityHint = STR_A11Y_PLAYER_FX_PAD_HINT;
    // VoiceOver hands the finger straight to the pad: a 2D drag has no
    // spoken equivalent worth building.
    self.accessibilityTraits = UIAccessibilityTraitAllowsDirectInteraction;

    _pillLabel = [[UILabel alloc] init];
    _pillLabel.text = STR_PLAYER_FX_PILL;
    _pillLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _pillLabel.textColor = UIColor.whiteColor;
    _pillLabel.alpha = kFXPadRestingAlpha;
    _pillLabel.isAccessibilityElement = NO;
    _pillLabel.userInteractionEnabled = NO;
    _pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_pillLabel];

    _padView = [[UIView alloc] init];
    _padView.layer.cornerRadius = kFXPadCornerRadius;
    _padView.layer.cornerCurve = kCACornerCurveContinuous;
    _padView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    _padView.layer.borderWidth = 1;
    _padView.userInteractionEnabled = NO;
    _padView.hidden = YES;
    [self addSubview:_padView];

    _verticalCaption = [self makeCaption:STR_PLAYER_FX_AXIS_LOW_CUT];
    _horizontalCaption = [self makeCaption:STR_PLAYER_FX_AXIS_REVERB_DELAY];

    _cursorView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kFXPadCursorDiameter, kFXPadCursorDiameter)];
    _cursorView.backgroundColor = [UIColor colorWithWhite:1 alpha:kFXPadCursorFillAlpha];
    _cursorView.layer.cornerRadius = kFXPadCursorDiameter / 2;
    _cursorView.layer.borderColor = [UIColor colorWithWhite:1 alpha:kFXPadCursorStrokeAlpha].CGColor;
    _cursorView.layer.borderWidth = 2;
    _cursorView.userInteractionEnabled = NO;
    _cursorView.hidden = YES;
    [self addSubview:_cursorView];

    // Immediate, not a hold: the pad opens on the touch itself, so a press
    // and drag in one motion works and a press and hold does too. It never
    // fails on movement — the drag IS the gesture — and it takes the touch
    // from everything under it.
    _press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pressed:)];
    _press.minimumPressDuration = 0;
    _press.allowableMovement = CGFLOAT_MAX;
    [self addGestureRecognizer:_press];

    _engageHaptics = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    _onsetHaptics = [[UISelectionFeedbackGenerator alloc] init];

    [NSLayoutConstraint activateConstraints:@[
        [_pillLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_pillLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
}

- (UILabel *)makeCaption:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    label.textColor = [UIColor colorWithWhite:1 alpha:kFXPadRestingAlpha];
    label.isAccessibilityElement = NO;
    label.userInteractionEnabled = NO;
    [label sizeToFit];
    [_padView addSubview:label];
    return label;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2;
}

- (UIGestureRecognizer *)pressRecognizer {
    return _press;
}

#pragma mark - The pad's geometry

// The square, from the capsule's bottom-left corner up and to the right,
// capped by the cell's extent. In this view's coordinates, y down.
- (CGRect)padFrameForBounds:(CGRect)bounds {
    CGFloat side = MIN(kFXPadSide, MIN(_padExtent.width, _padExtent.height));
    side = MAX(side, bounds.size.height);
    return CGRectMake(CGRectGetMinX(bounds), CGRectGetMaxY(bounds) - side, side, side);
}

// The finger as the pad's position: the press point is 0 on both axes and
// the pad's right and top edges are 1, so the axis is however much of the
// pad lies beyond the press, never less than a usable span.
- (CGPoint)positionForPoint:(CGPoint)point {
    CGFloat spanX = MAX(CGRectGetMaxX(_padFrame) - _origin.x, kFXPadMinimumSpan);
    CGFloat spanY = MAX(_origin.y - CGRectGetMinY(_padFrame), kFXPadMinimumSpan);
    CGFloat x = (point.x - _origin.x) / spanX;
    CGFloat y = (_origin.y - point.y) / spanY;
    return CGPointMake(MIN(MAX(x, 0), 1), MIN(MAX(y, 0), 1));
}

- (void)moveCursorToPoint:(CGPoint)point {
    CGFloat x = MIN(MAX(point.x, CGRectGetMinX(_padFrame)), CGRectGetMaxX(_padFrame));
    CGFloat y = MIN(MAX(point.y, CGRectGetMinY(_padFrame)), CGRectGetMaxY(_padFrame));
    _cursorView.center = CGPointMake(x, y);
}

#pragma mark - The gesture

- (void)pressed:(UILongPressGestureRecognizer *)recognizer {
    CGPoint point = [recognizer locationInView:self];
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self engageAtPoint:point];
            break;
        case UIGestureRecognizerStateChanged:
            [self moveToPoint:point];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self releaseHold];
            break;
        default:
            break;
    }
}

- (void)engageAtPoint:(CGPoint)point {
    _engaged = YES;
    _origin = point;
    _pastDelayOnset = NO;
    _padFrame = [self padFrameForBounds:self.bounds];
    [_engageHaptics prepare];
    [_onsetHaptics prepare];

    // The capsule becomes the pad: the pad starts at the capsule's frame and
    // grows to the square, on top of everything the square covers.
    [self.superview bringSubviewToFront:self];
    _padView.backgroundColor = self.backgroundColor;
    _padView.frame = self.bounds;
    _padView.layer.cornerRadius = self.bounds.size.height / 2;
    _padView.hidden = NO;
    _padView.alpha = 0;
    _verticalCaption.alpha = 0;
    _horizontalCaption.alpha = 0;
    [self layoutCaptionsForFrame:_padFrame];
    _cursorView.hidden = NO;
    _cursorView.alpha = 0;
    [self moveCursorToPoint:point];
    [UIView animateWithDuration:kFXPadExpandDuration delay:0
         usingSpringWithDamping:0.85 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self->_padView.frame = self->_padFrame;
        self->_padView.layer.cornerRadius = kFXPadCornerRadius;
        self->_padView.alpha = 1;
        self->_verticalCaption.alpha = 1;
        self->_horizontalCaption.alpha = 1;
        self->_cursorView.alpha = 1;
        self->_pillLabel.alpha = 0;
    } completion:nil];
    [_engageHaptics impactOccurred];
    [self.delegate fxPadView:self didChangePosition:CGPointZero engaged:YES];
}

- (void)moveToPoint:(CGPoint)point {
    [self moveCursorToPoint:point];
    CGPoint position = [self positionForPoint:point];
    BOOL pastOnset = position.x > kFXPadDelayOnset;
    if (pastOnset != _pastDelayOnset) {
        _pastDelayOnset = pastOnset;
        [_onsetHaptics selectionChanged];
    }
    [self.delegate fxPadView:self didChangePosition:position engaged:YES];
}

- (void)releaseHold {
    if (!_engaged) {
        return;
    }
    _engaged = NO;
    [UIView animateWithDuration:kFXPadCollapseDuration delay:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self->_padView.frame = self.bounds;
        self->_padView.layer.cornerRadius = self.bounds.size.height / 2;
        self->_padView.alpha = 0;
        self->_verticalCaption.alpha = 0;
        self->_horizontalCaption.alpha = 0;
        self->_cursorView.alpha = 0;
        self->_pillLabel.alpha = kFXPadRestingAlpha;
    } completion:^(BOOL finished) {
        if (!self->_engaged) {
            self->_padView.hidden = YES;
            self->_cursorView.hidden = YES;
        }
    }];
    [self.delegate fxPadView:self didChangePosition:CGPointZero engaged:NO];
}

- (void)cancelInteraction {
    if (!_engaged) {
        return;
    }
    // Disabling a recognizer mid-gesture cancels it, which releases through
    // the path a lift takes and frees the touch for the pager.
    _press.enabled = NO;
    _press.enabled = YES;
}

// The captions sit inside the pad's frame, in this view's coordinates as the
// pad's subviews: the vertical axis named at the top-left, the horizontal at
// the bottom-right.
- (void)layoutCaptionsForFrame:(CGRect)frame {
    CGSize vertical = _verticalCaption.bounds.size;
    _verticalCaption.frame = CGRectMake(kFXPadCaptionInset, kFXPadCaptionInset, vertical.width, vertical.height);
    CGSize horizontal = _horizontalCaption.bounds.size;
    _horizontalCaption.frame = CGRectMake(frame.size.width - horizontal.width - kFXPadCaptionInset,
                                          frame.size.height - horizontal.height - kFXPadCaptionInset,
                                          horizontal.width, horizontal.height);
}

@end
