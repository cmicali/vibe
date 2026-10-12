//
//  FilesSettingsViewController.h
//  Vibe (iOS)
//
//  Settings > Files and Dropbox: the Dropbox account (connect, the downloads
//  and their budget, and disconnect, which forgets the downloads), the
//  folder-open order (AppSettings.folderOpenSort, which governs the NEXT open,
//  so a write notifies nobody), and Allow Pasting Links, which opens this
//  app's page in the Settings app. The folders the app may read are the Files
//  tab's Locations.
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
