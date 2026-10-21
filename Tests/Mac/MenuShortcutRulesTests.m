//
//  MenuShortcutRulesTests.m
//  VibeTests
//

#import <XCTest/XCTest.h>

#import "MenuShortcutRules.h"

@interface MenuShortcutRulesTests : XCTestCase
@end

@implementation MenuShortcutRulesTests

static const NSEventModifierFlags kCmd = NSEventModifierFlagCommand;
static const NSEventModifierFlags kShift = NSEventModifierFlagShift;

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
    XCTAssertTrue(VibeShortcutIsCharacter(VibeShortcutDefault(VibeShortcutTable(), kVibeMenuOpen)));
}

- (void)testEveryDefaultIsCarriedByItsMenuItem {
    for (NSString *identifier in VibeShortcutIdentifiers()) {
        VibeShortcut shortcut = VibeShortcutDefault(VibeShortcutTable(), identifier);
        XCTAssertEqual(MenuItemForKey(identifier, shortcut, 0, nil), shortcut, @"%@", identifier);
    }
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

// A held ⌘R would cycle the repeat mode, so no Command default repeats.
- (void)testOnlyTheSkipsAndTrackStepsRepeat {
    XCTAssertTrue(VibeShortcutCommandRepeats(kVibeMenuSkipBackMost));
    XCTAssertTrue(VibeShortcutCommandRepeats(kVibeMenuNextTrack));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuPlay));
    XCTAssertFalse(VibeShortcutCommandRepeats(kVibeMenuShowPlaylist));
    for (NSString *identifier in @[kVibeMenuRepeat, kVibeMenuShuffle, kVibeMenuOpen, kVibeMenuAddToPlaylist,
                                   kVibeMenuSavePlaylist, kVibeMenuEditCopyName]) {
        XCTAssertFalse(VibeShortcutCommandRepeats(identifier), @"%@", identifier);
    }
}

@end
