//
//  TransportKeyMonitor.m
//  Vibe
//

#import "TransportKeyMonitor.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
#import "AudioPlayer.h"
#import "AudioPlayer+Devices.h"
#import "AudioTrack.h"
#import "MainPlayerController.h"
#import "MainPlayerController+Window.h"
#import "MainPlayerController+Transport.h"
#import "MainWindow.h"

// Each flips its effect at keyDown; keyUp decides: a tap latches the flip, a
// hold reverts to the pre-press state.
typedef NS_ENUM(NSInteger, VibeEffectKey) {
    VibeEffectKeyLowKill = 0,       // Q
    VibeEffectKeyLowKillBoost,      // W
    VibeEffectKeyReverb,            // E
    VibeEffectKeyDelay,             // R (1/8-note taps)
    VibeEffectKeyShortDelay,        // T (1/16-note taps)
    VibeEffectKeyCount
};

// Long enough that a lazy tap does not revert, short enough that a stab held
// over a beat never latches.
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

    // Indexed by VibeEffectKey. isDown gates keyUp: a release whose keyDown we
    // never handled must pass through untouched.
    BOOL                            _effectKeyIsDown[VibeEffectKeyCount];
    NSTimeInterval                  _effectKeyDownTime[VibeEffectKeyCount];
    BOOL                            _effectStateBeforeDown[VibeEffectKeyCount];
}

- (instancetype)initWithController:(MainPlayerController *)controller {
    self = [super init];
    if (self) {
        _controller = controller;
        __weak TransportKeyMonitor *weakSelf = self;
        _monitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
                                                          handler:^NSEvent *(NSEvent *event) {
            TransportKeyMonitor *strongSelf = weakSelf;
            return strongSelf ? [strongSelf handleKeyEvent:event inWindow:event.window] : event;
        }];
        // Resigning key mid-hold sends the release elsewhere, so the flip
        // would stick: revert held keys. Latched effects persist.
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
        // Nested tracking loops (a menu, a window drag) also swallow the
        // release.
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

// No keyUp is coming to decide, so every held key reverts.
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

// 0 for anything but one character; no key below is NUL.
static unichar VibeBareKeyChar(NSString *chars) {
    return chars.length == 1 ? [chars characterAtIndex:0] : 0;
}

- (BOOL)isPlaySelectionKey:(NSString *)chars {
    unichar c = VibeBareKeyChar(chars);
    return c == NSCarriageReturnCharacter || c == NSEnterCharacter;
}

// The Edit menu advertises Backspace alone; only this monitor knows Forward
// Delete.
- (BOOL)isRemoveSelectionKey:(NSString *)chars {
    unichar c = VibeBareKeyChar(chars);
    return c == NSDeleteCharacter || c == NSDeleteFunctionKey;
}

- (BOOL)isSelectionMoveKey:(NSString *)chars {
    unichar c = VibeBareKeyChar(chars);
    return c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey;
}

// Composed from the three above, so a key added to one is swallowed here too
// rather than reaching the focused table with the pane closed.
- (BOOL)isPlaylistKey:(NSString *)chars {
    return [self isPlaySelectionKey:chars]
            || [self isRemoveSelectionKey:chars]
            || [self isSelectionMoveKey:chars];
}

// Returns nil to swallow a handled key, or the event to pass it on.
- (NSEvent *)handleKeyEvent:(NSEvent *)event inWindow:(NSWindow *)window {
    MainPlayerController *controller = _controller;
    if (!controller || window != controller.window) {
        return event;
    }
    if (event.type == NSEventTypeKeyUp) {
        // Before the modifier guard: a modifier pressed mid-hold must not hide
        // the release.
        NSInteger effectKey = VibeEffectKeyForChars(event.charactersIgnoringModifiers.lowercaseString);
        if (effectKey >= 0 && _effectKeyIsDown[effectKey]) {
            _effectKeyIsDown[effectKey] = NO;
            if (event.timestamp - _effectKeyDownTime[effectKey] >= kEffectTapMaxDuration) {
                [self setEffect:effectKey active:_effectStateBeforeDown[effectKey] controller:controller];
            }
            return nil;
        }
        return event;
    }
    // Menu shortcuts and field editors keep their keys.
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
        [controller togglePitchPanel:nil]; // refuses the reveal under bit-perfect output
        return nil;
    }
#if VIBE_VERBOSE_LOGGING
    // Beta instrumentation: M marks the moment a tester hears a problem.
    // keyCode 46 is the physical M under any layout.
    if ([chars isEqualToString:@"m"] || event.keyCode == 46) {
        if (event.isARepeat) return nil;
        static NSUInteger marks;
        AudioPlayer *player = controller.audioPlayer;
        LogWarn(@"USER MARK %lu: %@ at %.3fs, playing %d, loading %d, input delay %.0f ms, output %@",
                (unsigned long)++marks, player.currentTrack.url.lastPathComponent, player.position,
                player.isPlaying, player.isLoading,
                MAX(0, NSProcessInfo.processInfo.systemUptime - event.timestamp) * 1000,
                player.bitPerfectReportDictionary);
        return nil;
    }
#endif
    // Dead while collapsed, and swallowed: the table keeps focus off screen,
    // and an unhandled key reaching it wedges its input context.
    if ([self isPlaylistKey:chars]) {
        if (!((MainWindow *)controller.window).isPlaylistShown) {
            return nil;
        }
        if ([self isPlaySelectionKey:chars]) {
            [controller playSelectedTrack:nil];   // the keyboard's double-click
            return nil;
        }
        if ([self isRemoveSelectionKey:chars]) {
            // A held delete takes one gesture's rows, not the playlist.
            if (!event.isARepeat) {
                [controller removeSelectedPlaylistTracks:nil];
            }
            return nil;
        }
        return event;   // the arrows are the table's own moveUp:/moveDown:
    }
    // Flipped at keyDown for an instant response; repeats are swallowed. With
    // no controls or FX disallowed, Q–T pass through. The keyUp side needs no
    // twin guard: an unhandled keyDown leaves _effectKeyIsDown clear.
    NSInteger effectKey = VibeEffectKeyForChars(chars);
    if (effectKey >= 0 && controller.audioPlayer.fx != nil
            && AppSettings.sharedInstance.audioFXAllowed) {
        if (!event.isARepeat) {
            BOOL wasActive = [self effectActive:effectKey controller:controller];
            _effectKeyIsDown[effectKey] = YES;
            _effectKeyDownTime[effectKey] = event.timestamp;
            _effectStateBeforeDown[effectKey] = wasActive;
            [self setEffect:effectKey active:!wasActive controller:controller];
        }
        return nil;
    }
    // Everything below honors hardware repeat. A/S/D skip forward, Z/X/C back:
    // the further the key, the longer the skip.
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
    if ([chars isEqualToString:@"\t"]) {
        [controller toggleSize:nil];
        return nil;
    }
    return event;
}

@end
