//
//  FilesSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Files: the folder-open order (AppSettings.folderOpenSort, which
//  governs the NEXT open, so a write notifies nobody) and the folders the app
//  may SEARCH (SearchFolderStore, which owns the grants and its notification).
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
