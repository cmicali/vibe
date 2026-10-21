//
//  SettingsFormViews+Debug.m
//  Vibe
//

#import "SettingsFormViews+Debug.h"

#if DEBUG

#import "DrawnControls.h"

@implementation VibeSettingsElement
@end

// A checkbox and a radio are indistinguishable through NSButton: setButtonType:
// leaves both cells with the same state and highlight masks, and the button's
// own accessibilityRole reads AXUnknown until an accessibility client attaches.
// The CELL's role is the one AppKit fills in eagerly, and it is exact.
static NSString *VibeButtonKind(NSButton *button) {
    NSAccessibilityRole role = button.cell.accessibilityRole;
    if ([role isEqualToString:NSAccessibilityRadioButtonRole]) {
        return @"radio";
    }
    if ([role isEqualToString:NSAccessibilityCheckBoxRole]) {
        return @"checkbox";
    }
    // A push button, and the fallback for a role AppKit did not answer for.
    // The click path is the same either way, and a caller can still read the
    // button's state.
    return @"button";
}

static NSString *VibeElementKind(NSView *view) {
    if ([view isKindOfClass:NSPopUpButton.class]) {
        return ((NSPopUpButton *)view).pullsDown ? @"pulldown" : @"popup";
    }
    if ([view isKindOfClass:NSButton.class]) {
        return VibeButtonKind((NSButton *)view);
    }
    if ([view isKindOfClass:NSTableView.class]) {
        return @"table";
    }
    if ([view isKindOfClass:NSTextField.class]) {
        return ((NSTextField *)view).isEditable ? @"field" : @"label";
    }
    if ([view isKindOfClass:NSSlider.class]) {
        return @"slider";
    }
    if ([view isKindOfClass:VibeSwitch.class]) {
        return @"switch";
    }
    if ([view isKindOfClass:NSColorWell.class]) {
        return @"colorwell";
    }
    if ([view isKindOfClass:NSControl.class]) {
        return @"control";
    }
    return nil; // a container: recurse into it
}

static NSString *VibeElementName(NSView *view, NSString *kind, NSString *rowLabel) {
    if ([kind isEqualToString:@"pulldown"]) {
        // A pull-down draws its title from the item at index 0, which is never
        // chosen, so that is the name on screen.
        NSString *title = ((NSPopUpButton *)view).itemArray.firstObject.title;
        if (title.length) {
            return title;
        }
    }
    else if ([view isKindOfClass:NSButton.class] && ![view isKindOfClass:NSPopUpButton.class]) {
        NSString *title = ((NSButton *)view).title;
        if (title.length) {
            return title;
        }
    }
    if (rowLabel.length) {
        return rowLabel;
    }
    if ([view isKindOfClass:NSTextField.class]) {
        NSString *text = ((NSTextField *)view).stringValue;
        if (text.length) {
            return text;
        }
    }
    return kind;
}

static void VibeCollectElements(NSView *view, NSString *rowLabel, SettingsRowView *row,
                                NSMutableArray<VibeSettingsElement *> *out) {
    // A scroll view's scrollers are NSControls, and nothing a caller would ever
    // aim at; the document view inside it still gets collected.
    if ([view isKindOfClass:NSScroller.class]) {
        return;
    }

    // A form row's title addresses the controls beside it; the title and
    // caption are structure, not elements. A section passes its header down
    // the same way, so an untitled row, such as a list, answers to its
    // section's header.
    if ([view isKindOfClass:SettingsRowView.class]) {
        SettingsRowView *row = (SettingsRowView *)view;
        NSString *title = row.titleLabel.stringValue;
        NSString *label = title.length ? title : rowLabel;
        for (NSView *subview in view.subviews) {
            if (subview == row.titleLabel || subview == row.captionLabel) {
                continue;
            }
            VibeCollectElements(subview, label, row, out);
        }
        return;
    }
    if ([view isKindOfClass:SettingsSectionView.class]) {
        SettingsSectionView *section = (SettingsSectionView *)view;
        NSString *header = section.headerLabel.stringValue;
        NSString *label = header.length ? header : rowLabel;
        for (NSView *subview in view.subviews) {
            if (subview == section.headerLabel) {
                continue;
            }
            VibeCollectElements(subview, label, row, out);
        }
        return;
    }
    NSString *kind = VibeElementKind(view);
    if (kind) {
        VibeSettingsElement *element = [[VibeSettingsElement alloc] init];
        element.view = view;
        element.kind = kind;
        element.label = rowLabel;
        element.row = row;
        element.name = VibeElementName(view, kind, rowLabel);
        [out addObject:element];
        // A control's own subviews are its innards, never separate controls;
        // a table's cell views are reported as its rows instead.
        return;
    }
    // A stack view or a scroll view: pass the row label through, so the radios
    // inside one still answer to the row they sit in.
    for (NSView *subview in view.subviews) {
        VibeCollectElements(subview, rowLabel, row, out);
    }
}

@implementation SettingsRowView (Debug)

+ (NSArray<VibeSettingsElement *> *)debugElementsInView:(NSView *)view {
    NSMutableArray<VibeSettingsElement *> *elements = [NSMutableArray array];
    VibeCollectElements(view, nil, nil, elements);
    return elements;
}

@end

#endif
