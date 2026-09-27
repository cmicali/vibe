//
//  SettingsChoiceViewController.h
//  Vibe (iOS)
//
//  One screen, one choice: a list of rows with the checkmark on the current
//  one. The waveform style and the time display are both exactly this shape, so
//  they push this rather than each growing a table of its own.
//
//  It knows titles and an index and nothing else — no setting, no stored
//  identifier. The screen that pushes it owns the row-to-value mapping, which
//  is what keeps a localized display name from ever becoming an identifier.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SettingsChoiceViewController : UITableViewController

// The settings screens' switch row, built once here since this is the one
// class they all share: a plain cell that does not select, its switch the
// accessory, `action` sent to `target` on a change with the switch as the
// sender. Dequeued under one identifier, so a screen with several switch
// rows re-targets the recycled switch each time.
+ (UITableViewCell *)switchCellInTableView:(UITableView *)tableView
                                     title:(NSString *)title
                                        on:(BOOL)on
                                    target:(id)target
                                    action:(SEL)action;

// The checkmark moves before onSelect runs, so the block only has to write the
// value. The screen stays up afterwards, as the system's own pickers do.
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
