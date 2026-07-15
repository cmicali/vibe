//
//  TransportKeyMonitor.m
//  Vibe
//

#import "TransportKeyMonitor.h"
#import "MainPlayerController.h"

@implementation TransportKeyMonitor {
    id                              _monitor;
    __weak MainPlayerController    *_controller;
}

- (instancetype)initWithController:(MainPlayerController *)controller {
    self = [super init];
    if (self) {
        _controller = controller;
        __weak TransportKeyMonitor *weakSelf = self;
        _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                          handler:^NSEvent *(NSEvent *event) {
            TransportKeyMonitor *strongSelf = weakSelf;
            return strongSelf ? [strongSelf handleKeyDown:event] : event;
        }];
    }
    return self;
}

- (void)dealloc {
    if (_monitor) {
        [NSEvent removeMonitor:_monitor];
    }
}

// Returns nil to swallow a handled key, or the event to pass it on.
- (NSEvent *)handleKeyDown:(NSEvent *)event {
    MainPlayerController *controller = _controller;
    if (!controller || event.window != controller.window) {
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
    // Skip seek: A/S forward 10s/30s, Z/X back 10s/30s (a 2×2 grid on the
    // keyboard — forward on top, back below; near key = 10s, far = 30s).
    if ([chars isEqualToString:@"a"]) {
        [controller skipForward:nil];
        return nil;
    }
    if ([chars isEqualToString:@"s"]) {
        [controller skipForwardMore:nil];
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
