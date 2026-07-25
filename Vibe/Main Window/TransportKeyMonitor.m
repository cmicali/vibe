//
//  TransportKeyMonitor.m
//  Vibe
//

#import "TransportKeyMonitor.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Transport.h"

@implementation TransportKeyMonitor {
    id                              _monitor;
    id                              _resignKeyObserver;
    __weak MainPlayerController    *_controller;
}

- (instancetype)initWithController:(MainPlayerController *)controller {
    self = [super init];
    if (self) {
        _controller = controller;
        __weak TransportKeyMonitor *weakSelf = self;
        // KeyUp too: W/E/R/T are momentary (low-kill boost / reverb / 1/8
        // delay / 1/16 delay while held), so their releases matter, unlike
        // the other keys.
        _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
                                                          handler:^NSEvent *(NSEvent *event) {
            TransportKeyMonitor *strongSelf = weakSelf;
            return strongSelf ? [strongSelf handleKeyEvent:event] : event;
        }];
        // If the window resigns key while W/E/R/T is held (Cmd-Tab, a panel
        // steals focus), the release lands elsewhere and the effect would
        // stick on — force all off. Idempotent, so firing with nothing
        // active is free.
        _resignKeyObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:NSWindowDidResignKeyNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            TransportKeyMonitor *strongSelf = weakSelf;
            MainPlayerController *strongController = strongSelf ? strongSelf->_controller : nil;
            if (strongController && note.object == strongController.window) {
                [strongController setLowKillBoostActive:NO];
                [strongController setReverbSendActive:NO];
                [strongController setDelaySendActive:NO];
                [strongController setShortDelaySendActive:NO];
            }
        }];
    }
    return self;
}

- (void)dealloc {
    if (_monitor) {
        [NSEvent removeMonitor:_monitor];
    }
    if (_resignKeyObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_resignKeyObserver];
    }
}

// Returns nil to swallow a handled key, or the event to pass it on.
- (NSEvent *)handleKeyEvent:(NSEvent *)event {
    MainPlayerController *controller = _controller;
    if (!controller || event.window != controller.window) {
        return event;
    }
    if (event.type == NSEventTypeKeyUp) {
        // Before the modifier guard: a modifier pressed mid-hold must not
        // make the release invisible and leave the send stuck on.
        NSString *upChars = event.charactersIgnoringModifiers.lowercaseString;
        if ([upChars isEqualToString:@"w"]) {
            [controller setLowKillBoostActive:NO];
            return nil;
        }
        if ([upChars isEqualToString:@"e"]) {
            [controller setReverbSendActive:NO];
            return nil;
        }
        if ([upChars isEqualToString:@"r"]) {
            [controller setDelaySendActive:NO];
            return nil;
        }
        if ([upChars isEqualToString:@"t"]) {
            [controller setShortDelaySendActive:NO];
            return nil;
        }
        return event;
    }
    // Leave anything that isn't a bare keypress alone (menu shortcuts,
    // future text editing in a field editor).
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
                NSEventModifierFlagOption | NSEventModifierFlagShift)) {
        return event;
    }
    if ([controller.window.firstResponder isKindOfClass:[NSTextView class]]) {
        return event;
    }
    NSString *chars = event.charactersIgnoringModifiers.lowercaseString;
    if ([chars isEqualToString:@" "]) {
        [controller playPause:nil];
        return nil;
    }
    if ([chars isEqualToString:@"b"]) {
        [controller previous:nil];
        return nil;
    }
    if ([chars isEqualToString:@"n"]) {
        [controller next:nil];
        return nil;
    }
    if ([chars isEqualToString:@"p"]) {
        [controller togglePitchPanel:nil];
        return nil;
    }
    if ([chars isEqualToString:@"q"]) {
        [controller toggleLowKill:nil];
        return nil;
    }
    // Momentary: down engages the effect, the keyUp branch above releases
    // it. Key-repeat downs are swallowed without re-sending (idempotent
    // anyway, but no point spamming the player queue).
    if ([chars isEqualToString:@"w"]) {
        if (!event.isARepeat) {
            [controller setLowKillBoostActive:YES];
        }
        return nil;
    }
    if ([chars isEqualToString:@"e"]) {
        if (!event.isARepeat) {
            [controller setReverbSendActive:YES];
        }
        return nil;
    }
    if ([chars isEqualToString:@"r"]) {
        if (!event.isARepeat) {
            [controller setDelaySendActive:YES];
        }
        return nil;
    }
    if ([chars isEqualToString:@"t"]) {
        if (!event.isARepeat) {
            [controller setShortDelaySendActive:YES];
        }
        return nil;
    }
    // Skip seek: A/S/D forward 8/16/32 bars, Z/X/C back 8/16/32 bars
    // (10s/30s/60s when the track has no BPM). A 2×3 grid on the keyboard —
    // forward on top, back below; the further the key, the longer the skip.
    if ([chars isEqualToString:@"a"]) {
        [controller skipForward:nil];
        return nil;
    }
    if ([chars isEqualToString:@"s"]) {
        [controller skipForwardMore:nil];
        return nil;
    }
    if ([chars isEqualToString:@"d"]) {
        [controller skipForwardMost:nil];
        return nil;
    }
    if ([chars isEqualToString:@"z"]) {
        [controller skipBack:nil];
        return nil;
    }
    if ([chars isEqualToString:@"x"]) {
        [controller skipBackMore:nil];
        return nil;
    }
    if ([chars isEqualToString:@"c"]) {
        [controller skipBackMost:nil];
        return nil;
    }
    // Tab is also a menu key equivalent (installed by MainMenuBuilder),
    // but that path only fires as a fallback after the focused view
    // declines the event — handle it here like the other bare keys.
    if ([chars isEqualToString:@"\t"]) {
        [controller toggleSize:nil];
        return nil;
    }
    return event;
}

@end
