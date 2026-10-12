//
//  BrowserViewController.h
//  Vibe (iOS)
//
//  The Files tab, and the Playlist tab's add sheet: one browser over every
//  place the app can list. The root's Locations are the app's own Documents,
//  Dropbox through its mirror, and each folder the user granted. A directory
//  lists its folders and playable files. The system folder picker's one
//  remaining job is granting a location, from the root's plus. The system
//  file picker stays behind Choose File… for a one-off pick outside them.
//
//  Every open goes through PlaybackController's roads, so nothing about
//  opening is reimplemented here.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface BrowserViewController : UITableViewController

// directoryURL nil is the root's list of sources. Appending is the add
// sheet: every action appends, and the sheet closes after it.
- (instancetype)initWithPlayback:(PlaybackController *)playback
                    directoryURL:(nullable NSURL *)directoryURL
                       appending:(BOOL)appending NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// On the root: makes its stack the path to `directory`, one screen per folder
// from the source covering it, so Back walks up; a directory no source covers
// is pushed alone. A file in it is scrolled to and selected for a moment.
- (void)showDirectory:(NSURL *)directory highlighting:(nullable NSURL *)file;

// On the root: handed snapshots of the rows an Add was asked for, framed in
// window coordinates, before the Add is requested. The shell animates them
// into the Playlist tab when the tracks land; this screen knows no tabs.
@property (nonatomic, copy, nullable) void (^addedRowsHandler)(NSArray<UIView *> *rows);

// On the root, set by whoever shows the stack: whether it is materially
// exposed — its tab selected, the card down, the scene foreground-active. The
// playing row's equalizer runs only while this and its own screen are.
@property (nonatomic) BOOL equalizerSurfaceVisible;

@end

NS_ASSUME_NONNULL_END
