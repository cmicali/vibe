//
//  VibeiOSSceneDelegate.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface VibeiOSSceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (nonatomic, strong) UIWindow *window;

// For the widget's App Intents alone: they run in this process but outside
// any scene. A scene property, not a global, because the scene owns the engine.
@property (nonatomic, readonly, nullable) PlaybackController *playback;

// Installs Vibe's VibeWidgetActions, which act on the connected scene.
+ (void)installWidgetActions;

@end

NS_ASSUME_NONNULL_END
