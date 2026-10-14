//
//  FilesRootViewController.h
//  Vibe (iOS)
//
//  The Files tab's root, and the Playlist tab's add sheet: one list of every
//  place the app can list. The Locations are the app's own Documents, each
//  linked account through its mirror, and each folder the user granted. Each
//  opens in a FolderViewController pushed above this one. The system folder
//  picker's one remaining job is granting a location, from the plus. The
//  system file picker stays behind Choose File… for a one-off pick outside
//  them.
//
//  Every open goes through PlaybackController's roads, so nothing about
//  opening is reimplemented here.
//

#import <UIKit/UIKit.h>

@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface FilesRootViewController : UITableViewController

// Appending is the add sheet: every action appends, and the sheet closes
// after it.
- (instancetype)initWithPlayback:(PlaybackController *)playback
                       appending:(BOOL)appending NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// Makes the stack the path to `directory`, one screen per folder from the
// source covering it, so Back walks up; a directory no source covers is
// pushed alone. A file in it is scrolled to and selected for a moment.
- (void)showDirectory:(NSURL *)directory highlighting:(nullable NSURL *)file;

// Handed snapshots of the rows an Add was asked for, framed in window
// coordinates, before the Add is requested. The shell animates them into the
// Playlist tab when the tracks land; this screen knows no tabs. Every folder
// pushed above this one is handed it too.
@property (nonatomic, copy, nullable) void (^addedRowsHandler)(NSArray<UIView *> *rows);

// Set by whoever shows the stack: whether it is materially exposed — its tab
// selected, the card down, the scene foreground-active. The playing row's
// equalizer runs only while this and its own screen are.
@property (nonatomic) BOOL equalizerSurfaceVisible;

@end

NS_ASSUME_NONNULL_END
