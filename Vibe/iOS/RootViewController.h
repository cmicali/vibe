//
//  RootViewController.h
//  Vibe (iOS)
//
//  The scene's root: Playlist and Files tabs, UIKit's separate search tab, the
//  mini player in the tab bar's bottomAccessory, and the full-screen
//  now-playing card above them. The scene owns playback; this container borrows
//  it and owns only presentation.
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

NS_ASSUME_NONNULL_BEGIN

@interface RootViewController : UIViewController

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// Foreground-active, supplied by the scene delegate. The root combines this
// with presentation visibility for the Library, and forwards the exact same
// fact to the card's display-link gate.
@property (nonatomic, getter=isSceneActive) BOOL sceneActive;

@end

NS_ASSUME_NONNULL_END
