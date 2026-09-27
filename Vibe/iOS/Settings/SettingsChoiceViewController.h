//
//  SettingsChoiceViewController.h
//  Vibe (iOS)
//
//  One choice: rows with a checkmark on the current one. It knows titles and an
//  index only; the pusher owns the row-to-value mapping, so a localized display
//  name never becomes an identifier.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SettingsChoiceViewController : UITableViewController

// The checkmark moves before onSelect runs; the screen stays up afterwards.
- (instancetype)initWithTitle:(NSString *)title
                      choices:(NSArray<NSString *> *)choices
                selectedIndex:(NSInteger)selectedIndex
                     onSelect:(void (^)(NSInteger index))onSelect NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)nibName
                         bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
