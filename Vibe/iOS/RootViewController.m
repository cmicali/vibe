//
//  RootViewController.m
//  Vibe (iOS)
//
//  See RootViewController.h.
//

#import "RootViewController.h"

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "FavoritesViewController.h"
#import "FilesViewController.h"
#import "LibraryViewController.h"
#import "MiniPlayerView.h"
#import "PlaybackController.h"
#import "PlayerScreenRules.h"
#import "PlayerViewController.h"
#import "Playlist.h"
#import "SearchViewController.h"
#import "VibeStrings.h"

// The card's corner radius while it is up, and the amount the screen behind it
// scales back — the Apple Music proportions.
static const CGFloat kCardCornerRadius = 14;
static const CGFloat kBackdropScale = 0.92;
static const CGFloat kBackdropCornerRadius = 38;

// What commits a downward drag: a quarter of the screen, or a flick. Either
// alone is enough — a slow long drag and a fast short one both read as "put it
// away".
static const CGFloat kDismissTravelFraction = 0.25;
static const CGFloat kDismissFlickVelocity = 900;

// What the Files browser's own bar needs to clear the floating capsule below
// it, and it is a sum of two measured things: UIKit's own 8pt gap between the
// mini strip and the tab bar — the spacing two floating capsules are meant to
// have — plus the ~12.7pt the browser draws PAST its own safe-area bottom.
// Leave the overhang out and the two capsules touch rather than clear each
// other. See applyFilesBottomInset.
static const CGFloat kFilesBarClearance = 21;

static NSString *const kTabPlaylist = @"playlist";
static NSString *const kTabFavorites = @"favorites";
static NSString *const kTabFiles = @"files";
static NSString *const kTabSearch = @"search";

@interface RootViewController () <PlaybackObserver, MiniPlayerViewDelegate,
        PlayerViewControllerDelegate, UITabBarControllerDelegate>
@end

@implementation RootViewController {
    PlaybackController   *_playback;
    UITabBarController   *_tabs;
    FilesViewController  *_filesController;
    FavoritesViewController *_favorites;
    LibraryViewController *_library;
    SearchViewController *_searchController;
    MiniPlayerView       *_miniPlayer;
    PlayerViewController *_player;
    BOOL                 _expanded;
    // Whether the accessory is installed. Kept rather than read back off the
    // tab bar controller, because it is also nil'd while the card is up.
    BOOL                 _miniWanted;
    // The two ways the card can be somewhere between up and away, which is the
    // only time the tabs behind it are worth rendering — see
    // updateBackdropVisibility.
    BOOL                 _cardAnimating;
    BOOL                 _interactiveDrag;
    UIViewPropertyAnimator *_cardAnimator;
    BOOL                   _playerAppearanceTransitionActive;
    NSArray<UIViewController *> *_parentAppearanceChildren;
    BOOL                   _rootPresentationVisible;
    BOOL                   _sceneActive;
    uint64_t               _accessibilityPresentationGeneration;
}

- (instancetype)initWithPlayback:(PlaybackController *)playback {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _playback = playback;
    }
    return self;
}

- (PlayerViewController *)player {
    return _player;
}

- (PlaybackController *)playback {
    return _playback;
}

- (LibraryViewController *)library {
    return _library;
}

- (FavoritesViewController *)favorites {
    return _favorites;
}

- (SearchViewController *)searchScreen {
    return _searchController;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // The card's rounded corners cut to this, so it has to be the colour the
    // corners should read as.
    self.view.backgroundColor = UIColor.blackColor;

    [self buildTabs];
    [self buildMiniPlayer];
    [self buildCard];

    [_playback addObserver:self];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(thumbnailDidLoad:)
                                               name:AudioTrackMetadataThumbnailDidLoadNotification
                                             object:nil];
    [self refreshMiniPlayer];
    [self syncTabSurfaces];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)thumbnailDidLoad:(NSNotification *)notification {
    AudioTrack *displayed = _playback.displayedTrack;
    if (displayed.metadata == notification.object) {
        [_miniPlayer renderTrack:displayed];
    }
}

// The iOS 26 tab shape, and Apple Music's: the tabs in a capsule and search as
// a circle beside it rather than one more tab inside it. UISearchTab is what
// draws that circle, and automaticallyActivatesSearch is what makes tapping it
// collapse the bar behind a search field and restore the previous tab on
// cancel — the whole behavior, from UIKit, with no bar of our own.
//
// Each tab builds its view controller lazily through a provider, so a tab
// never visited costs nothing; the Files browser in particular is not cheap.
- (void)buildTabs {
    __weak RootViewController *weakSelf = self;

    UITab *playlist = [[UITab alloc] initWithTitle:STR_TAB_PLAYLIST
                                             image:[UIImage systemImageNamed:@"music.note.list"]
                                        identifier:kTabPlaylist
                         viewControllerProvider:^UIViewController *(__kindof UITab *tab) {
        RootViewController *root = weakSelf;
        if (!root) {
            return nil;
        }
        LibraryViewController *library =
                [[LibraryViewController alloc] initWithPlayback:root->_playback];
        root->_library = library;
        [root syncTabSurfaces];
        return [[UINavigationController alloc] initWithRootViewController:library];
    }];

    // Between Playlist and Files, which is the order the three read in: what is
    // playing, what has been kept, and everywhere else.
    UITab *favorites = [[UITab alloc] initWithTitle:STR_TAB_FAVORITES
                                              image:[UIImage systemImageNamed:@"star"]
                                         identifier:kTabFavorites
                         viewControllerProvider:^UIViewController *(__kindof UITab *tab) {
        RootViewController *root = weakSelf;
        if (!root) {
            return nil;
        }
        FavoritesViewController *starred =
                [[FavoritesViewController alloc] initWithPlayback:root->_playback];
        root->_favorites = starred;
        return [[UINavigationController alloc] initWithRootViewController:starred];
    }];

    // No navigation controller: the browser brings its own bar and its own
    // hierarchy, and wrapping it in a second one stacks two.
    UITab *files = [[UITab alloc] initWithTitle:STR_TAB_FILES
                                          image:[UIImage systemImageNamed:@"folder"]
                                     identifier:kTabFiles
                         viewControllerProvider:^UIViewController *(__kindof UITab *tab) {
        RootViewController *root = weakSelf;
        if (!root) {
            return nil;
        }
        FilesViewController *browser =
                [[FilesViewController alloc] initWithPlayback:root->_playback];
        root->_filesController = browser;
        [root applyFilesBottomInset];
        return browser;
    }];

    UISearchTab *search = [[UISearchTab alloc] initWithViewControllerProvider:
            ^UIViewController *(__kindof UITab *tab) {
        RootViewController *root = weakSelf;
        if (!root) {
            return nil;
        }
        SearchViewController *results =
                [[SearchViewController alloc] initWithPlayback:root->_playback];
        root->_searchController = results;
        [root syncTabSurfaces];
        return [[UINavigationController alloc] initWithRootViewController:results];
    }];
    search.automaticallyActivatesSearch = YES;

    _tabs = [[UITabBarController alloc] init];
    _tabs.delegate = self;
    _tabs.tabs = @[playlist, favorites, files, search];

    [self addChildViewController:_tabs];
    _tabs.view.frame = self.view.bounds;
    _tabs.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tabs.view.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:_tabs.view];
    [_tabs didMoveToParentViewController:self];
    [self syncTabSurfaces];
}

- (void)buildMiniPlayer {
    _miniPlayer = [[MiniPlayerView alloc] initWithFrame:CGRectZero];
    _miniPlayer.delegate = self;
}

- (void)buildCard {
    _player = [[PlayerViewController alloc] initWithPlayback:_playback];
    _player.delegate = self;
    _player.sceneActive = _sceneActive;
    [self addChildViewController:_player];
    _player.view.frame = self.view.bounds;
    _player.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _player.view.layer.cornerRadius = kCardCornerRadius;
    _player.view.layer.cornerCurve = kCACornerCurveContinuous;
    _player.view.layer.masksToBounds = YES;
    [self.view addSubview:_player.view];
    [_player didMoveToParentViewController:self];
    // Built minimized, and never appears until it is expanded — which is what
    // the manual appearance forwarding below is for: its viewWillAppear: must
    // not fire just because it is in the hierarchy.
    _player.view.transform = [self minimizedCardTransform];
    _player.view.hidden = YES;
    _player.view.accessibilityViewIsModal = NO;
    _player.presented = NO;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_expanded) {
        // The offset is the view's own height, which a rotation or an iPad
        // resize changes under a minimized card.
        _player.view.transform = [self minimizedCardTransform];
    }
}

- (CGAffineTransform)minimizedCardTransform {
    return CGAffineTransformMakeTranslation(0, self.view.bounds.size.height);
}

#pragma mark - Appearance forwarding

// Both children are in the hierarchy from viewDidLoad, but only one of them is
// ever on screen at a time, so this controller says when each appears rather
// than letting UIKit forward to both. Automatic forwarding would tell the card
// it had appeared while it sits minimized and hidden, and would then double
// the begin/end pairs expandPlayerAnimated: and minimizePlayerAnimated: send.
//
// TRAP: the switch is per-parent, not per-child — turning it off for the card
// turns it off for the tabs too, which is why they are forwarded by hand here.
- (BOOL)shouldAutomaticallyForwardAppearanceMethods {
    return NO;
}

// The card only while it is up; expand and minimize own its transitions
// otherwise.
- (NSArray<UIViewController *> *)appearingChildren {
    return _expanded ? @[_tabs, _player] : @[_tabs];
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
    // Interactive parent transitions can reverse before their did-callback.
    // Close either outstanding pair before beginning the new direction, then
    // snapshot the exact children this parent begin belongs to. `_expanded`
    // may change before viewDidAppear:, but the matching end must not change
    // with it.
    [self finishParentAppearanceTransition];
    [self finishPlayerAppearanceTransition];
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
    [self finishPlayerAppearanceTransition];
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
    _player.sceneActive = sceneActive;
    [self syncTabSurfaces];
}

- (BOOL)isSceneActive {
    return _sceneActive;
}

// Each tab owns its own navigation/view lifecycle. The root contributes what
// no descendant can know: whether this scene is active and whether the custom
// card leaves the selected tab materially exposed.
- (void)syncTabSurfaces {
    BOOL playlistSelected = [_tabs.selectedTab.identifier isEqualToString:kTabPlaylist];
    _library.equalizerSurfaceVisible = _sceneActive
            && _rootPresentationVisible && !_tabs.view.hidden && playlistSelected;
    BOOL searchSelected = [_tabs.selectedTab isKindOfClass:UISearchTab.class];
    BOOL cardAtRestBelowTabs = !_expanded && !_cardAnimating && !_interactiveDrag;
    _searchController.materialSurfaceVisible = _sceneActive
            && _rootPresentationVisible && !_tabs.view.hidden
            && cardAtRestBelowTabs && searchSelected;
}

#pragma mark - The mini player

// The strip stands in for the card whenever there is a track to describe, and
// disappears with the playlist. It is never up while the card is.
- (void)refreshMiniPlayer {
    BOOL wanted = VibeMiniPlayerVisible(_playback.screenState) && !_expanded;
    if (wanted) {
        [_miniPlayer renderTrack:_playback.displayedTrack];
        [_miniPlayer setPlaying:_playback.isPlaying];
    }
    if (wanted == _miniWanted) {
        return;
    }
    _miniWanted = wanted;
    UITabAccessory *accessory = wanted
            ? [[UITabAccessory alloc] initWithContentView:_miniPlayer]
            : nil;
    [_tabs setBottomAccessory:accessory animated:!UIAccessibilityIsReduceMotionEnabled()];
}

// The Files browser draws its OWN bottom bar (Recents / Shared / Browse) as a
// floating capsule placed against its safe area — and UIKit's safe area ends
// exactly at the top of whichever of our floating capsules is lowest: the tab
// bar with the strip down, the strip itself with it up. So the browser's
// capsule lands flush on ours, overlapping by the few points it draws past its
// own safe-area bottom, and the two read as one collided pill. A scroll view
// never shows this — it just takes extra content inset — which is why this is
// the only tab that needs telling.
//
// TRAP: do NOT add the accessory's height here. UIKit's tab-child safe area
// already accounts for the strip, so an earlier version that measured the live
// strip and added it lifted the browser's bar a whole strip height clear of the
// mini player, leaving a band of dead space. The clearance is therefore
// constant — it does not depend on whether the strip is up, because UIKit has
// already moved the safe area for it, and one value lands the same 8pt gap in
// both states.
//
// TRAP: the browser's bar overhangs its safe area, so a clearance of only the
// 8pt system gap still leaves the capsules touching. Measured on iOS 26.5,
// window 874: with the strip down UIKit's inset is 83 and an added 12 put the
// content bottom at 779, where the bar's own bottom edge drew at 791.67 —
// 12.67pt past it, and flush against a tab capsule whose top is 791.
//
// Both halves are screenshot-measurable, which is how the numbers above were
// got: scan a screenshot column for runs of non-background rows. The tab
// capsule (791–853) and the accessory container (735–783) come from
// dump_view_tree and anchor the scale; a run that spans the browser's bar AND
// the capsule below it without a break is the bug.
- (void)applyFilesBottomInset {
    UIViewController *files = _filesController;
    if (!files) {
        return;   // the lazy provider has not been asked for Files yet
    }
    UIEdgeInsets insets = files.additionalSafeAreaInsets;
    if (fabs(insets.bottom - kFilesBarClearance) < 0.5) {
        return;
    }
    insets.bottom = kFilesBarClearance;
    files.additionalSafeAreaInsets = insets;
}

#pragma mark - Expanding and minimizing

- (BOOL)shouldAnimateCard:(BOOL)requested {
    return requested && !UIAccessibilityIsReduceMotionEnabled();
}

- (void)beginPlayerAppearanceTransition:(BOOL)appearing animated:(BOOL)animated {
    if (!_rootPresentationVisible) {
        return;
    }
    // A card intent can land between this container's will/did callbacks. End
    // that parent-owned pair before starting an opposite transition on the
    // same player child; UIKit appearance transitions cannot be nested.
    [self finishParentAppearanceTransition];
    [_player beginAppearanceTransition:appearing animated:animated];
    _playerAppearanceTransitionActive = YES;
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
        // This is a custom container transition rather than a presentation, so
        // UIKit cannot infer which sibling is the modal accessibility surface.
        _player.view.accessibilityViewIsModal = YES;
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
        _player.view.accessibilityViewIsModal = NO;
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
        UIView *surface = expanded ? self->_player.view : self->_miniPlayer;
        UIView *focus = [self firstAccessibleDescendantInView:surface];
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, focus);
    });
}

- (BOOL)isPlayerExpanded {
    return _expanded;
}

- (BOOL)isMiniPlayerShown {
    return _miniWanted;
}

- (void)expandPlayerAnimated:(BOOL)animated {
    if (_expanded || _playback.playlist.count == 0) {
        return;
    }
    [self interruptCardAnimationPreservingVisualState];
    BOOL shouldAnimate = [self shouldAnimateCard:animated];
    _expanded = YES;
    uint64_t accessibilityGeneration = [self beginAccessibilityTransitionToExpanded:YES];
    _player.view.hidden = NO;
    [self beginPlayerAppearanceTransition:YES animated:shouldAnimate];
    _player.presented = YES;
    [self refreshMiniPlayer];
    [self animateCardAnimated:shouldAnimate changes:^{
        self->_player.view.transform = CGAffineTransformIdentity;
        [self applyBackdropProgress:0];
    } completion:^{
        [self finishPlayerAppearanceTransition];
        [self completeAccessibilityTransitionToExpanded:YES
                                             generation:accessibilityGeneration];
    }];
}

- (void)minimizePlayerAnimated:(BOOL)animated {
    if (!_expanded) {
        return;
    }
    [self interruptCardAnimationPreservingVisualState];
    BOOL shouldAnimate = [self shouldAnimateCard:animated];
    _expanded = NO;
    uint64_t accessibilityGeneration = [self beginAccessibilityTransitionToExpanded:NO];
    [self beginPlayerAppearanceTransition:NO animated:shouldAnimate];
    _player.presented = NO;
    // Before the animation, not in its completion: the strip has to be on its
    // way in while the card is still travelling down over it, or it pops in a
    // beat after the card has already landed.
    [self refreshMiniPlayer];
    [self animateCardAnimated:shouldAnimate changes:^{
        self->_player.view.transform = [self minimizedCardTransform];
        [self applyBackdropProgress:1];
    } completion:^{
        self->_player.view.hidden = YES;
        [self finishPlayerAppearanceTransition];
        [self completeAccessibilityTransitionToExpanded:NO
                                             generation:accessibilityGeneration];
    }];
}

// TRAP: the card moves by TRANSFORM and never by frame. Its pages carry
// WaveformScrubberViews, and a scrubber tears down its baked envelope bitmap
// and re-bakes it (0.6s later) on any bounds change — over a layer tree twice
// the view's width. Animating the card's frame would pay that on every
// single expand, on every page.
//
// This is also the one place that knows the card is in motion, so the backdrop's
// visibility is bracketed here rather than at each caller.
- (void)animateCardAnimated:(BOOL)animated
                    changes:(void (^)(void))changes
                 completion:(void (^)(void))completion {
    [self interruptCardAnimationPreservingVisualState];
    _cardAnimating = YES;
    [self updateBackdropVisibility];
    if (!animated) {
        changes();
        _cardAnimating = NO;
        [self updateBackdropVisibility];
        completion();
        return;
    }
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
        [self updateBackdropVisibility];
        completion();
    }];
    [animator startAnimation];
}

// A second intent can arrive while the first spring is still on screen. Freeze
// at the presentation transform, cancel the stale completion, and balance the
// appearance pair before beginning the opposite transition.
- (void)interruptCardAnimationPreservingVisualState {
    if (!_cardAnimator) {
        return;
    }
    CALayer *presentation = _player.view.layer.presentationLayer;
    CGAffineTransform visibleTransform = presentation
            ? presentation.affineTransform
            : _player.view.transform;
    UIViewPropertyAnimator *animator = _cardAnimator;
    _cardAnimator = nil;
    [animator stopAnimation:YES];
    _player.view.transform = visibleTransform;
    CGFloat height = MAX(1, self.view.bounds.size.height);
    [self applyBackdropProgress:visibleTransform.ty / height];
    _cardAnimating = NO;
    [self updateBackdropVisibility];
    [self finishPlayerAppearanceTransition];
}

- (void)finishPlayerAppearanceTransition {
    if (!_playerAppearanceTransitionActive) {
        return;
    }
    _playerAppearanceTransitionActive = NO;
    [_player endAppearanceTransition];
}

// A card that has fully ARRIVED covers every pixel the tabs could draw, so they
// are hidden for as long as it does. Left visible they stay a full-screen
// subtree carrying a scale transform and a 38pt corner mask, which the render
// server composites on every frame of every rotation — measured on device as
// offscreen passes inside 6 of 8 rotation hitches.
//
// The claim that nothing shows through rests on two constants together: the
// card's own corners are cut to kCardCornerRadius (14pt), revealing this
// controller's black background, and the tabs are inset well inside that by
// kBackdropScale (0.92, so 16pt horizontally on an iPhone). Raise the scale to
// 1 and the corner wedges would show the tabs instead.
//
// Hidden only when the card is at rest: both its animation and the interactive
// drag reveal what is behind it, and either can be in flight while `_expanded`
// is already YES.
- (void)updateBackdropVisibility {
    BOOL hidden = _expanded && !_cardAnimating && !_interactiveDrag;
    if (_tabs.view.hidden != hidden) {
        _tabs.view.hidden = hidden;
    }
    [self syncTabSurfaces];
}

// 0 is the card fully up (the screen behind it scaled back), 1 is the card
// fully away. Interpolated rather than switched, so a drag moves the backdrop
// with the finger instead of snapping at the commit.
- (void)applyBackdropProgress:(CGFloat)progress {
    CGFloat t = MAX(0, MIN(1, progress));
    CGFloat scale = kBackdropScale + (1 - kBackdropScale) * t;
    _tabs.view.transform = CGAffineTransformMakeScale(scale, scale);
    _tabs.view.layer.cornerRadius = kBackdropCornerRadius * (1 - t);
    _tabs.view.layer.masksToBounds = t < 1;
}

#pragma mark - The interactive minimize

// The card reports the drag in points; this is where it becomes geometry. The
// card keeps `presented` for the whole gesture — it is still on screen, and a
// cancelled drag must not have stopped its display link on the way.
- (void)playerViewController:(PlayerViewController *)controller
       didPanWithTranslation:(CGFloat)translation
                    velocity:(CGFloat)velocity
                       state:(UIGestureRecognizerState)state {
    if (!_expanded) {
        return;
    }
    CGFloat height = MAX(1, self.view.bounds.size.height);
    switch (state) {
        case UIGestureRecognizerStateBegan:
            [self interruptCardAnimationPreservingVisualState];
            // Fall through: the first drag frame uses the same geometry as the
            // rest of the gesture.
        case UIGestureRecognizerStateChanged:
            // The finger is about to move the card off what it covers, so the
            // tabs have to be back before the first frame of travel.
            _interactiveDrag = YES;
            [self updateBackdropVisibility];
            _player.view.transform = CGAffineTransformMakeTranslation(0, translation);
            [self applyBackdropProgress:translation / height];
            break;
        case UIGestureRecognizerStateEnded:
            // Cleared BEFORE the settle, so the animation that follows owns the
            // visibility through _cardAnimating and its completion can hide the
            // backdrop again.
            _interactiveDrag = NO;
            if (translation > height * kDismissTravelFraction || velocity > kDismissFlickVelocity) {
                [self minimizePlayerAnimated:YES];
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
        self->_player.view.transform = CGAffineTransformIdentity;
        [self applyBackdropProgress:0];
    } completion:^{
        // A drag can interrupt the original expand animation before its
        // accessibility completion moves focus off the now-hidden mini player.
        // Landing back at the expanded card owns that same completion edge.
        [self completeAccessibilityTransitionToExpanded:YES
                                              generation:self->_accessibilityPresentationGeneration];
    }];
}

#pragma mark - Tabs

- (void)tabBarController:(UITabBarController *)tabBarController
 didSelectViewController:(UIViewController *)viewController {
    [self syncTabSurfaces];
}

// UISearchTab's identifier is UIKit's, not ours, so it is matched by kind —
// the two we mint are matched by the identifiers we gave them.
- (NSString *)selectedTabIdentifier {
    UITab *selected = _tabs.selectedTab;
    if ([selected isKindOfClass:UISearchTab.class]) {
        return kTabSearch;
    }
    return selected.identifier ?: kTabPlaylist;
}

- (void)setSelectedTabIdentifier:(NSString *)identifier {
    BOOL wantsSearch = [identifier isEqualToString:kTabSearch];
    for (UITab *tab in _tabs.tabs) {
        BOOL isSearch = [tab isKindOfClass:UISearchTab.class];
        if (wantsSearch ? isSearch : [tab.identifier isEqualToString:identifier]) {
            _tabs.selectedTab = tab;
            [self syncTabSurfaces];
            return;
        }
    }
}

#pragma mark - PlayerViewControllerDelegate

- (void)playerViewControllerDidRequestMinimize:(PlayerViewController *)controller {
    [self minimizePlayerAnimated:YES];
}

#pragma mark - MiniPlayerViewDelegate

- (void)miniPlayerViewDidRequestExpand:(MiniPlayerView *)view {
    [self expandPlayerAnimated:YES];
}

- (void)miniPlayerViewDidTapPlayPause:(MiniPlayerView *)view {
    [_playback playPause];
}

- (void)miniPlayerViewDidTapNext:(MiniPlayerView *)view {
    [_playback next];
}

#pragma mark - PlaybackObserver

- (void)playbackDidReplacePlaylist:(PlaybackController *)playback {
    [self refreshMiniPlayer];
}

// An open is a deliberate act with a result worth showing, so it presents the
// card — the one place that happens by itself. A relaunch restore sends no
// such event and stays minimized: nothing was asked for.
//
// It brings the Playlist tab forward too, so minimizing the card lands on what
// was just opened rather than back in the Files browser or the Favorites list.
// Search is the one exception: UISearchTab owns the selection while its field
// is up — it restores the previous tab on cancel — and its results are where
// the next pick comes from anyway.
- (void)playbackDidOpenNewFolder:(PlaybackController *)playback {
    [self bringPlaylistTabForward];
    [self expandPlayerAnimated:YES];
}

// A pick that found no audio still has to say so, and the only thing that says
// it is the Playlist tab's empty state — so the answer has to be brought to
// wherever the pick was made. Without this a favorite whose folder has emptied
// since it was starred, or an empty folder opened from Files, produces nothing
// visible at all. No card: there is nothing to show on it.
- (void)playbackDidOpenEmptyFolder:(PlaybackController *)playback {
    [self bringPlaylistTabForward];
}

- (void)bringPlaylistTabForward {
    if (![_tabs.selectedTab isKindOfClass:UISearchTab.class]) {
        [self setSelectedTabIdentifier:kTabPlaylist];
    }
}

- (void)playbackDidMoveToCurrentTrack:(PlaybackController *)playback animated:(BOOL)animated {
    [self refreshMiniPlayer];
}

- (void)playbackDidRenderCurrentTrack:(PlaybackController *)playback {
    [self refreshMiniPlayer];
}

- (void)playbackDidChangePlayState:(PlaybackController *)playback {
    [self refreshMiniPlayer];
}

- (void)playback:(PlaybackController *)playback didLoadMetadataForTrack:(AudioTrack *)track {
    if ([playback.playlist isCurrentTrack:track]) {
        [_miniPlayer renderTrack:playback.displayedTrack];
    }
}

@end
