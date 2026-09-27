//
//  PlayerViewController.h
//  Vibe (iOS)
//
//  The now-playing card: the track pager and the chrome over it. It observes
//  PlaybackController and owns no playback state.
//

#import <UIKit/UIKit.h>

@class PlaybackController;
@class PlayerViewController;

NS_ASSUME_NONNULL_BEGIN

@protocol PlayerViewControllerDelegate <NSObject>

// The grabber was tapped. The shell owns the animation.
- (void)playerViewControllerDidRequestMinimize:(PlayerViewController *)controller;

// A downward drag, in points; where that puts the card and whether it commits
// is the shell's. Translation is never negative.
- (void)playerViewController:(PlayerViewController *)controller
       didPanWithTranslation:(CGFloat)translation
                    velocity:(CGFloat)velocity
                       state:(UIGestureRecognizerState)state;

@end

@interface PlayerViewController : UIViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// The card is up. Gates the page commit — minimized, a reloadData can settle a
// scroll and change track — and the playhead display link.
@property (nonatomic, getter=isPresented) BOOL presented;

// Foreground-active for this scene. Inactive is off: no display link under
// Control Center or the app switcher.
@property (nonatomic, getter=isSceneActive) BOOL sceneActive;

@property (nonatomic, weak) id<PlayerViewControllerDelegate> delegate;

@end

NS_ASSUME_NONNULL_END
