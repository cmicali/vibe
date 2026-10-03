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
// the playlist comes through here.
+ (void)confirmReplacingPlaylistOf:(PlaybackController *)playback
                              from:(UIViewController *)presenter
                       openingURLs:(NSArray<NSURL *> *)urls
                          inFolder:(BOOL)inFolder;

// On the root: handed snapshots of the rows an Add was asked for, framed in
// window coordinates, before the Add is requested. The shell animates them
// into the Playlist tab when the tracks land; this screen knows no tabs.
@property (nonatomic, copy, nullable) void (^addedRowsHandler)(NSArray<UIView *> *rows);

@end

// The pieces the other screens' rows and alerts share with the browser's.
void VibePresentAlert(UIViewController *presenter, NSString *title, NSString *message);
UIAction *VibeMenuAction(NSString *title, NSString *symbol, void (^handler)(void));
// Two lines, cut in the middle, secondary line in the secondary color.
void VibeApplyFileNameStyle(UIListContentConfiguration *content);
// The accessory of a row whose file is not downloaded.
UIView *VibeNotDownloadedMark(void);
// A file row's icon where it has no art to draw: a rounded tile holding a
// symbol, `waveform` for audio and `music.note.list` for a CUE sheet. The
// side is also the size art is drawn at and what every such row reserves.
extern const CGFloat VibeFileTileSide;
extern const CGFloat VibeFileTileCornerRadius;
UIImage *VibeFileTileImage(NSString *symbol);

NS_ASSUME_NONNULL_END
