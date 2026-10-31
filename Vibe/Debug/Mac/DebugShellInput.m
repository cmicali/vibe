//
//  DebugShellInput.m
//  Vibe
//
//  The input verbs that reach the shell: shortcut remapping, the named gesture
//  probes, and direct row selection. The posting is vibe-libs'
//  dev/DebugVerbs (DebugSyntheticInput.h).
//

#import "DebugInternal.h"
#import "PlaylistTableView.h"
#import "PitchFaderView.h"
#import "AppSettings+Mac.h"
#import "MenuShortcutRules.h"
#import "ShortcutLayout.h"
#import "MainPlayerController+Settings.h"

#if DEBUG

// The pane's write path, keyed by the key names `key` takes.
NSString *VibeSetShortcut(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    if (tokens.count < 3) {
        return VibeErrorJSON(@"usage: set_shortcut <identifier> <key|none> [shift|cmd|opt|ctrl ...]");
    }
    NSString *identifier = tokens[1];
    if (![VibeShortcutIdentifiers() containsObject:identifier]) {
        return VibeErrorJSON(@"'%@' has no remappable shortcut (%@)", identifier,
                             [VibeShortcutIdentifiers() componentsJoinedByString:@", "]);
    }
    NSString *name = tokens[2].lowercaseString;
    VibeShortcut shortcut = kVibeShortcutNone;
    if (![name isEqualToString:@"none"]) {
        NSNumber *code = VibeKeyCodeForName(name);
        if (code == nil) {
            return VibeErrorJSON(@"unknown key '%@'", tokens[2]);
        }
        NSEventModifierFlags flags = 0;
        BOOL repeat = NO;
        NSString *errorJSON = nil;
        if (!VibeParseModifiers(tokens, 3, &flags, &repeat, &errorJSON)) {
            return errorJSON;
        }
        shortcut = VibeShortcutMake(code.unsignedShortValue, flags);
    }
    NSString *loser = nil;
    switch ([controller assignShortcut:shortcut toCommand:identifier loser:&loser]) {
        case VibeShortcutAssignmentReserved:
            return VibeErrorJSON(@"%@ is reserved", VibeShortcutDisplayString(shortcut));
        case VibeShortcutAssignmentUnusable:
            return VibeErrorJSON(@"%@ has no name in this layout", tokens[2]);
        case VibeShortcutAssignmentStored:
            break;
    }
    VibeDebugSettingsRefreshSelectedPane();
    VibeShortcut stored = VibeShortcutEffective(VibeShortcutTable(), identifier, AppSettings.sharedInstance.shortcutOverrides);
    return VibeJSONString(@{
        @"ok": @YES,
        @"command": identifier,
        @"shortcut": VibeShortcutDisplayString(stored),
        @"lost_by": loser ?: [NSNull null],
    });
}

NSString *VibeResetShortcuts(MainPlayerController *controller) {
    [controller setShortcutOverrides:@{}];
    VibeDebugSettingsRefreshSelectedPane();
    return VibeJSONString(@{@"ok": @YES});
}

// Resolves and hit-tests the real control after activation, in the same
// main-thread turn that queues the whole gesture. The runner checks the
// resulting pitch; queued events alone are not a pass.
NSString *VibeTestGesture(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    BOOL reset = tokens.count == 3 && [tokens[1] isEqualToString:@"pitch-reset"];
    BOOL drag = tokens.count == 3 && [tokens[1] isEqualToString:@"pitch-drag"];
    if ((!reset && !drag) || ![tokens.lastObject isEqualToString:@"isolated-desktop"]) {
        return VibeErrorJSON(@"usage: gesture_test pitch-reset|pitch-drag isolated-desktop (dedicated test Mac or VM only)");
    }
    NSWindow *window = controller.window;
    if (!window.isVisible || !((MainWindow *)window).isPitchPanelShown) {
        return VibeErrorJSON(@"gesture target unavailable: show the player and pitch panel first");
    }
    VibeMakeWindowKeyForInjection(window);
    if (!window.isKeyWindow) {
        return VibeErrorJSON(@"gesture target unavailable: player is not key");
    }
    [window.contentView layoutSubtreeIfNeeded];
    PitchFaderView *fader = nil;
    for (NSView *view in controller.pitchPanel.subviews) {
        if ([view isKindOfClass:PitchFaderView.class]) {
            fader = (PitchFaderView *)view;
            break;
        }
    }
    if (!fader || fader.isHiddenOrHasHiddenAncestor || NSIsEmptyRect(fader.visibleRect)) {
        return VibeErrorJSON(@"gesture target unavailable: pitch fader is hidden");
    }
    NSRect bounds = fader.bounds;
    NSPoint end = [fader convertPoint:NSMakePoint(NSMidX(bounds), NSMinY(bounds) + NSHeight(bounds) * 0.75) toView:nil];
    // Reset off-center: a plain scale click must not satisfy the double-click
    // assertion merely by landing on zero. Drag starts on the centered knob.
    NSPoint start = reset ? end : [fader convertPoint:NSMakePoint(NSMidX(bounds), NSMidY(bounds)) toView:nil];
    NSView *content = window.contentView;
    for (NSValue *value in @[[NSValue valueWithPoint:start], [NSValue valueWithPoint:end]]) {
        NSPoint point = value.pointValue;
        if (!NSPointInRect([fader convertPoint:point fromView:nil], fader.visibleRect)
                || [content hitTest:[content.superview convertPoint:point fromView:nil]] != fader) {
            return VibeErrorJSON(@"gesture target unavailable: pitch fader is clipped or covered");
        }
    }
    NSPoint from = VibeContentPointForWindowPoint(window, start);
    NSString *x1 = @(from.x).stringValue, *y1 = @(from.y).stringValue;
    if (reset) {
        return VibeInjectMouse(window, @[@"click", x1, y1, @"left", @"2"]);
    }
    NSPoint to = VibeContentPointForWindowPoint(window, end);
    return VibeInjectDrag(window, @[@"drag", x1, y1, @(to.x).stringValue, @(to.y).stringValue, @"20"]);
}

// Selection is a table operation; removal is the shell's transport decision.
// Neither needs a key window, a visible pane, or a pointer gesture.
NSString *VibeSelectPlaylistRows(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    PlaylistTableView *table = controller.playlistController.tableView;
    if (!table || tokens.count < 2) {
        return VibeErrorJSON(@"usage: select_rows all|none|<row|current> [row|current ...]");
    }
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    if (tokens.count == 2 && [tokens[1] isEqualToString:@"all"]) {
        [rows addIndexesInRange:NSMakeRange(0, (NSUInteger)table.numberOfRows)];
    }
    else if (!(tokens.count == 2 && [tokens[1] isEqualToString:@"none"])) {
        for (NSString *token in [tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]) {
            NSUInteger row = 0;
            if ([token isEqualToString:@"current"]) {
                row = controller.playlistController.currentIndex;
            }
            else if (!VibeParseNonnegativeInteger(token, &row)) {
                return VibeErrorJSON(@"select_rows requires nonnegative integer rows or current");
            }
            // A replacement or removal may have shortened the list since the
            // runner chose its rows. Select surviving row numbers, or none.
            if (row < (NSUInteger)table.numberOfRows) [rows addIndex:row];
        }
    }
    [table selectRowIndexes:rows byExtendingSelection:NO];
    NSMutableArray<NSNumber *> *selected = [NSMutableArray array];
    [table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        [selected addObject:@(row)];
    }];
    return VibeJSONString(@{@"ok": @YES, @"selectedRows": selected});
}

#endif
