//
//  SettingsSidebarController.h
//  Vibe
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SettingsSidebarController : NSViewController <NSTableViewDataSource, NSTableViewDelegate,
                                                         NSSearchFieldDelegate>
// The search field's placeholder, and the line shown when no pane matches.
- (instancetype)initWithSearchPlaceholder:(NSString *)placeholder noResultsText:(NSString *)noResultsText;
@property (weak, nonatomic) NSTabViewController *tabs;
// A group starts at each of these panes, after a spacer row.
@property (copy, nonatomic) NSSet<NSString *> *groupStartIdentifiers;
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
