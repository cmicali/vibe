//
//  DebugInput.m
//  Vibe
//
//  Synthesized input: keyboard, mouse, and the drag-and-drop of real files.
//

#import "DebugInternal.h"

#if DEBUG

#pragma mark Input injection

// Synthesized NSEvents posted into the app's own event queue, through
// [NSApp postEvent:atStart:NO]. Unlike --debug-cmd's direct action calls,
// these exercise the real event dispatch path, local monitors such as
// TransportKeyMonitor and view mouse handling included, and unlike CGEvent
// injection through input.swift they need no Accessibility permission and no
// frontmost window.
//
// They have two structural limits against real window-server events. Tracking
// areas and hover effects do not fire, because the window server drives those.
// And the posted events are processed after the reply is written, so poll
// dump_state to observe the result.
//
// Mouse coordinates are main-window points with a top-left origin, the same
// frame of reference as dump_screenshot, which is the retina pixel divided by
// two. NSEvent wants bottom-left window coordinates, converted here.

static NSTimeInterval VibeEventTimestamp(void) {
    return NSProcessInfo.processInfo.systemUptime;
}

static NSDictionary<NSString *, NSNumber *> *VibeKeyCodeMap(void) {
    static NSDictionary<NSString *, NSNumber *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // The ANSI virtual key codes: HIToolbox Events.h values, stated inline
        // so that Carbon stays unimported.
        map = @{
            @"a": @0,  @"s": @1,  @"d": @2,  @"f": @3,  @"h": @4,  @"g": @5,
            @"z": @6,  @"x": @7,  @"c": @8,  @"v": @9,  @"b": @11, @"q": @12,
            @"w": @13, @"e": @14, @"r": @15, @"y": @16, @"t": @17,
            @"1": @18, @"2": @19, @"3": @20, @"4": @21, @"6": @22, @"5": @23,
            @"9": @25, @"7": @26, @"8": @28, @"0": @29,
            @"o": @31, @"u": @32, @"i": @34, @"p": @35, @"l": @37, @"j": @38,
            @"k": @40, @"n": @45, @"m": @46,
            @"return": @36, @"tab": @48, @"space": @49, @"delete": @51, @"esc": @53,
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
            @"left": [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey],
            @"right": [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey],
            @"up": [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey],
            @"down": [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey],
        };
    });
    return special[name] ?: name;
}

// What `characters` carries when shift is held. uppercaseString covers letters
// alone, so the digits get their US-layout shifted forms explicitly. The
// specials and arrows are unaffected by shift either way.
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

// Any tokens trailing the key name are modifier names.
static BOOL VibeParseModifiers(NSArray<NSString *> *tokens, NSUInteger start,
                               NSEventModifierFlags *outFlags, NSString **errorJSON) {
    NSEventModifierFlags flags = 0;
    for (NSUInteger i = start; i < tokens.count; i++) {
        NSString *mod = tokens[i].lowercaseString;
        if ([mod isEqualToString:@"shift"]) {
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
            *errorJSON = VibeErrorJSON(@"unknown modifier '%@' (shift, cmd, opt, ctrl)", tokens[i]);
            return NO;
        }
    }
    *outFlags = flags;
    return YES;
}

// key posts a down and an up, while key_down and key_up post one edge each.
// That split is how the held W, E, R and T momentary FX keys are driven, since
// TransportKeyMonitor releases on keyUp.
NSString *VibeInjectKey(MainPlayerController *controller, NSArray<NSString *> *tokens,
                               BOOL down, BOOL up) {
    NSString *verb = tokens.firstObject;
    if (tokens.count < 2) {
        return VibeErrorJSON(@"usage: %@ <key> [shift|cmd|opt|ctrl ...]", verb);
    }
    NSString *name = tokens[1].lowercaseString;
    NSNumber *code = VibeKeyCodeMap()[name];
    if (code == nil) {
        return VibeErrorJSON(@"unknown key '%@' (a-z, 0-9, space, tab, return, esc, delete, up, down, left, right)",
                tokens[1]);
    }
    NSEventModifierFlags flags = 0;
    NSString *errorJSON = nil;
    if (!VibeParseModifiers(tokens, 2, &flags, &errorJSON)) {
        return errorJSON;
    }
    if (VibeKeyIsArrow(name)) {
        // Real arrow events carry these, and some responders check them.
        flags |= NSEventModifierFlagFunction | NSEventModifierFlagNumericPad;
    }
    NSString *chars = VibeKeyCharacters(name);
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
                                         isARepeat:NO
                                           keyCode:code.unsignedShortValue];
        [NSApp postEvent:event atStart:NO];
    };
    if (down) {
        post(NSEventTypeKeyDown);
    }
    if (up) {
        post(NSEventTypeKeyUp);
    }
    return VibeJSONString(@{@"ok": @YES, @"posted": verb, @"key": name});
}

// The shared tail for the mouse verbs. It converts to bottom-left window
// coordinates, posts through the block, and replies with the hit-tested view,
// so that a missed aim is visible in the reply rather than silently doing
// nothing.
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

// A non-key window swallows the first click as activation, because
// acceptsFirstMouse defaults to NO as click-through protection, so mouse
// injection self-activates first. It uses the deprecated force spelling,
// because the cooperative [NSApp activate] is declined while another app is
// frontmost, which is exactly the state a shell-driven test runs in.
// Activation lands asynchronously, so spin the run loop briefly until key
// status arrives: events posted before that are swallowed. The reply's
// windowKey reports whether it took.
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

// click, mouse_down, mouse_up and mouse_move. mouse_move with a button token
// posts a *dragged* event, and a plain move otherwise. CAUTION: a lone
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
    NSPoint location = NSMakePoint(x, NSHeight(window.frame) - y);
    NSInteger windowNumber = window.windowNumber;
    if (isClick) {
        // A double-click is two full press cycles with an ascending
        // clickCount, exactly as the window server delivers one.
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

// A full left-button drag gesture queued in one command: down, interpolated
// dragged steps, up. It is the only injection shape that works on
// tracking-loop controls; see VibeInjectMouse.
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
    CGFloat height = NSHeight(window.frame);
    NSInteger windowNumber = window.windowNumber;
    NSPoint start = NSMakePoint(x1, height - y1);
    [NSApp postEvent:VibeMouseEvent(NSEventTypeLeftMouseDown, start, windowNumber, 1, 1.0)
             atStart:NO];
    for (NSInteger i = 1; i <= steps; i++) {
        double t = (double)i / steps;
        NSPoint p = NSMakePoint(x1 + (x2 - x1) * t, height - (y1 + (y2 - y1) * t));
        [NSApp postEvent:VibeMouseEvent(NSEventTypeLeftMouseDragged, p, windowNumber, 1, 1.0)
                 atStart:NO];
    }
    NSPoint end = NSMakePoint(x2, height - y2);
    [NSApp postEvent:VibeMouseEvent(NSEventTypeLeftMouseUp, end, windowNumber, 1, 0.0)
             atStart:NO];
    return VibeMouseReply(@"drag", window, start, x1, y1);
}

#pragma mark Synthetic file drags

// drag_hover, drag_drop and drag_end drive the same FileDropDelegate path a
// real external file drag takes through MainWindow. A genuine
// NSDraggingSession cannot be synthesized, because only the window server can
// start one, which is what makes the playlist drop zone untestable through the
// event verbs above. These are direct delegate calls rather than posted
// events. Coordinates are main-window points with a top-left origin, as with
// the mouse verbs.

static NSString *VibeWellName(PlaylistDropWellAction action) {
    switch (action) {
        case PlaylistDropWellActionReplace: return @"replace";
        case PlaylistDropWellActionAdd:     return @"add";
        case PlaylistDropWellActionNone:    return @"none";
    }
}

// The shared coordinate parse and conversion for drag_hover and drag_drop. It
// returns NO with *errorJSON set on a malformed pair.
static BOOL VibeDragPointArgument(NSArray<NSString *> *tokens, NSWindow *window,
                                  NSPoint *outLocation, double *outX, double *outY,
                                  NSString **errorJSON) {
    NSString *verb = tokens.firstObject;
    double x = 0, y = 0;
    if (tokens.count < 3 || !VibeParseDouble(tokens[1], &x) || !VibeParseDouble(tokens[2], &y)) {
        *errorJSON = VibeErrorJSON(@"usage: %@ <x> <y>%@", verb,
                [verb isEqualToString:@"drag_drop"] ? @" <file-or-directory>" : @"");
        return NO;
    }
    *outX = x;
    *outY = y;
    *outLocation = NSMakePoint(x, NSHeight(window.frame) - y); // → bottom-left window coords
    return YES;
}

NSString *VibeSyntheticDragHover(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    MainWindow *window = (MainWindow *)controller.window;
    NSPoint location;
    double x, y;
    NSString *errorJSON = nil;
    if (!VibeDragPointArgument(tokens, window, &location, &x, &y, &errorJSON)) {
        return errorJSON;
    }
    if ([window.dropDelegate respondsToSelector:@selector(mainWindow:fileDraggingUpdatedAtLocation:)]) {
        [window.dropDelegate mainWindow:window fileDraggingUpdatedAtLocation:location];
    }
    // Which well the point resolves to, meaning what a drop here would do:
    // the assertable part of the reply.
    PlaylistDropWellAction well = [controller.playerContentView.playlistDropZoneView
            dropActionForWindowPoint:location];
    return VibeJSONString(@{@"ok": @YES, @"posted": @"drag_hover",
                            @"x": @(x), @"y": @(y), @"well": VibeWellName(well)});
}

NSString *VibeSyntheticDragEnd(MainPlayerController *controller) {
    MainWindow *window = (MainWindow *)controller.window;
    if ([window.dropDelegate respondsToSelector:@selector(mainWindowFileDraggingEnded:)]) {
        [window.dropDelegate mainWindowFileDraggingEnded:window];
    }
    return VibeJSONString(@{@"ok": @YES, @"posted": @"drag_end"});
}

NSString *VibeSyntheticDragDrop(MainPlayerController *controller, NSArray<NSString *> *tokens) {
    MainWindow *window = (MainWindow *)controller.window;
    NSPoint location;
    double x, y;
    NSString *errorJSON = nil;
    if (!VibeDragPointArgument(tokens, window, &location, &x, &y, &errorJSON)) {
        return errorJSON;
    }
    if (tokens.count < 4) {
        return VibeErrorJSON(@"usage: drag_drop <x> <y> <file-or-directory>");
    }
    NSString *path = [[tokens subarrayWithRange:NSMakeRange(3, tokens.count - 3)]
            componentsJoinedByString:@" "].stringByExpandingTildeInPath;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return VibeErrorJSON(@"no file or directory at '%@'", path);
    }
    // Resolved before anything mutates, purely for the reply. The geometry is
    // independent of drag state, and the real delivery below re-resolves it.
    PlaylistDropWellAction well = [controller.playerContentView.playlistDropZoneView
            dropActionForWindowPoint:location];
    // Mirror performDragOperation:'s pipeline and ordering: resolve the well
    // into an append flag, hand the URL to the app's open funnel, then tear
    // the drag-over presentation down. A real drop gets draggingEnded right
    // after performDragOperation returns. The funnel owns the expansion, so
    // this posts and returns rather than waiting for it. The sandbox caveat is
    // the same as with `open`: an ungranted path may be denied at read time.
    // Poll dump_state for the resulting playlist.
    BOOL append = NO;
    if ([window.dropDelegate respondsToSelector:@selector(mainWindow:dropAppendsAtLocation:)]) {
        append = [window.dropDelegate mainWindow:window dropAppendsAtLocation:location];
    }
    [(AppDelegate *)NSApp.delegate openDroppedURLs:@[[NSURL fileURLWithPath:path]] appending:append];
    if ([window.dropDelegate respondsToSelector:@selector(mainWindowFileDraggingEnded:)]) {
        [window.dropDelegate mainWindowFileDraggingEnded:window];
    }
    return VibeJSONString(@{@"ok": @YES, @"dropping": path,
                            @"x": @(x), @"y": @(y), @"well": VibeWellName(well)});
}

#endif
