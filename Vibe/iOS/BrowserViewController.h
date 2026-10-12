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

// Open URL: the typed link resolved (LinkStore), then its file opened alone
// through confirmReplacing…, which asks when the playlist was built by hand.
// It asks over what is on top of anchor's window when the link settles. The
// sheet, the add sheet, or the card may have come or gone by then. The
// replace token is taken now, so a later open supersedes it. A link that
// fails leaves the playlist as it is. Never the inbox road: it does not
// persist. Completion on main, with exactly one of file and error, before
// the replace question. The returned block cancels the resolve on main, as
// LinkStore's does.
+ (dispatch_block_t)openLinkString:(NSString *)string
                replacingPlaylistOf:(PlaybackController *)playback
                               from:(UIViewController *)anchor
                         completion:(nullable void (^)(NSURL *_Nullable file, NSError *_Nullable error))completion;

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
// What an alert goes over: the top of root's presentation stack, the add
// sheet or the card, past one being dismissed.
UIViewController *VibeTopmostPresenter(UIViewController *root);
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
// A list row's icon slot: the folder glyph, else the art, else the tile the
// name's extension asks for, at the tile's size and reserved in every row.
void VibeApplyFileIcon(UIListContentConfiguration *content, NSString *_Nullable name, BOOL folder,
                       UIImage *_Nullable art);
// Installs content, with a spinner in the icon slot while the open the row
// asked for runs. Every configuration of such a row goes through here, so a
// reused cell loses the spinner.
void VibeApplyRowContent(UITableViewCell *cell, UIListContentConfiguration *content, BOOL opening);
// Inside the table's viewport and the window: window attachment alone also
// counts the cells UIKit prepares beyond the screen.
BOOL VibeRowIsInViewport(UITableViewCell *cell, UITableView *tableView);

NS_ASSUME_NONNULL_END
