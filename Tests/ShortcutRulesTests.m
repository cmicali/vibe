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

// The command a key-code press performs, typing no character.
static NSString *CommandForKey(unsigned short keyCode, NSEventModifierFlags modifiers, NSDictionary *overrides) {
    return VibeShortcutOwner(VibeShortcutMake(keyCode, modifiers), 0, overrides, nil);
}

- (void)testDefaultsAreDistinctAndMatchTheBareKeysByPhysicalKey {
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (NSString *identifier in VibeShortcutIdentifiers()) {
        VibeShortcut shortcut = VibeShortcutDefault(identifier);
        // Every command but Open is one the player validates.
        XCTAssertTrue([identifier isEqualToString:kVibeMenuOpen]
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
    XCTAssertTrue(VibeShortcutIsCharacter(VibeShortcutDefault(kVibeMenuOpen)));
}

// What a held ⌘R would cycle through: the character defaults match the
// letter on any key and only with their own modifiers, and none repeats.
- (void)testCharacterDefaultsMatchTheirLetterWithTheirExactModifiers {
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutMake(15, kCmd), 'r', nil, nil), kVibeMenuRepeat);
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutMake(35, kCmd), 'r', nil, nil), kVibeMenuRepeat,
                          @"Dvorak's R is QWERTY's P");
    XCTAssertNil(VibeShortcutOwner(VibeShortcutMake(15, kCmd), 'p', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutMake(1, kCmd | kOption), 's', nil, nil), kVibeMenuShuffle);
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutMake(1, kCmd), 's', nil, nil), kVibeMenuSavePlaylist);
    // Shift is part of the set, against every character default.
    XCTAssertNil(VibeShortcutOwner(VibeShortcutMake(1, kCmd | kShift), 's', nil, nil));
    XCTAssertNil(VibeShortcutOwner(VibeShortcutMake(1, kCmd | kOption | kShift), 's', nil, nil));
    XCTAssertNil(VibeShortcutOwner(VibeShortcutMake(15, kCmd | kShift), 'r', nil, nil));
    XCTAssertNil(VibeShortcutOwner(VibeShortcutMake(31, kCmd | kShift), 'o', nil, nil));
    XCTAssertNil(VibeShortcutOwner(VibeShortcutMake(8, kShift), 'c', nil, nil));
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutMake(15, 0), 'r', nil, nil), kVibeMenuFXDelay,
                          @"bare R is the delay's key code, not Repeat");
    for (NSString *identifier in @[kVibeMenuRepeat, kVibeMenuShuffle, kVibeMenuOpen, kVibeMenuSavePlaylist,
                                   kVibeMenuEditCopyName]) {
        XCTAssertFalse(VibeShortcutCommandRepeats(identifier), @"%@", identifier);
    }
}

- (void)testAPressIsTriedAsTypedThenUnmodifiedAndAReservedOnePassesOn {
    XCTAssertEqualObjects(VibeShortcutCommandForPress(15, kCmd, 'r', 0x03C1, nil), kVibeMenuRepeat,
                          @"Greek types ρ, and r under ⌘");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(1, kCmd | kOption, 0x00DF, 's', nil), kVibeMenuShuffle,
                          @"⌥⌘S types ß");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(31, kCmd, 'o', 'r', nil), kVibeMenuOpen,
                          @"Dvorak – QWERTY ⌘'s R key types o under ⌘");
    XCTAssertEqualObjects(VibeShortcutCommandForPress(0, 0, 0, 'a', nil), kVibeMenuSkipForward);
    XCTAssertNil(VibeShortcutCommandForPress(12, kCmd, 'q', 'q', nil), @"⌘Q is the system's");
    XCTAssertNil(VibeShortcutCommandForPress(12, kCmd, 'q', 0x03C2, nil), @"reserved under either form");
    XCTAssertNil(VibeShortcutCommandForPress(126, 0, 0, 0, nil), @"an arrow is the table's");
}

- (void)testKeypadEnterAndForwardDeleteFoldIntoTheirTwins {
    XCTAssertEqualObjects(CommandForKey(76, 0, nil), kVibeMenuPlaySelected);
    XCTAssertEqualObjects(CommandForKey(117, 0, nil), kVibeMenuEditRemoveFromPlaylist);
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(nil, kVibeMenuPlay, VibeShortcutMake(76, kCmd), 0, NULL);
    XCTAssertEqualObjects(overrides[kVibeMenuPlay], @(VibeShortcutMake(36, kCmd)));
    XCTAssertEqualObjects(CommandForKey(36, kCmd, overrides), kVibeMenuPlay);
}

- (void)testReservedShortcutsAreTheSystemOnesTheArrowsEscapeAndTheKeypad {
    for (NSString *key in @[@",", @"h", @"q", @"w", @"z", @"c", @"a"]) {
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
    XCTAssertFalse(VibeShortcutIsReserved(46, 'm', 0), @"M is an ordinary key");
}

- (void)testAssigningTakesTheShortcutFromItsOwnerAndStaysSparse {
    NSString *loser = nil;
    // K is free: stored, no loser.
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(nil, kVibeMenuSkipForward,
            VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, @{kVibeMenuSkipForward: @(VibeShortcutMake(40, 0))});
    XCTAssertNil(CommandForKey(0, 0, overrides), @"A is now free");

    // Taking N from Next leaves Next unassigned, stored as None over its default.
    overrides = VibeShortcutOverridesByAssigning(overrides, kVibeMenuPlay, VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertEqualObjects(loser, kVibeMenuNextTrack);
    XCTAssertEqual(VibeShortcutEffective(kVibeMenuNextTrack, overrides), kVibeShortcutNone);
    XCTAssertEqualObjects(CommandForKey(45, 0, overrides), kVibeMenuPlay);

    // Skip Forward loses K in turn, and stays unassigned rather than reverting to A.
    overrides = VibeShortcutOverridesByAssigning(overrides, kVibeMenuNextTrack, VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertEqualObjects(loser, kVibeMenuSkipForward);
    XCTAssertEqual(VibeShortcutEffective(kVibeMenuSkipForward, overrides), kVibeShortcutNone);

    // Back to its default is absence; reassigning to self names no loser.
    overrides = VibeShortcutOverridesByAssigning(overrides, kVibeMenuNextTrack, VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertEqualObjects(loser, kVibeMenuPlay);
    XCTAssertNil(overrides[kVibeMenuNextTrack]);
    overrides = VibeShortcutOverridesByAssigning(overrides, kVibeMenuNextTrack, VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertNil(loser);

    // Clearing names no loser and needs no character.
    overrides = VibeShortcutOverridesByAssigning(overrides, kVibeMenuShowFileInfo, kVibeShortcutNone, 0, &loser);
    XCTAssertNil(loser);
    XCTAssertNil(overrides[kVibeMenuShowFileInfo], @"already None by default");
}

- (void)testAKeyCodeCollidesWithACharacterDefaultByCharacter {
    NSString *loser = nil;
    // ⌘O recorded on a QWERTY layout lands on Open's character default.
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(nil, kVibeMenuShowFileInfo,
            VibeShortcutMake(31, kCmd), 'o', &loser);
    XCTAssertEqualObjects(loser, kVibeMenuOpen);
    XCTAssertEqual(VibeShortcutEffective(kVibeMenuOpen, overrides), kVibeShortcutNone);
    // ⇧⌘C collides with Copy Name; ⌘C alone is reserved, not owned.
    XCTAssertEqualObjects(VibeShortcutOwner(VibeShortcutMake(8, kCmd | kShift), 'c', nil, nil), kVibeMenuEditCopyName);
    XCTAssertNil(VibeShortcutOwner(VibeShortcutMake(8, kCmd), 'c', nil, nil));
    // With no character known, only key codes collide.
    XCTAssertNil(VibeShortcutOwner(VibeShortcutMake(31, kCmd), 0, nil, nil));
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

// Not a remappable command: nothing is stored, and no command loses its key.
- (void)testAssigningAnIdentifierOutsideTheTableChangesNothing {
    NSDictionary *stored = @{kVibeMenuSkipForward: @(VibeShortcutMake(40, 0))};
    NSString *loser = @"stale";
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(stored, @"menu_gone", VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, stored);
    overrides = VibeShortcutOverridesByAssigning(nil, @"menu_gone", VibeShortcutMake(31, kCmd), 'o', &loser);
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
    XCTAssertEqual(VibeShortcutEffective(kVibeMenuPlay, stored), VibeShortcutDefault(kVibeMenuPlay));
    XCTAssertEqual(VibeShortcutEffective(kVibeMenuNextTrack, stored), VibeShortcutDefault(kVibeMenuNextTrack));
    XCTAssertEqual(VibeShortcutEffective(kVibeMenuSkipBack, stored), VibeShortcutDefault(kVibeMenuSkipBack));
    NSDictionary *cleaned = VibeShortcutOverridesByAssigning(stored, kVibeMenuShowFileInfo, kVibeShortcutNone, 0, NULL);
    XCTAssertEqualObjects(cleaned, @{});
}

- (void)testADuplicateResolvesToTheFirstCommandInTableOrder {
    NSDictionary *stored = @{kVibeMenuShowPitch: @(VibeShortcutMake(49, 0))}; // Space, as Play's default
    XCTAssertEqualObjects(CommandForKey(49, 0, stored), kVibeMenuPlay);
}

- (void)testOnlyTheSkipsAndTrackStepsRepeat {
    XCTAssertTrue(VibeShortcutCommandRepeats(kVibeMenuSkipBackMost));
    XCTAssertTrue(VibeShortcutCommandRepeats(kVibeMenuNextTrack));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuPlay));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuShowPlaylist));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuOpen));
}

@end
