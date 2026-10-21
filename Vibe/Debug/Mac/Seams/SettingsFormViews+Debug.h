//
//  SettingsFormViews+Debug.h
//  Vibe
//
//  The settings walker's seam: every control in a pane, each named by the
//  form row it sits in. A row's title labels the controls beside it, and a
//  section's header labels the untitled rows under it. The implementation
//  compiles only in a debug build.
//

#import "SettingsFormViews.h"

NS_ASSUME_NONNULL_BEGIN

// One addressable control in a pane. `name` is what a caller matches first:
// a button's own title, else its form row's title.
@interface VibeSettingsElement : NSObject
@property (nonatomic, strong) NSView *view;
// popup, pulldown, button, checkbox, radio, table, field, label, slider,
// switch, colorwell, or control.
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *label;
// The grouped-form row the element sits in, nil outside one.
@property (nonatomic, weak, nullable) SettingsRowView *row;
@end

@interface SettingsRowView (Debug)

// Every control under view, in subview order. A control's own subviews and a
// scroll view's scrollers are not elements.
+ (NSArray<VibeSettingsElement *> *)debugElementsInView:(NSView *)view;

@end

NS_ASSUME_NONNULL_END
