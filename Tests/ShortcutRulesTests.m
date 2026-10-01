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
    XCTAssertEqualObjects(VibeShortcutCommandForKey(0, 0, nil), kVibeMenuSkipForward);
    XCTAssertEqualObjects(VibeShortcutCommandForKey(12, 0, nil), kVibeMenuFXLowKill);
    XCTAssertEqualObjects(VibeShortcutCommandForKey(49, 0, nil), kVibeMenuPlay);
    // Shift, or any modifier, is a different shortcut.
    XCTAssertNil(VibeShortcutCommandForKey(0, kShift, nil));
    // Caps Lock and the function flag are not part of a shortcut.
    XCTAssertEqualObjects(VibeShortcutCommandForKey(0, NSEventModifierFlagCapsLock | NSEventModifierFlagFunction, nil),
                          kVibeMenuSkipForward);
    // Character defaults belong to the menu bar alone.
    XCTAssertNil(VibeShortcutCommandForKey(31, kCmd, nil));
    XCTAssertTrue(VibeShortcutIsCharacter(VibeShortcutDefault(kVibeMenuOpen)));
}

- (void)testKeypadEnterAndForwardDeleteFoldIntoTheirTwins {
    XCTAssertEqualObjects(VibeShortcutCommandForKey(76, 0, nil), kVibeMenuPlaySelected);
    XCTAssertEqualObjects(VibeShortcutCommandForKey(117, 0, nil), kVibeMenuEditRemoveFromPlaylist);
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(nil, kVibeMenuPlay, VibeShortcutMake(76, kCmd), 0, NULL);
    XCTAssertEqualObjects(overrides[kVibeMenuPlay], @(VibeShortcutMake(36, kCmd)));
    XCTAssertEqualObjects(VibeShortcutCommandForKey(36, kCmd, overrides), kVibeMenuPlay);
}

- (void)testReservedShortcutsAreTheSystemOnesTheArrowsAndEscape {
    for (NSString *key in @[@",", @"h", @"q", @"w", @"z", @"c", @"a"]) {
        XCTAssertTrue(VibeShortcutIsReserved(0, [key characterAtIndex:0], kCmd), @"⌘%@", key);
    }
    XCTAssertTrue(VibeShortcutIsReserved(4, 'h', kCmd | NSEventModifierFlagOption));
    XCTAssertTrue(VibeShortcutIsReserved(6, 'z', kCmd | kShift));
    XCTAssertTrue(VibeShortcutIsReserved(125, 0, kShift));
    XCTAssertTrue(VibeShortcutIsReserved(53, 0, 0));
    XCTAssertTrue(VibeShortcutIsReserved(83, '1', 0), @"keypad digits");
    XCTAssertFalse(VibeShortcutIsReserved(76, 0, 0), @"keypad Enter is Return");
    // Only the exact combination is reserved, matched by character.
    XCTAssertFalse(VibeShortcutIsReserved(12, 'q', 0));
    XCTAssertFalse(VibeShortcutIsReserved(12, 'q', kCmd | kShift));
    XCTAssertFalse(VibeShortcutIsReserved(0, 0x0444, kCmd), @"a Cyrillic ⌘ф is free");
#if VIBE_VERBOSE_LOGGING
    XCTAssertTrue(VibeShortcutIsReserved(46, 0, 0), @"the beta marker's physical M");
#else
    XCTAssertFalse(VibeShortcutIsReserved(46, 0, 0));
#endif
}

- (void)testAssigningTakesTheShortcutFromItsOwnerAndStaysSparse {
    NSString *loser = nil;
    // K is free: stored, no loser.
    NSDictionary *overrides = VibeShortcutOverridesByAssigning(nil, kVibeMenuSkipForward,
            VibeShortcutMake(40, 0), 'k', &loser);
    XCTAssertNil(loser);
    XCTAssertEqualObjects(overrides, @{kVibeMenuSkipForward: @(VibeShortcutMake(40, 0))});
    XCTAssertNil(VibeShortcutCommandForKey(0, 0, overrides), @"A is now free");

    // Taking N from Next leaves Next unassigned, stored as None over its default.
    overrides = VibeShortcutOverridesByAssigning(overrides, kVibeMenuPlay, VibeShortcutMake(45, 0), 'n', &loser);
    XCTAssertEqualObjects(loser, kVibeMenuNextTrack);
    XCTAssertEqual(VibeShortcutEffective(kVibeMenuNextTrack, overrides), kVibeShortcutNone);
    XCTAssertEqualObjects(VibeShortcutCommandForKey(45, 0, overrides), kVibeMenuPlay);

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
    XCTAssertEqualObjects(VibeShortcutCommandForKey(49, 0, stored), kVibeMenuPlay);
}

- (void)testOnlyTheSkipsAndTrackStepsRepeat {
    XCTAssertTrue(VibeShortcutCommandRepeats(kVibeMenuSkipBackMost));
    XCTAssertTrue(VibeShortcutCommandRepeats(kVibeMenuNextTrack));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuPlay));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuShowPlaylist));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuOpen));
}

@end
