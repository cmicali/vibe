//
//  RootViewController.m
//  Vibe (iOS)
//
//  See RootViewController.h.
//

#import "RootViewController.h"

#import "AudioTrack.h"
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

// The breathing room between the mini strip and the tab bar below it, which
// the Files browser's own bar has to clear along with the strip itself.
static const CGFloat kMiniAccessoryGap = 8;

static NSString *const kTabPlaylist = @"playlist";
static NSString *const kTabFiles = @"files";
static NSString *const kTabSearch = @"search";

@interface RootViewController () <PlaybackObserver, MiniPlayerViewDelegate,
        PlayerViewControllerDelegate>
@end

@implementation RootViewController {
    UITabBarController   *_tabs;
    UITab                *_filesTab;
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

- (void)viewDidLoad {
    [super viewDidLoad];
    // The card's rounded corners cut to this, so it has to be the colour the
    // corners should read as.
    self.view.backgroundColor = UIColor.blackColor;

    [self buildTabs];
    [self buildMiniPlayer];
    [self buildCard];

    [_playback addObserver:self];
    [self refreshMiniPlayer];
}

// The iOS 26 tab shape, and Apple Music's: two tabs in the capsule and search
// as a circle beside it rather than a third tab inside it. UISearchTab is what
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
        LibraryViewController *library =
                [[LibraryViewController alloc] initWithPlayback:root.playback];
        return [[UINavigationController alloc] initWithRootViewController:library];
    }];

    // No navigation controller: the browser brings its own bar and its own
    // hierarchy, and wrapping it in a second one stacks two.
    _filesTab = [[UITab alloc] initWithTitle:STR_TAB_FILES
                                          image:[UIImage systemImageNamed:@"folder"]
                                     identifier:kTabFiles
                         viewControllerProvider:^UIViewController *(__kindof UITab *tab) {
        RootViewController *root = weakSelf;
        return [[FilesViewController alloc] initWithPlayback:root.playback];
    }];
    UITab *files = _filesTab;

    UISearchTab *search = [[UISearchTab alloc] initWithViewControllerProvider:
            ^UIViewController *(__kindof UITab *tab) {
        RootViewController *root = weakSelf;
        SearchViewController *results =
                [[SearchViewController alloc] initWithPlayback:root.playback];
        return [[UINavigationController alloc] initWithRootViewController:results];
    }];
    search.automaticallyActivatesSearch = YES;

    _tabs = [[UITabBarController alloc] init];
    _tabs.tabs = @[playlist, files, search];

    [self addChildViewController:_tabs];
    _tabs.view.frame = self.view.bounds;
    _tabs.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tabs.view.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:_tabs.view];
    [_tabs didMoveToParentViewController:self];
}

- (void)buildMiniPlayer {
    _miniPlayer = [[MiniPlayerView alloc] initWithFrame:CGRectZero];
    _miniPlayer.delegate = self;
}

- (void)buildCard {
    _player = [[PlayerViewController alloc] initWithPlayback:_playback];
    _player.delegate = self;
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
    _player.presented = NO;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_expanded) {
        // The offset is the view's own height, which a rotation or an iPad
        // resize changes under a minimized card.
        _player.view.transform = [self minimizedCardTransform];
    }
    // A tab's view controller is built the first time it is shown, which can
    // be long after the strip appeared, so the inset is applied on arrival
    // too, not only when the strip's visibility changes.
    [self applyFilesBottomInset];
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    for (UIViewController *child in [self appearingChildren]) {
        [child beginAppearanceTransition:YES animated:animated];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    for (UIViewController *child in [self appearingChildren]) {
        [child endAppearanceTransition];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    for (UIViewController *child in [self appearingChildren]) {
        [child beginAppearanceTransition:NO animated:animated];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    for (UIViewController *child in [self appearingChildren]) {
        [child endAppearanceTransition];
    }
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
    [_tabs setBottomAccessory:accessory animated:YES];
    [self applyFilesBottomInset];
}

// The Files browser draws its OWN bottom bar (Recents / Shared / Browse) and
// places it against its safe area. UIKit's tab children are inset for the tab
// bar but not for the accessory, so with the strip up the browser's bar ends
// up half underneath it. A scroll view would never show this — it just gets
// extra content inset — which is why only this tab needs telling.
//
// Measured off the live accessory rather than assumed, so a system height
// change does not silently reopen the overlap.
- (void)applyFilesBottomInset {
    UIViewController *files = _filesTab.viewController;
    if (!files) {
        return;   // never visited; the provider will build it inset-free and
                  // the next refresh corrects it
    }
    CGFloat accessoryHeight = _miniPlayer.superview
            ? CGRectGetHeight(_miniPlayer.superview.frame)
            : CGRectGetHeight(_miniPlayer.frame);
    CGFloat wanted = _miniWanted ? accessoryHeight + kMiniAccessoryGap : 0;
    UIEdgeInsets insets = files.additionalSafeAreaInsets;
    if (fabs(insets.bottom - wanted) < 0.5) {
        return;
    }
    insets.bottom = wanted;
    files.additionalSafeAreaInsets = insets;
}

#pragma mark - Expanding and minimizing

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
    _expanded = YES;
    _player.view.hidden = NO;
    [_player beginAppearanceTransition:YES animated:animated];
    _playerAppearanceTransitionActive = YES;
    _player.presented = YES;
    [self refreshMiniPlayer];
    [self animateCardAnimated:animated changes:^{
        self->_player.view.transform = CGAffineTransformIdentity;
        [self applyBackdropProgress:0];
    } completion:^{
        [self finishPlayerAppearanceTransition];
    }];
}

- (void)minimizePlayerAnimated:(BOOL)animated {
    if (!_expanded) {
        return;
    }
    [self interruptCardAnimationPreservingVisualState];
    _expanded = NO;
    [_player beginAppearanceTransition:NO animated:animated];
    _playerAppearanceTransitionActive = YES;
    _player.presented = NO;
    // Before the animation, not in its completion: the strip has to be on its
    // way in while the card is still travelling down over it, or it pops in a
    // beat after the card has already landed.
    [self refreshMiniPlayer];
    [self animateCardAnimated:animated changes:^{
        self->_player.view.transform = [self minimizedCardTransform];
        [self applyBackdropProgress:1];
    } completion:^{
        self->_player.view.hidden = YES;
        [self finishPlayerAppearanceTransition];
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
    [_player endAppearanceTransition];
    _playerAppearanceTransitionActive = NO;
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
    [self animateCardAnimated:YES changes:^{
        self->_player.view.transform = CGAffineTransformIdentity;
        [self applyBackdropProgress:0];
    } completion:^{}];
}

#pragma mark - Tabs

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
- (void)playbackDidOpenNewFolder:(PlaybackController *)playback {
    [self expandPlayerAnimated:YES];
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
