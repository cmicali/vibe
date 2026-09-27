//
//  RootViewController.h
//  Vibe (iOS)
//
//  The scene's root: the tabs, the mini player in their bottomAccessory, and
//  the now-playing card above them. It owns presentation only.
//
//  A container, not a UITabBarController subclass: the tabs' whole view scales
//  back behind the card, and a subclass cannot transform its own view without
//  moving the card too.
//
//  The card is built once and never torn down; minimizing translates it off
//  the bottom, so its pager, art and waveform snapshots survive.
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

// Foreground-active, from the scene delegate; forwarded to the card.
@property (nonatomic, getter=isSceneActive) BOOL sceneActive;

@end

NS_ASSUME_NONNULL_END
