//
//  FilesSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Files: the two settings that are about files rather than pixels.
//
//  - the order a folder's tracks land in the playlist (AppSettings
//    .folderOpenSort, shared with the mac's Files pane). It governs the NEXT
//    open, so nothing on screen draws from it and writing it notifies nobody —
//    the one setting in this app's iOS screens that posts nothing.
//  - the folders the user has given the app to SEARCH (SearchFolderStore), last
//    because it grants access rather than choosing anything. The store owns the
//    grants and its own notification.
//
//  It writes the setting and presents the folder picker; it holds no playback
//  handle and never reaches for the screens behind it.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FilesSettingsViewController : UITableViewController

- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
