//
//  PlayerViewController.h
//  Vibe (iOS)
//
//  The now-playing screen: the track pager (one full-screen page per track,
//  blurred art + header) and the chrome over it — the waveform scrubber, the
//  time labels and the transport glyph. It DESCRIBES playback and never owns
//  it: the engine, the playlist, the caches and the sessions belong to the
//  PlaybackController it is given, which it observes.
//

#import <UIKit/UIKit.h>

@class PlaybackController;
@class PlayerViewController;

NS_ASSUME_NONNULL_BEGIN

@protocol PlayerViewControllerDelegate <NSObject>

// The card asked to go back to the strip: the grabber was tapped. The shell
// owns the animation, so the card never moves itself.
- (void)playerViewControllerDidRequestMinimize:(PlayerViewController *)controller;

// A downward drag on the card. The card only says how far down and how fast,
// in points; where that puts the card, and whether it commits, is the shell's.
// Translation is never negative — an upward drag past the top rubber-bands to
// zero rather than lifting the card off the screen.
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

// The card is up. Set by RootViewController around the expand and minimize
// animations, and it gates two things that must not run behind the shell: the
// pager's page commit — a reloadData while minimized can settle a scroll and
// change track under the user — and the playhead's display link, which would
// otherwise animate a waveform nobody can see.
@property (nonatomic, getter=isPresented) BOOL presented;

// Foreground-active for this exact scene, supplied by RootViewController from
// the scene delegate. Foreground-inactive is off: the display link must not run
// under Control Center or the app switcher merely because the scene has not
// entered the background.
@property (nonatomic, getter=isSceneActive) BOOL sceneActive;

@property (nonatomic, weak) id<PlayerViewControllerDelegate> delegate;

@end

NS_ASSUME_NONNULL_END
