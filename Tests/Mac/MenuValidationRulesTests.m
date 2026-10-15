//
//  MenuValidationRulesTests.m
//  VibeTests
//

// Recognition is explicit: an identifier this controller does not own answers
// Unknown, and the validator disables it.

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
                              kVibeMenuAlwaysOnTop,
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
                              kVibeMenuEditCopyName, kVibeMenuEditRemoveFromPlaylist,
                              kVibeMenuEditMoveToTrash]
                   classify:VibeMenuValidationDomainEdit];

    [self assertIdentifiers:@[kVibeMenuConvertToFLAC]
                   classify:VibeMenuValidationDomainConvert];

    [self assertIdentifiers:@[kVibeMenuShuffle, kVibeMenuRepeat,
                              VibeRepeatMenuIdentifier(VibeRepeatModeOff),
                              VibeRepeatMenuIdentifier(VibeRepeatModeAll),
                              VibeRepeatMenuIdentifier(VibeRepeatModeOne)]
                   classify:VibeMenuValidationDomainPlayOrder];
}

- (void)testEachRepeatModeRoundTripsThroughItsIdentifier {
    for (NSNumber *boxed in @[@(VibeRepeatModeOff), @(VibeRepeatModeAll), @(VibeRepeatModeOne)]) {
        VibeRepeatMode mode = (VibeRepeatMode)boxed.integerValue;
        XCTAssertEqual(VibeRepeatModeForMenuIdentifier(VibeRepeatMenuIdentifier(mode)), mode);
    }
    // The submenu's own item and a stranger name no mode.
    XCTAssertEqual(VibeRepeatModeForMenuIdentifier(kVibeMenuRepeat), VibeRepeatModeOff);
    XCTAssertEqual(VibeRepeatModeForMenuIdentifier(nil), VibeRepeatModeOff);
}

// The View items read Show or Hide; the window-state toggles keep a checkmark
// and no title rule.
- (void)testViewPanelItemsRetitleShowAndHide {
    XCTAssertEqualObjects(VibeViewToggleTitle(kVibeMenuShowPlaylist, NO), STR_MENU_VIEW_PLAYLIST);
    XCTAssertEqualObjects(VibeViewToggleTitle(kVibeMenuShowPlaylist, YES), STR_MENU_VIEW_HIDE_PLAYLIST);
    XCTAssertEqualObjects(VibeViewToggleTitle(kVibeMenuShowPitch, NO), STR_MENU_VIEW_PITCH_CONTROL);
    XCTAssertEqualObjects(VibeViewToggleTitle(kVibeMenuShowPitch, YES), STR_MENU_VIEW_HIDE_PITCH_CONTROL);
    XCTAssertNil(VibeViewToggleTitle(kVibeMenuAlwaysOnTop, YES));
    XCTAssertNil(VibeViewToggleTitle(kVibeMenuLockWindowPosition, NO));
}

// A skip names its distance: the base bar count, twice and four times it
// with a tempo, else 10, 30 and 60 seconds. A base of 0 is unset and reads 8.
- (void)testSkipItemsNameTheirDistance {
    XCTAssertEqualObjects(VibeSkipMenuTitle(kVibeMenuSkipBack, 4, YES), @"Skip Back 4 Bars");
    XCTAssertEqualObjects(VibeSkipMenuTitle(kVibeMenuSkipBackMore, 4, YES), @"Skip Back 8 Bars");
    XCTAssertEqualObjects(VibeSkipMenuTitle(kVibeMenuSkipBackMost, 16, YES), @"Skip Back 64 Bars");
    XCTAssertEqualObjects(VibeSkipMenuTitle(kVibeMenuSkipForward, 0, YES), @"Skip Forward 8 Bars");
    XCTAssertEqualObjects(VibeSkipMenuTitle(kVibeMenuSkipForwardMore, 8, YES), @"Skip Forward 16 Bars");
    XCTAssertEqualObjects(VibeSkipMenuTitle(kVibeMenuSkipForwardMost, 8, YES), @"Skip Forward 32 Bars");
    XCTAssertEqualObjects(VibeSkipMenuTitle(kVibeMenuSkipBack, 8, NO), @"Skip Back 10 Seconds");
    XCTAssertEqualObjects(VibeSkipMenuTitle(kVibeMenuSkipForwardMore, 8, NO), @"Skip Forward 30 Seconds");
    XCTAssertEqualObjects(VibeSkipMenuTitle(kVibeMenuSkipForwardMost, 8, NO), @"Skip Forward 60 Seconds");
    XCTAssertNil(VibeSkipMenuTitle(kVibeMenuNextTrack, 8, YES));
    XCTAssertNil(VibeSkipMenuTitle(nil, 8, NO));
}

// Matched by prefix, so a preset or theme added later is classified without
// touching the chain.
- (void)testTheWindowSizeFamilyIsMatchedByPrefix {
    [self assertIdentifiers:@[@"view_size_small", @"view_size_default", @"view_size_large",
                              @"view_size_enormous"]
                   classify:VibeMenuValidationDomainWindowSize];
}

- (void)testTheThemeFamilyIsMatchedByPrefix {
    for (NSString *theme in @[@"vibe", @"industrial",
                              NSUUID.UUID.UUIDString]) {
        XCTAssertEqual(VibeMenuValidationDomainForIdentifier(VibeThemeMenuIdentifier(theme)),
                       VibeMenuValidationDomainTheme, @"%@", theme);
    }
}

// The first five are owned elsewhere or carry no action (the clicked-row
// commands are PlaylistController's); the rest are a typo's and a missing
// identifier's shapes.
- (void)testUnclaimedIdentifiersAreUnknownRatherThanEnabled {
    [self assertIdentifiers:@[@"show_clicked_track_in_finder", @"menu_settings", @"menu_convert",
                              @"remove_clicked_track_from_playlist", @"move_clicked_track_to_trash",
                              @"menu_fx", @"menu_edit_select_all", @"menu_next_trak",
                              kVibeMenuThemeSubmenu, @"view_size", @"", @"menu_",
                              // Nobody's: a waveform-style identifier, the app
                              // delegate's Edit tail, a second Convert item
                              // (Cancel Conversion is kVibeMenuConvertToFLAC
                              // re-aimed in validation), the preference that
                              // left the menu bar for Settings > Files, and
                              // the row menu's Play.
                              @"waveform_style_detailed", kVibeMenuEditThemes,
                              @"menu_convert_cancel", @"menu_convert_delete_original",
                              @"play_clicked_track"]
                   classify:VibeMenuValidationDomainUnknown];
    XCTAssertEqual(VibeMenuValidationDomainForIdentifier(nil), VibeMenuValidationDomainUnknown);
}

- (void)testEachSizePresetRoundTripsThroughItsIdentifier {
    for (NSNumber *boxed in @[@(VibeWindowSizePresetSmall), @(VibeWindowSizePresetDefault),
                              @(VibeWindowSizePresetLarge)]) {
        VibeWindowSizePreset preset = (VibeWindowSizePreset)boxed.integerValue;
        XCTAssertEqual(VibeWindowSizePresetForMenuIdentifier(VibeWindowSizeMenuIdentifier(preset)),
                       preset);
    }
    // A size identifier naming no preset sizes to the design width.
    XCTAssertEqual(VibeWindowSizePresetForMenuIdentifier(@"view_size_enormous"),
                   VibeWindowSizePresetDefault);
}

- (void)testSelectionCommandsRequireVisibleSelectionInTheKeyWindow {
    for (NSInteger key = 0; key < 2; key++) for (NSInteger shown = 0; shown < 2; shown++) {
        for (NSInteger row = -1; row < 2; row++) {
            BOOL visible = VibeMenuHasVisibleSelection(key, shown, row);
            XCTAssertEqual(visible, key && shown && row >= 0);
            XCTAssertEqual(VibeTransportMenuEnabled(kVibeMenuPlaySelected, YES, YES, visible, YES, NO), visible);
            XCTAssertEqual(VibeEditMenuEnabled(kVibeMenuEditRemoveFromPlaylist, NO, YES, YES, visible, YES, YES, NO), visible);
            XCTAssertEqual(VibeEditMenuEnabled(kVibeMenuEditMoveToTrash, NO, YES, YES, visible, YES, YES, NO), visible);
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
    XCTAssertEqualObjects(VibeFileMenuTitle(kVibeMenuClose, 2, NO), STR_MENU_PLAYLIST_CLEAR);
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
            XCTAssertEqual(VibeEditMenuEnabled(kVibeMenuEditUndo, busy, undo, redo, NO, NO, NO, NO), !busy && undo);
            XCTAssertEqual(VibeEditMenuEnabled(kVibeMenuEditRedo, busy, undo, redo, NO, NO, NO, NO), !busy && redo);
        }
    }
    XCTAssertFalse(VibeEditMenuEnabled(kVibeMenuEditCopyFile, NO, YES, YES, YES, YES, NO, NO));
    XCTAssertTrue(VibeEditMenuEnabled(kVibeMenuEditCopyName, YES, NO, NO, NO, YES, NO, NO));
    XCTAssertFalse(VibeEditMenuEnabled(@"unknown", NO, YES, YES, YES, YES, YES, YES));
}

// ⌘C is Copy File's. With a text field focused it copies the text, so it is
// enabled with no track; nothing else in Edit follows the focus.
- (void)testCopyFileIsEnabledForAFocusedTextFieldWithoutATrack {
    for (NSInteger url = 0; url < 2; url++) for (NSInteger text = 0; text < 2; text++) {
        XCTAssertEqual(VibeEditMenuEnabled(kVibeMenuEditCopyFile, NO, NO, NO, NO, url, url, text), url || text);
    }
    XCTAssertFalse(VibeEditMenuEnabled(kVibeMenuEditCopyName, NO, NO, NO, NO, NO, NO, YES));
    XCTAssertFalse(VibeEditMenuEnabled(kVibeMenuEditRemoveFromPlaylist, NO, NO, NO, NO, YES, YES, YES));
    XCTAssertFalse(VibeEditMenuEnabled(kVibeMenuEditMoveToTrash, NO, NO, NO, NO, YES, YES, YES));
    for (NSString *identifier in @[kVibeMenuEditRemoveFromPlaylist, kVibeMenuEditMoveToTrash]) {
        XCTAssertFalse(VibeEditMenuEnabled(identifier, YES, YES, YES, YES, YES, YES, NO),
                       @"%@ while a trash still moves its files", identifier);
    }
    XCTAssertFalse(VibeEditMenuEnabled(kVibeMenuEditUndo, NO, NO, NO, NO, YES, YES, YES));
}

// Cut and Paste are nil-targeted, so the player never validates them. They
// must survive the Edit menu's cleaner, which drops what macOS appends.
- (void)testCutAndPasteSurviveTheEditMenuCleanerAndAreNotThePlayers {
    for (NSString *identifier in @[kVibeMenuEditCut, kVibeMenuEditPaste, kVibeMenuEditCopyFile,
                                   @"menu_edit_select_all", @"menu_edit_separator"]) {
        XCTAssertTrue(VibeEditMenuKeepsItem(identifier), @"%@", identifier);
    }
    [self assertIdentifiers:@[kVibeMenuEditCut, kVibeMenuEditPaste] classify:VibeMenuValidationDomainUnknown];
    XCTAssertFalse(VibeEditMenuKeepsItem(nil), @"AutoFill and Dictation carry no identifier");
    XCTAssertFalse(VibeEditMenuKeepsItem(@"NSMenuItemAutoFill"));
    XCTAssertFalse(VibeEditMenuKeepsItem(@"menu_cut"));
}

- (void)testOpenAddToPlaylistAndOpenURLAreTheAppDelegatesNotThePlayers {
    [self assertIdentifiers:@[kVibeMenuOpen, kVibeMenuAddToPlaylist, kVibeMenuOpenLink]
                   classify:VibeMenuValidationDomainUnknown];
    XCTAssertEqualObjects(kVibeMenuOpenLink, @"menu_open_link");
    XCTAssertFalse([kVibeMenuOpenLink isEqualToString:kVibeMenuOpen]);
}

- (void)testConvertHidesWhenOffOrForAFileUnderARemoteRoot {
    XCTAssertFalse(VibeConvertMenuItemHidden(YES, NO));
    XCTAssertTrue(VibeConvertMenuItemHidden(NO, NO));
    XCTAssertTrue(VibeConvertMenuItemHidden(YES, YES));
    XCTAssertTrue(VibeConvertMenuItemHidden(NO, YES));
}

- (void)testConvertCancelTitleAndActionReturnToIdleTogether {
    for (NSNumber *busy in @[@NO, @YES, @NO]) {
        XCTAssertEqualObjects(VibeConvertMenuTitle(busy.boolValue), busy.boolValue ? STR_MENU_CONVERT_CANCEL : STR_MENU_CONVERT_TO_FLAC);
        XCTAssertEqualObjects(NSStringFromSelector(VibeConvertMenuAction(busy.boolValue)),
                busy.boolValue ? @"cancelConversion:" : @"convertCurrentTrackToFLAC:");
    }
}

@end
