//
//  ShortcutRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "MenuShortcutRules.h"

@interface ShortcutRulesTests : XCTestCase
@end

@implementation ShortcutRulesTests

static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand;
static const NSEventModifierFlags kShift = NSEventModifierFlagShift;
static const NSEventModifierFlags kOption = NSEventModifierFlagOption;

// The command a key-code press performs, typing no character.
static NSString *CommandForKey(unsigned short keyCode, NSEventModifierFlags modifiers, NSDictionary *overrides) {
    return VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(keyCode, modifiers), 0, overrides, nil);
}

// What a key-code shortcut's menu item carries, the key typing character.
static VibeShortcut MenuItemForKey(NSString *identifier, VibeShortcut shortcut, unichar character,
                                   NSDictionary *overrides) {
    return VibeShortcutForMenuItem(VibeShortcutTable(), identifier, shortcut, kVibeShortcutKeyMask, character, overrides);
}

- (void)testDefaultsAreDistinctAndMatchTheBareKeysByPhysicalKey {
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (NSString *identifier in VibeShortcutIdentifiers()) {
        VibeShortcut shortcut = VibeShortcutDefault(VibeShortcutTable(), identifier);
        // Every command but Open, Add to Playlist and Open URL is one the player validates.
        XCTAssertTrue(([@[kVibeMenuOpen, kVibeMenuAddToPlaylist, kVibeMenuOpenLink] containsObject:identifier])
                      || VibeMenuValidationDomainForIdentifier(identifier) != VibeMenuValidationDomainUnknown,
                      @"%@", identifier);
        if (shortcut != kVibeShortcutNone) {
            XCTAssertFalse([seen containsObject:@(shortcut)], @"%@ duplicates a default", identifier);
            [seen addObject:@(shortcut)];
            BOOL character = VibeShortcutIsCharacter(shortcut);
            XCTAssertFalse(VibeShortcutIsReserved(character ? 0xFFFE : VibeShortcutKey(shortcut),
                                                  character ? VibeShortcutKey(shortcut) : 0,
                                                  VibeShortcutModifiers(shortcut)), @"%@", identifier);
        }
    }
    XCTAssertEqualObjects(CommandForKey(0, 0, nil), kVibeMenuSkipForward);
    XCTAssertEqualObjects(CommandForKey(12, 0, nil), kVibeMenuFXLowKill);
    XCTAssertEqualObjects(CommandForKey(49, 0, nil), kVibeMenuPlay);
    // Shift, or any modifier, is a different shortcut.
    XCTAssertNil(CommandForKey(0, kShift, nil));
    // Caps Lock and the function flag are not part of a shortcut.
    XCTAssertEqualObjects(CommandForKey(0, NSEventModifierFlagCapsLock | NSEventModifierFlagFunction, nil),
                          kVibeMenuSkipForward);
    // Character defaults match by character, never by key code.
    XCTAssertNil(CommandForKey(31, kCmd, nil));
    XCTAssertTrue(VibeShortcutIsCharacter(VibeShortcutDefault(VibeShortcutTable(), kVibeMenuOpen)));
}

// What a held ⌘R would cycle through: the character defaults match the
// letter on any key and only with their own modifiers, and none repeats.
- (void)testCharacterDefaultsMatchTheirLetterWithTheirExactModifiers {
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(15, kCmd), 'r', nil, nil), kVibeMenuRepeat);
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(35, kCmd), 'r', nil, nil), kVibeMenuRepeat,
                          @"Dvorak's R is QWERTY's P");
    XCTAssertNil(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(15, kCmd), 'p', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(1, kCmd | kOption), 's', nil, nil), kVibeMenuShuffle);
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(1, kCmd), 's', nil, nil), kVibeMenuSavePlaylist);
    // Shift is part of the set, against every character default.
    XCTAssertNil(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(1, kCmd | kShift), 's', nil, nil));
    XCTAssertNil(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(1, kCmd | kOption | kShift), 's', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(15, kCmd | kShift), 'r', nil, nil), kVibeMenuShowInFinder,
                          @"⇧⌘R is Show in Finder, never Repeat");
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(31, kCmd | kShift), 'o', nil, nil), kVibeMenuAddToPlaylist);
    XCTAssertNil(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(8, kShift), 'c', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(15, 0), 'r', nil, nil), kVibeMenuFXDelay,
                          @"bare R is the delay's key code, not Repeat");
    for (NSString *identifier in @[kVibeMenuRepeat, kVibeMenuShuffle, kVibeMenuOpen, kVibeMenuAddToPlaylist,
                                   kVibeMenuSavePlaylist, kVibeMenuEditCopyName]) {
        XCTAssertFalse(VibeShortcutCommandRepeats(identifier), @"%@", identifier);
    }
}

- (void)testAPressIsTriedAsTypedThenUnmodifiedAndAReservedOnePassesOn {
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 15, kCmd, 'r', 0x03C1, nil), kVibeMenuRepeat,
                          @"Greek types ρ, and r under ⌘");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 1, kCmd | kOption, 0x00DF, 's', nil), kVibeMenuShuffle,
                          @"⌥⌘S types ß");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 31, kCmd, 'o', 'r', nil), kVibeMenuOpen,
                          @"Dvorak – QWERTY ⌘'s R key types o under ⌘");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 0, 0, 0, 'a', nil), kVibeMenuSkipForward);
    XCTAssertNil(VibeShortcutCommandForPress(VibeShortcutTable(), 12, kCmd, 'q', 'q', nil), @"⌘Q is the system's");
    XCTAssertNil(VibeShortcutCommandForPress(VibeShortcutTable(), 12, kCmd, 'q', 0x03C2, nil), @"reserved under either form");
    XCTAssertNil(VibeShortcutCommandForPress(VibeShortcutTable(), 126, 0, 0, 0, nil), @"an arrow is the table's");
}

- (void)testKeypadEnterAndForwardDeleteFoldIntoTheirTwins {
    XCTAssertEqualObjects(CommandForKey(76, 0, nil), kVibeMenuPlaySelected);
    XCTAssertEqualObjects(CommandForKey(117, 0, nil), kVibeMenuEditRemoveFromPlaylist);
    XCTAssertEqualObjects(CommandForKey(117, kCmd, nil), kVibeMenuEditMoveToTrash);
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(VibeShortcutTable(), nil, kVibeMenuPlay, VibeShortcutMake(76, kCmd), 0, NULL);
    XCTAssertEqualObjects(overrides[kVibeMenuPlay], @(VibeShortcutMake(36, kCmd)));
    XCTAssertEqualObjects(CommandForKey(36, kCmd, overrides), kVibeMenuPlay);
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
    XCTAssertFalse(VibeShortcutIsReserved(7, 'x', 0), @"bare X stays Skip Back More");
    XCTAssertFalse(VibeShortcutIsReserved(9, 'v', kCmd | kShift));
    XCTAssertFalse(VibeShortcutIsReserved(9, 'v', kCmd | kOption));

    VibeShortcut pasteKey = VibeShortcutMake(9, kCmd);
    NSDictionary *overrides = @{kVibeMenuNextTrack: @(pasteKey)};
    XCTAssertEqual(VibeShortcutEffective(VibeShortcutTable(), kVibeMenuNextTrack, overrides), pasteKey, @"kept as stored");
    XCTAssertNil(VibeShortcutCommandForPress(VibeShortcutTable(), 9, kCmd, 'v', 'v', overrides), @"the press passes on to Paste");
    XCTAssertEqual(MenuItemForKey(kVibeMenuNextTrack, pasteKey, 'v', overrides), kVibeShortcutNone,
                   @"no shadowing equivalent");
    XCTAssertEqual(MenuItemForKey(kVibeMenuSkipBack, VibeShortcutMake(7, kCmd), 'x', nil), kVibeShortcutNone);
    // The same key under a layout that types another letter there is free.
    XCTAssertEqual(MenuItemForKey(kVibeMenuNextTrack, pasteKey, 0x043C, overrides), pasteKey, @"Russian ⌘м");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 9, kCmd, 0x043C, 0x043C, overrides), kVibeMenuNextTrack);
}

- (void)testAMenuItemCarriesEveryShortcutButAReservedOne {
    for (NSString *identifier in VibeShortcutIdentifiers()) {
        VibeShortcut shortcut = VibeShortcutDefault(VibeShortcutTable(), identifier);
        XCTAssertEqual(MenuItemForKey(identifier, shortcut, 0, nil), shortcut, @"%@", identifier);
    }
    XCTAssertEqual(MenuItemForKey(kVibeMenuPlay, kVibeShortcutNone, 'v', nil), kVibeShortcutNone);
    XCTAssertEqual(MenuItemForKey(kVibeMenuAlwaysOnTop, VibeShortcutMake(12, kCmd), 'q', nil), kVibeShortcutNone,
                   @"⌘Q");
    XCTAssertEqual(MenuItemForKey(kVibeMenuAlwaysOnTop, VibeShortcutMake(126, kCmd), 0, nil), kVibeShortcutNone,
                   @"an arrow");
    VibeShortcut commandK = VibeShortcutMake(40, kCmd);
    XCTAssertEqual(MenuItemForKey(kVibeMenuAlwaysOnTop, commandK, 'k', @{kVibeMenuAlwaysOnTop: @(commandK)}),
                   commandK);
}

// The Finder's own shortcut, by physical key. An override stored on ⌘⌫
// before the default existed keeps the key.
- (void)testMoveToTrashIsCommandDelete {
    XCTAssertEqual(VibeShortcutDefault(VibeShortcutTable(), kVibeMenuEditMoveToTrash), VibeShortcutMake(51, kCmd));
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 51, kCmd, 0x7F, 0x7F, nil), kVibeMenuEditMoveToTrash);
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 51, 0, 0, 0x7F, nil), kVibeMenuEditRemoveFromPlaylist);
    XCTAssertFalse(VibeShortcutIsReserved(51, 0x7F, kCmd));
    VibeShortcut commandDelete = VibeShortcutMake(51, kCmd);
    NSDictionary *overrides = @{kVibeMenuPlay: @(commandDelete)};
    XCTAssertEqualObjects(CommandForKey(51, kCmd, overrides), kVibeMenuPlay);
    XCTAssertEqual(MenuItemForKey(kVibeMenuEditMoveToTrash, commandDelete, 0, overrides), kVibeShortcutNone);
}

// QuickTime Player's and Safari's key for it.
- (void)testOpenLocationIsCommandLByItsLetter {
    VibeShortcut commandL = VibeShortcutMakeCharacter('l', kCmd);
    XCTAssertEqual(VibeShortcutDefault(VibeShortcutTable(), kVibeMenuOpenLink), commandL);
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 37, kCmd, 'l', 'l', nil), kVibeMenuOpenLink);
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 35, kCmd, 'l', 'l', nil), kVibeMenuOpenLink,
                          @"Dvorak types l on QWERTY's P key");
    XCTAssertNil(VibeShortcutCommandForPress(VibeShortcutTable(), 37, kCmd | kShift, 'l', 'l', nil));
    XCTAssertNil(VibeShortcutCommandForPress(VibeShortcutTable(), 37, 0, 0, 'l', nil), @"bare L is unbound");
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuOpenLink));
    XCTAssertEqual(VibeShortcutForMenuItem(VibeShortcutTable(), kVibeMenuOpenLink, commandL, 37, 0, nil), commandL);
    XCTAssertEqual(VibeShortcutForMenuItem(VibeShortcutTable(), kVibeMenuOpenLink, commandL, kVibeShortcutKeyMask, 0, nil), commandL,
                   @"a layout with no L still draws ⌘L");
}

// Music's key for it, last in the table so an older override keeps the key.
- (void)testShowInFinderIsShiftCommandR {
    VibeShortcut shiftCommandR = VibeShortcutMakeCharacter('r', kCmd | kShift);
    XCTAssertEqual(VibeShortcutDefault(VibeShortcutTable(), kVibeMenuShowInFinder), shiftCommandR);
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 15, kCmd | kShift, 'r', 'r', nil), kVibeMenuShowInFinder);
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 15, kCmd, 'r', 'r', nil), kVibeMenuRepeat,
                          @"⌘R stays Repeat");
    XCTAssertEqualObjects(VibeShortcutIdentifiers().lastObject, kVibeMenuShowInFinder);
}

// An override stored on ⌘L before Open Location existed keeps the key: its
// press and its menu item. Open Location's item carries nothing, and the
// recording that gave the key away again hands it back.
- (void)testAnOverrideAlreadyOnCommandLOutranksOpenLocation {
    VibeShortcut commandL = VibeShortcutMake(37, kCmd);
    VibeShortcut openLocation = VibeShortcutDefault(VibeShortcutTable(), kVibeMenuOpenLink);
    NSDictionary *overrides = @{kVibeMenuAlwaysOnTop: @(commandL)};
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 37, kCmd, 'l', 'l', overrides), kVibeMenuAlwaysOnTop);
    XCTAssertEqual(MenuItemForKey(kVibeMenuAlwaysOnTop, commandL, 'l', overrides), commandL);
    XCTAssertEqual(VibeShortcutForMenuItem(VibeShortcutTable(), kVibeMenuOpenLink, openLocation, 37, 0, overrides), kVibeShortcutNone);
    XCTAssertEqual(VibeShortcutEffective(VibeShortcutTable(), kVibeMenuOpenLink, overrides), openLocation, @"still its default");

    // Dvorak types n on that key and l on QWERTY's P: each keeps its own.
    XCTAssertEqual(MenuItemForKey(kVibeMenuAlwaysOnTop, commandL, 'n', overrides), commandL);
    XCTAssertEqual(VibeShortcutForMenuItem(VibeShortcutTable(), kVibeMenuOpenLink, openLocation, 35, 0, overrides), openLocation);
    XCTAssertEqualObjects(VibeShortcutCommandForPress(VibeShortcutTable(), 35, kCmd, 'l', 'l', overrides), kVibeMenuOpenLink);

    // Recording ⌘L now takes it from Open Location, as from any default.
    NSString *loser = nil;
    NSDictionary *recorded = VibeShortcutOverridesByAssigning(VibeShortcutTable(), nil, kVibeMenuAlwaysOnTop, commandL, 'l', &loser);
    XCTAssertEqualObjects(loser, kVibeMenuOpenLink);
    XCTAssertEqual(VibeShortcutEffective(VibeShortcutTable(), kVibeMenuOpenLink, recorded), kVibeShortcutNone);
}

- (void)testAssigningTakesTheShortcutFromItsOwnerAndStaysSparse {
    NSString *loser = nil;
    // K is free: stored, no loser.
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(VibeShortcutTable(), nil, kVibeMenuSkipForward,
            VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, @{kVibeMenuSkipForward: @(VibeShortcutMake(40, 0))});
    XCTAssertNil(CommandForKey(0, 0, overrides), @"A is now free");

    // Taking N from Next leaves Next unassigned, stored as None over its default.
    overrides = VibeShortcutOverridesByAssigning(VibeShortcutTable(), overrides, kVibeMenuPlay, VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertEqualObjects(loser, kVibeMenuNextTrack);
    XCTAssertEqual(VibeShortcutEffective(VibeShortcutTable(), kVibeMenuNextTrack, overrides), kVibeShortcutNone);
    XCTAssertEqualObjects(CommandForKey(45, 0, overrides), kVibeMenuPlay);

    // Skip Forward loses K in turn, and stays unassigned rather than reverting to A.
    overrides = VibeShortcutOverridesByAssigning(VibeShortcutTable(), overrides, kVibeMenuNextTrack, VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertEqualObjects(loser, kVibeMenuSkipForward);
    XCTAssertEqual(VibeShortcutEffective(VibeShortcutTable(), kVibeMenuSkipForward, overrides), kVibeShortcutNone);

    // Back to its default is absence; reassigning to self names no loser.
    overrides = VibeShortcutOverridesByAssigning(VibeShortcutTable(), overrides, kVibeMenuNextTrack, VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertEqualObjects(loser, kVibeMenuPlay);
    XCTAssertNil(overrides[kVibeMenuNextTrack]);
    overrides = VibeShortcutOverridesByAssigning(VibeShortcutTable(), overrides, kVibeMenuNextTrack, VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertNil(loser);

    // Clearing names no loser and needs no character.
    overrides = VibeShortcutOverridesByAssigning(VibeShortcutTable(), overrides, kVibeMenuAlwaysOnTop, kVibeShortcutNone, 0, &loser);
    XCTAssertNil(loser);
    XCTAssertNil(overrides[kVibeMenuAlwaysOnTop], @"already None by default");
}

- (void)testAKeyCodeCollidesWithACharacterDefaultByCharacter {
    NSString *loser = nil;
    // ⌘O recorded on a QWERTY layout lands on Open's character default.
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(VibeShortcutTable(), nil, kVibeMenuAlwaysOnTop,
            VibeShortcutMake(31, kCmd), 'o', &loser);
    XCTAssertEqualObjects(loser, kVibeMenuOpen);
    XCTAssertEqual(VibeShortcutEffective(VibeShortcutTable(), kVibeMenuOpen, overrides), kVibeShortcutNone);
    // ⇧⌘C collides with Copy Name; ⌘C alone is reserved, not owned.
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(8, kCmd | kShift), 'c', nil, nil), kVibeMenuEditCopyName);
    XCTAssertNil(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(8, kCmd), 'c', nil, nil));
    // With no character known, only key codes collide.
    XCTAssertNil(VibeShortcutOwner(VibeShortcutTable(), VibeShortcutMake(31, kCmd), 0, nil, nil));
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
    NSDictionary *stored = @{kVibeMenuSkipForward: @(VibeShortcutMake(40, 0))};
    NSString *loser = @"stale";
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(VibeShortcutTable(), stored, @"menu_gone", VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, stored);
    overrides = VibeShortcutOverridesByAssigning(VibeShortcutTable(), nil, @"menu_gone", VibeShortcutMake(31, kCmd), 'o', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, @{}, @"Open keeps ⌘O");
}

- (void)testMalformedOrForeignStoredValuesReadAsDefaultsAndAreDropped {
    NSDictionary *stored = @{
        kVibeMenuPlay: @"space",
        kVibeMenuNextTrack: @(VibeShortcutMakeCharacter('n', 0)), // never stored
        kVibeMenuSkipBack: @(1UL << 40),
        @"menu_gone": @(VibeShortcutMake(40, 0)),
    };
    XCTAssertEqual(VibeShortcutEffective(VibeShortcutTable(), kVibeMenuPlay, stored), VibeShortcutDefault(VibeShortcutTable(), kVibeMenuPlay));
    XCTAssertEqual(VibeShortcutEffective(VibeShortcutTable(), kVibeMenuNextTrack, stored), VibeShortcutDefault(VibeShortcutTable(), kVibeMenuNextTrack));
    XCTAssertEqual(VibeShortcutEffective(VibeShortcutTable(), kVibeMenuSkipBack, stored), VibeShortcutDefault(VibeShortcutTable(), kVibeMenuSkipBack));
    NSDictionary *cleaned = VibeShortcutOverridesByAssigning(VibeShortcutTable(), stored, kVibeMenuAlwaysOnTop, kVibeShortcutNone, 0, NULL);
    XCTAssertEqualObjects(cleaned, @{});
}

- (void)testADuplicateResolvesToTheFirstCommandInTableOrder {
    NSDictionary *stored = @{kVibeMenuShowPitch: @(VibeShortcutMake(49, 0))}; // Space, as Play's default
    XCTAssertEqualObjects(CommandForKey(49, 0, stored), kVibeMenuPlay);
    // The menu bar agrees: only Play's item carries Space.
    XCTAssertEqual(MenuItemForKey(kVibeMenuPlay, VibeShortcutMake(49, 0), ' ', stored), VibeShortcutMake(49, 0));
    XCTAssertEqual(MenuItemForKey(kVibeMenuShowPitch, VibeShortcutMake(49, 0), ' ', stored), kVibeShortcutNone);
}

- (void)testOnlyTheSkipsAndTrackStepsRepeat {
    XCTAssertTrue(VibeShortcutCommandRepeats(kVibeMenuSkipBackMost));
    XCTAssertTrue(VibeShortcutCommandRepeats(kVibeMenuNextTrack));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuPlay));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuShowPlaylist));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuOpen));
}

@end
