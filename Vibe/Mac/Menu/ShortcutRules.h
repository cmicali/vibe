//
//  ShortcutRules.h
//  Vibe
//
//  Remappable shortcuts: the encoding, the reserved keys, and the decisions a
//  key monitor, a menu bar and a recorder pane must agree on, over the app's
//  own command table. Carbon-free, so the host-less tests compile it: the
//  caller translates a key code to its character under the current layout.
//
//  The command table is the app's: @[identifier, @(default)] pairs, in the
//  order a hand-edited duplicate resolves. The first command wins. Every
//  function that takes `commands` takes that table.
//

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// One NSUInteger, stored as an NSNumber: the key in the low 16 bits, a
// character flag above it, and the four modifier flags at AppKit's own bits.
// A key-code shortcut names the physical key, so a default bare key stays put
// under AZERTY or Greek. A character shortcut is only ever a default — the
// Command shortcuts, which follow the letter as every Mac app's do — and is
// matched by the character the press types.
typedef NSUInteger VibeShortcut;

static const VibeShortcut kVibeShortcutKeyMask = 0xFFFF;
static const VibeShortcut kVibeShortcutCharacterFlag = 1UL << 16;
static const NSEventModifierFlags kVibeShortcutModifierMask =
        NSEventModifierFlagShift | NSEventModifierFlagControl
        | NSEventModifierFlagOption | NSEventModifierFlagCommand;
// Unassigned: stored over a default to remove it.
static const VibeShortcut kVibeShortcutNone = 0xFFFF;

// HIToolbox kVK_* codes the rules and their callers name, inline so Carbon
// stays unimported.
static const unsigned short kVibeKeyCodeReturn = 36;
static const unsigned short kVibeKeyCodeDelete = 51;
static const unsigned short kVibeKeyCodeEscape = 53;
static const unsigned short kVibeKeyCodeKeypadClear = 71;
static const unsigned short kVibeKeyCodeKeypadEnter = 76;
static const unsigned short kVibeKeyCodeForwardDelete = 117;
static const unsigned short kVibeKeyCodeLeftArrow = 123;
static const unsigned short kVibeKeyCodeRightArrow = 124;
static const unsigned short kVibeKeyCodeDownArrow = 125;
static const unsigned short kVibeKeyCodeUpArrow = 126;

static inline VibeShortcut VibeShortcutMake(unsigned short keyCode, NSEventModifierFlags modifiers) {
    return (keyCode & kVibeShortcutKeyMask) | (modifiers & kVibeShortcutModifierMask);
}

static inline VibeShortcut VibeShortcutMakeCharacter(unichar character, NSEventModifierFlags modifiers) {
    return character | kVibeShortcutCharacterFlag | (modifiers & kVibeShortcutModifierMask);
}

static inline BOOL VibeShortcutIsCharacter(VibeShortcut shortcut) {
    return (shortcut & kVibeShortcutCharacterFlag) != 0;
}

// The key code, or the character for a character shortcut.
static inline unsigned short VibeShortcutKey(VibeShortcut shortcut) {
    return (unsigned short)(shortcut & kVibeShortcutKeyMask);
}

static inline NSEventModifierFlags VibeShortcutModifiers(VibeShortcut shortcut) {
    return shortcut & kVibeShortcutModifierMask;
}

// Keypad Enter is Return and Forward Delete is Delete. A binding of either
// answers both.
static inline unsigned short VibeShortcutCanonicalKeyCode(unsigned short keyCode) {
    switch (keyCode) {
        case kVibeKeyCodeKeypadEnter:   return kVibeKeyCodeReturn;
        case kVibeKeyCodeForwardDelete: return kVibeKeyCodeDelete;
    }
    return keyCode;
}

// The keypad's digits, operators, decimal and Clear; Enter folds into Return.
static inline BOOL VibeShortcutIsKeypadKey(unsigned short keyCode) {
    switch (keyCode) {
        case 65: case 67: case 69: case kVibeKeyCodeKeypadClear: case 75: case 78: case 81:
        case 82: case 83: case 84: case 85: case 86: case 87: case 88: case 89: case 91: case 92:
            return YES;
    }
    return NO;
}

// kVibeShortcutNone for an identifier that is not in the table.
static inline VibeShortcut VibeShortcutDefault(NSArray<NSArray *> *commands, NSString *identifier) {
    for (NSArray *entry in commands) {
        if ([entry[0] isEqualToString:identifier]) {
            return [entry[1] unsignedIntegerValue];
        }
    }
    return kVibeShortcutNone;
}

// A stored value is a number naming a key code and modifiers, or None. A
// character shortcut is never stored — recording always yields a key code.
static inline BOOL VibeShortcutIsStorable(id _Nullable value) {
    if (![value isKindOfClass:NSNumber.class]) {
        return NO;
    }
    VibeShortcut shortcut = [value unsignedIntegerValue];
    return (shortcut & ~(kVibeShortcutKeyMask | kVibeShortcutModifierMask)) == 0
            && (shortcut == kVibeShortcutNone || VibeShortcutKey(shortcut) < kVibeShortcutKeyMask);
}

// The override when it is well-formed, else the default.
static inline VibeShortcut VibeShortcutEffective(NSArray<NSArray *> *commands, NSString *identifier,
                                                 NSDictionary *_Nullable overrides) {
    id stored = overrides[identifier];
    return VibeShortcutIsStorable(stored) ? [stored unsignedIntegerValue] : VibeShortcutDefault(commands, identifier);
}

// Never assignable, and passed on by the monitor whatever is bound: the fixed
// system shortcuts (matched by character, as their menu items match), the
// arrows a list's selection uses with any modifier, Escape, and every keypad
// key but Enter, which a menu cannot draw apart from the main keyboard's.
// character is the key's lowercase character under the current layout, 0
// when it has none.
static inline BOOL VibeShortcutIsReserved(unsigned short keyCode, unichar character,
                                          NSEventModifierFlags modifiers) {
    keyCode = VibeShortcutCanonicalKeyCode(keyCode);
    modifiers &= kVibeShortcutModifierMask;
    switch (keyCode) {
        case kVibeKeyCodeEscape:
        case kVibeKeyCodeLeftArrow: case kVibeKeyCodeRightArrow:
        case kVibeKeyCodeDownArrow: case kVibeKeyCodeUpArrow:
            return YES;
    }
    if (VibeShortcutIsKeypadKey(keyCode)) {
        return YES;
    }
    NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    if (modifiers == cmd) {
        switch (character) {
            case ',': case 'h': case 'q': case 'w': case 'z': case 'x': case 'c': case 'v': case 'a': case 'm':
                return YES;
        }
        return NO;
    }
    if (modifiers == (cmd | NSEventModifierFlagOption)) {
        return character == 'h';
    }
    if (modifiers == (cmd | NSEventModifierFlagShift)) {
        return character == 'z';
    }
    return NO;
}

// The command a key performs, or a recorded one would collide with, nil for
// none: a key-code shortcut matched by physical key, a character default by
// character (the key's lowercase character, 0 when unknown), each with the
// exact modifier set. A hand-edited duplicate resolves in table order.
static inline NSString *_Nullable VibeShortcutOwner(NSArray<NSArray *> *commands, VibeShortcut shortcut,
        unichar character, NSDictionary *_Nullable overrides, NSString *_Nullable excluding) {
    if (shortcut == kVibeShortcutNone) {
        return nil;
    }
    unsigned short keyCode = VibeShortcutCanonicalKeyCode(VibeShortcutKey(shortcut));
    NSEventModifierFlags modifiers = VibeShortcutModifiers(shortcut);
    for (NSArray *entry in commands) {
        NSString *identifier = entry[0];
        if (excluding && [identifier isEqualToString:excluding]) {
            continue;
        }
        id stored = overrides[identifier];
        VibeShortcut owned = VibeShortcutIsStorable(stored) ? [stored unsignedIntegerValue]
                                                            : [entry[1] unsignedIntegerValue];
        if (owned == kVibeShortcutNone || VibeShortcutModifiers(owned) != modifiers) {
            continue;
        }
        BOOL same = VibeShortcutIsCharacter(owned)
                ? character != 0 && VibeShortcutKey(owned) == character
                : VibeShortcutKey(owned) == keyCode;
        if (same) {
            return identifier;
        }
    }
    return nil;
}

// Reserved keys carry no equivalent. Duplicate bindings go to the first
// command in table order, as in the key monitor.
// layoutKeyCode maps a character default, or kVibeShortcutKeyMask for none.
// layoutCharacter maps a physical key, or 0 for none.
static inline VibeShortcut VibeShortcutForMenuItem(NSArray<NSArray *> *commands, NSString *identifier,
        VibeShortcut shortcut, unsigned short layoutKeyCode, unichar layoutCharacter,
        NSDictionary *_Nullable overrides) {
    if (shortcut == kVibeShortcutNone) {
        return kVibeShortcutNone;
    }
    BOOL isCharacter = VibeShortcutIsCharacter(shortcut);
    unsigned short keyCode = isCharacter ? layoutKeyCode : VibeShortcutCanonicalKeyCode(VibeShortcutKey(shortcut));
    unichar character = isCharacter ? VibeShortcutKey(shortcut) : layoutCharacter;
    NSEventModifierFlags modifiers = VibeShortcutModifiers(shortcut);
    if (VibeShortcutIsReserved(keyCode, character, modifiers)) {
        return kVibeShortcutNone;
    }
    NSString *owner = VibeShortcutOwner(commands, VibeShortcutMake(keyCode, modifiers), character, overrides, nil);
    return owner == nil || [owner isEqualToString:identifier] ? shortcut : kVibeShortcutNone;
}

// The command a press performs, nil to pass it on. Under Command a layout's
// ⌘ layer (Dvorak – QWERTY ⌘, Greek) types the Latin letter the menu bar
// matches while Option bends it (⌥⌘S types ß), so the press is tried as what
// it typed, 0 without ⌘, and as what it types unmodified. A key-code binding
// can land on a reserved shortcut after a layout switch; the system's wins.
static inline NSString *_Nullable VibeShortcutCommandForPress(NSArray<NSArray *> *commands,
        unsigned short keyCode, NSEventModifierFlags modifiers, unichar typed, unichar unmodified,
        NSDictionary *_Nullable overrides) {
    keyCode = VibeShortcutCanonicalKeyCode(keyCode);
    modifiers &= kVibeShortcutModifierMask;
    if (VibeShortcutIsReserved(keyCode, typed, modifiers) || VibeShortcutIsReserved(keyCode, unmodified, modifiers)) {
        return nil;
    }
    VibeShortcut pressed = VibeShortcutMake(keyCode, modifiers);
    NSString *owner = typed != 0 && typed != unmodified
            ? VibeShortcutOwner(commands, pressed, typed, overrides, nil) : nil;
    return owner ?: VibeShortcutOwner(commands, pressed, unmodified, overrides, nil);
}

// What the overrides hold for identifier: nil at its default, so the store
// stays sparse.
static inline NSNumber *_Nullable VibeShortcutStoredValue(NSArray<NSArray *> *commands, NSString *identifier,
                                                          VibeShortcut shortcut) {
    return shortcut == VibeShortcutDefault(commands, identifier) ? nil : @(shortcut);
}

// The overrides after giving identifier shortcut (None clears it). A command
// that held the shortcut loses it and is named in *loser; the recording
// wins rather than being refused. The caller has already refused a reserved
// shortcut. An identifier that is not in the table changes nothing.
static inline NSDictionary<NSString *, NSNumber *> *VibeShortcutOverridesByAssigning(
        NSArray<NSArray *> *commands, NSDictionary *_Nullable overrides, NSString *identifier,
        VibeShortcut shortcut, unichar character, NSString *_Nullable *_Nullable loser) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    BOOL known = NO;
    for (NSArray *entry in commands) {
        NSString *command = entry[0];
        known = known || [command isEqualToString:identifier];
        if (VibeShortcutIsStorable(overrides[command])) {
            result[command] = overrides[command];
        }
    }
    NSString *owner = nil;
    if (known) {
        if (shortcut != kVibeShortcutNone) {
            shortcut = VibeShortcutMake(VibeShortcutCanonicalKeyCode(VibeShortcutKey(shortcut)),
                                        VibeShortcutModifiers(shortcut));
        }
        owner = VibeShortcutOwner(commands, shortcut, character, result, identifier);
        if (owner) {
            result[owner] = VibeShortcutStoredValue(commands, owner, kVibeShortcutNone);
        }
        result[identifier] = VibeShortcutStoredValue(commands, identifier, shortcut);
    }
    if (loser) {
        *loser = owner;
    }
    return result;
}

NS_ASSUME_NONNULL_END
