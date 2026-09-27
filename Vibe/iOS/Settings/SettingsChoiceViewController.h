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

// The settings screens' switch row, built once here since this is the one
// class they share: a non-selecting cell with the switch as accessory,
// `action` sent to `target` with the switch as sender. One reuse identifier,
// so the recycled switch is re-targeted each time.
+ (UITableViewCell *)switchCellInTableView:(UITableView *)tableView
                                     title:(NSString *)title
                                        on:(BOOL)on
                                    target:(id)target
                                    action:(SEL)action;

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
