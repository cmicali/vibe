//
//  SettingsFormViews.h
//  Vibe
//
//  The debug walker keys off these classes — a row's title addresses the
//  controls beside it — so a pane built from anything else loses
//  settings_click's by-name addressing.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A layer fill re-resolved on a live light/dark flip.
@interface SettingsFillView : NSView
@property (nonatomic, strong) NSColor *darkColor;
@property (nonatomic, strong) NSColor *lightColor;
@property (nonatomic) CGFloat cornerRadius;
@end

// Sidebar selection stays accent-colored while unfocused; listRowViewForRow:
// configures it with the Sound settings palette instead.
@interface SettingsAccentRowView : NSTableRowView
@end

// TRAP: flipped, so a scroll view's document keeps its top in place; unflipped,
// every relayout strands the page further under the toolbar.
@interface SettingsStackView : NSStackView
@end

// Where a form row's title starts within its card.
static const CGFloat kSettingsRowInset = 16;

@interface SettingsRowView : NSView

// Use these rather than .enabled: a row whose controls are all disabled dims
// its labels too. The second form takes every control under a view, and
// deactivates a color well it disables.
+ (void)setControl:(NSControl *)control enabled:(BOOL)enabled;
+ (void)setControlsInView:(NSView *)view enabled:(BOOL)enabled;

// A trailing localized colon is stripped for display. nil title: the controls
// stand alone, trailing.
+ (instancetype)rowWithTitle:(nullable NSString *)title control:(NSView *)control;
+ (instancetype)rowWithTitle:(nullable NSString *)title
                     caption:(nullable NSString *)caption
                     control:(NSView *)control;
+ (instancetype)rowWithTitle:(nullable NSString *)title controls:(NSArray<NSView *> *)controls;
+ (instancetype)rowWithTitle:(nullable NSString *)title
                     caption:(nullable NSString *)caption
                    controls:(NSArray<NSView *> *)controls;
// Spans the card's width with no trailing cluster.
// TRAP: the content is pinned leading-to-trailing, so it must carry no
// required width, fixed or capped: the pin climbs to the window's content
// view, which follows the frame only at NSLayoutPriorityWindowSizeStayPut, and
// the content then stops short of a widened window on every pane.
+ (instancetype)rowWithContentView:(NSView *)contentView;

// An "icon" column is untitled and fixed at the shared glyph width.
+ (NSTableView *)listTableWithColumnIdentifiers:(NSArray<NSUserInterfaceItemIdentifier> *)identifiers
                                     delegate:(id<NSTableViewDelegate, NSTableViewDataSource>)delegate;

// A list inside a card, rowCount rows tall, scrolling past that. Multiple
// columns keep a header. Behavior stays the pane's.
+ (instancetype)rowWithTableView:(NSTableView *)table rowCount:(NSUInteger)rowCount;

+ (NSTableRowView *)listRowViewForRow:(NSInteger)row;

// Text (NSNoImage), icon and text (NSImageLeft), or a centered bold symbol
// (NSImageOnly).
+ (NSTableCellView *)listCellWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
                                inTableView:(NSTableView *)table
                              imagePosition:(NSCellImagePosition)imagePosition;

// A group header in a list: an ordinary row the delegate refuses to select,
// not an AppKit group row, whose gap and height would break a row budget.
+ (NSTableCellView *)listGroupCellWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
                                     inTableView:(NSTableView *)table
                                           title:(NSString *)title;

// For the debug walker.
@property (readonly, nullable) NSTextField *titleLabel;
@property (readonly, nullable) NSTextField *captionLabel;

// Retitles through the same colon trim as the constructor.
- (void)setRowTitle:(NSString *)title;

// An empty caption hides the label and recenters the title. Answers whether
// the row's height changed; the caller remeasures the pane only then.
- (BOOL)setCaption:(nullable NSString *)caption;
// What the row does, then on its own line why it is unavailable or how it
// settled; a nil detail leaves the description alone.
- (BOOL)setCaption:(NSString *)caption detail:(nullable NSString *)detail;

// Set by the section on every row but its first, so a hidden row takes its
// separator with it.
@property (nonatomic) BOOL showsTopSeparator;

// The sidebar search's mark: an accent wash behind the row.
@property (nonatomic) BOOL searchHighlighted;

@end

@interface SettingsSectionView : NSView

+ (instancetype)sectionWithRows:(NSArray<SettingsRowView *> *)rows;
// A trailing localized colon is stripped, as for a row title.
+ (instancetype)sectionWithHeader:(nullable NSString *)header
                             rows:(NSArray<SettingsRowView *> *)rows;

@property (readonly, nullable) NSTextField *headerLabel;

// The card a view sits in, or nil outside every card.
+ (nullable SettingsSectionView *)sectionContaining:(NSView *)view;

// Retitles a section built with a header; the label truncates rather than
// widening every pane.
- (void)setHeader:(NSString *)header;

@end

// Ticks above and below the track at detentValue, where its action snaps.
// NSSlider's own tick marks are evenly spaced and single-sided.
@interface VibeDetentSlider : NSSlider
@property (nonatomic) double detentValue;
@end

NS_ASSUME_NONNULL_END
