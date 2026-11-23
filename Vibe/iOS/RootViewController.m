//
//  RootViewController.m
//  Vibe (iOS)
//

#import "RootViewController.h"

#import "MiniPlayerView.h"

NSString *const RootViewControllerSearchTabIdentifier = @"search";

static const CGFloat kCardCornerRadius = 14;
static const CGFloat kBackdropScale = 0.92;
static const CGFloat kBackdropCornerRadius = 38;

// Either alone commits a downward drag.
static const CGFloat kDismissTravelFraction = 0.25;
static const CGFloat kDismissFlickVelocity = 900;

@interface RootViewController () <MiniPlayerViewDelegate, UITabBarControllerDelegate>
@end

@implementation RootViewController {
    NSArray<UITab *>     *_tabList;
    UITabBarController   *_tabs;
    // What scales under a moving card: a snapshot of the tabs, never the tabs
    // themselves (applyBackdropProgress:). Present only while the card moves.
    UIView               *_backdropSnapshot;
    MiniPlayerView       *_miniPlayer;
    UIViewController<RootViewControllerCard> *_card;
    BOOL                 _expanded;
    BOOL                 _miniWanted;
    // The card between up and away; see updateBackdropVisibility.
    BOOL                 _cardAnimating;
    BOOL                 _interactiveDrag;
    UIViewPropertyAnimator *_cardAnimator;
    BOOL                   _cardAppearanceTransitionActive;
    NSArray<UIViewController *> *_parentAppearanceChildren;
    BOOL                   _rootPresentationVisible;
    BOOL                   _sceneActive;
    uint64_t               _accessibilityPresentationGeneration;
}

- (instancetype)initWithTabs:(NSArray<UITab *> *)tabs card:(UIViewController<RootViewControllerCard> *)card {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _tabList = [tabs copy];
        _card = card;
        _miniPlayer = [[MiniPlayerView alloc] initWithFrame:CGRectZero];
        _miniPlayer.delegate = self;
    }
    return self;
}

- (UITabBarController *)tabs {
    return _tabs;
}

- (MiniPlayerView *)miniPlayer {
    return _miniPlayer;
}

- (UIView *)backdropSnapshot {
    return _backdropSnapshot;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    [self buildTabs];
    [self buildCard];
    if (_miniWanted) {
        [self applyMiniPlayerAccessory];
    }
    [self.delegate rootViewControllerDidLoad:self];
    [self syncTabSurfaces];
}

- (void)buildTabs {
    _tabs = [[UITabBarController alloc] init];
    _tabs.delegate = self;
    _tabs.tabs = _tabList;

    [self addChildViewController:_tabs];
    _tabs.view.frame = self.view.bounds;
    _tabs.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_tabs.view];
    [_tabs didMoveToParentViewController:self];
    [self syncTabSurfaces];
}

- (void)buildCard {
    _card.sceneActive = _sceneActive;
    [self addChildViewController:_card];
    _card.view.frame = self.view.bounds;
    _card.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _card.view.layer.cornerRadius = kCardCornerRadius;
    _card.view.layer.cornerCurve = kCACornerCurveContinuous;
    _card.view.layer.masksToBounds = YES;
    [self.view addSubview:_card.view];
    [_card didMoveToParentViewController:self];
    // Built minimized; the manual appearance forwarding below keeps its
    // viewWillAppear: from firing just because it is in the hierarchy.
    _card.view.transform = [self minimizedCardTransform];
    _card.view.hidden = YES;
    _card.view.accessibilityViewIsModal = NO;
    _card.presented = NO;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_expanded) {
        // The offset is the view's height, which a rotation or resize moves.
        _card.view.transform = [self minimizedCardTransform];
    }
}

- (CGAffineTransform)minimizedCardTransform {
    return CGAffineTransformMakeTranslation(0, self.view.bounds.size.height);
}

#pragma mark - Appearance forwarding

// Automatic forwarding would tell the minimized card it appeared and double
// the pairs expand and minimize send. TRAP: the switch is per-parent — off for
// the card is off for the tabs, so both are forwarded by hand.
- (BOOL)shouldAutomaticallyForwardAppearanceMethods {
    return NO;
}

// Expand and minimize own the card's transitions while it is down.
- (NSArray<UIViewController *> *)appearingChildren {
    return _expanded ? @[_tabs, _card] : @[_tabs];
}

- (void)finishParentAppearanceTransition {
    NSArray<UIViewController *> *children = _parentAppearanceChildren;
    _parentAppearanceChildren = nil;
    for (UIViewController *child in children) {
        [child endAppearanceTransition];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _rootPresentationVisible = YES;
    [self syncTabSurfaces];
    // An interactive transition can reverse before its did-callback, so close
    // any open pair, then snapshot the children: `_expanded` may change before
    // the matching end.
    [self finishParentAppearanceTransition];
    [self finishCardAppearanceTransition];
    _parentAppearanceChildren = [[self appearingChildren] copy];
    for (UIViewController *child in _parentAppearanceChildren) {
        [child beginAppearanceTransition:YES animated:animated];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self finishParentAppearanceTransition];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _rootPresentationVisible = NO;
    [self syncTabSurfaces];
    [self finishParentAppearanceTransition];
    [self finishCardAppearanceTransition];
    _parentAppearanceChildren = [[self appearingChildren] copy];
    for (UIViewController *child in _parentAppearanceChildren) {
        [child beginAppearanceTransition:NO animated:animated];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self finishParentAppearanceTransition];
}

- (void)setSceneActive:(BOOL)sceneActive {
    if (_sceneActive == sceneActive) {
        return;
    }
    _sceneActive = sceneActive;
    _card.sceneActive = sceneActive;
    [self syncTabSurfaces];
}

- (BOOL)isSceneActive {
    return _sceneActive;
}

// What no descendant can know: scene activity and whether the card leaves the
// selected tab exposed. The delegate maps it onto its screens.
- (BOOL)tabsExposed {
    return _sceneActive && _rootPresentationVisible && !_tabs.view.hidden;
}

- (BOOL)cardAtRest {
    return !_expanded && !_cardAnimating && !_interactiveDrag;
}

- (void)syncTabSurfaces {
    [self.delegate rootViewControllerDidChangeExposure:self];
}

#pragma mark - The mini player

// TRAP: the strip stays installed under the card. Taking the accessory away
// on expand shrinks every tab's bottom inset by the strip, a list scrolled
// to its end is clamped up by that much under the snapshot, and putting it
// back on dismiss moves nothing: one card cycle left the last row behind
// the strip. The card hides the tabs, strip included, so it costs nothing.
- (void)setMiniPlayerRow:(VibeTrackRow *)row playing:(BOOL)playing {
    BOOL wanted = row != nil;
    if (wanted) {
        [_miniPlayer renderRow:row];
        [_miniPlayer setPlaying:playing];
    }
    if (wanted == _miniWanted) {
        return;
    }
    _miniWanted = wanted;
    [self applyMiniPlayerAccessory];
}

// Before the view loads, viewDidLoad applies it.
- (void)applyMiniPlayerAccessory {
    UITabAccessory *accessory = _miniWanted
            ? [[UITabAccessory alloc] initWithContentView:_miniPlayer]
            : nil;
    [_tabs setBottomAccessory:accessory animated:!UIAccessibilityIsReduceMotionEnabled()];
}

- (BOOL)isMiniPlayerShown {
    return _miniWanted;
}

#pragma mark - Expanding and minimizing

- (BOOL)shouldAnimateCard:(BOOL)requested {
    return requested && !UIAccessibilityIsReduceMotionEnabled();
}

- (void)beginCardAppearanceTransition:(BOOL)appearing animated:(BOOL)animated {
    if (!_rootPresentationVisible) {
        return;
    }
    // A card intent can land between this container's will/did; appearance
    // transitions cannot nest, so end the parent's pair first.
    [self finishParentAppearanceTransition];
    [_card beginAppearanceTransition:appearing animated:animated];
    _cardAppearanceTransitionActive = YES;
}

- (UIView *)firstAccessibleDescendantInView:(UIView *)view {
    if (view.hidden || view.alpha <= 0.01) {
        return nil;
    }
    if (view.isAccessibilityElement) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *candidate = [self firstAccessibleDescendantInView:subview];
        if (candidate) {
            return candidate;
        }
    }
    return nil;
}

- (uint64_t)beginAccessibilityTransitionToExpanded:(BOOL)expanded {
    uint64_t generation = ++_accessibilityPresentationGeneration;
    if (expanded) {
        // Not a presentation, so UIKit cannot infer the modal surface.
        _card.view.accessibilityViewIsModal = YES;
        _tabs.view.accessibilityElementsHidden = YES;
    }
    return generation;
}

- (void)completeAccessibilityTransitionToExpanded:(BOOL)expanded
                                        generation:(uint64_t)generation {
    if (generation != _accessibilityPresentationGeneration || expanded != _expanded) {
        return;
    }
    if (!expanded) {
        _card.view.accessibilityViewIsModal = NO;
        _tabs.view.accessibilityElementsHidden = NO;
    }
    if (!_rootPresentationVisible || !UIAccessibilityIsVoiceOverRunning()) {
        return;
    }
    __weak RootViewController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        RootViewController *self = weakSelf;
        if (!self || generation != self->_accessibilityPresentationGeneration
                || expanded != self->_expanded || !self->_rootPresentationVisible) {
            return;
        }
        UIView *surface = expanded ? self->_card.view : self->_miniPlayer;
        UIView *focus = [self firstAccessibleDescendantInView:surface];
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, focus);
    });
}

- (BOOL)isCardExpanded {
    return _expanded;
}

- (void)expandCardAnimated:(BOOL)animated {
    if (_expanded || ![self.delegate rootViewControllerCanExpandCard:self]) {
        return;
    }
    [self interruptCardAnimationPreservingVisualState];
    BOOL shouldAnimate = [self shouldAnimateCard:animated];
    _expanded = YES;
    uint64_t accessibilityGeneration = [self beginAccessibilityTransitionToExpanded:YES];
    _card.view.hidden = NO;
    [self beginCardAppearanceTransition:YES animated:shouldAnimate];
    _card.presented = YES;
    [self animateCardAnimated:shouldAnimate changes:^{
        self->_card.view.transform = CGAffineTransformIdentity;
        [self applyBackdropProgress:0];
    } completion:^{
        [self finishCardAppearanceTransition];
        [self completeAccessibilityTransitionToExpanded:YES
                                             generation:accessibilityGeneration];
    }];
}

- (void)minimizeCardAnimated:(BOOL)animated {
    if (!_expanded) {
        return;
    }
    [self interruptCardAnimationPreservingVisualState];
    BOOL shouldAnimate = [self shouldAnimateCard:animated];
    _expanded = NO;
    uint64_t accessibilityGeneration = [self beginAccessibilityTransitionToExpanded:NO];
    [self beginCardAppearanceTransition:NO animated:shouldAnimate];
    _card.presented = NO;
    [self animateCardAnimated:shouldAnimate changes:^{
        self->_card.view.transform = [self minimizedCardTransform];
        [self applyBackdropProgress:1];
    } completion:^{
        self->_card.view.hidden = YES;
        [self finishCardAppearanceTransition];
        [self completeAccessibilityTransitionToExpanded:NO
                                             generation:accessibilityGeneration];
    }];
}

// TRAP: the card moves by TRANSFORM, never by frame: a WaveformScrubberView
// redraws its picture on any bounds change, which a frame animation would
// pay on every frame of an expand, on every page.
//
// The one place that knows the card is moving, so it brackets the backdrop.
- (void)animateCardAnimated:(BOOL)animated
                    changes:(void (^)(void))changes
                 completion:(void (^)(void))completion {
    [self interruptCardAnimationPreservingVisualState];
    _cardAnimating = YES;
    if (!animated) {
        changes();
        _cardAnimating = NO;
        [self endBackdropSnapshot];
        completion();
        return;
    }
    // Before the changes: the tabs come back under it first.
    [self beginBackdropSnapshot];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc]
            initWithDuration:0.45 dampingRatio:0.86 animations:changes];
    _cardAnimator = animator;
    __weak UIViewPropertyAnimator *weakAnimator = animator;
    [animator addCompletion:^(UIViewAnimatingPosition finalPosition) {
        if (self->_cardAnimator != weakAnimator) {
            return;
        }
        self->_cardAnimator = nil;
        self->_cardAnimating = NO;
        [self endBackdropSnapshot];
        completion();
    }];
    [animator startAnimation];
}

// A second intent during a spring: freeze at the presentation transform, drop
// the stale completion, and balance the appearance pair.
- (void)interruptCardAnimationPreservingVisualState {
    if (!_cardAnimator) {
        return;
    }
    CALayer *presentation = _card.view.layer.presentationLayer;
    CGAffineTransform visibleTransform = presentation
            ? presentation.affineTransform
            : _card.view.transform;
    UIViewPropertyAnimator *animator = _cardAnimator;
    _cardAnimator = nil;
    [animator stopAnimation:YES];
    _card.view.transform = visibleTransform;
    CGFloat height = MAX(1, self.view.bounds.size.height);
    [self applyBackdropProgress:visibleTransform.ty / height];
    _cardAnimating = NO;
    // The snapshot stays: the intent that interrupted is about to animate.
    [self finishCardAppearanceTransition];
}

- (void)finishCardAppearanceTransition {
    if (!_cardAppearanceTransitionActive) {
        return;
    }
    _cardAppearanceTransitionActive = NO;
    [_card endAppearanceTransition];
}

// A card at rest covers the tabs, so they are hidden: shown, the glass tab
// bar keeps sampling for nothing. While the card moves a snapshot stands in
// for them and they are shown under it, drawn twice for those frames on
// purpose: the tab bar comes back with an appearance of its own, which then
// plays out under the snapshot rather than after the card has landed.
- (void)updateBackdropVisibility {
    BOOL hidden = _expanded && !_cardAnimating && !_interactiveDrag;
    if (_tabs.view.hidden != hidden) {
        _tabs.view.hidden = hidden;
    }
    [self syncTabSurfaces];
}

// TRAP: what scales under the card is a SNAPSHOT of the tabs, never the tabs
// view. Scaling the view itself, by its transform or by a sublayer transform
// above it, moved its edges away from the screen's, and UIKit took away the
// safe-area insets and the edge layout margins as it did: the navigation
// bar, the large title, the rows and the tab bar re-laid out and the screen
// jumped under the card on every expand and dismiss. A snapshot has no
// layout to lose. Taken as the card starts moving and dropped once it rests.
- (void)beginBackdropSnapshot {
    if (_backdropSnapshot) {
        return;
    }
    // A hidden view snapshots nothing: shown first, and a view that was
    // hidden is captured after the next screen update.
    BOOL wasHidden = _tabs.view.hidden;
    [self updateBackdropVisibility];
    UIView *snapshot = [_tabs.view snapshotViewAfterScreenUpdates:wasHidden];
    if (!snapshot) {
        return;
    }
    snapshot.frame = _tabs.view.frame;
    snapshot.layer.cornerCurve = kCACornerCurveContinuous;
    snapshot.layer.masksToBounds = YES;
    [self.view insertSubview:snapshot aboveSubview:_tabs.view];
    _backdropSnapshot = snapshot;
}

- (void)endBackdropSnapshot {
    [_backdropSnapshot removeFromSuperview];
    _backdropSnapshot = nil;
    [self updateBackdropVisibility];
}

// 0 is the card fully up, 1 fully away.
- (void)applyBackdropProgress:(CGFloat)progress {
    CGFloat t = MAX(0, MIN(1, progress));
    CGFloat scale = kBackdropScale + (1 - kBackdropScale) * t;
    _backdropSnapshot.transform = CGAffineTransformMakeScale(scale, scale);
    _backdropSnapshot.layer.cornerRadius = kBackdropCornerRadius * (1 - t);
}

#pragma mark - The interactive minimize

// `presented` holds for the whole gesture, so a cancelled drag has not stopped
// the card's display link.
- (void)cardDidPanWithTranslation:(CGFloat)translation
                         velocity:(CGFloat)velocity
                            state:(UIGestureRecognizerState)state {
    if (!_expanded) {
        return;
    }
    CGFloat height = MAX(1, self.view.bounds.size.height);
    switch (state) {
        case UIGestureRecognizerStateBegan:
            [self interruptCardAnimationPreservingVisualState];
            // Fall through.
        case UIGestureRecognizerStateChanged:
            _interactiveDrag = YES;
            [self beginBackdropSnapshot];
            _card.view.transform = CGAffineTransformMakeTranslation(0, translation);
            [self applyBackdropProgress:translation / height];
            break;
        case UIGestureRecognizerStateEnded:
            // Before the settle, whose animation then owns the backdrop.
            _interactiveDrag = NO;
            if (translation > height * kDismissTravelFraction || velocity > kDismissFlickVelocity) {
                [self minimizeCardAnimated:YES];
            }
            else {
                [self springCardBackUp];
            }
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            _interactiveDrag = NO;
            [self springCardBackUp];
            break;
        default:
            break;
    }
}

- (void)springCardBackUp {
    [self animateCardAnimated:[self shouldAnimateCard:YES] changes:^{
        self->_card.view.transform = CGAffineTransformIdentity;
        [self applyBackdropProgress:0];
    } completion:^{
        // A drag can interrupt the expand before its accessibility completion.
        [self completeAccessibilityTransitionToExpanded:YES
                                              generation:self->_accessibilityPresentationGeneration];
    }];
}

#pragma mark - Tabs

- (void)tabBarController:(UITabBarController *)tabBarController
            didSelectTab:(UITab *)selectedTab
             previousTab:(UITab *)previousTab {
    [self.delegate rootViewController:self didSelectTab:selectedTab previousTab:previousTab];
    [self syncTabSurfaces];
}

// UISearchTab's identifier is UIKit's, so it is matched by kind.
- (NSString *)selectedTabIdentifier {
    UITab *selected = _tabs.selectedTab;
    if ([selected isKindOfClass:UISearchTab.class]) {
        return RootViewControllerSearchTabIdentifier;
    }
    return selected.identifier ?: _tabList.firstObject.identifier;
}

- (void)setSelectedTabIdentifier:(NSString *)identifier {
    BOOL wantsSearch = [identifier isEqualToString:RootViewControllerSearchTabIdentifier];
    for (UITab *tab in _tabs.tabs) {
        BOOL isSearch = [tab isKindOfClass:UISearchTab.class];
        if (wantsSearch ? isSearch : [tab.identifier isEqualToString:identifier]) {
            _tabs.selectedTab = tab;
            [self syncTabSurfaces];
            return;
        }
    }
}

// UITab has no view of its own, so the bar's is found by the label it draws;
// a bar that is not on screen (the iPad's is elsewhere), or one drawn without
// that label, answers NO.
- (BOOL)getCenterOfTabWithIdentifier:(NSString *)identifier center:(CGPoint *)center {
    UITabBar *bar = _tabs.tabBar;
    NSString *title = [_tabs tabForIdentifier:identifier].title;
    if (!bar.window || bar.hidden || CGRectIsEmpty(bar.bounds) || title.length == 0) {
        return NO;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:bar.subviews];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view.accessibilityLabel isEqualToString:title]) {
            *center = [self.view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                                     fromView:view];
            return YES;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return NO;
}

#pragma mark - MiniPlayerViewDelegate

- (void)miniPlayerViewDidRequestExpand:(MiniPlayerView *)view {
    [self expandCardAnimated:YES];
}

- (void)miniPlayerViewDidTapPlayPause:(MiniPlayerView *)view {
    [self.delegate rootViewControllerDidTapPlayPause:self];
}

- (void)miniPlayerViewDidTapNext:(MiniPlayerView *)view {
    [self.delegate rootViewControllerDidTapNext:self];
}

@end
