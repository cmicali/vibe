//
//  DebugSyntheticInput.m
//  vibe-libs
//
//  Synthesized input: the key, mouse, drag, and scroll posting, and the input
//  table.
//

#import "DebugSyntheticInput.h"

#if DEBUG

#import "DebugCommandDispatch.h"
#import "DebugStandardVerbs.h"
#import "DebugWireFormat.h"

#pragma mark Input injection

// Synthesized NSEvents posted into the app's own event queue. Unlike verbs
// that call an action directly, they exercise real event dispatch, local
// event monitors and view mouse handling included. Unlike CGEvent injection,
// they need no Accessibility permission. Mouse injection still activates the
// window, and handlers can start native file/window dragging: app-local
// events are not containment.
//
// Two limits against real window-server events: tracking areas and hover
// effects do not fire, since the window server drives those, and the events
// are processed after the reply is written, so poll the app's state for the
// result.
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
            @"k": @40, @"n": @45, @"m": @46, @"period": @47,
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
            @"return": @"\r", @"tab": @"\t", @"space": @" ", @"period": @".",
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

NSNumber *VibeKeyCodeForName(NSString *name) {
    return VibeKeyCodeMap()[name];
}

BOOL VibeParseModifiers(NSArray<NSString *> *tokens, NSUInteger start,
                        NSEventModifierFlags *outFlags, BOOL *outRepeat,
                        NSString **errorJSON) {
    NSEventModifierFlags flags = 0;
    BOOL repeat = NO;
    for (NSUInteger i = start; i < tokens.count; i++) {
        NSString *mod = tokens[i].lowercaseString;
        // Hardware key repeat, not a modifier flag: a handler may gate on it,
        // as one that takes a single step per press does.
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
// is how a held key is driven: a handler that latches on a tap and reverts on
// a hold decides on key up.
NSString *VibeInjectKey(NSWindow *window, NSArray<NSString *> *tokens, BOOL down, BOOL up) {
    NSString *verb = tokens.firstObject;
    if (tokens.count < 2) {
        return VibeErrorJSON(@"usage: %@ <key> [shift|cmd|opt|ctrl|repeat ...]", verb);
    }
    NSString *name = tokens[1].lowercaseString;
    NSNumber *code = VibeKeyCodeForName(name);
    if (code == nil) {
        return VibeErrorJSON(@"unknown key '%@' (a-z, 0-9, period, space, tab, return, esc, delete, forward_delete, up, down, left, right)",
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

NSPoint VibeWindowPointForContentPoint(NSWindow *window, double x, double y) {
    NSView *content = window.contentView;
    return [content convertPoint:NSMakePoint(x, content.isFlipped ? y : NSHeight(content.bounds) - y)
                          toView:nil];
}

NSPoint VibeContentPointForWindowPoint(NSWindow *window, NSPoint point) {
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
void VibeMakeWindowKeyForInjection(NSWindow *window) {
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
NSString *VibeInjectMouse(NSWindow *window, NSArray<NSString *> *tokens) {
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
    else {
        NSEventType type = !haveButton ? NSEventTypeMouseMoved
                : (right ? NSEventTypeRightMouseDragged : NSEventTypeLeftMouseDragged);
        [NSApp postEvent:VibeMouseEvent(type, location, windowNumber, 0, haveButton ? 1.0 : 0.0)
                 atStart:NO];
    }
    return VibeMouseReply(verb, window, location, x, y);
}

// A whole left-button drag queued in one command, the only injection shape
// that works on tracking-loop controls; see VibeInjectMouse.
NSString *VibeInjectDrag(NSWindow *window, NSArray<NSString *> *tokens) {
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

// One scroll event at a content point, from the window's own dispatch down.
// lines, the default, is a wheel's. pixels is a trackpad's precise scroll, and
// momentum the coast after the fingers lift. dy is the raw delta, before the
// user's scrolling direction. No activation: a scroll reaches a window that is
// not key.
NSString *VibeInjectScroll(NSWindow *window, NSArray<NSString *> *tokens) {
    NSString *usage = @"usage: scroll <x> <y> <dy> [lines|pixels] [momentum]";
    double x = 0, y = 0, dy = 0;
    if (tokens.count < 4 || !VibeParseDouble(tokens[1], &x) || !VibeParseDouble(tokens[2], &y)
            || !VibeParseDouble(tokens[3], &dy)) {
        return VibeErrorJSON(@"%@", usage);
    }
    BOOL pixels = NO, momentum = NO;
    for (NSUInteger i = 4; i < tokens.count; i++) {
        NSString *option = tokens[i].lowercaseString;
        if ([option isEqualToString:@"pixels"]) {
            pixels = YES;
        }
        else if ([option isEqualToString:@"momentum"]) {
            momentum = YES;
        }
        else if (![option isEqualToString:@"lines"]) {
            return VibeErrorJSON(@"%@", usage);
        }
    }
    NSPoint location = VibeWindowPointForContentPoint(window, x, y);
    CGEventRef cg = CGEventCreateScrollWheelEvent2(NULL, pixels ? kCGScrollEventUnitPixel : kCGScrollEventUnitLine,
                                                   1, (int32_t)lround(dy), 0, 0);
    // TRAP: an NSEvent made from a CGEvent has no window. NSApp drops it, and
    // its locationInWindow is the screen point. So the point is placed to read
    // as the window point (Quartz's origin is the primary screen's top left),
    // and the window gets the event directly.
    CGEventSetLocation(cg, CGPointMake(location.x, NSMaxY(NSScreen.screens.firstObject.frame) - location.y));
    if (momentum) {
        CGEventSetIntegerValueField(cg, kCGScrollWheelEventMomentumPhase, kCGMomentumScrollPhaseContinue);
    }
    NSEvent *event = [NSEvent eventWithCGEvent:cg];
    CFRelease(cg);
    [window sendEvent:event];
    return VibeMouseReply(@"scroll", window, location, x, y);
}

#pragma mark The input table

static NSWindow *VibeDebugTargetWindow(VibeDebugStandardOptions *options, id controller) {
    return (options.targetWindow ? options.targetWindow(controller) : nil) ?: NSApp.mainWindow;
}

NSArray<NSDictionary *> *VibeDebugInputVerbs(VibeDebugStandardOptions *options) {
    VibeDebugCommandHandler mouse = ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
        NSWindow *window = VibeDebugTargetWindow(options, controller);
        return window ? VibeInjectMouse(window, tokens) : VibeErrorJSON(@"no window to aim at");
    };
    // Into the key window, as a real press goes, so a press reaches whichever
    // window is key. The target window when none is.
    VibeDebugCommandHandler (^key)(BOOL, BOOL) = ^VibeDebugCommandHandler(BOOL down, BOOL up) {
        return ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            NSWindow *window = NSApp.keyWindow ?: VibeDebugTargetWindow(options, controller);
            return window ? VibeInjectKey(window, tokens, down, up) : VibeErrorJSON(@"no window to post into");
        };
    };
    return @[
        VibeDebugCmd(@"click <x> <y> [left|right] [clickCount]", 0, mouse),
        VibeDebugCmd(@"mouse_down <x> <y> [left|right]", 0, mouse),
        VibeDebugCmd(@"mouse_up <x> <y> [left|right]", 0, mouse),
        VibeDebugCmd(@"mouse_move <x> <y> [left|right]", 0, mouse),
        VibeDebugCmd(@"drag <x1> <y1> <x2> <y2> [steps]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            NSWindow *window = VibeDebugTargetWindow(options, controller);
            return window ? VibeInjectDrag(window, tokens) : VibeErrorJSON(@"no window to aim at");
        }),
        VibeDebugCmd(@"scroll <x> <y> <dy> [lines|pixels] [momentum]", 0, ^NSString *(NSArray<NSString *> *tokens, NSString *commandId, id controller) {
            NSWindow *window = VibeDebugTargetWindow(options, controller);
            return window ? VibeInjectScroll(window, tokens) : VibeErrorJSON(@"no window to aim at");
        }),
        VibeDebugCmd(@"key <key> [mods...]", 0, key(YES, YES)),
        VibeDebugCmd(@"key_down <key> [mods...]", 0, key(YES, NO)),
        VibeDebugCmd(@"key_up <key> [mods...]", 0, key(NO, YES)),
    ];
}

#endif
