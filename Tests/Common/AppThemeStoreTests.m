//
// The theme store in AppSettings: user theme edits, undo and redo,
// duplicate, rename and removal, the images a theme's history keeps, and
// the stored themes' migration.
//

#import "AppThemeTestCase.h"

@interface AppThemeStoreTests : AppThemeTestCase
@end

@implementation AppThemeStoreTests

- (AppSettings *)editingSettings {
    _editingSettings = AppSettings.sharedInstance;
    [_editingSettings factoryReset];
    NSString *identifier = [_editingSettings addUserThemeWithRecord:@{} name:@"Editing"];
    [_editingSettings applyThemeWithIdentifier:identifier];
    return _editingSettings;
}

- (void)testUserThemeEditsPersistAndUndoRestoresTheSameWorkingObject {
    AppSettings *settings = self.editingSettings;
    AppTheme *working = settings.currentTheme;
    working.showTransportButtons = NO;
    [settings currentThemeDidChange];
    XCTAssertTrue(settings.canUndoThemeEdit);
    AppSettings *reloaded = [AppSettings new];
    XCTAssertEqualObjects(reloaded.activeThemeIdentifier, settings.activeThemeIdentifier);
    XCTAssertFalse(reloaded.currentTheme.showTransportButtons);
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme, working);
    XCTAssertTrue(working.showTransportButtons);
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:settings.activeThemeIdentifier], @{});
    XCTAssertTrue([AppSettings new].currentTheme.showTransportButtons);
}

- (void)testRedoRestoresEditsAndRenamesInOrder {
    AppSettings *settings = self.editingSettings;
    NSString *identifier = settings.activeThemeIdentifier;
    AppTheme *working = settings.currentTheme;
    working.showTransportButtons = NO;
    [settings currentThemeDidChange];
    [settings renameUserThemeWithIdentifier:identifier toName:@"Renamed"];
    [settings undoThemeEdit];
    [settings undoThemeEdit];
    XCTAssertTrue(settings.canRedoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertEqual(settings.currentTheme, working);
    XCTAssertFalse(working.showTransportButtons);
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], @"Editing");
    [settings redoThemeEdit];
    XCTAssertEqualObjects([[AppSettings new] displayNameForThemeIdentifier:identifier], @"Renamed");
    XCTAssertFalse(settings.canRedoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], @"Renamed");
}

- (void)testAddingOrDuplicatingThemesDiscardsHistoryWithoutChangingCurrentTheme {
    for (NSNumber *duplicate in @[@NO, @YES]) {
        AppSettings *settings = self.editingSettings;
        [settings applyThemeWithIdentifier:@"vibe"];
        AppTheme *working = settings.currentTheme;
        working.showTransportButtons = NO;
        [settings currentThemeDidChange];
        working.appIconShape = NO;
        [settings currentThemeDidChange];
        [settings undoThemeEdit];
        XCTAssertTrue(settings.canUndoThemeEdit);
        XCTAssertTrue(settings.canRedoThemeEdit);
        NSDictionary *record = working.dictionaryRepresentation;
        NSString *added = duplicate.boolValue
                ? [settings duplicateThemeWithIdentifier:@"vibe"]
                : [settings addUserThemeWithRecord:record name:@"Imported"];
        NSArray *order = settings.orderedThemeIdentifiers;
        XCTAssertFalse(settings.canUndoThemeEdit);
        XCTAssertFalse(settings.canRedoThemeEdit);
        [settings undoThemeEdit];
        [settings redoThemeEdit];
        XCTAssertEqualObjects(settings.orderedThemeIdentifiers, order);
        XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
        XCTAssertEqual(settings.currentTheme, working);
        XCTAssertEqualObjects(working.dictionaryRepresentation, record);
        XCTAssertTrue(settings.currentThemeIsModified);
        XCTAssertEqualObjects([[AppSettings new] recordForThemeIdentifier:added], record);
    }
}

- (void)testThemeDragCoalescesFromTheFirstEditAndExtendsItsQuietPeriod {
    AppSettings *settings = self.editingSettings;
    for (NSUInteger i = 0; i < 4; i++) {
        settings.currentTheme.windowCornerRadius = 20 + i;
        [settings currentThemeDidChangeContinuous:YES atTime:100 + i * 1.5];
    }
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, kVibeThemeCornerRadiusDefault);
    XCTAssertFalse(settings.canUndoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 23);
    XCTAssertFalse(settings.canRedoThemeEdit);
}

- (void)testThemeDragAtTwoSecondsStartsAnotherUndoEntry {
    AppSettings *settings = self.editingSettings;
    settings.currentTheme.windowCornerRadius = 20;
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    settings.currentTheme.windowCornerRadius = 24;
    [settings currentThemeDidChangeContinuous:YES atTime:102];
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 20);
    XCTAssertTrue(settings.canUndoThemeEdit);
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, kVibeThemeCornerRadiusDefault);
    XCTAssertFalse(settings.canUndoThemeEdit);
}

- (void)testDifferentThemeFieldsNeverCoalesce {
    AppSettings *settings = self.editingSettings;
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    settings.currentTheme.waveformGradient = NO;
    [settings currentThemeDidChangeContinuous:YES atTime:100.1];
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.waveformGradient);
    XCTAssertFalse(settings.currentTheme.showTransportButtons);
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.showTransportButtons);
    XCTAssertFalse(settings.canUndoThemeEdit);
}

- (void)testUnchangedThemeWriteDoesNotCreateOrExtendAnUndoEntry {
    AppSettings *settings = self.editingSettings;
    [settings currentThemeDidChangeContinuous:YES atTime:99];
    XCTAssertFalse(settings.canUndoThemeEdit);
    settings.currentTheme.windowCornerRadius = 20;
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    [settings currentThemeDidChangeContinuous:YES atTime:101.9];
    settings.currentTheme.windowCornerRadius = 24;
    [settings currentThemeDidChangeContinuous:YES atTime:102];
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 20);
    XCTAssertTrue(settings.canUndoThemeEdit);
}

- (void)testEditingAfterUndoStartsFreshHistory {
    AppSettings *settings = self.editingSettings;
    settings.currentTheme.windowCornerRadius = 20;
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    settings.currentTheme.windowCornerRadius = 24;
    [settings currentThemeDidChangeContinuous:YES atTime:103];
    [settings undoThemeEdit];
    settings.currentTheme.windowCornerRadius = 28;
    [settings currentThemeDidChangeContinuous:YES atTime:103.1];
    XCTAssertFalse(settings.canRedoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 28);
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 20);
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, kVibeThemeCornerRadiusDefault);
    XCTAssertFalse(settings.canUndoThemeEdit);
}

- (void)testThemeHistoryKeepsOnlyFiftyEdits {
    AppSettings *settings = self.editingSettings;
    for (NSUInteger i = 0; i < 55; i++) {
        settings.currentTheme.showTransportButtons = !settings.currentTheme.showTransportButtons;
        [settings currentThemeDidChangeContinuous:YES atTime:100 + i * 3];
    }
    for (NSUInteger i = 0; i < 50; i++) {
        XCTAssertTrue(settings.canUndoThemeEdit);
        [settings undoThemeEdit];
    }
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertFalse(settings.currentTheme.showTransportButtons); // five edits remain
    [settings undoThemeEdit];
    XCTAssertFalse(settings.currentTheme.showTransportButtons);
    for (NSUInteger i = 0; i < 50; i++) {
        XCTAssertTrue(settings.canRedoThemeEdit);
        [settings redoThemeEdit];
    }
    XCTAssertFalse(settings.canRedoThemeEdit);
}

- (void)testApplyingAnotherThemeClearsUndoWithoutChangingTheOldRecord {
    AppSettings *settings = self.editingSettings;
    NSString *edited = settings.activeThemeIdentifier;
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChange];
    [settings applyThemeWithIdentifier:@"vibe"];
    XCTAssertFalse(settings.canUndoThemeEdit);
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.showTransportButtons);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:edited][@"showTransportButtons"], @NO);
}

- (void)testBuiltInDivergencePersistsAndUndoKeepsTheBuiltInPristine {
    AppSettings *settings = self.editingSettings;
    [settings applyThemeWithIdentifier:@"vibe"];
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChange];
    XCTAssertTrue(settings.canUndoThemeEdit);
    XCTAssertTrue(settings.currentThemeIsModified);
    XCTAssertFalse([AppSettings new].currentTheme.showTransportButtons);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:@"vibe"], @{});
    [settings undoThemeEdit];
    XCTAssertFalse(settings.currentThemeIsModified);
    XCTAssertTrue([AppSettings new].currentTheme.showTransportButtons);
    XCTAssertFalse(settings.canUndoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertTrue(settings.currentThemeIsModified);
    XCTAssertFalse([AppSettings new].currentTheme.showTransportButtons);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:@"vibe"], @{});
}

- (void)testDuplicateAndRenamePreserveRecordsAndDeduplicateNames {
    AppSettings *settings = self.editingSettings;
    NSString *original = settings.activeThemeIdentifier;
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChange];
    NSString *duplicate = [settings duplicateThemeWithIdentifier:original];
    XCTAssertNotEqualObjects(duplicate, original);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:duplicate],
                          [settings recordForThemeIdentifier:original]);
    XCTAssertNotEqualObjects([settings displayNameForThemeIdentifier:duplicate], @"Editing");
    [settings renameUserThemeWithIdentifier:duplicate toName:@"  Renamed  "];
    XCTAssertEqualObjects([[AppSettings new] displayNameForThemeIdentifier:duplicate], @"Renamed");
    [settings renameUserThemeWithIdentifier:duplicate toName:@"Editing"];
    XCTAssertNotEqualObjects([settings displayNameForThemeIdentifier:duplicate], @"Editing");
    XCTAssertEqualObjects(settings.activeThemeIdentifier, original);
    XCTAssertNil([settings duplicateThemeWithIdentifier:@"missing"]);
}

- (void)testBuiltInsRefuseRenameAndRemovalButCanBeDuplicated {
    AppSettings *settings = self.editingSettings;
    NSString *name = [settings displayNameForThemeIdentifier:@"vibe"];
    [settings renameUserThemeWithIdentifier:@"vibe" toName:@"Changed"];
    [settings removeUserThemeWithIdentifier:@"vibe" fallingBackTo:nil];
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:@"vibe"], name);
    XCTAssertTrue([settings.orderedThemeIdentifiers containsObject:@"vibe"]);
    NSString *duplicate = [settings duplicateThemeWithIdentifier:@"vibe"];
    XCTAssertNotNil(duplicate);
    XCTAssertFalse([AppTheme isBuiltInIdentifier:duplicate]);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:duplicate], @{});
}

- (void)testDuplicatingTheActiveBuiltInPreservesItsWorkingAppearance {
    AppSettings *settings = self.editingSettings;
    [settings applyThemeWithIdentifier:@"vibe"];
    settings.currentTheme.waveformStyle = @"detailed";
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChange];
    NSDictionary *workingRecord = settings.currentTheme.dictionaryRepresentation;

    NSString *duplicate = [settings duplicateThemeWithIdentifier:@"vibe"];
    XCTAssertNotNil(duplicate);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:duplicate], workingRecord);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:@"vibe"], @{});
    XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
    XCTAssertTrue(settings.currentThemeIsModified);

    [settings applyThemeWithIdentifier:duplicate];
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, workingRecord);
    XCTAssertEqualObjects([AppSettings new].currentTheme.dictionaryRepresentation, workingRecord);
    XCTAssertFalse(settings.currentThemeIsModified);
}

- (void)testRemovingAnActiveThemeUsesOnlyASurvivingFallback {
    AppSettings *settings = self.editingSettings;
    NSString *first = settings.activeThemeIdentifier;
    NSString *second = [settings addUserThemeWithRecord:@{@"showTransportButtons": @NO} name:@"Second"];
    [settings removeUserThemeWithIdentifier:first fallingBackTo:second];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, second);
    XCTAssertFalse(settings.currentTheme.showTransportButtons);
    [settings removeUserThemeWithIdentifier:second fallingBackTo:second];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
    XCTAssertTrue(settings.currentTheme.showTransportButtons);
}

- (NSString *)installEditingImageInSettings:(AppSettings *)settings {
    NSString *reference = [AppTheme storeCustomImageData:VibeSquarePNG(64) error:NULL];
    XCTAssertNotNil(reference);
    [settings.currentTheme setImageReference:reference forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    [settings applyThemeWithIdentifier:settings.activeThemeIdentifier]; // begin with clean history
    return [_artDir stringByAppendingPathComponent:[reference substringFromIndex:7]];
}

- (void)testInactiveRenameDiscardsHistoryButUnchangedNameKeepsIt {
    AppSettings *settings = self.editingSettings;
    NSString *other = [settings addUserThemeWithRecord:@{} name:@"Other"];
    NSString *active = settings.activeThemeIdentifier;
    NSString *path = [self installEditingImageInSettings:settings];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    NSDictionary *working = settings.currentTheme.dictionaryRepresentation;
    [settings renameUserThemeWithIdentifier:other toName:@"Other"];
    XCTAssertTrue(settings.canUndoThemeEdit);
    XCTAssertTrue(settings.canRedoThemeEdit);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings renameUserThemeWithIdentifier:other toName:@"Renamed"];
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertFalse(settings.canRedoThemeEdit);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    [settings redoThemeEdit];
    XCTAssertEqualObjects([[AppSettings new] displayNameForThemeIdentifier:other], @"Renamed");
    XCTAssertEqualObjects(settings.activeThemeIdentifier, active);
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, working);
}

- (void)testAddingThemeSweepsDiscardedHistoryAfterRetainingImportedImages {
    AppSettings *settings = self.editingSettings;
    NSString *oldPath = [self installEditingImageInSettings:settings];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:oldPath]);
    NSString *imported = [AppTheme storeCustomImageData:VibeSquarePNG(128) error:NULL];
    XCTAssertNotNil(imported);
    NSString *importedPath = [_artDir stringByAppendingPathComponent:[imported substringFromIndex:7]];
    XCTAssertNotEqualObjects(oldPath, importedPath);
    NSString *added = [settings addUserThemeWithRecord:@{@"defaultArtworkDark": imported} name:@"Imported"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:oldPath]);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:importedPath]);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:added][@"defaultArtworkDark"], imported);
}

- (void)testRemovalUndoRestoresIdentityOrderImagesAndEarlierEdits {
    AppSettings *settings = self.editingSettings;
    NSString *first = settings.activeThemeIdentifier;
    NSString *path = [self installEditingImageInSettings:settings];
    NSString *second = [settings addUserThemeWithRecord:@{} name:@"Second"];
    NSArray *order = settings.orderedThemeIdentifiers;
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChange];
    [settings removeUserThemeWithIdentifier:first fallingBackTo:second];
    XCTAssertTrue(settings.themeUndoRemovesTheme);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings removeUserThemeWithIdentifier:second fallingBackTo:nil];
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, second);
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.orderedThemeIdentifiers, order);
    XCTAssertEqualObjects(settings.activeThemeIdentifier, first);
    XCTAssertFalse(settings.currentTheme.showTransportButtons);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.showTransportButtons);
    XCTAssertFalse(settings.canUndoThemeEdit);
    [settings removeUserThemeWithIdentifier:first fallingBackTo:nil];
    [settings applyThemeWithIdentifier:@"vibe"];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
}

- (void)testRemovalUndoRestoresInactiveThemeWithoutLosingBuiltInDivergence {
    AppSettings *settings = self.editingSettings;
    NSString *removed = settings.activeThemeIdentifier;
    [settings applyThemeWithIdentifier:@"vibe"];
    settings.currentTheme.appIconShape = NO;
    [settings currentThemeDidChange];
    [settings removeUserThemeWithIdentifier:removed fallingBackTo:nil];
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
    XCTAssertFalse(settings.currentTheme.appIconShape);
    XCTAssertTrue(settings.currentThemeIsModified);
    XCTAssertTrue([settings.orderedThemeIdentifiers containsObject:removed]);
    [settings redoThemeEdit];
    XCTAssertFalse([settings.orderedThemeIdentifiers containsObject:removed]);
    XCTAssertFalse(settings.currentTheme.appIconShape);
    [settings undoThemeEdit];
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.appIconShape);
}

- (void)testRemovalRedoKeepsFallbackOrderImagesAndPreviousEdits {
    AppSettings *settings = self.editingSettings;
    NSString *removed = settings.activeThemeIdentifier;
    NSString *path = [self installEditingImageInSettings:settings];
    NSString *fallback = [settings addUserThemeWithRecord:@{@"showTransportButtons": @NO} name:@"Fallback"];
    NSArray *order = settings.orderedThemeIdentifiers;
    settings.currentTheme.appIconShape = NO;
    [settings currentThemeDidChange];
    [settings removeUserThemeWithIdentifier:removed fallingBackTo:fallback];
    [settings undoThemeEdit];
    XCTAssertTrue(settings.themeRedoRemovesTheme);
    [settings undoThemeEdit];
    XCTAssertFalse(settings.themeRedoRemovesTheme);
    [settings redoThemeEdit];
    [settings redoThemeEdit];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, fallback);
    XCTAssertFalse(settings.currentTheme.showTransportButtons);
    XCTAssertFalse([settings.orderedThemeIdentifiers containsObject:removed]);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.orderedThemeIdentifiers, order);
    XCTAssertEqualObjects(settings.activeThemeIdentifier, removed);
    XCTAssertFalse(settings.currentTheme.appIconShape);
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    XCTAssertFalse(settings.canRedoThemeEdit);
}

- (void)testRedoRetainsAddedImagesUntilHistoryBranchesOrClears {
    AppSettings *settings = self.editingSettings;
    NSString *reference = [AppTheme storeCustomImageData:VibeSquarePNG(64) error:NULL];
    NSString *path = [_artDir stringByAppendingPathComponent:[reference substringFromIndex:7]];
    [settings.currentTheme setImageReference:reference forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings currentThemeDidChange]; // an unchanged write keeps redo
    XCTAssertTrue(settings.canRedoThemeEdit);
    [settings redoThemeEdit];
    XCTAssertEqualObjects([settings.currentTheme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark], reference);
    [settings undoThemeEdit];
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChange];
    XCTAssertFalse(settings.canRedoThemeEdit);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    [settings applyThemeWithIdentifier:@"vibe"];
    XCTAssertFalse(settings.canRedoThemeEdit);
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    [settings factoryReset];
    XCTAssertFalse(settings.canRedoThemeEdit);
}

- (void)testClearedThemeImageSurvivesUntilUndoHistoryIsDiscarded {
    AppSettings *settings = self.editingSettings;
    NSString *path = [self installEditingImageInSettings:settings];
    NSString *reference = [settings.currentTheme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    XCTAssertEqualObjects([settings.currentTheme imageReferenceForKey:kVibeThemeImageDefaultArtworkDark], reference);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChangeContinuous:YES atTime:103];
    [settings applyThemeWithIdentifier:settings.activeThemeIdentifier];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
}

- (void)testHistoryEvictionSweepsImagesEvenWhenOnlyDisplayFlagsChange {
    AppSettings *settings = self.editingSettings;
    NSString *path = [self installEditingImageInSettings:settings];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChangeContinuous:YES atTime:100];
    for (NSUInteger i = 0; i < 49; i++) {
        settings.currentTheme.showTransportButtons = !settings.currentTheme.showTransportButtons;
        [settings currentThemeDidChangeContinuous:YES atTime:103 + i * 3];
    }
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
    settings.currentTheme.showTransportButtons = !settings.currentTheme.showTransportButtons;
    [settings currentThemeDidChangeContinuous:YES atTime:250];
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
}

- (void)testFactoryResetRetiresThemeUndoImagesAndAppearancePreview {
    AppSettings *settings = self.editingSettings;
    NSString *path = [self installEditingImageInSettings:settings];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    settings.windowAppearancePreviewStyle = @"light";
    XCTAssertTrue(settings.canUndoThemeEdit);
    [settings factoryReset];
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertNil(settings.windowAppearancePreviewStyle);
    XCTAssertNil(settings.windowAppearance);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, @{});
}

- (void)testRenameEvictionSweepsImagesFromUndoHistory {
    AppSettings *settings = self.editingSettings;
    NSString *path = [self installEditingImageInSettings:settings];
    [settings.currentTheme setImageReference:@"" forKey:kVibeThemeImageDefaultArtworkDark];
    [settings currentThemeDidChange];
    for (NSUInteger i = 0; i < 50; i++) {
        XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:path]);
        [settings renameUserThemeWithIdentifier:settings.activeThemeIdentifier
                                        toName:[NSString stringWithFormat:@"Name %lu", i]];
    }
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:path]);
}

- (void)testFactoryResetClearsTheUserThemesCache {
    AppSettings *settings = AppSettings.sharedInstance;
    NSString *identifier = [settings addUserThemeWithRecord:@{@"waveformTheme": @"orange"}
                                                       name:@"CacheProbe"];
    (void)[settings orderedThemeIdentifiers];          // populate the memo
    [settings factoryReset];
    XCTAssertFalse([[settings orderedThemeIdentifiers] containsObject:identifier],
            @"reset must not leave the deleted theme resurrectable");
}

- (void)testResetKeepsCustomThemesAndImagesUntilFactoryReset {
    AppSettings *settings = self.editingSettings;
    NSString *imagePath = [self installEditingImageInSettings:settings];
    NSString *identifier = settings.activeThemeIdentifier;
    NSDictionary *record = [settings recordForThemeIdentifier:identifier];
    NSString *name = [settings displayNameForThemeIdentifier:identifier];
    NSArray *identifiers = settings.orderedThemeIdentifiers;
    settings.waveformGainDB = 6;
    settings.windowAppearancePreviewStyle = @"light";

    [settings resetToDefaults];
    XCTAssertTrue(settings.allSettingsAtDefaults);
    XCTAssertEqual(settings.waveformGainDB, 0);
    XCTAssertEqualObjects(settings.activeThemeIdentifier, kVibeThemeIdentifierVibe);
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, @{});
    XCTAssertEqualObjects(settings.orderedThemeIdentifiers, identifiers);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:identifier], record);
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], name);
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:imagePath]);
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertFalse(settings.canRedoThemeEdit);
    XCTAssertNil(settings.windowAppearancePreviewStyle);
    XCTAssertEqualObjects([[AppSettings new] recordForThemeIdentifier:identifier], record);

    [settings factoryReset];
    XCTAssertTrue(settings.allSettingsAtDefaults);
    XCTAssertEqualObjects(settings.orderedThemeIdentifiers, AppTheme.builtInThemeIdentifiers);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:imagePath]);
    XCTAssertFalse([[[AppSettings new] orderedThemeIdentifiers] containsObject:identifier]);
}

- (void)testDivergenceBlobAndDeletedActiveFallback {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings factoryReset];
    // A casual edit over a built-in diverges the working record, not the built-in.
    [settings applyThemeWithIdentifier:@"vibe"];
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChange];
    XCTAssertFalse(settings.currentTheme.showTransportButtons);
    XCTAssertEqualObjects([AppTheme builtInRecordForIdentifier:@"vibe"], @{});

    NSString *identifier = [settings addUserThemeWithRecord:@{} name:@"Doomed"];
    [settings applyThemeWithIdentifier:identifier];
    [settings removeUserThemeWithIdentifier:identifier fallingBackTo:nil];
    XCTAssertEqualObjects(settings.activeThemeIdentifier, @"vibe");
    [settings factoryReset];
}

// Two picks of one menu are two undos. A restore lands in the stored entry,
// not only the working record.
- (void)testUndoKeepsDiscreteEditsApartAndFoldsAGesture {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings factoryReset];
    NSString *identifier = [settings addUserThemeWithRecord:@{} name:@"Undo"];
    [settings applyThemeWithIdentifier:identifier];
    XCTAssertFalse(settings.canUndoThemeEdit);

    settings.currentTheme.playButtonGlyph = @"play";
    [settings currentThemeDidChange];
    settings.currentTheme.playButtonGlyph = @"play.circle";
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.currentTheme.playButtonGlyph, @"play");
    XCTAssertEqualObjects([settings recordForThemeIdentifier:identifier][@"playButtonGlyph"], @"play");
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.currentTheme.playButtonGlyph, @"play.fill");
    XCTAssertFalse(settings.canUndoThemeEdit);

    for (NSNumber *radius in @[@8, @9, @10]) {
        settings.currentTheme.windowCornerRadius = radius.doubleValue;
        [settings currentThemeDidChangeContinuous:YES];
    }
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 10);
    [settings undoThemeEdit];
    XCTAssertEqual(settings.currentTheme.windowCornerRadius, 16, @"one drag, one undo");
    XCTAssertFalse(settings.canUndoThemeEdit);

    settings.currentTheme.windowCornerRadius = 8;
    [settings currentThemeDidChangeContinuous:YES];
    settings.currentTheme.customCornerRadius = NO;
    [settings currentThemeDidChange];
    settings.currentTheme.waveformTheme = @"orange";
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    XCTAssertFalse(settings.currentTheme.customCornerRadius);
    XCTAssertEqual(settings.currentTheme.resolvedWindowCornerRadius, 16);
    XCTAssertEqualObjects([settings recordForThemeIdentifier:identifier],
                          (@{@"windowCornerRadius": @8, @"customCornerRadius": @NO}));

    // A rename is its own entry, undone in order with the field edits.
    [settings renameUserThemeWithIdentifier:identifier toName:@"Renamed"];
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], @"Renamed");
    [settings renameUserThemeWithIdentifier:identifier toName:@"Renamed"];
    settings.currentTheme.showTransportButtons = NO;
    [settings currentThemeDidChange];
    [settings undoThemeEdit];
    XCTAssertTrue(settings.currentTheme.showTransportButtons);
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], @"Renamed",
                          @"the field edit undone, the rename still stands");
    [settings undoThemeEdit];
    XCTAssertEqualObjects([settings displayNameForThemeIdentifier:identifier], @"Undo",
                          @"a same-name rename pushed nothing");
    XCTAssertFalse(settings.currentTheme.customCornerRadius, @"the fields rode along untouched");
    [settings factoryReset];
}

// Written straight to the defaults key, as an external `defaults write` would,
// and read back by a fresh instance so no memoized list hides it.
- (void)testStoredUserThemesDropsJunkAndBuiltInSpoofs {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings factoryReset];
    NSString *real = [settings addUserThemeWithRecord:@{} name:@"Real"];
    NSString *key = @"Appearance.userThemes";
    NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:key];
    XCTAssertEqual(stored.count, 1u, @"the key the store writes is the one this test forges");
    NSMutableArray *forged = [stored mutableCopy];
    [forged addObjectsFromArray:@[
        @"not a dictionary",
        @42,
        @{kVibeThemeRecordNameKey: @"No id"},
        @{kVibeThemeRecordIdentifierKey: @"", kVibeThemeRecordNameKey: @"Empty id"},
        @{kVibeThemeRecordIdentifierKey: @7, kVibeThemeRecordNameKey: @"Numeric id"},
        @{kVibeThemeRecordIdentifierKey: @"user-nameless"},
        @{kVibeThemeRecordIdentifierKey: @"user-empty-name", kVibeThemeRecordNameKey: @""},
        @{kVibeThemeRecordIdentifierKey: kVibeThemeIdentifierVibe,
          kVibeThemeRecordNameKey: @"Spoofed Vibe"},
    ]];
    [NSUserDefaults.standardUserDefaults setObject:forged forKey:key];

    AppSettings *reloaded = [AppSettings new];
    NSArray *expected = [[AppTheme builtInThemeIdentifiers] arrayByAddingObject:real];
    XCTAssertEqualObjects([reloaded orderedThemeIdentifiers], expected);
    [settings factoryReset];
}

// Themes carried the display choices through 1.14, and the volume slider's
// layout through 1.16: the active theme's become the app-wide settings, once,
// and no stored record keeps them.
- (void)testThemeDisplayChoicesMigrateFromTheActiveThemeOnce {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings factoryReset];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:@[
        @{kVibeThemeRecordIdentifierKey: @"user-active", kVibeThemeRecordNameKey: @"Active",
          @"showBPM": @NO, @"keyNotation": @"musical", @"showPlaylistArtworkColumn": @NO,
          @"dockIcon": @"app_icon", @"windowTint": @"mono",
          @"volumeLocation": @"bottom", @"volumeVisibility": @"always", @"showVolumeLabels": @NO},
        @{kVibeThemeRecordIdentifierKey: @"user-other", kVibeThemeRecordNameKey: @"Other",
          @"showKey": @NO},
    ] forKey:@"Appearance.userThemes"];
    [defaults setObject:@"user-active" forKey:@"Appearance.activeTheme"];

    AppSettings *migrated = [AppSettings new];
    XCTAssertFalse(migrated.showBPM);
    XCTAssertEqualObjects(migrated.keyNotation, @"musical");
    XCTAssertFalse(migrated.showPlaylistArtworkColumn);
    XCTAssertEqualObjects(migrated.dockIcon, @"app_icon");
    XCTAssertEqualObjects(migrated.volumeLocation, @"bottom");
    XCTAssertEqualObjects(migrated.volumeVisibility, @"always");
    XCTAssertFalse(migrated.showVolumeLabels);
    XCTAssertTrue(migrated.showKey, @"an inactive theme's choice is not the user's");
    NSArray *stored = [defaults arrayForKey:@"Appearance.userThemes"];
    XCTAssertEqualObjects(stored[0], (@{kVibeThemeRecordIdentifierKey: @"user-active",
                                        kVibeThemeRecordNameKey: @"Active", @"windowTint": @"mono"}));
    XCTAssertEqualObjects(stored[1], (@{kVibeThemeRecordIdentifierKey: @"user-other",
                                        kVibeThemeRecordNameKey: @"Other"}));

    migrated.showBPM = YES;
    XCTAssertTrue([AppSettings new].showBPM);
    [settings factoryReset];
}

// Kinda Blue and Dark Wolf shipped their volume labels off through 1.16, so
// an unedited one keeps them off, once: either picked since keeps them on.
- (void)testUneditedBuiltInsKeepTheirVolumeLabelsOffOnce {
    AppSettings *settings = AppSettings.sharedInstance;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *builtIn in @[@"kinda_blue", @"dark_wolf"]) {
        [settings factoryReset];
        [defaults removeObjectForKey:@"Appearance.builtInVolumeLabelsRead"];
        [defaults setObject:builtIn forKey:@"Appearance.activeTheme"];
        XCTAssertFalse([AppSettings new].showVolumeLabels, @"%@ as 1.16 shipped it", builtIn);
    }

    [settings factoryReset];
    [defaults removeObjectForKey:@"Appearance.builtInVolumeLabelsRead"];
    (void)[AppSettings new];
    [defaults setObject:@"kinda_blue" forKey:@"Appearance.activeTheme"];
    XCTAssertTrue([AppSettings new].showVolumeLabels, @"picked after the update");
    [settings factoryReset];
}

// 1.14's window "solid" kept the glass panes, which 1.15 calls frosted.
- (void)testAVersion1SolidWindowImportsAsFrosted {
    NSData *(^json)(NSNumber *) = ^NSData *(NSNumber *version) {
        return [NSJSONSerialization dataWithJSONObject:@{@"version": version, @"name": @"Old",
                @"window": @{@"backgroundStyle": @"solid"}, @"playlist": @{@"backgroundStyle": @"solid"}}
                                               options:0 error:NULL];
    };
    NSDictionary *old = [AppTheme recordFromJSONData:json(@1) name:NULL error:NULL];
    XCTAssertEqualObjects(old[@"windowBackgroundStyle"], @"frosted");
    XCTAssertEqualObjects(old[@"playlistBackgroundStyle"], @"solid", @"the playlist's solid never changed");
    NSDictionary *current = [AppTheme recordFromJSONData:json(@2) name:NULL error:NULL];
    XCTAssertEqualObjects(current[@"windowBackgroundStyle"], @"solid");
    NSDictionary *trip = [AppTheme recordFromJSONData:
            [AppTheme JSONDataForRecord:current name:@"Trip"] name:NULL error:NULL];
    XCTAssertEqualObjects(trip[@"windowBackgroundStyle"], @"solid", @"an export keeps its own meaning");
}

// Wiggle MC is Wiggle grounded on its baseline at any record version: 1.14
// stored it at 1, a 1.15 beta at 2. A grounded theme keeps the choice
// through an export.
- (void)testWiggleMCReadsAsWiggleWithCenteredOffAtAnyVersion {
    NSData *(^json)(NSNumber *) = ^NSData *(NSNumber *version) {
        return [NSJSONSerialization dataWithJSONObject:@{@"version": version, @"name": @"Old",
                @"waveform": @{@"style": @"wiggle"}} options:0 error:NULL];
    };
    NSDictionary *old = [AppTheme recordFromJSONData:json(@1) name:NULL error:NULL];
    XCTAssertEqualObjects(old[@"waveformStyle"], SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE);
    XCTAssertEqualObjects(old[@"waveformCentered"], @NO);
    XCTAssertEqualObjects([AppTheme recordFromJSONData:json(@2) name:NULL error:NULL], old);
    AppTheme *stored = [[AppTheme alloc] initWithRecord:@{@"waveformStyle": @"wiggle"}];
    XCTAssertEqualObjects(stored.waveformStyle, SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE);
    XCTAssertFalse(stored.waveformCentered);
    NSDictionary *trip = [AppTheme recordFromJSONData:
            [AppTheme JSONDataForRecord:old name:@"Trip"] name:NULL error:NULL];
    XCTAssertEqualObjects(trip[@"waveformCentered"], @NO);
    XCTAssertFalse([[AppTheme alloc] initWithRecord:trip].waveformCentered);
}

// iOS's half: each Wiggle MC, the card's or the widget's, is Wiggle with its
// own Centered off, so the other's style keeps the look it had.
- (void)testIOSWiggleMCMigratesEachCenteredOnItsOwn {
    VibeTestUserDefaults *defaults = [[VibeTestUserDefaults alloc] initWithSuiteName:NSUUID.UUID.UUIDString];
    [defaults setObject:@"wiggle" forKey:SETTING_WAVEFORM_STYLE];
    [defaults setObject:@"detailed" forKey:SETTING_WIDGET_WAVEFORM_STYLE];
    [AppSettings migrateLegacyWiggleMCInDefaults:defaults];
    XCTAssertEqualObjects([defaults stringForKey:SETTING_WAVEFORM_STYLE], SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE);
    XCTAssertEqualObjects([defaults objectForKey:SETTING_WAVEFORM_CENTERED], @NO);
    XCTAssertEqualObjects([defaults stringForKey:SETTING_WIDGET_WAVEFORM_STYLE], @"detailed");
    XCTAssertNil([defaults objectForKey:SETTING_WIDGET_WAVEFORM_CENTERED]);

    defaults = [[VibeTestUserDefaults alloc] initWithSuiteName:NSUUID.UUID.UUIDString];
    [defaults setObject:@"detailed" forKey:SETTING_WAVEFORM_STYLE];
    [defaults setObject:@"wiggle" forKey:SETTING_WIDGET_WAVEFORM_STYLE];
    [AppSettings migrateLegacyWiggleMCInDefaults:defaults];
    XCTAssertEqualObjects([defaults stringForKey:SETTING_WAVEFORM_STYLE], @"detailed");
    XCTAssertNil([defaults objectForKey:SETTING_WAVEFORM_CENTERED]);
    XCTAssertEqualObjects([defaults stringForKey:SETTING_WIDGET_WAVEFORM_STYLE], SETTINGS_VALUE_WAVEFORM_STYLE_WIGGLE);
    XCTAssertEqualObjects([defaults objectForKey:SETTING_WIDGET_WAVEFORM_CENTERED], @NO);
}

- (void)testStoredThemesFrom114KeepTheirGlassOnce {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings factoryReset];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // A 1.14 divergence of Technical made by one display toggle, and a user
    // theme duplicated from it.
    NSMutableDictionary *working = [[AppTheme builtInRecordForIdentifier:@"technical"] mutableCopy];
    working[@"windowBackgroundStyle"] = @"solid";
    working[@"showRemainingTime"] = @YES;
    NSMutableDictionary *duplicate = [working mutableCopy];
    duplicate[@"id"] = @"user-1";
    duplicate[@"name"] = @"Mine";
    [defaults setObject:@"technical" forKey:@"Appearance.activeTheme"];
    [defaults setObject:working forKey:@"Appearance.currentTheme"];
    [defaults setObject:@[duplicate] forKey:@"Appearance.userThemes"];
    [defaults removeObjectForKey:@"Appearance.themeRecordVersion"];

    AppSettings *migrated = [AppSettings new];
    XCTAssertTrue(migrated.showRemainingTime);
    XCTAssertFalse(migrated.currentThemeIsModified, @"only the display choice diverged");
    XCTAssertEqualObjects([defaults arrayForKey:@"Appearance.userThemes"][0][@"windowBackgroundStyle"], @"frosted");

    // Once: a Solid picked in 1.15 stays Solid.
    duplicate[@"windowBackgroundStyle"] = @"solid";
    [defaults setObject:@[duplicate] forKey:@"Appearance.userThemes"];
    (void)[AppSettings new];
    XCTAssertEqualObjects([defaults arrayForKey:@"Appearance.userThemes"][0][@"windowBackgroundStyle"], @"solid");
    [settings factoryReset];
}

- (void)testABuiltInDivergenceOfOnlyDisplayChoicesMigratesToNone {
    AppSettings *settings = AppSettings.sharedInstance;
    [settings factoryReset];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:@"technical" forKey:@"Appearance.activeTheme"];
    NSMutableDictionary *working = [[AppTheme builtInRecordForIdentifier:@"technical"] mutableCopy];
    working[@"showFileInfo"] = @NO;
    [defaults setObject:working forKey:@"Appearance.currentTheme"];

    AppSettings *migrated = [AppSettings new];
    XCTAssertFalse(migrated.showFileInfo);
    XCTAssertFalse(migrated.currentThemeIsModified);
    [settings factoryReset];
}



- (void)testGlyphSelectionClearsOnlyItsImagesAndPairsPlayPause {
    NSArray *buttons = @[kVibeThemeImagePlaylistButtonDark, kVibeThemeImageNextButtonDark, kVibeThemeImagePlayButtonDark];
    for (NSString *button in buttons) {
        AppTheme *theme = [[AppTheme alloc] initWithRecord:@{}];
        for (NSString *other in buttons) for (NSString *slot in [AppTheme imageKeysForButton:other]) {
            [theme setImageReference:@"bundled:field_dark.png" forKey:slot];
        }
        NSString *glyph = [button isEqualToString:kVibeThemeImagePlayButtonDark] ? @"play.circle.fill" : @"star.fill";
        [theme setGlyph:glyph forButtonImageKey:button];
        for (NSString *other in buttons) for (NSString *slot in [AppTheme imageKeysForButton:other]) {
            XCTAssertEqual([theme imageReferenceForKey:slot].length > 0, ![other isEqual:button]);
        }
        if ([button isEqualToString:kVibeThemeImagePlayButtonDark]) {
            XCTAssertEqualObjects(theme.playButtonGlyph, glyph);
            XCTAssertEqualObjects(theme.pauseButtonGlyph, @"pause.circle.fill");
        } else if ([button isEqualToString:kVibeThemeImageNextButtonDark]) {
            XCTAssertEqualObjects(theme.nextButtonGlyph, glyph);
        } else {
            XCTAssertEqualObjects(theme.playlistButtonGlyph, glyph);
        }
    }
}

- (void)testGlyphSelectionIsOneUndoableEditIncludingItsRetiredImage {
    AppSettings *settings = self.editingSettings;
    NSString *reference = [AppTheme storeCustomImageData:VibeSquarePNG(96) error:NULL];
    [settings.currentTheme setImageReference:reference forKey:kVibeThemeImagePauseButtonLight];
    [settings currentThemeDidChange];
    NSDictionary *before = settings.currentTheme.dictionaryRepresentation;
    [settings.currentTheme setGlyph:@"play.circle.fill" forButtonImageKey:kVibeThemeImagePlayButtonDark];
    [settings currentThemeDidChange];
    XCTAssertEqualObjects([settings.currentTheme imageReferenceForKey:kVibeThemeImagePauseButtonLight], @"");
    XCTAssertFalse([AppTheme referenceIsMissing:reference]);
    [settings undoThemeEdit];
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, before);
}

- (void)testSupersededOrBuiltInImagePickerStoresNothing {
    AppSettings *settings = self.editingSettings;
    NSString *original = settings.activeThemeIdentifier;
    NSString *other = [settings addUserThemeWithRecord:@{} name:@"Other"];
    [settings applyThemeWithIdentifier:other];
    NSData *data = VibeSquarePNG(96);
    NSError *error = nil;
    XCTAssertFalse([settings setCurrentThemeImageForKey:kVibeThemeImageAppIcon themeIdentifier:original data:data error:&error]);
    XCTAssertNil(error);
    [settings applyThemeWithIdentifier:kVibeThemeIdentifierVibe];
    XCTAssertFalse([settings setCurrentThemeImageForKey:kVibeThemeImageAppIcon themeIdentifier:kVibeThemeIdentifierVibe data:data error:&error]);
    XCTAssertNil(error);
    XCTAssertFalse(settings.canUndoThemeEdit);
    XCTAssertEqual(settings.currentTheme.dictionaryRepresentation.count, 0u);
}

- (void)testImagePickerInstallsOnlyItsSlotAndInvalidDataLeavesThemeUntouched {
    AppSettings *settings = self.editingSettings;
    NSString *identifier = settings.activeThemeIdentifier;
    NSError *error = nil;
    XCTAssertTrue([settings setCurrentThemeImageForKey:kVibeThemeImageNextButtonLight themeIdentifier:identifier
            data:VibeSquarePNG(96) error:&error]);
    [settings currentThemeDidChange];
    XCTAssertNil(error);
    XCTAssertTrue([[settings.currentTheme imageReferenceForKey:kVibeThemeImageNextButtonLight] hasPrefix:@"custom:"]);
    XCTAssertEqualObjects([settings.currentTheme imageReferenceForKey:kVibeThemeImageNextButtonDark], @"");
    NSDictionary *before = settings.currentTheme.dictionaryRepresentation;
    XCTAssertFalse([settings setCurrentThemeImageForKey:kVibeThemeImageNextButtonLight themeIdentifier:identifier
            data:[@"not an image" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
    XCTAssertNotNil(error);
    XCTAssertEqualObjects(settings.currentTheme.dictionaryRepresentation, before);
    [settings undoThemeEdit];
    XCTAssertEqualObjects([settings.currentTheme imageReferenceForKey:kVibeThemeImageNextButtonLight], @"");
}

- (void)testImageEditsRequestTheirOwnLiveEffects {
    XCTAssertEqual(VibeThemeImageEditEffect(kVibeThemeImageAppIcon), VibeSettingsLiveEffectAppIcon);
    for (NSString *key in @[kVibeThemeImageDefaultArtworkDark, kVibeThemeImageDefaultArtworkLight]) {
        XCTAssertEqual(VibeThemeImageEditEffect(key), VibeSettingsLiveEffectTrackDisplay | VibeSettingsLiveEffectPlaylistAppearance);
    }
    for (NSString *button in @[kVibeThemeImagePlayButtonDark, kVibeThemeImageNextButtonDark, kVibeThemeImagePlaylistButtonDark]) {
        for (NSString *key in [AppTheme imageKeysForButton:button]) {
            XCTAssertEqual(VibeThemeImageEditEffect(key), VibeSettingsLiveEffectTransportButtons);
        }
    }
}

@end
