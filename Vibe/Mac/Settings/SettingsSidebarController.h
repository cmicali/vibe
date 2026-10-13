//
//  SettingsSidebarController.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SettingsSidebarController : NSViewController <NSTableViewDataSource, NSTableViewDelegate,
                                                         NSSearchFieldDelegate>
@property (weak, nonatomic) NSTabViewController *tabs;
@property (readonly, nonatomic) NSTableView *tableView;
@property (readonly, nonatomic) NSSearchField *searchField;
// Moves the highlighted row; a pane the search hides selects nothing.
- (void)selectRowForTabItem:(NSTabViewItem *)item;
// Rebuilds the rows from the search field: matching panes only, ungrouped.
- (void)reloadRows;
- (void)searchChanged:(nullable id)sender;
- (NSArray<NSString *> *)visiblePaneIdentifiers;
@end

NS_ASSUME_NONNULL_END
