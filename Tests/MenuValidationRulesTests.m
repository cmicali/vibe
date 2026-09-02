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
    [self assertIdentifiers:@[@"menu_show_playlist", @"menu_show_pitch",
                              @"menu_show_file_info", @"menu_always_on_top"]
                   classify:VibeMenuValidationDomainViewToggle];

    [self assertIdentifiers:@[@"view_appearance_system_default", @"view_appearance_light",
                              @"view_appearance_dark"]
                   classify:VibeMenuValidationDomainAppearance];

    [self assertIdentifiers:@[@"menu_next_track", @"menu_previous_track", @"menu_play_selected",
                              @"menu_skip_forward", @"menu_skip_forward_more",
                              @"menu_skip_forward_most", @"menu_skip_back",
                              @"menu_skip_back_more", @"menu_skip_back_most"]
                   classify:VibeMenuValidationDomainTransport];

    [self assertIdentifiers:@[@"menu_fx_low_kill", @"menu_fx_low_kill_boost", @"menu_fx_reverb",
                              @"menu_fx_delay", @"menu_fx_short_delay"]
                   classify:VibeMenuValidationDomainFX];

    [self assertIdentifiers:@[@"pitch_range_8", @"pitch_range_16"]
                   classify:VibeMenuValidationDomainPitchRange];

    [self assertIdentifiers:@[@"menu_play", @"menu_close", @"show_in_finder"]
                   classify:VibeMenuValidationDomainFile];

    [self assertIdentifiers:@[@"menu_edit_undo", @"menu_edit_redo", @"menu_edit_copy_file",
                              @"menu_edit_copy_name", @"menu_edit_remove_from_playlist"]
                   classify:VibeMenuValidationDomainEdit];

    [self assertIdentifiers:@[@"menu_convert_to_flac", @"menu_convert_delete_original"]
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
                              @"view_appearance", @"view_theme", @"view_size", @"", @"menu_",
                              // The retired style family and the app-delegate-
                              // targeted Edit tail both deliberately classify
                              // as nobody's.
                              @"waveform_style_detailed", @"menu_edit_themes"]
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
