//
//  FileRow.h
//  Vibe (iOS)
//
//  The pieces every file and track row shares: the browser's, Recents',
//  Search's, Favorites', the Playlist tab's and the mini player's.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

UIAction *VibeMenuAction(NSString *title, NSString *symbol, void (^handler)(void));
// The accessory of a row whose file is not downloaded.
UIView *VibeNotDownloadedMark(void);
// File-list rows reserve this width for either art or a tile.
static const CGFloat kFileTileSide = 40;
static const CGFloat kFileTileCornerRadius = 8;
// A row's icon where it has no art: a waveform tile, or a note list for a
// CUE sheet or an M3U.
UIImage *VibeFileTileImage(BOOL playlist);

@interface UIListContentConfiguration (VibeFileRow)

// Two lines, cut in the middle, secondary line in the secondary color.
- (void)vibeApplyFileNameStyle;

// A list row's icon slot: the folder glyph, else the art, else the tile the
// name's extension asks for, at the tile's size and reserved in every row.
- (void)vibeApplyFileIconForName:(nullable NSString *)name folder:(BOOL)folder art:(nullable UIImage *)art;

@end

@interface UITableViewCell (VibeFileRow)

// Installs content, with a spinner in the icon slot while the open the row
// asked for runs. Every configuration of such a row goes through here, so a
// reused cell loses the spinner.
- (void)vibeApplyRowContent:(UIListContentConfiguration *)content opening:(BOOL)opening;

// Inside the table's viewport and the window: window attachment alone also
// counts the cells UIKit prepares beyond the screen.
- (BOOL)vibeIsInViewportOfTableView:(UITableView *)tableView;

@end

NS_ASSUME_NONNULL_END
