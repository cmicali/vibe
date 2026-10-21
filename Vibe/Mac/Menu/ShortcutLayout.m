//
//  ShortcutLayout.m
//  Vibe
//

#import <Carbon/Carbon.h> // TIS and UCKeyTranslate: a key code's character under the current layout
#import "ShortcutLayout.h"

// Empty until the app pushes them, so a label before then is blank, never nil.
static NSString *sSpaceName = @"";
static NSString *sKeypadFormat = @"";
static NSString *sUnknownFormat = @"";
static NSString *sUnassignedName = @"";

// Each key code's character under the current ASCII-capable layout, per
// Carbon modifier state; empty until first needed and after
// VibeShortcutForgetLayout.
static NSMutableDictionary<NSNumber *, NSDictionary<NSNumber *, NSString *> *> *sLayoutCharacters;

void VibeShortcutSetKeyNames(NSString *space, NSString *keypadFormat, NSString *unknownFormat,
                             NSString *unassigned) {
    sSpaceName = [space copy];
    sKeypadFormat = [keypadFormat copy];
    sUnknownFormat = [unknownFormat copy];
    sUnassignedName = [unassigned copy];
}

void VibeShortcutForgetLayout(void) {
    [sLayoutCharacters removeAllObjects];
}

// The keys a layout does not name: key equivalent, then the label drawn for
// it. Space's label is the app's, so it is read per call.
static NSArray<NSString *> *SpecialKey(unsigned short keyCode) {
    if (keyCode == 49) {
        return @[@" ", sSpaceName];
    }
    static NSDictionary<NSNumber *, NSArray<NSString *> *> *special;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *(^fn)(unichar) = ^NSString *(unichar c) { return [NSString stringWithCharacters:&c length:1]; };
        NSMutableDictionary *keys = [@{
            @(kVibeKeyCodeReturn): @[@"\r", @"↩"],
            @48:  @[@"\t", @"⇥"],
            // NSBackspaceCharacter draws as ⌫; a real press delivers
            // NSDeleteCharacter, which the monitor matches by key code.
            @(kVibeKeyCodeDelete): @[fn(NSBackspaceCharacter), @"⌫"],
            // Reserved, so only ever named in a refusal.
            @(kVibeKeyCodeEscape):      @[@"\e", @"⎋"],
            @(kVibeKeyCodeLeftArrow):   @[fn(NSLeftArrowFunctionKey), @"←"],
            @(kVibeKeyCodeRightArrow):  @[fn(NSRightArrowFunctionKey), @"→"],
            @(kVibeKeyCodeDownArrow):   @[fn(NSDownArrowFunctionKey), @"↓"],
            @(kVibeKeyCodeUpArrow):     @[fn(NSUpArrowFunctionKey), @"↑"],
            @(kVibeKeyCodeKeypadClear): @[fn(NSClearLineFunctionKey), @"⌧"],
            @115: @[fn(NSHomeFunctionKey), @"↖"],
            @119: @[fn(NSEndFunctionKey), @"↘"],
            @116: @[fn(NSPageUpFunctionKey), @"⇞"],
            @121: @[fn(NSPageDownFunctionKey), @"⇟"],
        } mutableCopy];
        // kVK_F1 … kVK_F20.
        const unsigned short fKeys[] = {122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                        103, 111, 105, 107, 113, 106, 64, 79, 80, 90};
        for (unichar n = 0; n < sizeof(fKeys) / sizeof(fKeys[0]); n++) {
            keys[@(fKeys[n])] = @[fn(NSF1FunctionKey + n), [NSString stringWithFormat:@"F%u", (unsigned)(n + 1)]];
        }
        special = keys;
    });
    return special[@(keyCode)];
}

// Built from the ASCII-capable layout so a Greek or Cyrillic user's menus show
// the Latin letters their Command shortcuts type. modifierKeyState is
// UCKeyTranslate's: Carbon's modifier bits shifted down a byte.
static NSDictionary<NSNumber *, NSString *> *LayoutCharacters(UInt32 modifierKeyState) {
    NSDictionary<NSNumber *, NSString *> *cached = sLayoutCharacters[@(modifierKeyState)];
    if (cached) {
        return cached;
    }
    NSMutableDictionary<NSNumber *, NSString *> *characters = [NSMutableDictionary dictionary];
    TISInputSourceRef source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    CFDataRef data = source ? TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) : NULL;
    if (!data) {
        if (source) {
            CFRelease(source);
        }
        source = TISCopyCurrentKeyboardLayoutInputSource();
        data = source ? TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) : NULL;
    }
    if (data) {
        const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
        for (unsigned short keyCode = 0; keyCode < 128; keyCode++) {
            UInt32 deadKeyState = 0;
            UniChar buffer[4];
            UniCharCount length = 0;
            // No dead-key state: an accent key labels itself, not a pending accent.
            OSStatus status = UCKeyTranslate(layout, keyCode, kUCKeyActionDisplay, modifierKeyState,
                                             LMGetKbdType(), kUCKeyTranslateNoDeadKeysMask, &deadKeyState,
                                             4, &length, buffer);
            if (status != noErr || length != 1
                    || [NSCharacterSet.controlCharacterSet characterIsMember:buffer[0]]
                    || [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:buffer[0]]) {
                continue;
            }
            characters[@(keyCode)] = [NSString stringWithCharacters:buffer length:1];
        }
    }
    if (source) {
        CFRelease(source);
    }
    if (!sLayoutCharacters) {
        sLayoutCharacters = [NSMutableDictionary dictionary];
    }
    sLayoutCharacters[@(modifierKeyState)] = characters;
    return characters;
}

// The key's lowercase character in the layer its shortcut types in:
// Command's when it has ⌘, since a layout such as Dvorak – QWERTY ⌘ puts
// other letters there, and the press is the ⌘ letter the layer types.
static NSString *_Nullable LayoutCharacter(unsigned short keyCode, NSEventModifierFlags modifiers) {
    UInt32 state = (modifiers & NSEventModifierFlagCommand) ? (cmdKey >> 8) : 0;
    return LayoutCharacters(state)[@(keyCode)].lowercaseString;
}

unichar VibeShortcutCharacterForKeyCode(unsigned short keyCode, NSEventModifierFlags modifiers) {
    NSString *character = LayoutCharacter(keyCode, modifiers);
    return character.length == 1 ? [character characterAtIndex:0] : 0;
}

unsigned short VibeShortcutKeyCodeForCharacter(unichar character, NSEventModifierFlags modifiers) {
    for (unsigned short keyCode = 0; keyCode < 128; keyCode++) {
        NSString *typed = LayoutCharacter(keyCode, modifiers);
        if (typed.length == 1 && [typed characterAtIndex:0] == character) {
            return keyCode;
        }
    }
    return kVibeShortcutKeyMask;
}

NSString *_Nullable VibeShortcutKeyLabel(unsigned short keyCode, NSEventModifierFlags modifiers) {
    NSString *label = SpecialKey(keyCode)[1];
    if (label) {
        return label;
    }
    label = LayoutCharacter(keyCode, modifiers).uppercaseString;
    // The keypad's keys type what the main keyboard's do.
    return label && VibeShortcutIsKeypadKey(keyCode) ? [NSString stringWithFormat:sKeypadFormat, label] : label;
}

NSString *VibeShortcutDisplayString(VibeShortcut shortcut) {
    if (shortcut == kVibeShortcutNone) {
        return sUnassignedName;
    }
    NSEventModifierFlags modifiers = VibeShortcutModifiers(shortcut);
    NSMutableString *display = [NSMutableString string];
    if (modifiers & NSEventModifierFlagControl) [display appendString:@"⌃"];
    if (modifiers & NSEventModifierFlagOption)  [display appendString:@"⌥"];
    if (modifiers & NSEventModifierFlagShift)   [display appendString:@"⇧"];
    if (modifiers & NSEventModifierFlagCommand) [display appendString:@"⌘"];
    unsigned short key = VibeShortcutKey(shortcut);
    NSString *label = VibeShortcutIsCharacter(shortcut)
            ? [NSString stringWithCharacters:&key length:1].uppercaseString
            : VibeShortcutKeyLabel(key, modifiers);
    [display appendString:label ?: [NSString stringWithFormat:sUnknownFormat, (long)key]];
    return display;
}

NSString *_Nullable VibeShortcutKeyEquivalent(VibeShortcut shortcut, NSEventModifierFlags *mask) {
    *mask = 0;
    if (shortcut == kVibeShortcutNone) {
        return nil;
    }
    unsigned short key = VibeShortcutKey(shortcut);
    NSEventModifierFlags modifiers = VibeShortcutModifiers(shortcut);
    NSString *equivalent = VibeShortcutIsCharacter(shortcut) ? [NSString stringWithCharacters:&key length:1]
            : SpecialKey(key)[0] ?: LayoutCharacter(key, modifiers);
    if (!equivalent) {
        return nil;
    }
    // TRAP: a shifted key rides in the character Shift types ("C" with
    // Command is ⇧⌘C, "!" is ⇧1 on US); the unshifted character with Shift
    // in the mask draws right but never matches a real press. A letter takes
    // its capital, another key its Shift layer's character; the special keys
    // keep the flag.
    if (modifiers & NSEventModifierFlagShift) {
        NSString *shifted = nil;
        if (![equivalent.uppercaseString isEqualToString:equivalent.lowercaseString]) {
            shifted = equivalent.uppercaseString;
        }
        else if (!VibeShortcutIsCharacter(shortcut) && !SpecialKey(key)) {
            shifted = LayoutCharacters(shiftKey >> 8)[@(key)];
        }
        if (shifted && ![shifted isEqualToString:equivalent]) {
            equivalent = shifted;
            modifiers &= ~NSEventModifierFlagShift;
        }
    }
    *mask = modifiers;
    return equivalent;
}
