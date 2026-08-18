//
//  RootViewController.h
//  Vibe (iOS)
//
//  The scene's root, and the app's shape: a tab bar controller (Library,
//  Search) with the mini player in its bottomAccessory, and the full-screen
//  now-playing card above both. It owns the PlaybackController every screen
//  reads, and it is the only thing that knows whether the card is up.
//
//  A CONTAINER, NOT A UITabBarController SUBCLASS. The card has to sit above
//  the tab bar controller's whole view so the underlying screen can scale back
//  behind it, Apple Music-style, and a subclass cannot transform its own view
//  without dragging the card along with it.
//
//  THE CARD IS BUILT ONCE AND NEVER TORN DOWN. Minimizing translates it off
//  the bottom; it is not presented and not dismissed. Its pager, art window
//  and waveform snapshots have to survive a minimize, or every expand pays a
//  re-read and a re-decode of the art that is already in memory.
//

#import <UIKit/UIKit.h>

@class PlaybackController;
@class PlayerViewController;

NS_ASSUME_NONNULL_BEGIN

@interface RootViewController : UIViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property (nonatomic, readonly) PlaybackController *playback;
// Foreground-active, supplied by the scene delegate. The root combines this
// with its own appearance and the card's actual exposure of the tabs before
// allowing the library's equalizer to run.
@property (nonatomic, getter=isSceneActive) BOOL sceneActive;
// The card. Exposed for the debug channel's dump_art, which asks the pager
// about its art window.
@property (nonatomic, readonly) PlayerViewController *player;

@property (nonatomic, readonly, getter=isPlayerExpanded) BOOL playerExpanded;
// Whether the strip is installed in the tab bar's accessory. It never is while
// the card is up.
@property (nonatomic, readonly, getter=isMiniPlayerShown) BOOL miniPlayerShown;
- (void)expandPlayerAnimated:(BOOL)animated;
- (void)minimizePlayerAnimated:(BOOL)animated;

// Which tab is up, by identifier ("library", "search"), for the debug channel.
@property (nonatomic, copy) NSString *selectedTabIdentifier;

@end

NS_ASSUME_NONNULL_END
