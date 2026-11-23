//
//  FilesRootViewController.h
//  Vibe (iOS)
//
//  The Files tab's root, and the Playlist tab's add sheet. It is the
//  browser's root with Vibe's host (PlaybackBrowserHost) and Vibe's groups
//  below Locations: Recents, Choose File…, Open URL…, and the paste row.
//  Choose File… is the system file picker, for a one-off pick outside the
//  Locations.
//
//  Every open goes through PlaybackController's roads, so nothing about
//  opening is reimplemented here.
//

#import "BrowserRootViewController.h"

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface FilesRootViewController : BrowserRootViewController

// Appending is the add sheet: every action appends, and the sheet closes
// after it.
- (instancetype)initWithPlayback:(PlaybackController *)playback
                       appending:(BOOL)appending NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithHost:(id<VibeBrowserHost>)host NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
