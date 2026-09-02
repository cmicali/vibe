//
//  DebugSettingsUI.m
//  Vibe
//

#import "DebugSettingsUI.h"
#import "SettingsAppearanceViewController.h"

#if DEBUG

#import <AppKit/AppKit.h>
#import "AppDelegate.h"
#import "AppSettings.h"
#import "DebugWireFormat.h"
#import "PlatformColor.h"
#import "SettingsFormViews.h"
#import "SettingsWindowController.h"

#pragma mark - Reaching the window

static NSWindow *VibeSettingsWindow(void) {
    for (NSWindow *window in NSApp.windows) {
        if ([window.windowController isKindOfClass:SettingsWindowController.class]) {
            return window;
        }
    }
    return nil;
}

// The tab controller, but only while the window is on screen: the controller
// keeps a closed window alive (releasedWhenClosed = NO), and a pane that has
// not appeared has not run refreshFromSettings, so its controls would read
// stale. Writes the error reply and returns nil otherwise.
static NSTabViewController *VibeSettingsTabs(NSString **errorJSON) {
    NSWindow *window = VibeSettingsWindow();
    if (!window || !window.isVisible) {
        *errorJSON = VibeErrorJSON(@"settings window is not open (run settings_open)");
        return nil;
    }
    // The window's content is the split controller (sidebar + panes); the tab
    // controller that owns pane selection is its content child. Driving IT is
    // what keeps this channel honest — didSelectTabViewItem syncs the sidebar
    // row back, so a programmatic selection looks exactly like a click.
    NSViewController *root = window.contentViewController;
    if ([root isKindOfClass:NSSplitViewController.class]) {
        for (NSViewController *child in root.childViewControllers) {
            if ([child isKindOfClass:NSTabViewController.class]) {
                return (NSTabViewController *)child;
            }
        }
    }
    *errorJSON = VibeErrorJSON(@"settings window has no tab controller");
    return nil;
}

static NSString *VibePaneIdentifier(NSTabViewItem *item) {
    return [item.identifier isKindOfClass:NSString.class] ? (NSString *)item.identifier : @"";
}

// selectedTabViewItemIndex is -1 while nothing is selected, which no live
// settings window is ever in — but an index into tabViewItems must not take
// that on trust.
static NSTabViewItem *VibeSelectedPane(NSTabViewController *tabs) {
    NSInteger index = tabs.selectedTabViewItemIndex;
    return (index >= 0 && index < (NSInteger)tabs.tabViewItems.count)
            ? tabs.tabViewItems[(NSUInteger)index] : nil;
}

static NSArray<NSDictionary *> *VibePaneList(NSTabViewController *tabs) {
    NSMutableArray<NSDictionary *> *panes = [NSMutableArray array];
    NSInteger selected = tabs.selectedTabViewItemIndex;
    [tabs.tabViewItems enumerateObjectsUsingBlock:^(NSTabViewItem *item, NSUInteger index, BOOL *stop) {
        [panes addObject:@{
            @"index": @(index),
            @"id": VibePaneIdentifier(item),
            @"title": item.label ?: @"",
            @"selected": @((NSInteger)index == selected),
        }];
    }];
    return panes;
}

// A pane by stable identifier, by index, or by displayed (localized) title —
// identifier first, so a script never has to know the running language.
static NSInteger VibePaneIndexForToken(NSTabViewController *tabs, NSString *token) {
    NSArray<NSTabViewItem *> *items = tabs.tabViewItems;
    NSScanner *scanner = [NSScanner scannerWithString:token];
    NSInteger index = 0;
    if ([scanner scanInteger:&index] && scanner.isAtEnd) {
        return (index >= 0 && index < (NSInteger)items.count) ? index : -1;
    }
    for (NSUInteger i = 0; i < items.count; i++) {
        if ([VibePaneIdentifier(items[i]) caseInsensitiveCompare:token] == NSOrderedSame ||
                [items[i].label caseInsensitiveCompare:token] == NSOrderedSame) {
            return (NSInteger)i;
        }
    }
    return -1;
}

static NSString *VibePaneNameList(NSTabViewController *tabs) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSTabViewItem *item in tabs.tabViewItems) {
        [names addObject:VibePaneIdentifier(item)];
    }
    return [names componentsJoinedByString:@", "];
}

void VibeDebugSettingsRefreshSelectedPane(void) {
    NSString *unusedError = nil;
    NSTabViewController *tabs = VibeSettingsTabs(&unusedError);
    if (!tabs) {
        return;
    }
    NSViewController *pane = VibeSelectedPane(tabs).viewController;
    if ([pane isKindOfClass:SettingsPaneViewController.class]) {
        [(SettingsPaneViewController *)pane refreshSettingsAndPaneSize];
    }
}

#pragma mark - Control inventory

// One addressable thing in a pane. `name` is what settings_click matches on
// first: a button's own title, or the form grid's row label for the controls
// that have no title of their own.
@interface VibeSettingsElement : NSObject
@property (nonatomic, strong) NSView *view;
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *label;
@end

@implementation VibeSettingsElement
@end

// A checkbox and a radio are indistinguishable through NSButton: setButtonType:
// leaves both cells with the same state and highlight masks, and the button's
// own accessibilityRole reads AXUnknown until an accessibility client attaches.
// The CELL's role is the one AppKit fills in eagerly, and it is exact.
static NSString *VibeButtonKind(NSButton *button) {
    NSCell *cell = button.cell;
    NSAccessibilityRole role = [cell respondsToSelector:@selector(accessibilityRole)]
            ? cell.accessibilityRole : nil;
    if ([role isEqualToString:NSAccessibilityRadioButtonRole]) {
        return @"radio";
    }
    if ([role isEqualToString:NSAccessibilityCheckBoxRole]) {
        return @"checkbox";
    }
    // A push button, and the fallback for a role AppKit did not answer for:
    // the click path is the same either way, and the state still rides in the
    // dump for a caller to read.
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
    if ([view isKindOfClass:NSSwitch.class]) {
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

static void VibeCollectElements(NSView *view, NSString *rowLabel,
                                NSMutableArray<VibeSettingsElement *> *out) {
    // A scroll view's scrollers are NSControls, and nothing a caller would ever
    // aim at; the document view inside it still gets collected.
    if ([view isKindOfClass:NSScroller.class]) {
        return;
    }

    // A grouped-form row: its title is the addressing label for the controls
    // beside it, and the title and caption are structure, not elements. A
    // section passes its header down the same way, which is how the Files
    // pane's folder list answers to "Permissions".
    if ([view isKindOfClass:SettingsRowView.class]) {
        SettingsRowView *row = (SettingsRowView *)view;
        NSString *title = row.titleLabel.stringValue;
        NSString *label = title.length ? title : rowLabel;
        for (NSView *subview in view.subviews) {
            if (subview == row.titleLabel || subview == row.captionLabel) {
                continue;
            }
            VibeCollectElements(subview, label, out);
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
            VibeCollectElements(subview, label, out);
        }
        return;
    }
    NSString *kind = VibeElementKind(view);
    if (kind) {
        VibeSettingsElement *element = [[VibeSettingsElement alloc] init];
        element.view = view;
        element.kind = kind;
        element.label = rowLabel;
        element.name = VibeElementName(view, kind, rowLabel);
        [out addObject:element];
        // A control's own subviews are its innards, never separate controls;
        // a table's cell views are reported as its rows instead.
        return;
    }
    // A stack view or a scroll view: pass the row label through, so the radios
    // inside one still answer to the row they sit in.
    for (NSView *subview in view.subviews) {
        VibeCollectElements(subview, rowLabel, out);
    }
}

static NSArray<VibeSettingsElement *> *VibeElementsForPane(NSViewController *pane) {
    NSMutableArray<VibeSettingsElement *> *elements = [NSMutableArray array];
    VibeCollectElements(pane.view, nil, elements);
    return elements;
}

#pragma mark - Rendering one control

static NSString *VibeStateName(NSControlStateValue state) {
    return state == NSControlStateValueOn ? @"on"
            : state == NSControlStateValueMixed ? @"mixed" : @"off";
}

// Top-left origin in the window's CONTENT view, which is the frame
// dump_screenshot renders, so a rect here can be aimed at in a capture.
static NSDictionary *VibeElementRect(NSView *view, NSWindow *window) {
    NSView *content = window.contentView;
    if (!content) {
        return nil;
    }
    NSRect rect = [view convertRect:view.bounds toView:content];
    return @{
        @"x": @(round(NSMinX(rect))),
        @"y": @(round(NSHeight(content.bounds) - NSMaxY(rect))),
        @"w": @(round(NSWidth(rect))),
        @"h": @(round(NSHeight(rect))),
    };
}

static NSArray<NSDictionary *> *VibeMenuItemList(NSPopUpButton *popUp) {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    [popUp.itemArray enumerateObjectsUsingBlock:^(NSMenuItem *item, NSUInteger index, BOOL *stop) {
        NSMutableDictionary *node = [NSMutableDictionary dictionary];
        node[@"index"] = @(index);
        node[@"title"] = item.title ?: @"";
        node[@"enabled"] = @(item.isEnabled);
        if (item.isSeparatorItem) {
            node[@"separator"] = @YES;
        }
        if (item.state != NSControlStateValueOff) {
            node[@"state"] = VibeStateName(item.state);
        }
        // The waveform styles, the key notations and the appearances all carry
        // their stable identifier here while the title is localized.
        if ([item.representedObject isKindOfClass:NSString.class]) {
            node[@"represented"] = item.representedObject;
        }
        [items addObject:node];
    }];
    return items;
}

static NSArray<NSString *> *VibeTableRowTitles(NSTableView *table) {
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    for (NSInteger row = 0; row < table.numberOfRows; row++) {
        // makeIfNecessary, so a row scrolled out of view still reports its
        // text; these lists are short enough for that to be free.
        NSView *cell = [table viewAtColumn:0 row:row makeIfNecessary:YES];
        NSString *text = [cell isKindOfClass:NSTableCellView.class]
                ? ((NSTableCellView *)cell).textField.stringValue : nil;
        [rows addObject:text ?: @""];
    }
    return rows;
}

// The live part of a control: what a click would change, and what a caller
// asserts on. Shared by the dump and by settings_click's reply, so the reply
// alone shows the result.
static NSDictionary *VibeElementStateJSON(VibeSettingsElement *element) {
    NSView *view = element.view;
    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    if ([view isKindOfClass:NSControl.class]) {
        node[@"enabled"] = @(((NSControl *)view).isEnabled);
    }
    if ([element.kind isEqualToString:@"popup"] || [element.kind isEqualToString:@"pulldown"]) {
        NSPopUpButton *popUp = (NSPopUpButton *)view;
        node[@"items"] = VibeMenuItemList(popUp);
        if ([element.kind isEqualToString:@"popup"]) {
            node[@"value"] = popUp.titleOfSelectedItem ?: @"";
            node[@"selected"] = @(popUp.indexOfSelectedItem);
            if ([popUp.selectedItem.representedObject isKindOfClass:NSString.class]) {
                node[@"represented"] = popUp.selectedItem.representedObject;
            }
        }
    }
    else if ([view isKindOfClass:NSButton.class]) {
        node[@"title"] = ((NSButton *)view).title ?: @"";
        if (![element.kind isEqualToString:@"button"]) {
            node[@"state"] = VibeStateName(((NSButton *)view).state);
        }
    }
    else if ([element.kind isEqualToString:@"table"]) {
        NSTableView *table = (NSTableView *)view;
        node[@"rows"] = VibeTableRowTitles(table);
        NSMutableArray<NSNumber *> *selected = [NSMutableArray array];
        [table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
            [selected addObject:@(row)];
        }];
        node[@"selectedRows"] = selected;
    }
    else if ([element.kind isEqualToString:@"switch"]) {
        node[@"state"] = VibeStateName(((NSSwitch *)view).state);
    }
    else if ([element.kind isEqualToString:@"slider"]) {
        NSSlider *slider = (NSSlider *)view;
        node[@"value"] = @(slider.doubleValue);
        node[@"min"] = @(slider.minValue);
        node[@"max"] = @(slider.maxValue);
    }
    else if ([element.kind isEqualToString:@"colorwell"]) {
        node[@"value"] = VibeHexStringFromColor(((NSColorWell *)view).color) ?: @"";
    }
    else if ([view isKindOfClass:NSTextField.class]) {
        node[@"value"] = ((NSTextField *)view).stringValue ?: @"";
    }
    return node;
}

static NSDictionary *VibeElementJSON(VibeSettingsElement *element, NSUInteger index, NSWindow *window) {
    NSMutableDictionary *node = [VibeElementStateJSON(element) mutableCopy];
    node[@"index"] = @(index);
    node[@"kind"] = element.kind;
    node[@"name"] = element.name;
    if (element.label.length) {
        node[@"label"] = element.label;
    }
    NSDictionary *rect = VibeElementRect(element.view, window);
    if (rect) {
        node[@"rect"] = rect;
    }
    if (element.view.isHiddenOrHasHiddenAncestor) {
        node[@"hidden"] = @YES;
    }
    return node;
}

#pragma mark - Addressing a control

// `#3` is the dump's index; anything else matches the name, the row label or a
// button's title, case-insensitively — exactly first, then as a substring, so
// "delete" reaches "Delete Original After Convert". An ambiguous match is an
// error naming the candidates rather than a guess.
static VibeSettingsElement *VibeElementForToken(NSArray<VibeSettingsElement *> *elements,
                                                NSString *token, NSString *paneName,
                                                NSString **errorJSON) {
    if ([token hasPrefix:@"#"]) {
        NSScanner *scanner = [NSScanner scannerWithString:[token substringFromIndex:1]];
        NSInteger index = 0;
        if ([scanner scanInteger:&index] && scanner.isAtEnd &&
                index >= 0 && index < (NSInteger)elements.count) {
            return elements[(NSUInteger)index];
        }
        *errorJSON = VibeErrorJSON(@"no control %@ in the %@ pane (it has %lu)",
                token, paneName, (unsigned long)elements.count);
        return nil;
    }
    for (NSUInteger pass = 0; pass < 2; pass++) {
        NSMutableArray<VibeSettingsElement *> *matches = [NSMutableArray array];
        for (VibeSettingsElement *element in elements) {
            NSArray<NSString *> *candidates = @[element.name, element.label ?: @""];
            for (NSString *candidate in candidates) {
                BOOL hit = pass == 0
                        ? [candidate caseInsensitiveCompare:token] == NSOrderedSame
                        : [candidate rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound;
                if (candidate.length && hit) {
                    [matches addObject:element];
                    break;
                }
            }
        }
        if (matches.count == 1) {
            return matches.firstObject;
        }
        if (matches.count > 1) {
            // A hidden page's controls stay in the dump for honesty, but a
            // NAME should resolve against what is on screen: the two-page
            // Appearance pane has an "Appearance" popup on each page, and
            // without this tie-break neither is ever reachable by name.
            NSMutableArray<VibeSettingsElement *> *visible = [NSMutableArray array];
            for (VibeSettingsElement *match in matches) {
                if (!match.view.isHiddenOrHasHiddenAncestor) {
                    [visible addObject:match];
                }
            }
            if (visible.count == 1) {
                return visible.firstObject;
            }
            if (visible.count) {
                matches = visible;
            }
            // A readout beside a control legitimately shares its row's label
            // (the corner-radius slider's px value), and a readout cannot be
            // clicked — so the unclickable kinds only make a name ambiguous
            // when nothing clickable matched.
            NSMutableArray<VibeSettingsElement *> *clickable = [NSMutableArray array];
            for (VibeSettingsElement *match in matches) {
                if (![match.kind isEqualToString:@"label"] &&
                        ![match.kind isEqualToString:@"field"] &&
                        ![match.kind isEqualToString:@"control"]) {
                    [clickable addObject:match];
                }
            }
            if (clickable.count == 1) {
                return clickable.firstObject;
            }
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (VibeSettingsElement *match in matches) {
                [names addObject:match.name];
            }
            *errorJSON = VibeErrorJSON(@"'%@' matches %lu controls (%@) — use a longer name or #index",
                    token, (unsigned long)matches.count, [names componentsJoinedByString:@", "]);
            return nil;
        }
    }
    *errorJSON = VibeErrorJSON(@"no control matching '%@' in the %@ pane (run dump_settings_ui)",
            token, paneName);
    return nil;
}

static NSMenuItem *VibeMenuItemForToken(NSPopUpButton *popUp, NSString *token, NSString **errorJSON) {
    NSArray<NSMenuItem *> *items = popUp.itemArray;
    if ([token hasPrefix:@"#"]) {
        NSScanner *scanner = [NSScanner scannerWithString:[token substringFromIndex:1]];
        NSInteger index = 0;
        if ([scanner scanInteger:&index] && scanner.isAtEnd &&
                index >= 0 && index < (NSInteger)items.count) {
            return items[(NSUInteger)index];
        }
        *errorJSON = VibeErrorJSON(@"no item %@ in '%@' (it has %lu)",
                token, popUp.itemArray.firstObject.title ?: @"", (unsigned long)items.count);
        return nil;
    }
    for (NSUInteger pass = 0; pass < 2; pass++) {
        for (NSMenuItem *item in items) {
            // The identifier a localized title hides, first: waveform styles,
            // key notations and appearances are all chosen by it.
            NSString *represented = [item.representedObject isKindOfClass:NSString.class]
                    ? item.representedObject : @"";
            BOOL hit = pass == 0
                    ? ([item.title caseInsensitiveCompare:token] == NSOrderedSame ||
                       [represented caseInsensitiveCompare:token] == NSOrderedSame)
                    : [item.title rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound;
            if (hit) {
                return item;
            }
        }
    }
    *errorJSON = VibeErrorJSON(@"no menu item matching '%@' (run dump_settings_ui for the item list)", token);
    return nil;
}

#pragma mark - Activating a control

static NSString *VibeClickReply(VibeSettingsElement *element, NSString *action) {
    NSMutableDictionary *reply = [VibeElementStateJSON(element) mutableCopy];
    reply[@"ok"] = @YES;
    reply[@"control"] = element.name;
    reply[@"kind"] = element.kind;
    reply[@"action"] = action;
    return VibeJSONString(reply);
}

// Buttons, checkboxes and radios go through performClick:, the real click path,
// rather than a state write plus a hand-sent action: only the click keeps a
// radio group's siblings in step. on|off is therefore idempotent — already in
// that state means no click at all.
static NSString *VibeClickButton(VibeSettingsElement *element, NSString *value) {
    NSButton *button = (NSButton *)element.view;
    BOOL stateful = ![element.kind isEqualToString:@"button"];
    if (!value) {
        [button performClick:nil];
        return VibeClickReply(element, @"clicked");
    }
    if (!stateful) {
        return VibeErrorJSON(@"'%@' is a push button and takes no value", element.name);
    }
    NSString *wanted = value.lowercaseString;
    if ([wanted isEqualToString:@"toggle"]) {
        [button performClick:nil];
        return VibeClickReply(element, @"clicked");
    }
    if (![wanted isEqualToString:@"on"] && ![wanted isEqualToString:@"off"]) {
        return VibeErrorJSON(@"'%@' takes on, off or toggle, not '%@'", element.name, value);
    }
    BOOL wantOn = [wanted isEqualToString:@"on"];
    if ([element.kind isEqualToString:@"radio"] && !wantOn) {
        return VibeErrorJSON(@"a radio button cannot be switched off; click the other one on instead");
    }
    if ((button.state == NSControlStateValueOn) == wantOn) {
        return VibeClickReply(element, @"unchanged");
    }
    [button performClick:nil];
    if ((button.state == NSControlStateValueOn) != wantOn) {
        return VibeErrorJSON(@"'%@' is still %@ after the click", element.name,
                VibeStateName(button.state));
    }
    return VibeClickReply(element, @"clicked");
}

// A switch has no cell, so performClick: is not its click path; a real toggle
// is a state flip plus one action send, and that is what this does. on|off is
// idempotent like the checkbox's.
static NSString *VibeToggleSwitch(VibeSettingsElement *element, NSString *value) {
    NSSwitch *toggle = (NSSwitch *)element.view;
    NSString *wanted = value.lowercaseString ?: @"toggle";
    if (![wanted isEqualToString:@"toggle"] &&
            ![wanted isEqualToString:@"on"] && ![wanted isEqualToString:@"off"]) {
        return VibeErrorJSON(@"'%@' takes on, off or toggle, not '%@'", element.name, value);
    }
    BOOL isOn = toggle.state == NSControlStateValueOn;
    BOOL wantOn = [wanted isEqualToString:@"toggle"] ? !isOn : [wanted isEqualToString:@"on"];
    if (isOn == wantOn) {
        return VibeClickReply(element, @"unchanged");
    }
    toggle.state = wantOn ? NSControlStateValueOn : NSControlStateValueOff;
    if (toggle.action && ![NSApp sendAction:toggle.action to:toggle.target from:toggle]) {
        return VibeErrorJSON(@"no responder handled %@", NSStringFromSelector(toggle.action));
    }
    return VibeClickReply(element, @"clicked");
}

// A popup or pull-down is NOT clicked: opening its menu spins a modal tracking
// loop, and the command channel, on the main queue, could never deliver
// anything to close it again. Choosing an item programmatically takes the same
// two steps AppKit does — select it, then send the item's own action if it
// carries one (the output devices do), else the button's.
static NSString *VibeChooseMenuItem(VibeSettingsElement *element, NSString *value) {
    NSPopUpButton *popUp = (NSPopUpButton *)element.view;
    BOOL isPullDown = [element.kind isEqualToString:@"pulldown"];
    if (!value) {
        return VibeErrorJSON(@"'%@' needs an item: settings_click '%@' <item-or-#index>",
                element.name, element.name);
    }
    NSString *errorJSON = nil;
    NSMenuItem *item = VibeMenuItemForToken(popUp, value, &errorJSON);
    if (!item) {
        return errorJSON;
    }
    if (isPullDown && item == popUp.itemArray.firstObject) {
        return VibeErrorJSON(@"item 0 of a pull-down is its title, not a choice");
    }
    if (!item.isEnabled) {
        return VibeErrorJSON(@"menu item '%@' is disabled", item.title);
    }
    if (!isPullDown) {
        [popUp selectItem:item];
    }
    SEL action = item.action ?: popUp.action;
    id target = item.action ? item.target : popUp.target;
    id sender = item.action ? (id)item : (id)popUp;
    if (action && ![NSApp sendAction:action to:target from:sender]) {
        return VibeErrorJSON(@"no responder handled %@", NSStringFromSelector(action));
    }
    NSMutableDictionary *reply = [VibeElementStateJSON(element) mutableCopy];
    reply[@"ok"] = @YES;
    reply[@"control"] = element.name;
    reply[@"kind"] = element.kind;
    reply[@"action"] = @"chose";
    reply[@"chose"] = item.title ?: @"";
    return VibeJSONString(reply);
}

static NSString *VibeSelectTableRows(VibeSettingsElement *element, NSString *value) {
    NSTableView *table = (NSTableView *)element.view;
    if (!value) {
        return VibeErrorJSON(@"'%@' is a list: settings_click '%@' <row[,row...] | all | none>",
                element.name, element.name);
    }
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    NSString *wanted = value.lowercaseString;
    if ([wanted isEqualToString:@"all"]) {
        [rows addIndexesInRange:NSMakeRange(0, (NSUInteger)table.numberOfRows)];
    }
    else if (![wanted isEqualToString:@"none"]) {
        for (NSString *token in [value componentsSeparatedByString:@","]) {
            NSScanner *scanner = [NSScanner scannerWithString:token];
            NSInteger row = 0;
            if (![scanner scanInteger:&row] || !scanner.isAtEnd) {
                return VibeErrorJSON(@"'%@' is not a row list (rows, all or none)", value);
            }
            if (row < 0 || row >= table.numberOfRows) {
                return VibeErrorJSON(@"row %ld is out of range (%ld rows)",
                        (long)row, (long)table.numberOfRows);
            }
            [rows addIndex:(NSUInteger)row];
        }
    }
    if (rows.count > 1 && !table.allowsMultipleSelection) {
        return VibeErrorJSON(@"'%@' does not allow a multiple selection", element.name);
    }
    // Posts the selection-changed notification and runs the delegate, the same
    // as a click on the row, which is what re-enables the buttons beside it.
    [table selectRowIndexes:rows byExtendingSelection:NO];
    return VibeClickReply(element, @"selected");
}

#pragma mark - The verbs

NSString *VibeDebugSettingsOpen(NSArray<NSString *> *tokens) {
    if (tokens.count > 2) {
        return VibeErrorJSON(@"usage: settings_open [pane]");
    }
    AppDelegate *appDelegate = (AppDelegate *)NSApp.delegate;
    if (![appDelegate isKindOfClass:AppDelegate.class]) {
        return VibeErrorJSON(@"app not fully launched");
    }
    // The menu's own path: it creates the window on first use and levels it
    // with the player's.
    [appDelegate showSettingsWindow:nil];
    NSString *errorJSON = nil;
    NSTabViewController *tabs = VibeSettingsTabs(&errorJSON);
    if (!tabs) {
        return errorJSON;
    }
    if (tokens.count == 2) {
        NSInteger index = VibePaneIndexForToken(tabs, tokens[1]);
        if (index < 0) {
            return VibeErrorJSON(@"no settings pane '%@' (panes: %@)",
                    tokens[1], VibePaneNameList(tabs));
        }
        // The tab controller's own selection path, so the pane's
        // refreshFromSettings and the animated window resize both run.
        tabs.selectedTabViewItemIndex = index;
    }
    NSWindow *window = VibeSettingsWindow();
    NSTabViewItem *selected = VibeSelectedPane(tabs);
    if (!selected) {
        return VibeErrorJSON(@"no pane is selected");
    }
    // After a layout flush: whether the pane's view fills the tab view is
    // the one thing dump_settings_ui cannot show — a pane collapsed to its
    // fitting size (loadPaneWithSections:'s autoresizing trap) still drew
    // every control and reported a plausible rect while no click could land.
    [window.contentView layoutSubtreeIfNeeded];
    NSView *paneView = selected.viewController.view;
    return VibeJSONString(@{
        @"ok": @YES,
        @"pane": VibePaneIdentifier(selected),
        @"paneTitle": selected.label ?: @"",
        @"panes": VibePaneList(tabs),
        @"frame": NSStringFromRect(window.frame),
        @"paneFrame": NSStringFromRect(paneView.frame),
        @"paneFillsTabView": @(paneView.superview != nil
                && NSEqualRects(paneView.frame, paneView.superview.bounds)),
        @"key": @(window.isKeyWindow),
    });
}

NSString *VibeDebugSettingsResize(NSArray<NSString *> *tokens) {
    double width = 0, height = 0;
    if (tokens.count != 3 || !VibeParseDouble(tokens[1], &width)
            || !VibeParseDouble(tokens[2], &height)) {
        return VibeErrorJSON(@"usage: settings_resize <width> <height>");
    }
    NSWindow *window = VibeSettingsWindow();
    if (!window) {
        return VibeErrorJSON(@"settings window is not open (run settings_open)");
    }
    NSSize minSize = window.contentMinSize;
    // The window refuses engine-driven size changes, so the resize must go
    // through the controller's blessed funnel.
    [(SettingsWindowController *)window.windowController applyContentSize:
            NSMakeSize(MAX(width, minSize.width), MAX(height, minSize.height))];
    // Flush layout so any constraint-driven snap-back would happen before the
    // reply reads the frame — its absence is what this verb verifies.
    [window layoutIfNeeded];
    return VibeJSONString(@{
        @"ok": @YES,
        @"frame": NSStringFromRect(window.frame),
        @"contentMinSize": NSStringFromSize(window.contentMinSize),
    });
}

NSString *VibeDebugSettingsClose(void) {
    NSWindow *window = VibeSettingsWindow();
    if (!window || !window.isVisible) {
        return VibeJSONString(@{@"ok": @YES, @"open": @NO});
    }
    // An open panel run as a sheet — Add Folder, Add Common Folder — cannot be
    // dismissed through the channel any other way: the injection verbs post
    // into the main player window, and powerbox owns the sheet itself.
    NSWindow *sheet = window.attachedSheet;
    if (sheet) {
        [window endSheet:sheet returnCode:NSModalResponseCancel];
    }
    [window performClose:nil];
    return VibeJSONString(@{
        @"ok": @YES,
        @"open": @(window.isVisible),
        @"endedSheet": @(sheet != nil),
    });
}

NSString *VibeDebugSettingsDump(void) {
    NSString *errorJSON = nil;
    NSTabViewController *tabs = VibeSettingsTabs(&errorJSON);
    if (!tabs) {
        return errorJSON;
    }
    NSWindow *window = VibeSettingsWindow();
    NSTabViewItem *selected = VibeSelectedPane(tabs);
    if (!selected) {
        return VibeErrorJSON(@"no pane is selected");
    }
    NSArray<VibeSettingsElement *> *elements = VibeElementsForPane(selected.viewController);
    NSMutableArray<NSDictionary *> *controls = [NSMutableArray array];
    [elements enumerateObjectsUsingBlock:^(VibeSettingsElement *element, NSUInteger index, BOOL *stop) {
        [controls addObject:VibeElementJSON(element, index, window)];
    }];
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    reply[@"pane"] = VibePaneIdentifier(selected);
    reply[@"paneTitle"] = selected.label ?: @"";
    reply[@"panes"] = VibePaneList(tabs);
    reply[@"controls"] = controls;
    reply[@"window"] = @{
        @"title": window.title ?: @"",
        @"frame": NSStringFromRect(window.frame),
        @"key": @(window.isKeyWindow),
    };
    if (window.attachedSheet) {
        reply[@"sheet"] = window.attachedSheet.className;
    }
    return VibeJSONString(reply);
}

NSString *VibeDebugSettingsClick(NSArray<NSString *> *tokens) {
    // The toolbar sits outside the pane, beyond the walker's reach; its
    // navigation pill and its light/dark preview toggle route by name so
    // scripts keep one addressing scheme. Both are the Appearance pane's own
    // model, so both are driven through it rather than through the control.
    BOOL back = tokens.count == 2 && [tokens[1] caseInsensitiveCompare:@"back"] == NSOrderedSame;
    BOOL forward = tokens.count == 2
            && [tokens[1] caseInsensitiveCompare:@"forward"] == NSOrderedSame;
    BOOL preview = tokens.count == 3
            && [tokens[1] caseInsensitiveCompare:@"preview"] == NSOrderedSame;
    if (back || forward || preview) {
        NSString *tabsError = nil;
        NSTabViewController *tabs = VibeSettingsTabs(&tabsError);
        if (!tabs) {
            return tabsError;
        }
        SettingsAppearanceViewController *pane =
                [(SettingsWindowController *)VibeSettingsWindow().windowController appearancePane];
        if (pane) {
            if (preview) {
                BOOL dark = [tokens[2] caseInsensitiveCompare:@"dark"] == NSOrderedSame;
                if (!dark && [tokens[2] caseInsensitiveCompare:@"light"] != NSOrderedSame) {
                    return VibeErrorJSON(@"usage: settings_click preview <light|dark>");
                }
                [pane previewAppearanceDark:dark];
                return VibeJSONString(@{@"ok": @YES, @"control": @"preview",
                                        @"action": @"previewed",
                                        @"windowAppearancePreview": tokens[2].lowercaseString,
                                        @"windowAppearance":
                                                AppSettings.sharedInstance.windowAppearanceStyle
                                                        ?: @""});
            }
            if (back ? pane.canGoBack : pane.canGoForward) {
                back ? [pane navigateBack] : [pane navigateForward];
                return VibeJSONString(@{@"ok": @YES, @"control": tokens[1].lowercaseString,
                                        @"action": @"navigated"});
            }
            return VibeErrorJSON(@"%@ is not available here", tokens[1].lowercaseString);
        }
    }
    NSString *usage = @"usage: settings_click <control> [value] — quote names with spaces";
    if (tokens.count < 2 || tokens.count > 3) {
        return VibeErrorJSON(@"%@", usage);
    }
    NSString *errorJSON = nil;
    NSTabViewController *tabs = VibeSettingsTabs(&errorJSON);
    if (!tabs) {
        return errorJSON;
    }
    NSWindow *window = VibeSettingsWindow();
    if (window.attachedSheet) {
        // A real click could not reach the pane behind a sheet, so neither does
        // this. settings_close ends the sheet.
        return VibeErrorJSON(@"a sheet (%@) is attached; nothing in the pane is reachable",
                window.attachedSheet.className);
    }
    NSTabViewItem *selected = VibeSelectedPane(tabs);
    if (!selected) {
        return VibeErrorJSON(@"no pane is selected");
    }
    NSArray<VibeSettingsElement *> *elements = VibeElementsForPane(selected.viewController);
    VibeSettingsElement *element = VibeElementForToken(elements, tokens[1],
            VibePaneIdentifier(selected), &errorJSON);
    if (!element) {
        return errorJSON;
    }
    NSString *value = tokens.count == 3 ? tokens[2] : nil;
    if (element.view.isHiddenOrHasHiddenAncestor) {
        return VibeErrorJSON(@"'%@' is hidden", element.name);
    }
    if ([element.view isKindOfClass:NSControl.class] && !((NSControl *)element.view).isEnabled) {
        return VibeErrorJSON(@"'%@' is disabled", element.name);
    }
    if ([element.kind isEqualToString:@"popup"] || [element.kind isEqualToString:@"pulldown"]) {
        return VibeChooseMenuItem(element, value);
    }
    if ([element.view isKindOfClass:NSButton.class]) {
        return VibeClickButton(element, value);
    }
    if ([element.kind isEqualToString:@"switch"]) {
        return VibeToggleSwitch(element, value);
    }
    if ([element.kind isEqualToString:@"table"]) {
        return VibeSelectTableRows(element, value);
    }
    if ([element.kind isEqualToString:@"slider"]) {
        double number = 0;
        if (!value || !VibeParseDouble(value, &number)) {
            return VibeErrorJSON(@"'%@' is a slider and needs a number", element.name);
        }
        NSSlider *slider = (NSSlider *)element.view;
        slider.doubleValue = number;
        if (slider.action && ![NSApp sendAction:slider.action to:slider.target from:slider]) {
            return VibeErrorJSON(@"no responder handled %@", NSStringFromSelector(slider.action));
        }
        return VibeClickReply(element, @"set");
    }
    if ([element.kind isEqualToString:@"colorwell"]) {
        // The value is the same #RRGGBB the dump reports, so the pane's
        // action-side hex persistence round-trips through this verb.
        NSColor *color = value ? VibeColorFromHexString(value) : nil;
        if (!color) {
            return VibeErrorJSON(@"'%@' is a color well and needs #RRGGBB", element.name);
        }
        NSColorWell *well = (NSColorWell *)element.view;
        well.color = color;
        if (well.action && ![NSApp sendAction:well.action to:well.target from:well]) {
            return VibeErrorJSON(@"no responder handled %@", NSStringFromSelector(well.action));
        }
        return VibeClickReply(element, @"set");
    }
    return VibeErrorJSON(@"'%@' is a %@, not something to click", element.name, element.kind);
}

#endif
