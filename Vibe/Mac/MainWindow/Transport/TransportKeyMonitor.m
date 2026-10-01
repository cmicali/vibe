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
#import "MainPlayerController+Menus.h"
#import "MainPlayerController+Transport.h"
#import "MainWindow.h"
#import "ShortcutRules.h"

// Each flips its effect at keyDown; keyUp decides: a tap latches the flip, a
// hold reverts to the pre-press state.
typedef NS_ENUM(NSInteger, VibeEffectKey) {
    VibeEffectKeyLowKill = 0,
    VibeEffectKeyLowKillBoost,
    VibeEffectKeyReverb,
    VibeEffectKeyDelay,             // 1/8-note taps
    VibeEffectKeyShortDelay,        // 1/16-note taps
    VibeEffectKeyCount
};

// Long enough that a lazy tap does not revert, short enough that a stab held
// over a beat never latches.
static const NSTimeInterval kEffectTapMaxDuration = 0.35;

static NSInteger VibeEffectKeyForCommand(NSString *identifier) {
    static NSArray<NSString *> *commands;   // indexed by VibeEffectKey
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        commands = @[kVibeMenuFXLowKill, kVibeMenuFXLowKillBoost, kVibeMenuFXReverb,
                     kVibeMenuFXDelay, kVibeMenuFXShortDelay];
    });
    NSUInteger index = [commands indexOfObject:identifier];
    return index == NSNotFound ? -1 : (NSInteger)index;
}

// The playlist's physical keys, unmodified: Return, Delete (each folding its
// twin) and the two arrows that move its selection.
static BOOL VibeIsPlaylistKey(unsigned short keyCode, NSEventModifierFlags modifiers) {
    return modifiers == 0 && (keyCode == kVibeKeyCodeReturn || keyCode == kVibeKeyCodeDelete
                              || keyCode == kVibeKeyCodeDownArrow || keyCode == kVibeKeyCodeUpArrow);
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
    // The release is matched by key alone: a modifier pressed or let go
    // mid-hold must not hide it.
    unsigned short                  _effectDownKeyCode[VibeEffectKeyCount];
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

// Returns nil to swallow a handled key, or the event to pass it on. Matched
// by physical key and the exact modifier set against ShortcutRules.h, so a
// layout's letters never move a binding.
- (NSEvent *)handleKeyEvent:(NSEvent *)event inWindow:(NSWindow *)window {
    MainPlayerController *controller = _controller;
    if (!controller || window != controller.window) {
        return event;
    }
    unsigned short keyCode = VibeShortcutCanonicalKeyCode(event.keyCode);
    if (event.type == NSEventTypeKeyUp) {
        for (NSInteger effectKey = 0; effectKey < VibeEffectKeyCount; effectKey++) {
            if (_effectKeyIsDown[effectKey] && _effectDownKeyCode[effectKey] == keyCode) {
                _effectKeyIsDown[effectKey] = NO;
                if (event.timestamp - _effectKeyDownTime[effectKey] >= kEffectTapMaxDuration) {
                    [self setEffect:effectKey active:_effectStateBeforeDown[effectKey] controller:controller];
                }
                return nil;
            }
        }
        return event;
    }
    if ([controller.window.firstResponder isKindOfClass:[NSTextView class]]) {
        return event;
    }
    NSEventModifierFlags mods = event.modifierFlags & kVibeShortcutModifierMask;
#if VIBE_VERBOSE_LOGGING
    // Beta instrumentation: M marks the moment a tester hears a problem.
    // keyCode 46 is the physical M under any layout.
    if (keyCode == kVibeKeyCodeM && mods == 0) {
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
    BOOL playlistShown = ((MainWindow *)controller.window).isPlaylistShown;
    // Dead while collapsed and swallowed whatever is bound: the table keeps
    // focus off screen, and an unhandled key reaching it wedges its input
    // context.
    if (!playlistShown && VibeIsPlaylistKey(keyCode, mods)) {
        return nil;
    }
    // A key-code binding can land on a fixed system shortcut after a layout
    // switch; the system shortcut wins.
    NSString *chars = event.charactersIgnoringModifiers.lowercaseString;
    unichar character = chars.length == 1 ? [chars characterAtIndex:0] : 0;
    if (VibeShortcutIsReserved(keyCode, character, mods)) {
        return event;   // the arrows are the table's own moveUp:/moveDown:
    }
    NSString *command = VibeShortcutCommandForKey(keyCode, mods, AppSettings.sharedInstance.shortcutOverrides);
    if (!command) {
        return event;
    }
    // Flipped at keyDown for an instant response; repeats are swallowed. With
    // no controls or FX disallowed, the key passes through. The keyUp side
    // needs no twin guard: an unhandled keyDown leaves _effectKeyIsDown clear.
    NSInteger effectKey = VibeEffectKeyForCommand(command);
    if (effectKey >= 0) {
        if (controller.audioPlayer.fx == nil || !AppSettings.sharedInstance.audioFXAllowed) {
            return event;
        }
        if (!event.isARepeat) {
            BOOL wasActive = [self effectActive:effectKey controller:controller];
            _effectKeyIsDown[effectKey] = YES;
            _effectKeyDownTime[effectKey] = event.timestamp;
            _effectDownKeyCode[effectKey] = keyCode;
            _effectStateBeforeDown[effectKey] = wasActive;
            [self setEffect:effectKey active:!wasActive controller:controller];
        }
        return nil;
    }
    // Validation gates the rest: Play Selected and Remove need the playlist
    // showing with a row selected, so a press over a collapsed playlist is
    // swallowed and does nothing. Remove never repeats, so a held delete
    // takes one gesture's rows.
    if (!event.isARepeat || VibeShortcutCommandRepeats(command)) {
        [controller performMenuCommandWithIdentifier:command];
    }
    return nil;
}

@end
