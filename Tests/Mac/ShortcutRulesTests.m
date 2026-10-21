//
//  ShortcutRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "ShortcutRules.h"

@interface ShortcutRulesTests : XCTestCase
@end

@implementation ShortcutRulesTests

static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand;
static const NSEventModifierFlags kShift = NSEventModifierFlagShift;
static const NSEventModifierFlags kOption = NSEventModifierFlagOption;

// The test's own command table, in the order a duplicate resolves: bare keys
// by key code, Command defaults by character, and one command with none.
static NSArray<NSArray *> *Table(void) {
    return @[
        @[@"play",      @(VibeShortcutMake(49, 0))],   // Space
        @[@"select",    @(VibeShortcutMake(kVibeKeyCodeReturn, 0))],
        @[@"next",      @(VibeShortcutMake(45, 0))],   // N
        @[@"shuffle",   @(VibeShortcutMakeCharacter('s', kCmd | kOption))],
        @[@"repeat",    @(VibeShortcutMakeCharacter('r', kCmd))],
        @[@"skip",      @(VibeShortcutMake(0, 0))],    // A
        @[@"skip_back", @(VibeShortcutMake(6, 0))],    // Z
        @[@"low_kill",  @(VibeShortcutMake(12, 0))],   // Q
        @[@"delay",     @(VibeShortcutMake(15, 0))],   // R
        @[@"pitch",     @(VibeShortcutMake(35, 0))],   // P
        @[@"pin",       @(kVibeShortcutNone)],
        @[@"open",      @(VibeShortcutMakeCharacter('o', kCmd))],
        @[@"save",      @(VibeShortcutMakeCharacter('s', kCmd))],
        @[@"copy_name", @(VibeShortcutMakeCharacter('c', kCmd | kShift))],
        @[@"remove",    @(VibeShortcutMake(kVibeKeyCodeDelete, 0))],
        @[@"trash",     @(VibeShortcutMake(kVibeKeyCodeDelete, kCmd))],
        @[@"add",       @(VibeShortcutMakeCharacter('o', kCmd | kShift))],
        @[@"reveal",    @(VibeShortcutMakeCharacter('r', kCmd | kShift))],
    ];
}

// The command a key-code press performs, typing no character.
static NSString *CommandForKey(unsigned short keyCode, NSEventModifierFlags modifiers, NSDictionary *overrides) {
    return VibeShortcutOwner(Table(), VibeShortcutMake(keyCode, modifiers), 0, overrides, nil);
}

// What a key-code shortcut's menu item carries, the key typing character.
static VibeShortcut MenuItemForKey(NSString *identifier, VibeShortcut shortcut, unichar character,
                                   NSDictionary *overrides) {
    return VibeShortcutForMenuItem(Table(), identifier, shortcut, kVibeShortcutKeyMask, character, overrides);
}

- (void)testBareKeysMatchByPhysicalKeyWithTheirExactModifiers {
    XCTAssertEqualObjects(CommandForKey(0, 0, nil), @"skip");
    XCTAssertEqualObjects(CommandForKey(12, 0, nil), @"low_kill");
    XCTAssertEqualObjects(CommandForKey(49, 0, nil), @"play");
    // Shift, or any modifier, is a different shortcut.
    XCTAssertNil(CommandForKey(0, kShift, nil));
    // Caps Lock and the function flag are not part of a shortcut.
    XCTAssertEqualObjects(CommandForKey(0, NSEventModifierFlagCapsLock | NSEventModifierFlagFunction, nil), @"skip");
    // Character defaults match by character, never by key code.
    XCTAssertNil(CommandForKey(31, kCmd, nil));
    XCTAssertEqual(VibeShortcutDefault(Table(), @"menu_gone"), kVibeShortcutNone);
}

- (void)testCharacterDefaultsMatchTheirLetterWithTheirExactModifiers {
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(15, kCmd), 'r', nil, nil), @"repeat");
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(35, kCmd), 'r', nil, nil), @"repeat",
                          @"Dvorak's R is QWERTY's P");
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(15, kCmd), 'p', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(1, kCmd | kOption), 's', nil, nil), @"shuffle");
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(1, kCmd), 's', nil, nil), @"save");
    // Shift is part of the set, against every character default.
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(1, kCmd | kShift), 's', nil, nil));
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(1, kCmd | kOption | kShift), 's', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(15, kCmd | kShift), 'r', nil, nil), @"reveal",
                          @"⇧⌘R is its own command, never ⌘R's");
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(31, kCmd | kShift), 'o', nil, nil), @"add");
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(8, kShift), 'c', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(15, 0), 'r', nil, nil), @"delay",
                          @"bare R is the delay's key code, not ⌘R's letter");
}

- (void)testAPressIsTriedAsTypedThenUnmodifiedAndAReservedOnePassesOn {
    XCTAssertEqualObjects(VibeShortcutCommandForPress(Table(), 15, kCmd, 'r', 0x03C1, nil), @"repeat",
                          @"Greek types ρ, and r under ⌘");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(Table(), 1, kCmd | kOption, 0x00DF, 's', nil), @"shuffle",
                          @"⌥⌘S types ß");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(Table(), 31, kCmd, 'o', 'r', nil), @"open",
                          @"Dvorak – QWERTY ⌘'s R key types o under ⌘");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(Table(), 0, 0, 0, 'a', nil), @"skip");
    XCTAssertNil(VibeShortcutCommandForPress(Table(), 12, kCmd, 'q', 'q', nil), @"⌘Q is the system's");
    XCTAssertNil(VibeShortcutCommandForPress(Table(), 12, kCmd, 'q', 0x03C2, nil), @"reserved under either form");
    XCTAssertNil(VibeShortcutCommandForPress(Table(), 126, 0, 0, 0, nil), @"an arrow is the list's");
}

- (void)testKeypadEnterAndForwardDeleteFoldIntoTheirTwins {
    XCTAssertEqualObjects(CommandForKey(76, 0, nil), @"select");
    XCTAssertEqualObjects(CommandForKey(117, 0, nil), @"remove");
    XCTAssertEqualObjects(CommandForKey(117, kCmd, nil), @"trash");
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(Table(), nil, @"play", VibeShortcutMake(76, kCmd), 0, NULL);
    XCTAssertEqualObjects(overrides[@"play"], @(VibeShortcutMake(36, kCmd)));
    XCTAssertEqualObjects(CommandForKey(36, kCmd, overrides), @"play");
}

- (void)testReservedShortcutsAreTheSystemOnesTheArrowsEscapeAndTheKeypad {
    for (NSString *key in @[@",", @"h", @"q", @"w", @"z", @"x", @"c", @"v", @"a", @"m"]) {
        XCTAssertTrue(VibeShortcutIsReserved(0, [key characterAtIndex:0], kCmd), @"⌘%@", key);
    }
    XCTAssertTrue(VibeShortcutIsReserved(4, 'h', kCmd | NSEventModifierFlagOption));
    XCTAssertTrue(VibeShortcutIsReserved(6, 'z', kCmd | kShift));
    XCTAssertTrue(VibeShortcutIsReserved(125, 0, kShift));
    XCTAssertTrue(VibeShortcutIsReserved(53, 0, 0));
    XCTAssertTrue(VibeShortcutIsReserved(123, 0, kCmd));
    XCTAssertTrue(VibeShortcutIsReserved(83, '1', 0), @"keypad digits");
    XCTAssertTrue(VibeShortcutIsReserved(67, '*', kOption), @"keypad operators");
    XCTAssertTrue(VibeShortcutIsReserved(65, '.', 0), @"keypad decimal");
    XCTAssertTrue(VibeShortcutIsReserved(71, 0, 0), @"keypad Clear");
    XCTAssertFalse(VibeShortcutIsReserved(18, '1', 0), @"the top row's 1");
    XCTAssertFalse(VibeShortcutIsReserved(76, 0, 0), @"keypad Enter is Return");
    XCTAssertFalse(VibeShortcutIsKeypadKey(76));
    // Only the exact combination is reserved, matched by character.
    XCTAssertFalse(VibeShortcutIsReserved(12, 'q', 0));
    XCTAssertFalse(VibeShortcutIsReserved(12, 'q', kCmd | kShift));
    XCTAssertFalse(VibeShortcutIsReserved(0, 0x0444, kCmd), @"a Cyrillic ⌘ф is free");
    XCTAssertFalse(VibeShortcutIsReserved(46, 'm', 0), @"bare M is an ordinary key; ⌘M is Window > Minimize");
}

// Cut and Paste own ⌘X and ⌘V. Neither can be recorded, and an override
// stored before they existed reaches neither the key monitor nor a menu item.
- (void)testCutAndPasteKeysAreReservedAndAStoredOverrideOnThemIsInert {
    XCTAssertTrue(VibeShortcutIsReserved(7, 'x', kCmd));
    XCTAssertTrue(VibeShortcutIsReserved(9, 'v', kCmd));
    XCTAssertTrue(VibeShortcutIsReserved(47, 'v', kCmd), @"Dvorak's V key types v under ⌘");
    XCTAssertFalse(VibeShortcutIsReserved(7, 'x', 0), @"bare X is an ordinary key");
    XCTAssertFalse(VibeShortcutIsReserved(9, 'v', kCmd | kShift));
    XCTAssertFalse(VibeShortcutIsReserved(9, 'v', kCmd | kOption));

    VibeShortcut pasteKey = VibeShortcutMake(9, kCmd);
    NSDictionary *overrides = @{@"next": @(pasteKey)};
    XCTAssertEqual(VibeShortcutEffective(Table(), @"next", overrides), pasteKey, @"kept as stored");
    XCTAssertNil(VibeShortcutCommandForPress(Table(), 9, kCmd, 'v', 'v', overrides), @"the press passes on to Paste");
    XCTAssertEqual(MenuItemForKey(@"next", pasteKey, 'v', overrides), kVibeShortcutNone, @"no shadowing equivalent");
    XCTAssertEqual(MenuItemForKey(@"skip_back", VibeShortcutMake(7, kCmd), 'x', nil), kVibeShortcutNone);
    // The same key under a layout that types another letter there is free.
    XCTAssertEqual(MenuItemForKey(@"next", pasteKey, 0x043C, overrides), pasteKey, @"Russian ⌘м");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(Table(), 9, kCmd, 0x043C, 0x043C, overrides), @"next");
}

- (void)testAMenuItemCarriesEveryShortcutButAReservedOne {
    for (NSArray *entry in Table()) {
        VibeShortcut shortcut = [entry[1] unsignedIntegerValue];
        XCTAssertEqual(MenuItemForKey(entry[0], shortcut, 0, nil), shortcut, @"%@", entry[0]);
    }
    XCTAssertEqual(MenuItemForKey(@"play", kVibeShortcutNone, 'v', nil), kVibeShortcutNone);
    XCTAssertEqual(MenuItemForKey(@"pin", VibeShortcutMake(12, kCmd), 'q', nil), kVibeShortcutNone, @"⌘Q");
    XCTAssertEqual(MenuItemForKey(@"pin", VibeShortcutMake(126, kCmd), 0, nil), kVibeShortcutNone, @"an arrow");
    VibeShortcut commandK = VibeShortcutMake(40, kCmd);
    XCTAssertEqual(MenuItemForKey(@"pin", commandK, 'k', @{@"pin": @(commandK)}), commandK);
}

- (void)testAssigningTakesTheShortcutFromItsOwnerAndStaysSparse {
    NSString *loser = nil;
    // K is free: stored, no loser.
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(Table(), nil, @"skip", VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, @{@"skip": @(VibeShortcutMake(40, 0))});
    XCTAssertNil(CommandForKey(0, 0, overrides), @"A is now free");

    // Taking N from next leaves next unassigned, stored as None over its default.
    overrides = VibeShortcutOverridesByAssigning(Table(), overrides, @"play", VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertEqualObjects(loser, @"next");
    XCTAssertEqual(VibeShortcutEffective(Table(), @"next", overrides), kVibeShortcutNone);
    XCTAssertEqualObjects(CommandForKey(45, 0, overrides), @"play");

    // skip loses K in turn, and stays unassigned rather than reverting to A.
    overrides = VibeShortcutOverridesByAssigning(Table(), overrides, @"next", VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertEqualObjects(loser, @"skip");
    XCTAssertEqual(VibeShortcutEffective(Table(), @"skip", overrides), kVibeShortcutNone);

    // Back to its default is absence; reassigning to self names no loser.
    overrides = VibeShortcutOverridesByAssigning(Table(), overrides, @"next", VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertEqualObjects(loser, @"play");
    XCTAssertNil(overrides[@"next"]);
    overrides = VibeShortcutOverridesByAssigning(Table(), overrides, @"next", VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertNil(loser);

    // Clearing names no loser and needs no character.
    overrides = VibeShortcutOverridesByAssigning(Table(), overrides, @"pin", kVibeShortcutNone, 0, &loser);
    XCTAssertNil(loser);
    XCTAssertNil(overrides[@"pin"], @"already None by default");
}

- (void)testAKeyCodeCollidesWithACharacterDefaultByCharacter {
    NSString *loser = nil;
    // ⌘O recorded on a QWERTY layout lands on open's character default.
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(Table(), nil, @"pin", VibeShortcutMake(31, kCmd), 'o', &loser);
    XCTAssertEqualObjects(loser, @"open");
    XCTAssertEqual(VibeShortcutEffective(Table(), @"open", overrides), kVibeShortcutNone);
    // ⇧⌘C collides with copy_name; ⌘C alone is reserved, not owned.
    XCTAssertEqualObjects(VibeShortcutOwner(Table(), VibeShortcutMake(8, kCmd | kShift), 'c', nil, nil), @"copy_name");
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(8, kCmd), 'c', nil, nil));
    // With no character known, only key codes collide.
    XCTAssertNil(VibeShortcutOwner(Table(), VibeShortcutMake(31, kCmd), 0, nil, nil));
}

- (void)testOnlyAKeyCodeWithModifiersOrNoneIsStorable {
    XCTAssertTrue(VibeShortcutIsStorable(@(kVibeShortcutNone)));
    XCTAssertTrue(VibeShortcutIsStorable(@(VibeShortcutMake(40, kCmd | kShift | kOption | NSEventModifierFlagControl))));
    XCTAssertTrue(VibeShortcutIsStorable(@(VibeShortcutMake(0, 0))));
    XCTAssertFalse(VibeShortcutIsStorable(@(kVibeShortcutNone | kCmd)), @"None takes no modifiers");
    XCTAssertFalse(VibeShortcutIsStorable(@(VibeShortcutMakeCharacter('o', kCmd))));
    XCTAssertFalse(VibeShortcutIsStorable(@(VibeShortcutMake(40, 0) | NSEventModifierFlagCapsLock)));
    XCTAssertFalse(VibeShortcutIsStorable(@(-1)));
    XCTAssertFalse(VibeShortcutIsStorable(@(-40)));
    XCTAssertFalse(VibeShortcutIsStorable(nil));
    XCTAssertFalse(VibeShortcutIsStorable(@"40"));
    XCTAssertFalse(VibeShortcutIsStorable(@[@40]));
    XCTAssertFalse(VibeShortcutIsStorable(NSNull.null));
}

- (void)testAssigningAnIdentifierOutsideTheTableChangesNothing {
    NSDictionary *stored = @{@"skip": @(VibeShortcutMake(40, 0))};
    NSString *loser = @"stale";
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(Table(), stored, @"menu_gone", VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, stored);
    overrides = VibeShortcutOverridesByAssigning(Table(), nil, @"menu_gone", VibeShortcutMake(31, kCmd), 'o', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, @{}, @"open keeps ⌘O");
}

- (void)testMalformedOrForeignStoredValuesReadAsDefaultsAndAreDropped {
    NSDictionary *stored = @{
        @"play": @"space",
        @"next": @(VibeShortcutMakeCharacter('n', 0)), // never stored
        @"skip_back": @(1UL << 40),
        @"menu_gone": @(VibeShortcutMake(40, 0)),
    };
    XCTAssertEqual(VibeShortcutEffective(Table(), @"play", stored), VibeShortcutDefault(Table(), @"play"));
    XCTAssertEqual(VibeShortcutEffective(Table(), @"next", stored), VibeShortcutDefault(Table(), @"next"));
    XCTAssertEqual(VibeShortcutEffective(Table(), @"skip_back", stored), VibeShortcutDefault(Table(), @"skip_back"));
    NSDictionary *cleaned = VibeShortcutOverridesByAssigning(Table(), stored, @"pin", kVibeShortcutNone, 0, NULL);
    XCTAssertEqualObjects(cleaned, @{});
}

- (void)testADuplicateResolvesToTheFirstCommandInTableOrder {
    NSDictionary *stored = @{@"pitch": @(VibeShortcutMake(49, 0))}; // Space, as play's default
    XCTAssertEqualObjects(CommandForKey(49, 0, stored), @"play");
    // The menu bar agrees: only play's item carries Space.
    XCTAssertEqual(MenuItemForKey(@"play", VibeShortcutMake(49, 0), ' ', stored), VibeShortcutMake(49, 0));
    XCTAssertEqual(MenuItemForKey(@"pitch", VibeShortcutMake(49, 0), ' ', stored), kVibeShortcutNone);
}

@end
