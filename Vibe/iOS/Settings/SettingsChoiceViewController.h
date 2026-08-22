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
