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
                              kVibeMenuShowFileInfo, kVibeMenuAlwaysOnTop]
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

    [self assertIdentifiers:@[kVibeMenuPlay, kVibeMenuClose, kVibeMenuShowInFinder]
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

@end
