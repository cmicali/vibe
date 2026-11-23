//
//  RootViewController.h
//  Vibe (iOS)
//
//  The scene's root: the tabs, the mini player in their bottomAccessory, and
//  the now-playing card above them. It owns presentation only. The app hands
//  it the tabs and the card, pushes the strip's row, and hears every event
//  through the delegate.
//
//  A container, not a UITabBarController subclass, so the card and the
//  backdrop snapshot can sit above the tabs' whole view.
//
//  The card is built once and never torn down. Minimizing translates it off
//  the bottom, so its pager, art and waveform snapshots survive.
//

#import <UIKit/UIKit.h>

@class MiniPlayerView;
@class RootViewController;
@class VibeTrackRow;

NS_ASSUME_NONNULL_BEGIN

// What the root needs of the card: whether it is presented, and whether the
// scene is foreground-active.
@protocol RootViewControllerCard <NSObject>
@property (nonatomic, getter=isPresented) BOOL presented;
@property (nonatomic, getter=isSceneActive) BOOL sceneActive;
@end

@protocol RootViewControllerDelegate <NSObject>

// The view, the tabs and the card are built. The card has loaded its view,
// so an observer registered here hears each event after the card.
- (void)rootViewControllerDidLoad:(RootViewController *)root;
// Asked on every expand. NO keeps the card down.
- (BOOL)rootViewControllerCanExpandCard:(RootViewController *)root;
- (void)rootViewControllerDidTapPlayPause:(RootViewController *)root;
- (void)rootViewControllerDidTapNext:(RootViewController *)root;
- (void)rootViewController:(RootViewController *)root
              didSelectTab:(UITab *)selectedTab
               previousTab:(nullable UITab *)previousTab;
// tabsExposed, cardAtRest or the selected tab may have changed. It is sent
// often, and the delegate pushes what its screens need.
- (void)rootViewControllerDidChangeExposure:(RootViewController *)root;

@end

@interface RootViewController : UIViewController

// `tabs` hold their view controllers behind lazy providers, and at most one
// is a UISearchTab. The card's view is installed above them, minimized.
- (instancetype)initWithTabs:(NSArray<UITab *> *)tabs
                        card:(UIViewController<RootViewControllerCard> *)card NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, weak, nullable) id<RootViewControllerDelegate> delegate;

// Foreground-active, from the scene delegate; forwarded to the card.
@property (nonatomic, getter=isSceneActive) BOOL sceneActive;

@property (nonatomic, readonly) UITabBarController *tabs;
// The strip's view; the app sets its VoiceOver labels and renders a row into
// it as a row's art arrives.
@property (nonatomic, readonly) MiniPlayerView *miniPlayer;
// The snapshot that scales over the tabs while the card moves; nil at rest.
@property (nonatomic, readonly, nullable) UIView *backdropSnapshot;

// The strip shows `row`, or goes away for nil. Push it from the delegate's
// rootViewControllerDidLoad: on.
- (void)setMiniPlayerRow:(nullable VibeTrackRow *)row playing:(BOOL)playing;
@property (nonatomic, readonly, getter=isMiniPlayerShown) BOOL miniPlayerShown;

// The scene is foreground-active, the root is on screen, and the card at rest
// does not cover the tabs.
@property (nonatomic, readonly) BOOL tabsExposed;
// The card is down and still: neither moving nor dragged.
@property (nonatomic, readonly) BOOL cardAtRest;

// The selected tab's identifier. A UISearchTab's is UIKit's. Setting an
// identifier no tab has does nothing.
@property (nonatomic, copy) NSString *selectedTabIdentifier;
// The bar's item for the tab, in this view; NO when the bar does not show it.
- (BOOL)getCenterOfTabWithIdentifier:(NSString *)identifier center:(CGPoint *)center;

@property (nonatomic, readonly, getter=isCardExpanded) BOOL cardExpanded;
- (void)expandCardAnimated:(BOOL)animated;
- (void)minimizeCardAnimated:(BOOL)animated;
// The card's downward drag, as its pan recognizer reports it.
- (void)cardDidPanWithTranslation:(CGFloat)translation
                         velocity:(CGFloat)velocity
                            state:(UIGestureRecognizerState)state;

@end

NS_ASSUME_NONNULL_END
