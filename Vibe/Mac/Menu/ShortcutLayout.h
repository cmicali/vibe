//
//  ShortcutLayout.h
//  Vibe
//
//  A shortcut under the current keyboard layout: the character a key types,
//  the key that types a character, the key's name, the display string, and
//  the key equivalent a menu item takes. Main thread only. The layout is read
//  once per modifier layer and kept until VibeShortcutForgetLayout.
//

#import <AppKit/AppKit.h>
#import "ShortcutRules.h"

NS_ASSUME_NONNULL_BEGIN

// The names no layout gives. The app pushes them once, before the first
// label: the space bar's, the keypad's (%@ is the character the key types),
// a key no layout names (%ld is its key code), and an unassigned shortcut's.
void VibeShortcutSetKeyNames(NSString *space, NSString *keypadFormat, NSString *unknownFormat,
                             NSString *unassigned);

// Drops the layout read so far. The app calls it on
// kTISNotifySelectedKeyboardInputSourceChanged, before it redraws a shortcut.
void VibeShortcutForgetLayout(void);

// The key's lowercase character under the current layout, in Command's layer
// when modifiers hold ⌘, 0 when it has none; what the rules compare against
// the fixed and character shortcuts.
unichar VibeShortcutCharacterForKeyCode(unsigned short keyCode, NSEventModifierFlags modifiers);

// The key that types character in that layer, kVibeShortcutKeyMask when no
// key does. The lowest key code wins, so the answer is the same every time.
unsigned short VibeShortcutKeyCodeForCharacter(unichar character, NSEventModifierFlags modifiers);

// The key's name as a menu draws it, in the same layer, nil for a key no
// layout names.
NSString *_Nullable VibeShortcutKeyLabel(unsigned short keyCode, NSEventModifierFlags modifiers);

// ⌃⌥⇧⌘ then the key, as a menu draws it; the unassigned name for None.
NSString *VibeShortcutDisplayString(VibeShortcut shortcut);

// The key equivalent and modifier mask a menu item takes for shortcut. Nil,
// with an empty mask, for None or a key the layout cannot name.
NSString *_Nullable VibeShortcutKeyEquivalent(VibeShortcut shortcut, NSEventModifierFlags *mask);

NS_ASSUME_NONNULL_END
