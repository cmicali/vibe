//
//  BrowserViewController.h
//  Vibe (iOS)
//
//  The Files tab, and the Playlist tab's add sheet: one browser over every
//  place the app can list. The root lists the sources — Dropbox through its
//  mirror, the app's own Documents, and each location the user granted — and
//  a directory lists its folders and playable files. The system folder
//  picker's one remaining job is granting a location; the system file picker
//  stays behind Browse Files… for a one-off pick outside them.
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

// Opens urls as the playlist — one through openFileURL:inFolder:, several
// through openURLs:openInPlace: — asking first when the playlist was built by
// hand, with Add Instead as the other answer. Every screen whose tap replaces
// the playlist comes through here. `token` is PlaybackController's
// replaceRequestTokenOpening:, taken when the user asked: a caller with asynchronous
// work first (a bookmark to resolve, a Dropbox folder to list) is dropped
// here when another open was asked for meanwhile, or an older tap landing
// late would replace what the user chose last.
+ (void)confirmReplacingPlaylistOf:(PlaybackController *)playback
                              from:(UIViewController *)presenter
                       openingURLs:(NSArray<NSURL *> *)urls
                          inFolder:(BOOL)inFolder
                             token:(uint64_t)token;

// On the root: handed snapshots of the rows an Add was asked for, framed in
// window coordinates, before the Add is requested. The shell animates them
// into the Playlist tab when the tracks land; this screen knows no tabs.
@property (nonatomic, copy, nullable) void (^addedRowsHandler)(NSArray<UIView *> *rows);

// On the root, set by whoever shows the stack: whether it is materially
// exposed — its tab selected, the card down, the scene foreground-active. The
// playing row's equalizer runs only while this and its own screen are.
@property (nonatomic) BOOL equalizerSurfaceVisible;

@end

// The pieces the other screens' rows and alerts share with the browser's.
void VibePresentAlert(UIViewController *presenter, NSString *title, NSString *message);
UIAction *VibeMenuAction(NSString *title, NSString *symbol, void (^handler)(void));
// Two lines, cut in the middle, secondary line in the secondary color.
void VibeApplyFileNameStyle(UIListContentConfiguration *content);
// The accessory of a row whose file is not downloaded.
UIView *VibeNotDownloadedMark(void);
// The side of a file or track row's icon — its art or its tile — and what
// every such row reserves, so the names line up.
static const CGFloat kFileTileSide = 40;
static const CGFloat kFileTileCornerRadius = 8;
// A row's icon where it has no art: a waveform tile, or a note list for a
// CUE sheet or an M3U.
UIImage *VibeFileTileImage(BOOL playlist);
// Installs content, with a spinner in the icon slot while the open the row
// asked for runs. Every configuration of such a row goes through here, so a
// reused cell loses the spinner.
void VibeApplyRowContent(UITableViewCell *cell, UIListContentConfiguration *content, BOOL opening);
// Inside the table's viewport and the window: window attachment alone also
// counts the cells UIKit prepares beyond the screen.
BOOL VibeRowIsInViewport(UITableViewCell *cell, UITableView *tableView);

NS_ASSUME_NONNULL_END
