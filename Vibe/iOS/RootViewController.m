//
//  RootViewController.m
//  Vibe (iOS)
//

#import "RootViewController.h"

#import "AudioTrack.h"
#import "AudioTrackMetadata.h"
#import "FavoritesViewController.h"
#import "BrowserViewController.h"
#import "LibraryViewController.h"
#import "MiniPlayerView.h"
#import "PlaybackController.h"
#import "PlayerScreenRules.h"
#import "PlayerViewController.h"
#import "Playlist.h"
#import "SearchViewController.h"
#import "VibeStrings.h"

// Apple Music's proportions.
static const CGFloat kCardCornerRadius = 14;
static const CGFloat kBackdropScale = 0.92;
static const CGFloat kBackdropCornerRadius = 38;

// Either alone commits a downward drag.
static const CGFloat kDismissTravelFraction = 0.25;
static const CGFloat kDismissFlickVelocity = 900;

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
    // What scales under a moving card: a snapshot of the tabs, never the tabs
    // themselves (applyBackdropProgress:). Present only while the card moves.
    UIView               *_backdropSnapshot;
    BrowserViewController *_filesController;
    FavoritesViewController *_favorites;
    LibraryViewController *_library;
    SearchViewController *_searchController;
    MiniPlayerView       *_miniPlayer;
    PlayerViewController *_player;
    BOOL                 _expanded;
    // Whether the accessory is installed.
    BOOL                 _miniWanted;
    // The card between up and away; see updateBackdropVisibility.
    BOOL                 _cardAnimating;
    BOOL                 _interactiveDrag;
    UIViewPropertyAnimator *_cardAnimator;
    // Rows of Adds asked for and not yet settled, oldest first, and when
    // each was lifted.
    NSMutableArray<NSArray<UIView *> *> *_liftedRowBatches;
    NSMutableArray<NSNumber *> *_liftedRowBatchTimes;
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

- (UITabBarController *)tabs {
    return _tabs;
}

- (UIView *)miniPlayerView {
    return _miniPlayer;
}

- (UIView *)backdropSnapshot {
    return _backdropSnapshot;
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
    // Shows through the card's rounded corners.
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

// Lazy providers, so a tab never visited costs nothing; the Files browser is
// not cheap.
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
        // The empty state's Open; the library knows nothing about tabs.
        library.openFilesHandler = ^{
            [weakSelf setSelectedTabIdentifier:kTabFiles];
        };
        [root syncTabSurfaces];
        return [[UINavigationController alloc] initWithRootViewController:library];
    }];

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
        starred.showDirectoryHandler = ^(NSURL *directory) {
            [weakSelf showDirectoryInFiles:directory highlighting:nil];
        };
        return [[UINavigationController alloc] initWithRootViewController:starred];
    }];

    UITab *files = [[UITab alloc] initWithTitle:STR_TAB_FILES
                                          image:[UIImage systemImageNamed:@"folder"]
                                     identifier:kTabFiles
                         viewControllerProvider:^UIViewController *(__kindof UITab *tab) {
        RootViewController *root = weakSelf;
        if (!root) {
            return nil;
        }
        BrowserViewController *browser = [[BrowserViewController alloc] initWithPlayback:root->_playback
                                                                            directoryURL:nil
                                                                               appending:NO];
        root->_filesController = browser;
        browser.addedRowsHandler = ^(NSArray<UIView *> *rows) {
            [weakSelf liftAddedRows:rows];
        };
        return [[UINavigationController alloc] initWithRootViewController:browser];
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
        results.showDirectoryHandler = ^(NSURL *directory, NSURL *file) {
            [weakSelf showDirectoryInFiles:directory highlighting:file];
        };
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
    // Built minimized; the manual appearance forwarding below keeps its
    // viewWillAppear: from firing just because it is in the hierarchy.
    _player.view.transform = [self minimizedCardTransform];
    _player.view.hidden = YES;
    _player.view.accessibilityViewIsModal = NO;
    _player.presented = NO;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_expanded) {
        // The offset is the view's height, which a rotation or resize moves.
        _player.view.transform = [self minimizedCardTransform];
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
    // An interactive transition can reverse before its did-callback, so close
    // any open pair, then snapshot the children: `_expanded` may change before
    // the matching end.
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

// What no descendant can know: scene activity and whether the card leaves the
// selected tab exposed.
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

// TRAP: the strip stays installed under the card. Taking the accessory away
// on expand shrinks every tab's bottom inset by the strip, a list scrolled
// to its end is clamped up by that much under the snapshot, and putting it
// back on dismiss moves nothing: one card cycle left the last row behind
// the strip. The card hides the tabs, strip included, so it costs nothing.
- (void)refreshMiniPlayer {
    BOOL wanted = VibeMiniPlayerVisible(_playback.screenState);
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

#pragma mark - Expanding and minimizing

- (BOOL)shouldAnimateCard:(BOOL)requested {
    return requested && !UIAccessibilityIsReduceMotionEnabled();
}

- (void)beginPlayerAppearanceTransition:(BOOL)appearing animated:(BOOL)animated {
    if (!_rootPresentationVisible) {
        return;
    }
    // A card intent can land between this container's will/did; appearance
    // transitions cannot nest, so end the parent's pair first.
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
        // Not a presentation, so UIKit cannot infer the modal surface.
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

// TRAP: the card moves by TRANSFORM, never by frame: a WaveformScrubberView
// tears down and re-bakes its envelope bitmap on any bounds change, which a
// frame animation would pay on every expand, on every page.
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
        // A drag may have left a snapshot up.
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
    // The snapshot stays: the intent that interrupted is about to animate.
    [self finishPlayerAppearanceTransition];
}

- (void)finishPlayerAppearanceTransition {
    if (!_playerAppearanceTransitionActive) {
        return;
    }
    _playerAppearanceTransitionActive = NO;
    [_player endAppearanceTransition];
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
            // Fall through.
        case UIGestureRecognizerStateChanged:
            _interactiveDrag = YES;
            [self beginBackdropSnapshot];
            _player.view.transform = CGAffineTransformMakeTranslation(0, translation);
            [self applyBackdropProgress:translation / height];
            break;
        case UIGestureRecognizerStateEnded:
            // Before the settle, whose animation then owns the backdrop.
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
        // A drag can interrupt the expand before its accessibility completion.
        [self completeAccessibilityTransitionToExpanded:YES
                                              generation:self->_accessibilityPresentationGeneration];
    }];
}

#pragma mark - Tabs

// Settings rides the Playlist tab's stack: leaving the tab pops it, so
// coming back shows the playlist, not the screen left open.
- (void)tabBarController:(UITabBarController *)tabBarController
            didSelectTab:(UITab *)selectedTab
             previousTab:(UITab *)previousTab {
    if (selectedTab != previousTab && [previousTab.identifier isEqualToString:kTabPlaylist]
            && [previousTab.viewController isKindOfClass:UINavigationController.class]) {
        [(UINavigationController *)previousTab.viewController popToRootViewControllerAnimated:NO];
    }
    [self syncTabSurfaces];
}

// The stack is built before the tab shows, so the tab arrives on the folder
// rather than on its old screen and then jumping.
- (void)showDirectoryInFiles:(NSURL *)directory highlighting:(NSURL *)file {
    // A tab's controller is built on first ask: one never visited has none yet.
    (void)[_tabs tabForIdentifier:kTabFiles].viewController;
    [_filesController showDirectory:directory highlighting:file];
    [self setSelectedTabIdentifier:kTabFiles];
}

// UISearchTab's identifier is UIKit's, so it is matched by kind.
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
    // An Add onto nothing became an open: the card says so.
    for (NSArray<UIView *> *rows in [_liftedRowBatches copy]) {
        [self settleLiftedRows:rows landed:NO];
    }
}

// Every Add ends here; the oldest lift is its.
- (void)playback:(PlaybackController *)playback didSettleAddLanding:(BOOL)landed {
    if (_liftedRowBatches.count > 0) {
        [self settleLiftedRows:_liftedRowBatches.firstObject landed:landed];
    }
}

#pragma mark - Added rows

// An Add in the Files tab changes nothing on its own screen, so its rows say
// what happened: they lift when asked for, fly into the Playlist tab when the
// tracks land, and set back down when nothing did (all already there, or a
// folder with no songs directly inside). Every Add ends in a settle event,
// so there is no timer: a lift that outlives its Add is a bug, and
// check_consistency reports one (liftedRowTimes).
static const NSTimeInterval kRowLiftDuration = 0.25;
static const NSTimeInterval kRowFlightDuration = 0.7;
static const NSTimeInterval kRowFlightStagger = 0.07;
static const CGFloat kLiftedRowScale = 1.03;
static const CGFloat kLandedRowScale = 0.1;

- (void)liftAddedRows:(NSArray<UIView *> *)rows {
    if (rows.count == 0) {
        return;
    }
    if (!_liftedRowBatches) {
        _liftedRowBatches = [NSMutableArray array];
        _liftedRowBatchTimes = [NSMutableArray array];
    }
    [_liftedRowBatches addObject:rows];
    [_liftedRowBatchTimes addObject:@(CACurrentMediaTime())];
    for (UIView *row in rows) {
        row.frame = [self.view convertRect:row.frame fromView:nil];
        row.userInteractionEnabled = NO;
        row.layer.shadowOpacity = 0.25f;
        row.layer.shadowRadius = 12;
        row.layer.shadowOffset = CGSizeMake(0, 4);
        // Without a path the shadow is re-derived from the snapshot's pixels
        // on every frame of the flight.
        row.layer.shadowPath = [UIBezierPath bezierPathWithRect:row.bounds].CGPath;
        [self.view addSubview:row];
    }
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        [UIView animateWithDuration:kRowLiftDuration delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction animations:^{
            for (UIView *row in rows) {
                row.transform = CGAffineTransformMakeScale(kLiftedRowScale, kLiftedRowScale);
            }
        } completion:nil];
    }
}

- (NSArray<NSNumber *> *)liftedRowTimes {
    return [_liftedRowBatchTimes copy] ?: @[];
}

- (void)settleLiftedRows:(NSArray<UIView *> *)rows landed:(BOOL)landed {
    NSUInteger index = [_liftedRowBatches indexOfObjectIdenticalTo:rows];
    if (index == NSNotFound) {
        return;   // already settled
    }
    CFTimeInterval liftedAt = _liftedRowBatchTimes[index].doubleValue;
    [_liftedRowBatches removeObjectAtIndex:index];
    [_liftedRowBatchTimes removeObjectAtIndex:index];
    CGPoint target = CGPointZero;
    if (!landed || UIAccessibilityIsReduceMotionEnabled() || ![self getPlaylistTabCenter:&target]) {
        [UIView animateWithDuration:0.2 animations:^{
            for (UIView *row in rows) {
                row.transform = CGAffineTransformIdentity;
                row.alpha = 0;
            }
        } completion:^(BOOL finished) {
            [rows makeObjectsPerformSelector:@selector(removeFromSuperview)];
        }];
        if (landed) {
            [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
        }
        return;
    }
    // A local Add lands within a frame or two: the flight waits out the lift,
    // or it would cut the lift short and start with a jump.
    NSTimeInterval wait = MAX(0, liftedAt + kRowLiftDuration - CACurrentMediaTime());
    // A UIKit animation, not a CAAnimation added to the layer. An
    // iPhone caps an app's own CAAnimations at 60 Hz unless its Info.plist
    // opts out, while UIKit's run at the display's rate, so on a 120 Hz
    // phone the hand-built flight stuttered beside the swipe it followed.
    UIViewKeyframeAnimationOptions options = UIViewKeyframeAnimationOptionCalculationModeCubic
            | (UIViewKeyframeAnimationOptions)UIViewAnimationOptionCurveEaseInOut;
    CGFloat midScale = (kLiftedRowScale + kLandedRowScale) / 2;
    [rows enumerateObjectsUsingBlock:^(UIView *row, NSUInteger i, BOOL *stop) {
        // Across, then down into the tab: the midpoint of the curve whose
        // control point is the tab's column at the row's height.
        CGPoint start = row.center;
        CGPoint mid = CGPointMake(0.25 * start.x + 0.75 * target.x, 0.75 * start.y + 0.25 * target.y);
        [UIView animateKeyframesWithDuration:kRowFlightDuration
                                       delay:wait + (NSTimeInterval)i * kRowFlightStagger
                                     options:options
                                  animations:^{
            [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.5 animations:^{
                row.center = mid;
                row.transform = CGAffineTransformMakeScale(midScale, midScale);
            }];
            [UIView addKeyframeWithRelativeStartTime:0.5 relativeDuration:0.5 animations:^{
                row.center = target;
                row.transform = CGAffineTransformMakeScale(kLandedRowScale, kLandedRowScale);
            }];
            // Solid for most of the way, gone as it reaches the tab.
            [UIView addKeyframeWithRelativeStartTime:0.7 relativeDuration:0.3 animations:^{
                row.alpha = 0;
            }];
        } completion:^(BOOL finished) {
            [row removeFromSuperview];
            if (i == 0) {
                [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
            }
        }];
    }];
}

// The Playlist tab's item, in this view. UITab has no view of its own, so the
// bar's is found by the label it draws; a bar that is not on screen (the
// iPad's is elsewhere), or one drawn without that label, answers NO and the
// rows fade where they are.
- (BOOL)getPlaylistTabCenter:(CGPoint *)center {
    UITabBar *bar = _tabs.tabBar;
    NSString *title = [_tabs tabForIdentifier:kTabPlaylist].title;
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

// The only place the card presents by itself. The Playlist tab comes forward
// so minimizing lands on what was opened — except over Search, whose tab owns
// the selection while its field is up, and except a single file played
// alone — one track, no folder — whose tab stays where it was picked, so
// minimizing lands back in the browser rather than on a one-row playlist.
- (void)playbackDidOpenNewFolder:(PlaybackController *)playback {
    if (playback.playlist.count > 1 || playback.folderURL) {
        [self bringPlaylistTabForward];
    }
    [self expandPlayerAnimated:YES];
}

// Only the Playlist tab's empty state says a pick found no audio, so the tab
// comes forward only over an empty playlist. An open supersedes every Add in
// flight whatever it found, so their lifted rows settle here as they do on
// a replace that landed.
- (void)playbackDidOpenEmptyFolder:(PlaybackController *)playback {
    if (playback.playlist.count == 0) {
        [self bringPlaylistTabForward];
    }
    for (NSArray<UIView *> *rows in [_liftedRowBatches copy]) {
        [self settleLiftedRows:rows landed:NO];
    }
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
