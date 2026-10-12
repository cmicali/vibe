//
//  FolderViewController.h
//  Vibe (iOS)
//
//  One directory of the Files tab, or of the Playlist tab's add sheet: its
//  folders, then its M3U playlists, then its playable files. The root
//  (FilesRootViewController) pushes the first, and each pushes the next.
//
//  Every open goes through PlaybackController's roads, so nothing about
//  opening is reimplemented here.
//

#import <UIKit/UIKit.h>

@class AudioTrackMetadataCache;
@class PlaybackController;

NS_ASSUME_NONNULL_BEGIN

@interface FolderViewController : UITableViewController

// Appending is the add sheet: every action appends, and the sheet closes
// after it. stackArtCache answers the stack's one metadata cache. It is
// asked only once a row needs art. Open Folder hands the last screen of its
// stack the file to highlight, and a screen for a folder no source covers
// holds its scope (holdsScope), stopped when the screen goes.
- (instancetype)initWithPlayback:(PlaybackController *)playback
                    directoryURL:(NSURL *)directoryURL
                       appending:(BOOL)appending
                   stackArtCache:(AudioTrackMetadataCache *(^)(void))stackArtCache
                    highlighting:(nullable NSURL *)file
                      holdsScope:(BOOL)holdsScope NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// The root's, set at push: handed snapshots of the rows an Add was asked
// for, framed in window coordinates, before the Add is requested.
@property (nonatomic, copy, nullable) void (^addedRowsHandler)(NSArray<UIView *> *rows);

// Set at push, and by the root on every screen of its stack: whether the
// stack is materially exposed. The playing row's equalizer runs only while
// this and its own screen are.
@property (nonatomic) BOOL equalizerSurfaceVisible;

@end

NS_ASSUME_NONNULL_END
