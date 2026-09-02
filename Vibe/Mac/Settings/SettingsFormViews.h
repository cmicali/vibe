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

@interface SettingsRowView : NSView

// The title may end with a localized colon (the strings are shared with the
// old form layout); it is stripped for display. nil title: the control
// cluster stands alone, trailing.
+ (instancetype)rowWithTitle:(nullable NSString *)title control:(NSView *)control;
+ (instancetype)rowWithTitle:(nullable NSString *)title
                     caption:(nullable NSString *)caption
                     control:(NSView *)control;
+ (instancetype)rowWithTitle:(nullable NSString *)title controls:(NSArray<NSView *> *)controls;
// A row that is all content — the folder list, a wrapping explainer —
// spanning the card's width with no trailing cluster.
+ (instancetype)rowWithContentView:(NSView *)contentView;

// The structural labels, exposed so the debug walker can use the title as the
// row's addressing label and skip both as elements of their own.
@property (readonly, nullable) NSTextField *titleLabel;
@property (readonly, nullable) NSTextField *captionLabel;

// Retitle in place, through the same form-label trim the constructor applies.
// The theme editor's per-side color rows lose their side under a single-mode
// theme, and the title is what the debug walker addresses the row by.
- (void)setRowTitle:(NSString *)title;

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
