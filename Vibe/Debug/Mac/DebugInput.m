//
//  DebugInput.m
//  Vibe
//
//  Synthesized input: keyboard, mouse, and the drag-and-drop of real files.
//

#import "DebugInternal.h"
#import "PlaylistTableView.h"
#import "PitchFaderView.h"
#import "AppSettings+Mac.h"
#import "MainMenuBuilder.h"
#import "MainPlayerController+Settings.h"
#import "LinkRules.h"

#if DEBUG

#pragma mark Input injection

// Synthesized NSEvents posted into the app's own event queue. Unlike the
// direct-action verbs they exercise real event dispatch, local monitors such
// as TransportKeyMonitor and view mouse handling included; unlike CGEvent
// injection through input.swift they need no Accessibility permission. Mouse
// injection still activates the window, and handlers can start native
// file/window dragging: app-local events are not containment.
//
// Two limits against real window-server events: tracking areas and hover
// effects do not fire, since the window server drives those, and the events
// are processed after the reply is written, so poll dump_state for the result.
//
// Mouse coordinates are content-view points with a top-left origin, the frame
// dump_screenshot renders: its pixels divided by the backing scale.

static NSTimeInterval VibeEventTimestamp(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static NSDictionary<NSString *, NSNumber *> *VibeKeyCodeMap(void) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // HIToolbox Events.h ANSI key codes, inline so Carbon stays unimported.
        map = @{
            @"a": @0,  @"s": @1,  @"d": @2,  @"f": @3,  @"h": @4,  @"g": @5,
            @"z": @6,  @"x": @7,  @"c": @8,  @"v": @9,  @"b": @11, @"q": @12,
            @"w": @13, @"e": @14, @"r": @15, @"y": @16, @"t": @17,
            @"1": @18, @"2": @19, @"3": @20, @"4": @21, @"6": @22, @"5": @23,
            @"9": @25, @"7": @26, @"8": @28, @"0": @29,
            @"o": @31, @"u": @32, @"i": @34, @"p": @35, @"l": @37, @"j": @38,
            @"k": @40, @"n": @45, @"m": @46,
            @"return": @36, @"tab": @48, @"space": @49, @"delete": @51, @"esc": @53,
            @"forward_delete": @117,
            @"left": @123, @"right": @124, @"down": @125, @"up": @126,
        };
    });
    return map;
}

static NSString *VibeKeyCharacters(NSString *name) {
    static NSDictionary<NSString *, NSString *> *special;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        special = @{
            @"return": @"\r", @"tab": @"\t", @"space": @" ",
            @"delete": @"\x7f", @"esc": @"\x1b",
            // Backspace and Forward Delete are different characters and reach
            // different code, so `key delete` does not cover both.
            @"forward_delete": [NSString stringWithFormat:@"%C", (unichar)NSDeleteFunctionKey],
            @"left": [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey],
            @"right": [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey],
            @"up": [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey],
            @"down": [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey],
        };
    });
    return special[name] ?: name;
}

// What `characters` carries with shift held. uppercaseString covers letters
// only, so the digits get their US-layout shifted forms explicitly.
static NSString *VibeShiftedKeyCharacters(NSString *chars) {
    static NSDictionary<NSString *, NSString *> *shifted;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shifted = @{
            @"1": @"!", @"2": @"@", @"3": @"#", @"4": @"$", @"5": @"%",
            @"6": @"^", @"7": @"&", @"8": @"*", @"9": @"(", @"0": @")",
        };
    });
    return shifted[chars] ?: chars.uppercaseString;
}

static BOOL VibeKeyIsArrow(NSString *name) {
    return [@[@"left", @"right", @"up", @"down"] containsObject:name];
}

// Characters AppKit places in the function-key private-use range — the arrows,
// both delete keys, the page and home cluster — which real events flag as such.
static BOOL VibeCharacterIsFunctionKey(NSString *chars) {
    if (chars.length != 1) {
        return NO;
    }
    unichar c = [chars characterAtIndex:0];
    return c >= NSUpArrowFunctionKey && c <= NSModeSwitchFunctionKey;
}

// Any tokens trailing the key name are modifier names, plus the repeat token.
static BOOL VibeParseModifiers(NSArray<NSString *> *tokens, NSUInteger start,
                               NSEventModifierFlags *outFlags, BOOL *outRepeat,
                               NSString **errorJSON) {
    NSEventModifierFlags flags = 0;
    BOOL repeat = NO;
    for (NSUInteger i = start; i < tokens.count; i++) {
        NSString *mod = tokens[i].lowercaseString;
        // Hardware key repeat, not a modifier flag: several handlers gate on
        // it (a held delete takes one row; the effect keys ignore repeats).
        if ([mod isEqualToString:@"repeat"]) {
            repeat = YES;
        }
        else if ([mod isEqualToString:@"shift"]) {
            flags |= NSEventModifierFlagShift;
        }
        else if ([mod isEqualToString:@"cmd"] || [mod isEqualToString:@"command"]) {
            flags |= NSEventModifierFlagCommand;
        }
        else if ([mod isEqualToString:@"opt"] || [mod isEqualToString:@"option"] || [mod isEqualToString:@"alt"]) {
            flags |= NSEventModifierFlagOption;
        }
        else if ([mod isEqualToString:@"ctrl"] || [mod isEqualToString:@"control"]) {
            flags |= NSEventModifierFlagControl;
        }
        else {
            *errorJSON = VibeErrorJSON(@"unknown modifier '%@' (shift, cmd, opt, ctrl, repeat)", tokens[i]);
            return NO;
        }
    }
    *outFlags = flags;
    *outRepeat = repeat;
    return YES;
}

// key posts a down and an up; key_down and key_up post one edge each, which
// is how a held Q/W/E/R/T effect key is driven: TransportKeyMonitor decides
// latch (tap) or revert (hold) on keyUp.
NSString *VibeInjectKey(MainPlayerController *controller, NSArray<NSString *> *tokens,
                               BOOL down, BOOL up) {
    NSString *verb = tokens.firstObject;
    if (tokens.count < 2) {
        return VibeErrorJSON(@"usage: %@ <key> [shift|cmd|opt|ctrl|repeat ...]", verb);
    }
    NSString *name = tokens[1].lowercaseString;
    NSNumber *code = VibeKeyCodeMap()[name];
    if (code == nil) {
        return VibeErrorJSON(@"unknown key '%@' (a-z, 0-9, space, tab, return, esc, delete, forward_delete, up, down, left, right)",
                tokens[1]);
    }
    NSEventModifierFlags flags = 0;
    BOOL isRepeat = NO;
    NSString *errorJSON = nil;
    if (!VibeParseModifiers(tokens, 2, &flags, &isRepeat, &errorJSON)) {
        return errorJSON;
    }
    NSString *chars = VibeKeyCharacters(name);
    // Derived from the character, not a list of key names, so a key added to
    // VibeKeyCodeMap carries the flag a real event would without a second edit.
    if (VibeCharacterIsFunctionKey(chars)) {
        flags |= NSEventModifierFlagFunction;
    }
    if (VibeKeyIsArrow(name)) {
        flags |= NSEventModifierFlagNumericPad;   // real arrow events carry it too
    }
    // charactersIgnoringModifiers ignores Option, NOT Shift: hardware delivers
    // the shifted character in BOTH fields, and AppKit's menu key-equivalent
    // matching reads it — a lowercase char there makes ⇧⌘C match a plain ⌘C
    // equivalent instead of the ⇧⌘C one.
    NSString *charsWithMods = (flags & NSEventModifierFlagShift) ? VibeShiftedKeyCharacters(chars) : chars;
    NSWindow *window = controller.window;
    void (^post)(NSEventType) = ^(NSEventType type) {
        NSEvent *event = [NSEvent keyEventWithType:type
                                          location:NSZeroPoint
                                     modifierFlags:flags
                                         timestamp:VibeEventTimestamp()
                                      windowNumber:window.windowNumber
                                           context:nil
                                        characters:charsWithMods
                       charactersIgnoringModifiers:charsWithMods
                                         isARepeat:isRepeat
                                           keyCode:code.unsignedShortValue];
        [NSApp postEvent:event atStart:NO];
    };
    if (down) {
        post(NSEventTypeKeyDown);
    }
    if (up) {
        post(NSEventTypeKeyUp);
    }
    return VibeJSONString(@{@"ok": @YES, @"posted": verb, @"key": name, @"repeat": @(isRepeat)});
}

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
        NSNumber *code = VibeKeyCodeMap()[name];
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
            return VibeErrorJSON(@"%@ is reserved", [MainMenuBuilder displayStringForShortcut:shortcut]);
        case VibeShortcutAssignmentUnusable:
            return VibeErrorJSON(@"%@ has no name in this layout", tokens[2]);
        case VibeShortcutAssignmentStored:
            break;
    }
    VibeDebugSettingsRefreshSelectedPane();
    VibeShortcut stored = VibeShortcutEffective(identifier, AppSettings.sharedInstance.shortcutOverrides);
    return VibeJSONString(@{
        @"ok": @YES,
        @"command": identifier,
        @"shortcut": [MainMenuBuilder displayStringForShortcut:stored],
        @"lost_by": loser ?: [NSNull null],
    });
}

NSString *VibeResetShortcuts(MainPlayerController *controller) {
    [controller resetShortcuts];
    VibeDebugSettingsRefreshSelectedPane();
    return VibeJSONString(@{@"ok": @YES});
}

static NSPoint VibeWindowPointForContentPoint(NSWindow *window, double x, double y) {
    NSView *content = window.contentView;
    return [content convertPoint:NSMakePoint(x, content.isFlipped ? y : NSHeight(content.bounds) - y)
                          toView:nil];
}

static NSPoint VibeContentPointForWindowPoint(NSWindow *window, NSPoint point) {
    NSView *content = window.contentView;
    NSPoint local = [content convertPoint:point fromView:nil];
    return NSMakePoint(local.x, content.isFlipped ? local.y : NSHeight(content.bounds) - local.y);
}

// Replies with the hit-tested view, so a missed aim shows in the reply rather
// than silently doing nothing.
static NSString *VibeMouseReply(NSString *verb, NSWindow *window, NSPoint location,
                                double x, double y) {
    NSView *content = window.contentView;
    NSView *hit = (content && content.superview)
            ? [content hitTest:[content.superview convertPoint:location fromView:nil]]
            : nil;
    return VibeJSONString(@{
        @"ok": @YES,
        @"posted": verb,
        @"x": @(x),
        @"y": @(y),
        @"hitView": hit ? hit.className : (id)NSNull.null,
        @"windowKey": @(window.isKeyWindow),
    });
}

// A non-key window swallows the first click as activation (acceptsFirstMouse
// defaults to NO), so mouse injection activates first. The deprecated force
// spelling, because the cooperative [NSApp activate] is declined while another
// app is frontmost, which is exactly where a shell-driven test runs.
// Activation lands asynchronously and events posted before it are swallowed,
// so spin the run loop briefly for key status; the reply's windowKey reports
// whether it took.
static void VibeMakeWindowKeyForInjection(NSWindow *window) {
    if (window.isKeyWindow) {
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    [window makeKeyAndOrderFront:nil];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (!window.isKeyWindow && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

static NSEvent *VibeMouseEvent(NSEventType type, NSPoint location, NSInteger windowNumber,
                               NSInteger clickCount, float pressure) {
    return [NSEvent mouseEventWithType:type
                              location:location
                         modifierFlags:0
                             timestamp:VibeEventTimestamp()
                          windowNumber:windowNumber
                               context:nil
                           eventNumber:0
                            clickCount:clickCount
                              pressure:pressure];
}

// mouse_move with a button token posts a dragged event. CAUTION: a lone
// mouse_down on a control that runs a modal mouse-tracking loop stalls the app
// inside that loop, and the command channel, on the GCD main queue, cannot
// deliver the matching mouse_up while it spins. Use `click` or `drag`, whose
// events are all queued before the loop starts.
NSString *VibeInjectMouse(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    NSString *verb = tokens.firstObject;
    BOOL isClick = [verb isEqualToString:@"click"];
    NSString *usage = isClick
            ? @"usage: click <x> <y> [left|right] [clickCount]"
            : [NSString stringWithFormat:@"usage: %@ <x> <y> [left|right]", verb];
    double x = 0, y = 0;
    if (tokens.count < 3 || !VibeParseDouble(tokens[1], &x) || !VibeParseDouble(tokens[2], &y)) {
        return VibeErrorJSON(@"%@", usage);
    }
    NSUInteger next = 3;
    BOOL right = NO;
    BOOL haveButton = NO;
    if (tokens.count > next) {
        NSString *button = tokens[next].lowercaseString;
        if ([button isEqualToString:@"left"] || [button isEqualToString:@"right"]) {
            right = [button isEqualToString:@"right"];
            haveButton = YES;
            next++;
        }
    }
    NSInteger clickCount = 1;
    if (isClick && tokens.count > next) {
        clickCount = tokens[next].integerValue;
        if (clickCount < 1 || clickCount > 3) {
            return VibeErrorJSON(@"clickCount must be 1-3");
        }
        next++;
    }
    if (tokens.count > next) {
        return VibeErrorJSON(@"%@", usage);
    }
    NSWindow *window = controller.window;
    VibeMakeWindowKeyForInjection(window);
    NSPoint location = VibeWindowPointForContentPoint(window, x, y);
    NSInteger windowNumber = window.windowNumber;
    if (isClick) {
        // A double-click is two press cycles with an ascending clickCount, as
        // the window server delivers one.
        for (NSInteger i = 1; i <= clickCount; i++) {
            [NSApp postEvent:VibeMouseEvent(right ? NSEventTypeRightMouseDown : NSEventTypeLeftMouseDown,
                                            location, windowNumber, i, 1.0) atStart:NO];
            [NSApp postEvent:VibeMouseEvent(right ? NSEventTypeRightMouseUp : NSEventTypeLeftMouseUp,
                                            location, windowNumber, i, 0.0) atStart:NO];
        }
    }
    else if ([verb isEqualToString:@"mouse_down"]) {
        [NSApp postEvent:VibeMouseEvent(right ? NSEventTypeRightMouseDown : NSEventTypeLeftMouseDown,
                                        location, windowNumber, 1, 1.0) atStart:NO];
    }
    else if ([verb isEqualToString:@"mouse_up"]) {
        [NSApp postEvent:VibeMouseEvent(right ? NSEventTypeRightMouseUp : NSEventTypeLeftMouseUp,
                                        location, windowNumber, 1, 0.0) atStart:NO];
    }
    else { // mouse_move
        NSEventType type = !haveButton ? NSEventTypeMouseMoved
                : (right ? NSEventTypeRightMouseDragged : NSEventTypeLeftMouseDragged);
        [NSApp postEvent:VibeMouseEvent(type, location, windowNumber, 0, haveButton ? 1.0 : 0.0)
                 atStart:NO];
    }
    return VibeMouseReply(verb, window, location, x, y);
}

// A whole left-button drag queued in one command, the only injection shape
// that works on tracking-loop controls; see VibeInjectMouse.
NSString *VibeInjectDrag(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    NSString *usage = @"usage: drag <x1> <y1> <x2> <y2> [steps]";
    double x1 = 0, y1 = 0, x2 = 0, y2 = 0;
    if (tokens.count < 5
            || !VibeParseDouble(tokens[1], &x1) || !VibeParseDouble(tokens[2], &y1)
            || !VibeParseDouble(tokens[3], &x2) || !VibeParseDouble(tokens[4], &y2)) {
        return VibeErrorJSON(@"%@", usage);
    }
    NSInteger steps = 12;
    if (tokens.count >= 6) {
        steps = tokens[5].integerValue;
        if (steps < 2 || steps > 200) {
            return VibeErrorJSON(@"steps must be 2-200");
        }
    }
    if (tokens.count > 6) {
        return VibeErrorJSON(@"%@", usage);
    }
    NSWindow *window = controller.window;
    VibeMakeWindowKeyForInjection(window);
    NSInteger windowNumber = window.windowNumber;
    NSPoint start = VibeWindowPointForContentPoint(window, x1, y1);
    [NSApp postEvent:VibeMouseEvent(NSEventTypeLeftMouseDown, start, windowNumber, 1, 1.0)
             atStart:NO];
    for (NSInteger i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        NSPoint p = VibeWindowPointForContentPoint(window, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
        [NSApp postEvent:VibeMouseEvent(NSEventTypeLeftMouseDragged, p, windowNumber, 1, 1.0)
                 atStart:NO];
    }
    NSPoint end = VibeWindowPointForContentPoint(window, x2, y2);
    [NSApp postEvent:VibeMouseEvent(NSEventTypeLeftMouseUp, end, windowNumber, 1, 0.0)
             atStart:NO];
    return VibeMouseReply(@"drag", window, start, x1, y1);
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
        return VibeInjectMouse(controller, @[@"click", x1, y1, @"left", @"2"]);
    }
    NSPoint to = VibeContentPointForWindowPoint(window, end);
    return VibeInjectDrag(controller, @[@"drag", x1, y1, @(to.x).stringValue, @(to.y).stringValue, @"20"]);
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

#pragma mark Synthetic file drags

// file_drag_hover, file_drag_drop and file_drag_end drive the FileDropDelegate
// path a real external file drag takes through MainWindow, as direct delegate
// calls with no mouse events or NSDraggingSession: mouse handlers can start
// window-server dragging, which unattended stress must avoid. Coordinates are
// the mouse verbs'. file_drag_drop takes a link too, dropped as text.

static NSString *VibeWellName(PlaylistDropWellAction action) {
    switch (action) {
        case PlaylistDropWellActionReplace: return @"replace";
        case PlaylistDropWellActionAdd:     return @"add";
        case PlaylistDropWellActionNone:    return @"none";
    }
}

// Returns NO with *errorJSON set on a malformed pair.
static BOOL VibeDragPointArgument(NSArray<NSString *> *tokens, NSWindow *window,
                                  NSPoint *outLocation, double *outX, double *outY,
                                  NSString **errorJSON) {
    NSString *verb = tokens.firstObject;
    double x = 0, y = 0;
    if (tokens.count < 3 || !VibeParseDouble(tokens[1], &x) || !VibeParseDouble(tokens[2], &y)) {
        *errorJSON = VibeErrorJSON(@"usage: %@ <x> <y>%@", verb,
                [verb isEqualToString:@"file_drag_drop"] ? @" <file-directory-or-link>" : @"");
        return NO;
    }
    *outX = x;
    *outY = y;
    *outLocation = VibeWindowPointForContentPoint(window, x, y);
    return YES;
}

NSString *VibeSyntheticFileDragHover(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    MainWindow *window = (MainWindow *)controller.window;
    NSPoint location;
    double x, y;
    NSString *errorJSON = nil;
    if (!VibeDragPointArgument(tokens, window, &location, &x, &y, &errorJSON)) {
        return errorJSON;
    }
    [window.dropDelegate mainWindow:window fileDraggingUpdatedAtLocation:location];
    // What a drop here would do: the assertable part of the reply.
    PlaylistDropWellAction well = [controller.playerContentView.playlistDropZoneView
            dropActionForWindowPoint:location];
    return VibeJSONString(@{@"ok": @YES, @"posted": @"file_drag_hover",
                            @"x": @(x), @"y": @(y), @"well": VibeWellName(well)});
}

NSString *VibeSyntheticFileDragEnd(MainPlayerController *controller) {
    MainWindow *window = (MainWindow *)controller.window;
    [window.dropDelegate mainWindowFileDraggingEnded:window];
    return VibeJSONString(@{@"ok": @YES, @"posted": @"file_drag_end"});
}

NSString *VibeSyntheticFileDragDrop(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    MainWindow *window = (MainWindow *)controller.window;
    NSPoint location;
    double x, y;
    NSString *errorJSON = nil;
    if (!VibeDragPointArgument(tokens, window, &location, &x, &y, &errorJSON)) {
        return errorJSON;
    }
    if (tokens.count < 4) {
        return VibeErrorJSON(@"usage: file_drag_drop <x> <y> <file-directory-or-link>");
    }
    NSString *argument = [[tokens subarrayWithRange:NSMakeRange(3, tokens.count - 3)]
            componentsJoinedByString:@" "];
    NSString *path = argument.stringByExpandingTildeInPath;
    // A file as Finder drags one. Anything else as a browser's text.
    NSDictionary<NSString *, NSString *> *item;
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        item = @{kVibeDropTypeFileURL: [NSURL fileURLWithPath:path].absoluteString};
    }
    else if (VibeLinkIsWebLink(VibeLinkURLFromString(argument))) {
        item = @{kVibeDropTypeText: argument};
        path = argument;
    }
    else {
        return VibeErrorJSON(@"no file or directory at '%@'", path);
    }
    // For the reply only, resolved before anything mutates; the delivery
    // below re-resolves it.
    PlaylistDropWellAction well = [controller.playerContentView.playlistDropZoneView
            dropActionForWindowPoint:location];
    // performDragOperation:'s order: the well's append flag, the open funnel,
    // then draggingEnded's teardown. The funnel owns the expansion and a
    // link's resolve, so this returns without waiting; poll dump_state for the
    // playlist. As with `open`, an ungranted path may be denied at read time.
    BOOL append = [window.dropDelegate mainWindow:window dropAppendsAtLocation:location];
    [window openDroppedItems:@[item] appending:append];
    [window.dropDelegate mainWindowFileDraggingEnded:window];
    return VibeJSONString(@{@"ok": @YES, @"dropping": path,
                            @"x": @(x), @"y": @(y), @"well": VibeWellName(well)});
}

#pragma mark Synthetic reorder drags

// The reorder verbs drive the playlist's row-reorder drag through the
// NSTableViewDataSource methods a real session calls, in the same order:
// writer per dragged row, willBegin, validate, accept, ended. No
// NSDraggingSession is started; a stand-in NSDraggingInfo carries the real
// table as draggingSource and what the real writers minted as its pasteboard.
// Everything downstream — token match, survivor resolution, slot arithmetic,
// the model move, table reconciliation, undo — is the shipping path. AppKit's
// half is not exercised: the drag threshold, which rows a gesture picks up,
// the insertion line, autoscroll. The session deliberately survives across
// commands, so another verb can mutate the playlist mid-drag — races no
// pointer can stage deterministically.

// The stand-in dragging info. Only draggingSource and draggingPasteboard are
// read by the reorder path; the rest of the protocol is inert.
@interface VibeDebugReorderDraggingInfo : NSObject <NSDraggingInfo>
@property (nonatomic, weak) id source;
@property (nonatomic, strong) NSPasteboard *pasteboard;
@end

@implementation VibeDebugReorderDraggingInfo
@synthesize numberOfValidItemsForDrop = _numberOfValidItemsForDrop;
@synthesize animatesToDestination = _animatesToDestination;
@synthesize draggingFormation = _draggingFormation;

- (NSWindow *)draggingDestinationWindow { return nil; }
- (NSDragOperation)draggingSourceOperationMask { return NSDragOperationMove; }
- (NSPoint)draggingLocation { return NSZeroPoint; }
- (NSPoint)draggedImageLocation { return NSZeroPoint; }
// Deprecated protocol members, inert, for conformance only.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (NSImage *)draggedImage { return nil; }
- (NSPasteboard *)draggingPasteboard { return self.pasteboard; }
- (id)draggingSource { return self.source; }
- (NSInteger)draggingSequenceNumber { return 1; }
- (void)slideDraggedImageTo:(NSPoint)screenPoint {}
- (NSArray<NSString *> *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination {
    return nil;
}
#pragma clang diagnostic pop
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)enumOpts
                                  forView:(NSView *)view
                                  classes:(NSArray<Class> *)classArray
                            searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id> *)searchOptions
                               usingBlock:(void (^)(NSDraggingItem *, NSInteger, BOOL *))block {}
- (NSSpringLoadingHighlight)springLoadingHighlight { return NSSpringLoadingHighlightNone; }
- (void)resetSpringLoading {}
@end

// One synthetic session at most, as with real drags. Statics rather than
// controller state: this is harness bookkeeping, and the controller's own
// session ivars are set and cleared by the real delegate calls.
static VibeDebugReorderDraggingInfo *vibeReorderInfo;
static NSPasteboard *vibeReorderPasteboard;

static void VibeReorderClearSession(void) {
    [vibeReorderPasteboard releaseGlobally];
    vibeReorderPasteboard = nil;
    vibeReorderInfo = nil;
}

// Ends a live synthetic session the way a real cancel would, so the
// controller's token and retained tracks are cleared through the same call.
static void VibeReorderEndSession(PlaylistController *playlist, NSDragOperation operation) {
    NSDraggingSession *noSession = nil;
    [playlist tableView:playlist.tableView draggingSession:noSession
           endedAtPoint:NSZeroPoint operation:operation];
    VibeReorderClearSession();
}

NSString *VibeReorderBegin(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    PlaylistController *playlist = controller.playlistController;
    NSTableView *table = playlist.tableView;
    if (!table) {
        return VibeErrorJSON(@"no playlist table");
    }
    if (tokens.count < 2) {
        return VibeErrorJSON(@"usage: reorder_begin <row> [row ...]");
    }
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (NSString *token in [tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]) {
        double row = 0;
        if (!VibeParseDouble(token, &row) || row < 0) {
            return VibeErrorJSON(@"usage: reorder_begin <row> [row ...]");
        }
        [rows addIndex:(NSUInteger)row];
    }
    // A leftover session would strand the controller's token; a real drag
    // cannot start while another is live, so neither can this one.
    if (vibeReorderInfo) {
        VibeReorderEndSession(playlist, NSDragOperationNone);
    }
    // Per dragged row, as AppKit asks; this mints the controller's session
    // token.
    NSMutableArray<id<NSPasteboardWriting>> *items = [NSMutableArray arrayWithCapacity:rows.count];
    __block NSUInteger refusedRow = NSNotFound;
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        id<NSPasteboardWriting> item = [playlist tableView:table
                                    pasteboardWriterForRow:(NSInteger)row];
        if (!item) {
            refusedRow = row;
            *stop = YES;
            return;
        }
        [items addObject:item];
    }];
    if (refusedRow != NSNotFound) {
        VibeReorderEndSession(playlist, NSDragOperationNone);
        return VibeErrorJSON(@"row %lu is not draggable", (unsigned long)refusedRow);
    }
    vibeReorderPasteboard = [NSPasteboard pasteboardWithUniqueName];
    [vibeReorderPasteboard clearContents];
    [vibeReorderPasteboard writeObjects:items];
    NSDraggingSession *noSession = nil;
    [playlist tableView:table draggingSession:noSession
       willBeginAtPoint:NSZeroPoint forRowIndexes:rows];
    vibeReorderInfo = [VibeDebugReorderDraggingInfo new];
    vibeReorderInfo.source = table;
    vibeReorderInfo.pasteboard = vibeReorderPasteboard;
    NSMutableArray<NSNumber *> *began = [NSMutableArray arrayWithCapacity:rows.count];
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        [began addObject:@(row)];
    }];
    return VibeJSONString(@{@"ok": @YES, @"rows": began});
}

static NSString *VibeReorderSlotArgument(NSArray<NSString *> *tokens, NSInteger *outSlot) {
    double slot = 0;
    if (tokens.count < 2 || !VibeParseDouble(tokens[1], &slot)) {
        return VibeErrorJSON(@"usage: %@ <slot>", tokens.firstObject);
    }
    *outSlot = (NSInteger)slot;
    return nil;
}

NSString *VibeReorderUpdate(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    PlaylistController *playlist = controller.playlistController;
    if (!vibeReorderInfo) {
        return VibeErrorJSON(@"no reorder session; run reorder_begin first");
    }
    NSInteger slot = 0;
    NSString *errorJSON = VibeReorderSlotArgument(tokens, &slot);
    if (errorJSON) {
        return errorJSON;
    }
    NSDragOperation operation = [playlist tableView:playlist.tableView
                                       validateDrop:vibeReorderInfo
                                        proposedRow:slot
                              proposedDropOperation:NSTableViewDropAbove];
    return VibeJSONString(@{@"ok": @YES, @"slot": @(slot),
                            @"operation": operation == NSDragOperationMove ? @"move" : @"none"});
}

NSString *VibeReorderDrop(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    PlaylistController *playlist = controller.playlistController;
    if (!vibeReorderInfo) {
        return VibeErrorJSON(@"no reorder session; run reorder_begin first");
    }
    NSInteger slot = 0;
    NSString *errorJSON = VibeReorderSlotArgument(tokens, &slot);
    if (errorJSON) {
        return errorJSON;
    }
    // AppKit's ordering: a drop is only delivered through a passing
    // validation, and the session ends either way — a refused slot slides
    // back, it does not keep dragging.
    NSTableView *table = playlist.tableView;
    BOOL dropped = NO;
    if ([playlist tableView:table validateDrop:vibeReorderInfo proposedRow:slot
      proposedDropOperation:NSTableViewDropAbove] == NSDragOperationMove) {
        dropped = [playlist tableView:table acceptDrop:vibeReorderInfo row:slot
                        dropOperation:NSTableViewDropAbove];
    }
    VibeReorderEndSession(playlist, dropped ? NSDragOperationMove : NSDragOperationNone);
    return VibeJSONString(@{@"ok": @YES, @"slot": @(slot), @"dropped": @(dropped)});
}

NSString *VibeReorderCancel(MainPlayerController *controller) {
    if (!vibeReorderInfo) {
        return VibeErrorJSON(@"no reorder session; run reorder_begin first");
    }
    VibeReorderEndSession(controller.playlistController, NSDragOperationNone);
    return VibeJSONString(@{@"ok": @YES, @"cancelled": @YES});
}

#endif
