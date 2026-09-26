//
//  MenuValidationRulesTests.m
//  VibeTests
//

// The identifier-to-domain classification behind MainPlayerController's
// validateMenuItem:. The policy under test is that recognition is explicit:
// an identifier this controller does not own answers Unknown, and the
// validator disables it rather than letting it through.

#import <XCTest/XCTest.h>

#import "MenuValidationRules.h"

@interface MenuValidationRulesTests : XCTestCase
@end

@implementation MenuValidationRulesTests

- (void)assertIdentifiers:(NSArray<NSString *> *)identifiers
                 classify:(VibeMenuValidationDomain)expected {
    for (NSString *identifier in identifiers) {
        XCTAssertEqual(VibeMenuValidationDomainForIdentifier(identifier), expected,
                       @"%@", identifier);
    }
}

- (void)testEveryBuilderOwnedIdentifierHasADomain {
    [self assertIdentifiers:@[kVibeMenuShowPlaylist, kVibeMenuShowPitch,
                              kVibeMenuShowFileInfo, kVibeMenuAlwaysOnTop,
                              kVibeMenuLockWindowPosition]
                   classify:VibeMenuValidationDomainViewToggle];

    [self assertIdentifiers:@[kVibeMenuNextTrack, kVibeMenuPreviousTrack, kVibeMenuPlaySelected,
                              kVibeMenuSkipForward, kVibeMenuSkipForwardMore,
                              kVibeMenuSkipForwardMost, kVibeMenuSkipBack,
                              kVibeMenuSkipBackMore, kVibeMenuSkipBackMost]
                   classify:VibeMenuValidationDomainTransport];

    [self assertIdentifiers:@[kVibeMenuFXLowKill, kVibeMenuFXLowKillBoost, kVibeMenuFXReverb,
                              kVibeMenuFXDelay, kVibeMenuFXShortDelay]
                   classify:VibeMenuValidationDomainFX];

    [self assertIdentifiers:@[kVibeMenuPitchRange8, kVibeMenuPitchRange16]
                   classify:VibeMenuValidationDomainPitchRange];

    [self assertIdentifiers:@[kVibeMenuPlay, kVibeMenuSavePlaylist, kVibeMenuClose, kVibeMenuShowInFinder]
                   classify:VibeMenuValidationDomainFile];

    [self assertIdentifiers:@[kVibeMenuEditUndo, kVibeMenuEditRedo, kVibeMenuEditCopyFile,
                              kVibeMenuEditCopyName, kVibeMenuEditRemoveFromPlaylist]
                   classify:VibeMenuValidationDomainEdit];

    [self assertIdentifiers:@[kVibeMenuConvertToFLAC, kVibeMenuConvertDeleteOriginal]
                   classify:VibeMenuValidationDomainConvert];
}

// Both dynamic families are matched by prefix, so a preset or style added later
// is classified without touching the chain.
- (void)testTheWindowSizeFamilyIsMatchedByPrefix {
    [self assertIdentifiers:@[@"view_size_small", @"view_size_default", @"view_size_large",
                              @"view_size_enormous"]
                   classify:VibeMenuValidationDomainWindowSize];
}

- (void)testTheThemeFamilyIsMatchedByPrefix {
    // Built-ins and minted user-theme UUIDs alike.
    for (NSString *theme in @[@"vibe", @"industrial",
                              NSUUID.UUID.UUIDString]) {
        XCTAssertEqual(VibeMenuValidationDomainForIdentifier(VibeThemeMenuIdentifier(theme)),
                       VibeMenuValidationDomainTheme, @"%@", theme);
    }
}

// The whole point of the enum: an item nobody claimed is not silently enabled.
// The first five are owned elsewhere or carry no action — the two clicked-row
// commands are PlaylistController's, which validates them itself — and the rest
// are the shapes a typo and a missing identifier take.
- (void)testUnclaimedIdentifiersAreUnknownRatherThanEnabled {
    [self assertIdentifiers:@[@"show_clicked_track_in_finder", @"menu_settings", @"menu_convert",
                              @"remove_clicked_track_from_playlist",
                              @"menu_fx", @"menu_edit_select_all", @"menu_next_trak",
                              kVibeMenuThemeSubmenu, @"view_size", @"", @"menu_",
                              // The retired style family and the app-delegate-
                              // targeted Edit tail both deliberately classify
                              // as nobody's, as does the identifier a second
                              // Convert item would carry: Cancel Conversion is
                              // kVibeMenuConvertToFLAC re-aimed in validation.
                              @"waveform_style_detailed", kVibeMenuEditThemes,
                              @"menu_convert_cancel"]
                   classify:VibeMenuValidationDomainUnknown];
    XCTAssertEqual(VibeMenuValidationDomainForIdentifier(nil), VibeMenuValidationDomainUnknown);
}

// The identifier is derived from the preset in one place, so the builder, the
// checkmark and the width lookup cannot disagree about a spelling.
- (void)testEachSizePresetRoundTripsThroughItsIdentifier {
    for (NSNumber *boxed in @[@(VibeWindowSizePresetSmall), @(VibeWindowSizePresetDefault),
                              @(VibeWindowSizePresetLarge)]) {
        VibeWindowSizePreset preset = (VibeWindowSizePreset)boxed.integerValue;
        XCTAssertEqual(VibeWindowSizePresetForMenuIdentifier(VibeWindowSizeMenuIdentifier(preset)),
                       preset);
    }
    // A size identifier naming no preset sizes to the design width, which is
    // what the width lookup has always answered for one.
    XCTAssertEqual(VibeWindowSizePresetForMenuIdentifier(@"view_size_enormous"),
                   VibeWindowSizePresetDefault);
}


- (void)testSelectionCommandsRequireVisibleSelectionInTheKeyWindow {
    for (NSInteger key = 0; key < 2; key++) for (NSInteger shown = 0; shown < 2; shown++) {
        for (NSInteger row = -1; row < 2; row++) {
            BOOL visible = VibeMenuHasVisibleSelection(key, shown, row);
            XCTAssertEqual(visible, key && shown && row >= 0);
            XCTAssertEqual(VibeTransportMenuEnabled(kVibeMenuPlaySelected, YES, YES, visible, YES, NO), visible);
            XCTAssertEqual(VibeEditMenuEnabled(kVibeMenuEditRemoveFromPlaylist, NO, YES, YES, visible, YES, YES), visible);
        }
    }
}

- (void)testTransportBoundariesAndStoppedSkips {
    XCTAssertFalse(VibeTransportMenuEnabled(kVibeMenuNextTrack, NO, YES, YES, YES, NO));
    XCTAssertTrue(VibeTransportMenuEnabled(kVibeMenuPreviousTrack, NO, YES, NO, YES, YES));
    XCTAssertFalse(VibeTransportMenuEnabled(kVibeMenuPreviousTrack, YES, NO, YES, YES, NO));
    for (NSString *identifier in @[kVibeMenuSkipForward, kVibeMenuSkipForwardMore,
            kVibeMenuSkipForwardMost, kVibeMenuSkipBack, kVibeMenuSkipBackMore, kVibeMenuSkipBackMost]) {
        XCTAssertTrue(VibeTransportMenuEnabled(identifier, NO, NO, NO, YES, NO));
        XCTAssertFalse(VibeTransportMenuEnabled(identifier, YES, YES, YES, YES, YES));
        XCTAssertFalse(VibeTransportMenuEnabled(identifier, YES, YES, YES, NO, NO));
    }
    XCTAssertFalse(VibeTransportMenuEnabled(@"unknown", YES, YES, YES, YES, NO));
}

- (void)testFileMenuTitlesAndKeyWindowGate {
    XCTAssertEqualObjects(VibeFileMenuTitle(kVibeMenuPlay, 1, YES), STR_TRANSPORT_PAUSE);
    XCTAssertEqualObjects(VibeFileMenuTitle(kVibeMenuPlay, 1, NO), STR_TRANSPORT_PLAY);
    XCTAssertEqualObjects(VibeFileMenuTitle(kVibeMenuClose, 2, NO), STR_MENU_FILE_CLOSE_ALL);
    XCTAssertEqualObjects(VibeFileMenuTitle(kVibeMenuClose, 1, NO), STR_MENU_FILE_CLOSE);
    for (NSUInteger count = 0; count < 3; count++) {
        XCTAssertEqual(VibeFileMenuEnabled(kVibeMenuPlay, count, NO, NO), count > 0);
        XCTAssertEqual(VibeFileMenuEnabled(kVibeMenuClose, count, YES, YES), count > 0);
        XCTAssertFalse(VibeFileMenuEnabled(kVibeMenuSavePlaylist, count, NO, YES));
        XCTAssertEqual(VibeFileMenuEnabled(kVibeMenuSavePlaylist, count, YES, NO), count > 0);
    }
    XCTAssertFalse(VibeFileMenuEnabled(kVibeMenuShowInFinder, 1, YES, NO));
    XCTAssertTrue(VibeFileMenuEnabled(kVibeMenuShowInFinder, 1, NO, YES));
    XCTAssertFalse(VibeFileMenuEnabled(@"unknown", 1, YES, YES));
}

- (void)testUndoRedoAvailabilityAndCopyHaveIndependentInputs {
    for (NSInteger busy = 0; busy < 2; busy++) for (NSInteger undo = 0; undo < 2; undo++) {
        for (NSInteger redo = 0; redo < 2; redo++) {
            XCTAssertEqual(VibeEditMenuEnabled(kVibeMenuEditUndo, busy, undo, redo, NO, NO, NO), !busy && undo);
            XCTAssertEqual(VibeEditMenuEnabled(kVibeMenuEditRedo, busy, undo, redo, NO, NO, NO), !busy && redo);
        }
    }
    XCTAssertFalse(VibeEditMenuEnabled(kVibeMenuEditCopyFile, NO, YES, YES, YES, YES, NO));
    XCTAssertTrue(VibeEditMenuEnabled(kVibeMenuEditCopyName, YES, NO, NO, NO, YES, NO));
    XCTAssertFalse(VibeEditMenuEnabled(@"unknown", NO, YES, YES, YES, YES, YES));
}

- (void)testConvertCancelTitleAndActionReturnToIdleTogether {
    for (NSNumber *busy in @[@NO, @YES, @NO]) {
        XCTAssertEqualObjects(VibeConvertMenuTitle(busy.boolValue), busy.boolValue ? STR_MENU_CONVERT_CANCEL : STR_MENU_CONVERT_TO_FLAC);
        XCTAssertEqualObjects(NSStringFromSelector(VibeConvertMenuAction(busy.boolValue)),
                busy.boolValue ? @"cancelConversion:" : @"convertCurrentTrackToFLAC:");
    }
}

@end
