//
//  TransportKeyMonitor.m
//  Vibe
//

#import "TransportKeyMonitor.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Window.h"
#import "MainPlayerController+Transport.h"
#import "MainWindow.h"

// The dual-mode performance-effect keys. Each flips its effect at keyDown, and
// keyUp decides what the press meant: a tap, shorter than
// kEffectTapMaxDuration, latches the flip like a toggle, while a hold reverts
// to the pre-press state, making the press momentary.
typedef NS_ENUM(NSInteger, VibeEffectKey) {
    VibeEffectKeyLowKill = 0,       // Q
    VibeEffectKeyLowKillBoost,      // W
    VibeEffectKeyReverb,            // E
    VibeEffectKeyDelay,             // R (1/8-note taps)
    VibeEffectKeyShortDelay,        // T (1/16-note taps)
    VibeEffectKeyCount
};

// The longest press that still counts as a tap. It is long enough that a lazy
// tap does not revert by accident, and short enough that a deliberate
// momentary stab, held and released over a beat, never latches.
static const NSTimeInterval kEffectTapMaxDuration = 0.35;

static NSInteger VibeEffectKeyForChars(NSString *chars) {
    if (chars.length != 1) {
        return -1;
    }
    switch ([chars characterAtIndex:0]) {
        case 'q': return VibeEffectKeyLowKill;
        case 'w': return VibeEffectKeyLowKillBoost;
        case 'e': return VibeEffectKeyReverb;
        case 'r': return VibeEffectKeyDelay;
        case 't': return VibeEffectKeyShortDelay;
    }
    return -1;
}

@implementation TransportKeyMonitor {
    id                              _monitor;
    id                              _resignKeyObserver;
    id                              _menuTrackingObserver;
    id                              _windowMoveObserver;
    __weak MainPlayerController    *_controller;

    // The tap-against-hold state, indexed by VibeEffectKey. isDown gates the
    // keyUp side: a keyUp whose keyDown we never handled — typed into a text
    // view, or pressed with a modifier down — must pass through untouched.
    BOOL                            _effectKeyIsDown[VibeEffectKeyCount];
    NSTimeInterval                  _effectKeyDownTime[VibeEffectKeyCount];
    BOOL                            _effectStateBeforeDown[VibeEffectKeyCount];
}

- (instancetype)initWithController:(MainPlayerController *)controller {
    self = [super init];
    if (self) {
        _controller = controller;
        __weak TransportKeyMonitor *weakSelf = self;
        // keyUp too, because Q, W, E, R and T toggle on a tap and are
        // momentary on a hold, so their releases matter, unlike other keys'.
        _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
                                                          handler:^NSEvent *(NSEvent *event) {
            TransportKeyMonitor *strongSelf = weakSelf;
            return strongSelf ? [strongSelf handleKeyEvent:event] : event;
        }];
        // If the window resigns key while an effect key is held, through
        // Cmd-Tab or a panel stealing focus, the release lands elsewhere and
        // the flip would stick. Revert every held key to its pre-press state.
        // Latched effects, turned on by a tap, are deliberate and persist.
        _resignKeyObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:NSWindowDidResignKeyNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            TransportKeyMonitor *strongSelf = weakSelf;
            MainPlayerController *strongController = strongSelf ? strongSelf->_controller : nil;
            if (strongController && note.object == strongController.window) {
                [strongSelf revertHeldEffectKeys];
            }
        }];
        // Nested event-tracking loops also swallow the release: menu tracking,
        // and a window drag through movableByWindowBackground. The keyUp never
        // reaches the monitor, so a momentary hold would stay flipped with the
        // isDown state stale. Treat the loop's start like losing key status.
        _menuTrackingObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:NSMenuDidBeginTrackingNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            [weakSelf revertHeldEffectKeys];
        }];
        _windowMoveObserver = [[NSNotificationCenter defaultCenter]
                addObserverForName:NSWindowWillMoveNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            TransportKeyMonitor *strongSelf = weakSelf;
            MainPlayerController *strongController = strongSelf ? strongSelf->_controller : nil;
            if (strongController && note.object == strongController.window) {
                [strongSelf revertHeldEffectKeys];
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
    if (_menuTrackingObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_menuTrackingObserver];
    }
    if (_windowMoveObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_windowMoveObserver];
    }
}

#pragma mark - Effect key state

- (BOOL)effectActive:(NSInteger)key controller:(MainPlayerController *)controller {
    switch (key) {
        case VibeEffectKeyLowKill:      return controller.lowKillActive;
        case VibeEffectKeyLowKillBoost: return controller.lowKillBoostActive;
        case VibeEffectKeyReverb:       return controller.reverbSendActive;
        case VibeEffectKeyDelay:        return controller.delaySendActive;
        case VibeEffectKeyShortDelay:   return controller.shortDelaySendActive;
    }
    return NO;
}

- (void)setEffect:(NSInteger)key active:(BOOL)active controller:(MainPlayerController *)controller {
    switch (key) {
        case VibeEffectKeyLowKill:      [controller setLowKillActive:active]; break;
        case VibeEffectKeyLowKillBoost: [controller setLowKillBoostActive:active]; break;
        case VibeEffectKeyReverb:       [controller setReverbSendActive:active]; break;
        case VibeEffectKeyDelay:        [controller setDelaySendActive:active]; break;
        case VibeEffectKeyShortDelay:   [controller setShortDelaySendActive:active]; break;
    }
}

// Focus left mid-press. Treat every held key as a hold release, and revert it,
// however long it was down: no keyUp is coming to decide.
- (void)revertHeldEffectKeys {
    MainPlayerController *controller = _controller;
    if (!controller) {
        return;
    }
    for (NSInteger key = 0; key < VibeEffectKeyCount; key++) {
        if (_effectKeyIsDown[key]) {
            _effectKeyIsDown[key] = NO;
            [self setEffect:key active:_effectStateBeforeDown[key] controller:controller];
        }
    }
}

#pragma mark - Event handling

// The single character of a bare keypress, or 0 for anything longer. None of
// the keys below is NUL, so 0 matches nothing.
static unichar VibeBareKeyChar(NSString *chars) {
    return chars.length == 1 ? [chars characterAtIndex:0] : 0;
}

// Return and the keypad's Enter both mean "play the selected row".
- (BOOL)isPlaySelectionKey:(NSString *)chars {
    unichar c = VibeBareKeyChar(chars);
    return c == NSCarriageReturnCharacter || c == NSEnterCharacter;
}

// Backspace and Forward Delete both mean "remove the selected row". The Edit
// menu advertises Backspace alone; Forward Delete is a physical-key twin, not a
// second shortcut, so only this monitor knows about it.
- (BOOL)isRemoveSelectionKey:(NSString *)chars {
    unichar c = VibeBareKeyChar(chars);
    return c == NSDeleteCharacter || c == NSDeleteFunctionKey;
}

// The up and down arrows, which are the table's own moveUp:/moveDown:.
- (BOOL)isSelectionMoveKey:(NSString *)chars {
    unichar c = VibeBareKeyChar(chars);
    return c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey;
}

// Everything whose meaning is the playlist's, and so is dead while it is
// collapsed. Composed from the three above rather than re-listing their
// characters: a key added to one of them must be swallowed here too, or it
// falls through to the focused table with the pane closed.
- (BOOL)isPlaylistKey:(NSString *)chars {
    return [self isPlaySelectionKey:chars]
            || [self isRemoveSelectionKey:chars]
            || [self isSelectionMoveKey:chars];
}

// Returns nil to swallow a handled key, or the event to pass it on.
- (NSEvent *)handleKeyEvent:(NSEvent *)event {
    MainPlayerController *controller = _controller;
    if (!controller || event.window != controller.window) {
        return event;
    }
    if (event.type == NSEventTypeKeyUp) {
        // This runs before the modifier guard, because a modifier pressed
        // mid-hold must not make the release invisible and leave the effect
        // stuck flipped.
        NSInteger effectKey = VibeEffectKeyForChars(event.charactersIgnoringModifiers.lowercaseString);
        if (effectKey >= 0 && _effectKeyIsDown[effectKey]) {
            _effectKeyIsDown[effectKey] = NO;
            if (event.timestamp - _effectKeyDownTime[effectKey] >= kEffectTapMaxDuration) {
                // Held, so momentary: restore the state the keyDown flipped.
                [self setEffect:effectKey active:_effectStateBeforeDown[effectKey] controller:controller];
            }
            // Tapped, so the keyDown's flip stays latched, like a toggle.
            return nil;
        }
        return event;
    }
    // Leave anything that is not a bare keypress alone: menu shortcuts, and
    // any future text editing in a field editor.
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
    // The playlist keys, dead while the playlist is collapsed: the table keeps
    // focus off screen, and moving a selection nobody can see is not
    // navigation. Swallowed rather than passed on, because an unhandled key
    // reaching the focused table wedges its input context.
    if ([self isPlaylistKey:chars]) {
        if (!((MainWindow *)controller.window).isPlaylistShown) {
            return nil;
        }
        if ([self isPlaySelectionKey:chars]) {
            [controller playSelectedTrack:nil];   // the keyboard's double-click
            return nil;
        }
        if ([self isRemoveSelectionKey:chars]) {
            // Repeat downs are swallowed: a held delete key must take one row,
            // not walk the playlist. The transport and skip keys below honor
            // repeat deliberately; a structural edit cannot.
            if (!event.isARepeat) {
                [controller removeSelectedPlaylistTracks:nil];
            }
            return nil;
        }
        return event;   // the arrows are the table's own moveUp:/moveDown:
    }
    // For the effect keys, flip the effect right at keyDown, so that both
    // meanings of the press get an instant response. The keyUp branch above
    // decides whether the flip latches, on a tap, or reverts, on a hold.
    // Key-repeat downs are swallowed without touching the state machine.
    // Graph availability is fixed for the app's lifetime, but its controls
    // follow the stored setting immediately. With either half off, this
    // monitor leaves Q/W/E/R/T alone; the menu builder removes its fallback
    // equivalents and validation disables the items. The keyUp side needs no
    // twin guard — a keyDown never handled leaves _effectKeyIsDown clear, and
    // that branch already yields.
    NSInteger effectKey = VibeEffectKeyForChars(chars);
    if (effectKey >= 0 && controller.audioPlayer.fx != nil
            && AppSettings.sharedInstance.audioFXEnabled) {
        if (!event.isARepeat) {
            BOOL wasActive = [self effectActive:effectKey controller:controller];
            _effectKeyIsDown[effectKey] = YES;
            _effectKeyDownTime[effectKey] = event.timestamp;
            _effectStateBeforeDown[effectKey] = wasActive;
            [self setEffect:effectKey active:!wasActive controller:controller];
        }
        return nil;
    }
    // Transport, navigation, skip and size keys deliberately honor hardware
    // repeat. Only the effect keys above suppress it because they carry
    // keyDown-to-keyUp state.
    //
    // Skip seek. A, S and D go forward by the configured base bar count,
    // twice it and four times it; Z, X and C go back the same, or 10, 30 and
    // 60 seconds when the track has no BPM. The six bindings form a two-by-three
    // grid, forward on top and back below; the further the key, the longer the
    // skip.
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
    // Tab is also a menu key equivalent, installed by MainMenuBuilder, but
    // that path fires only as a fallback after the focused view declines the
    // event. Handle it here, like the other bare keys.
    if ([chars isEqualToString:@"\t"]) {
        [controller toggleSize:nil];
        return nil;
    }
    return event;
}

@end
