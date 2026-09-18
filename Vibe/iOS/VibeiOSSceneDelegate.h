//
//  VibeiOSSceneDelegate.h
//  Vibe (iOS)
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface VibeiOSSceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (nonatomic, strong) UIWindow *window;

// The scene's model, exposed for the widget's App Intents alone. They are
// AudioPlaybackIntents, so the system performs them in THIS process — but
// outside any scene, so they have no other way in. It stays a scene property
// rather than becoming a global on PlaybackController: the scene owns the one
// engine (`CLAUDE.md`), and a global accessor would quietly say otherwise.
@property (nonatomic, readonly, nullable) PlaybackController *playback;

// The connected scene's controller, or nil when the app was launched with no
// scene at all. An intent that gets nil opens the app rather than guessing.
+ (nullable PlaybackController *)connectedPlayback;

@end

NS_ASSUME_NONNULL_END
