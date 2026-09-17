//
//  SettingsFormViews.h
//  Vibe
//
//  The System Settings-style grouped form the settings panes are built from:
//  rounded section cards of hairline-separated rows, title leading, controls
//  trailing. The debug walker keys off these classes — a row's title is the
//  addressing label for the controls beside it — so a pane built from
//  anything else loses settings_click's by-name addressing.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// A flat, appearance-following layer fill: the color for the side the view
// is drawn under, re-resolved on a live light/dark flip. Every plain surface
// of the form is one — the row hairline, the section card, the pane's own
// backdrop — differing only in colors and radius.
@interface SettingsFillView : NSView
@property (nonatomic, strong) NSColor *darkColor;
@property (nonatomic, strong) NSColor *lightColor;
@property (nonatomic) CGFloat cornerRadius;
@end

// Sidebar selection stays accent-colored while unfocused; the shared list
// factory configures this same row with the Sound settings palette instead.
@interface SettingsAccentRowView : NSTableRowView
@end

// Where a row's title starts, and where a list's text starts
// with it, so the two line up down a card — the System Settings alignment.
static const CGFloat kSettingsRowInset = 16;

@interface SettingsRowView : NSView

// The title may end with a localized colon (the strings are shared with the
// old form layout); it is stripped for display. nil title: the control
// cluster stands alone, trailing.
+ (instancetype)rowWithTitle:(nullable NSString *)title control:(NSView *)control;
+ (instancetype)rowWithTitle:(nullable NSString *)title
                     caption:(nullable NSString *)caption
                     control:(NSView *)control;
+ (instancetype)rowWithTitle:(nullable NSString *)title controls:(NSArray<NSView *> *)controls;
// A row that is all content — a wrapping explainer, a button row — spanning
// the card's width with no trailing cluster. TRAP: the content is pinned
// leading-to-trailing, so it must carry no required width of its own, fixed
// or capped: that pin climbs the required equalities up to the pane and, by
// way of the split view, decides the window's content view — which follows
// the window frame only at NSLayoutPriorityWindowSizeStayPut — so the content
// stops short of a widened window and, stay-put keeping it there, stays
// short after a switch to any other pane. The folder list's fixed 408 did
// exactly that: an 839-point window drawing 680 points of content.
+ (instancetype)rowWithContentView:(NSView *)contentView;

// Shared setup; panes supply selection policy, column titles and actions.
+ (NSTableView *)listTableWithColumnIdentifiers:(NSArray<NSUserInterfaceItemIdentifier> *)identifiers
                                     delegate:(id<NSTableViewDelegate, NSTableViewDataSource>)delegate;

// A list inside a card, in the System Settings shape (the Sound pane's device
// table): rounded edges, full-width alternating rows without separators,
// rowCount rows tall and scrolling past that. Multiple columns keep their
// header. The look is set here; the table's behavior — selection, drag types,
// delegate — stays the pane's, and its cells come from
// listCellWithIdentifier:inTableView:imagePosition:.
+ (instancetype)rowWithTableView:(NSTableView *)table rowCount:(NSUInteger)rowCount;

+ (NSTableRowView *)listRowViewForRow:(NSInteger)row;

// A reusable list cell: text (NSNoImage), icon and text
// (NSImageLeft), or a centered icon (NSImageOnly).
+ (NSTableCellView *)listCellWithIdentifier:(NSUserInterfaceItemIdentifier)identifier
                                inTableView:(NSTableView *)table
                              imagePosition:(NSCellImagePosition)imagePosition;

// The structural labels, exposed so the debug walker can use the title as the
// row's addressing label and skip both as elements of their own.
@property (readonly, nullable) NSTextField *titleLabel;
@property (readonly, nullable) NSTextField *captionLabel;

// Retitle in place, through the same form-label trim the constructor applies.
// The theme editor's per-side color rows lose their side under a single-mode
// theme, and the title is what the debug walker addresses the row by.
- (void)setRowTitle:(NSString *)title;

// Recaption in place: creates the caption label on first use, hides it and
// returns the title to the row's center for an empty caption, and answers
// whether anything visible changed — the caller remeasures the pane only
// then. The bit-perfect and FX rows change their captions live.
- (BOOL)setCaption:(nullable NSString *)caption;

// Set by the section on every row but its first, so a hidden row takes its
// separator with it.
@property (nonatomic) BOOL showsTopSeparator;

@end

@interface SettingsSectionView : NSView

+ (instancetype)sectionWithRows:(NSArray<SettingsRowView *> *)rows;
// The header may end with a localized colon, stripped like a row title.
+ (instancetype)sectionWithHeader:(nullable NSString *)header
                             rows:(NSArray<SettingsRowView *> *)rows;

@property (readonly, nullable) NSTextField *headerLabel;

@end

NS_ASSUME_NONNULL_END
