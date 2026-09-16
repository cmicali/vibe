//
//  MenuValidationRulesTests.m
//  VibeTests
//

// The identifier-to-domain classification behind MainPlayerController's
// validateMenuItem:. The policy under test is that recognition is explicit:
// an identifier this controller does not own answers Unknown, and the
// validator disables it rather than letting it through.
// The bare-key monitor is the menu equivalents' other route into the player;
// its real event handler runs here with no native event dispatch.

#import <XCTest/XCTest.h>

#import "MenuValidationRules.h"
#import "TransportKeyMonitor.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"

@interface MenuValidationRulesTests : XCTestCase
// Duck collaborators for the real key monitor: no NSWindow or audio engine.
@property (nonatomic, getter=isPlaylistShown) BOOL playlistShown;
@property (nonatomic) BOOL hasFXGraph;
@property (nonatomic) BOOL lowKillActive;
@property (nonatomic) BOOL lowKillBoostActive;
@property (nonatomic) BOOL reverbSendActive;
@property (nonatomic) BOOL delaySendActive;
@property (nonatomic) BOOL shortDelaySendActive;
@property (nonatomic) NSUInteger removals;
@property (nonatomic) NSUInteger plays;
@end

@implementation MenuValidationRulesTests

- (NSWindow *)window { return (id)self; }
- (NSResponder *)firstResponder { return nil; }
- (id)audioPlayer { return self; }
- (id)fx { return self.hasFXGraph ? self : nil; }
- (void)removeSelectedPlaylistTracks:(id)sender { self.removals++; }
- (void)playPause:(id)sender { self.plays++; }

- (NSEvent *)key:(NSString *)characters type:(NSEventType)type time:(NSTimeInterval)time
         repeat:(BOOL)repeat modifiers:(NSEventModifierFlags)modifiers {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:modifiers
                          timestamp:time windowNumber:0 context:nil characters:characters
        charactersIgnoringModifiers:characters isARepeat:repeat keyCode:0];
}

- (void)testEffectKeysTapLatchAndHeldRepeatRestoresTheOriginalState {
    BOOL enabled = AppSettings.sharedInstance.audioFXEnabled;
    AppSettings.sharedInstance.audioFXEnabled = YES;
    self.hasFXGraph = YES;
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    NSDictionary *keys = @{@"q": @"lowKillActive", @"w": @"lowKillBoostActive",
                           @"e": @"reverbSendActive", @"r": @"delaySendActive",
                           @"t": @"shortDelaySendActive"};
    @try {
        for (NSString *key in keys) for (NSNumber *initial in @[@NO, @YES]) {
            for (NSNumber *duration in @[@0.1, @0.5]) {
                [self setValue:initial forKey:keys[key]];
                XCTAssertNil([monitor handleKeyEvent:[self key:key type:NSEventTypeKeyDown
                        time:10 repeat:NO modifiers:0] inWindow:self.window]);
                XCTAssertEqual([[self valueForKey:keys[key]] boolValue], !initial.boolValue);
                XCTAssertNil([monitor handleKeyEvent:[self key:key type:NSEventTypeKeyDown
                        time:10.05 repeat:YES modifiers:0] inWindow:self.window]);
                // A modifier pressed during the hold must not hide its release.
                XCTAssertNil([monitor handleKeyEvent:[self key:key type:NSEventTypeKeyUp
                        time:10 + duration.doubleValue repeat:NO modifiers:NSEventModifierFlagCommand]
                        inWindow:self.window]);
                XCTAssertEqual([[self valueForKey:keys[key]] boolValue],
                               duration.doubleValue < 0.35 ? !initial.boolValue : initial.boolValue);
            }
        }
    } @finally {
        AppSettings.sharedInstance.audioFXEnabled = enabled;
    }
}

- (void)testLostEffectReleaseRevertsHeldKeysButPreservesTaps {
    BOOL enabled = AppSettings.sharedInstance.audioFXEnabled;
    AppSettings.sharedInstance.audioFXEnabled = YES;
    self.hasFXGraph = YES;
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    @try {
        for (NSString *notification in @[NSWindowDidResignKeyNotification,
                                        NSMenuDidBeginTrackingNotification, NSWindowWillMoveNotification]) {
            self.lowKillActive = NO;
            self.reverbSendActive = YES;
            self.delaySendActive = NO;
            for (NSString *key in @[@"q", @"e", @"r"]) {
                [monitor handleKeyEvent:[self key:key type:NSEventTypeKeyDown time:10 repeat:NO modifiers:0]
                               inWindow:self.window];
            }
            [monitor handleKeyEvent:[self key:@"r" type:NSEventTypeKeyUp time:10.1 repeat:NO modifiers:0]
                           inWindow:self.window]; // deliberately latched
            [[NSNotificationCenter defaultCenter] postNotificationName:notification object:self.window];
            XCTAssertFalse(self.lowKillActive);
            XCTAssertTrue(self.reverbSendActive);
            XCTAssertTrue(self.delaySendActive);
            NSEvent *late = [self key:@"q" type:NSEventTypeKeyUp time:11 repeat:NO modifiers:0];
            XCTAssertEqual([monitor handleKeyEvent:late inWindow:self.window], late);
        }
    } @finally {
        AppSettings.sharedInstance.audioFXEnabled = enabled;
    }
}

- (void)testDisabledEffectKeysPassThroughWithoutLatching {
    BOOL enabled = AppSettings.sharedInstance.audioFXEnabled;
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    @try {
        for (NSNumber *graph in @[@NO, @YES]) {
            self.hasFXGraph = graph.boolValue;
            AppSettings.sharedInstance.audioFXEnabled = !graph.boolValue;
            NSEvent *down = [self key:@"w" type:NSEventTypeKeyDown time:10 repeat:NO modifiers:0];
            NSEvent *up = [self key:@"w" type:NSEventTypeKeyUp time:11 repeat:NO modifiers:0];
            XCTAssertEqual([monitor handleKeyEvent:down inWindow:self.window], down);
            XCTAssertEqual([monitor handleKeyEvent:up inWindow:self.window], up);
            XCTAssertFalse(self.lowKillBoostActive);
        }
    } @finally {
        AppSettings.sharedInstance.audioFXEnabled = enabled;
    }
}

- (void)testDeleteRepeatIsSwallowedAndHiddenOrModifiedDeletesDoNotRemove {
    TransportKeyMonitor *monitor = [[TransportKeyMonitor alloc] initWithController:(id)self];
    for (NSNumber *character in @[@(NSDeleteCharacter), @(NSDeleteFunctionKey)]) {
        NSString *key = [NSString stringWithFormat:@"%C", character.unsignedShortValue];
        self.playlistShown = YES;
        self.removals = 0;
        NSEvent *down = [self key:key type:NSEventTypeKeyDown time:10 repeat:NO modifiers:0];
        XCTAssertEqual([monitor handleKeyEvent:down inWindow:nil], down);
        XCTAssertEqual(self.removals, 0u);
        XCTAssertNil([monitor handleKeyEvent:down inWindow:self.window]);
        XCTAssertNil([monitor handleKeyEvent:[self key:key type:NSEventTypeKeyDown time:11
                repeat:YES modifiers:0] inWindow:self.window]);
        self.playlistShown = NO;
        XCTAssertNil([monitor handleKeyEvent:down inWindow:self.window]);
        self.playlistShown = YES;
        NSEvent *modified = [self key:key type:NSEventTypeKeyDown time:12 repeat:NO
                                  modifiers:NSEventModifierFlagCommand];
        XCTAssertEqual([monitor handleKeyEvent:modified inWindow:self.window], modified);
        XCTAssertEqual(self.removals, 1u);
    }
    for (NSNumber *repeat in @[@NO, @YES]) {
        XCTAssertNil([monitor handleKeyEvent:[self key:@" " type:NSEventTypeKeyDown time:13
                repeat:repeat.boolValue modifiers:0] inWindow:self.window]);
    }
    XCTAssertEqual(self.plays, 2u, @"transport still honors repeat");
}

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
