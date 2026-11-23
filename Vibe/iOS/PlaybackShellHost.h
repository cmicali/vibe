//
//  PlaybackShellHost.h
//  Vibe (iOS)
//
//  Vibe's side of the tab shell: it builds the tabs and the card, fills the
//  mini player from PlaybackController, and answers the shell's delegate.
//  What the model says the shell does (an open brings the Playlist tab
//  forward, an Add's rows fly into it) is decided here.
//

#import <UIKit/UIKit.h>

@class PlaybackController;
@class RootViewController;

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackShellHost : NSObject

- (instancetype)initWithPlayback:(PlaybackController *)playback NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// The scene's root. It holds this host weakly, so the scene delegate keeps it.
@property (nonatomic, readonly) RootViewController *root;
@property (nonatomic, readonly) PlaybackController *playback;

// The widget's playlist button. The card goes down and the Playlist tab shows
// its list, not Settings. It replaces Search too, because the user asked for
// the playlist. It does nothing while a sheet or alert is up.
- (void)showPlaylist;

@end

NS_ASSUME_NONNULL_END
