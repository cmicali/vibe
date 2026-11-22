//
//  FileRow.h
//  Vibe (iOS)
//
//  The pieces file and track rows share: the menu action, the not-downloaded
//  mark, the file tile, the row value, the icon slot, the opening spinner and
//  the viewport test.
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

// One track as a row or the mini player draws it. The app fills it from its
// own model. Rows compare it by content to skip an unchanged render, so the
// thumbnail is compared by identity and the strings by value.
@interface VibeTrackRow : NSObject <NSCopying>
@property (nonatomic, copy, nullable) NSString *title;
// Nil or empty draws one line, the title, centred on its own.
@property (nonatomic, copy, nullable) NSString *subtitle;
// Nil draws the file tile.
@property (nonatomic, nullable) UIImage *thumbnail;
@property (nonatomic, copy, nullable) NSString *durationText;
// The gutter's text, such as the row's position. Nil leaves it empty.
@property (nonatomic, copy, nullable) NSString *numberText;
// The gutter's equalizer in place of the number. Loading outranks it, and
// is pushed on its own, since a transfer changes without the row.
@property (nonatomic, getter=isPlaying) BOOL playing;
@end

@interface UIListContentConfiguration (VibeFileRow)

// Two lines, cut in the middle, secondary line in the secondary color.
- (void)vibeApplyFileNameStyle;

// A list row's icon slot: the folder glyph, else the art, else the file or
// playlist tile, at the tile's size and reserved in every row.
- (void)vibeApplyFileIconForFolder:(BOOL)folder playlist:(BOOL)playlist art:(nullable UIImage *)art;

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
