//
//  PlaybackBrowserHost.h
//  Vibe (iOS)
//
//  The browser's host over PlaybackController: one per stack of folder
//  screens. Its actions are the Files tab's, or the add sheet's when
//  appending, where every action adds and closes the sheet. Every open goes
//  through PlaybackController's roads.
//

#import "VibeBrowserHost.h"

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface PlaybackBrowserHost : NSObject <VibeBrowserPlaybackHost>

- (instancetype)initWithPlayback:(PlaybackController *)playback appending:(BOOL)appending NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// A replace: a file alone, a file with its folder, a folder, or a pick of
// several. In the add sheet the same pick is added.
- (void)openURLs:(NSArray<NSURL *> *)urls inFolder:(BOOL)inFolder fromScreen:(UIViewController *)screen;

@end

NS_ASSUME_NONNULL_END
