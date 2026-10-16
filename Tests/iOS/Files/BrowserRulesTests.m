
#import <XCTest/XCTest.h>

#import "BrowserRules.h"

@interface BrowserRulesTests : XCTestCase
@end

@implementation BrowserRulesTests

#pragma mark - The root's rows

- (void)testTheLocationsAreTheSourcesThenTheGrantedFolders {
    NSArray *unlinked = @[@(VibeBrowserRootRowDevice), @(VibeBrowserRootRowLocation), @(VibeBrowserRootRowLocation)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionLocations, NO, 2, NO), unlinked);
    NSArray *linked = @[@(VibeBrowserRootRowDevice), @(VibeBrowserRootRowDropbox), @(VibeBrowserRootRowLocation)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionLocations, YES, 1, YES), linked);
}

- (void)testALocationRowMapsToItsIndexInTheStore {
    for (NSNumber *linked in @[@NO, @YES]) {
        NSArray<NSNumber *> *rows = VibeBrowserRootRows(VibeBrowserRootSectionLocations, linked.boolValue, 3, NO);
        NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
        for (NSUInteger row = 0; row <= rows.count; row++) {
            NSUInteger index = VibeBrowserRootLocationIndex(VibeBrowserRootSectionLocations, row, linked.boolValue, 3);
            BOOL location = row < rows.count && rows[row].integerValue == VibeBrowserRootRowLocation;
            XCTAssertEqual(index == NSNotFound, !location, @"row %lu, linked %@", (unsigned long)row, linked);
            if (location) {
                [indexes addObject:@(index)];
            }
        }
        XCTAssertEqualObjects(indexes, (@[@0, @1, @2]));
    }
    XCTAssertEqual(VibeBrowserRootLocationIndex(VibeBrowserRootSectionActions, 2, NO, 3), (NSUInteger)NSNotFound);
}

- (void)testThePasteRowFollowsOpenURLOnlyWithALinkOnTheClipboard {
    NSArray *expected = @[@(VibeBrowserRootRowChooseFile), @(VibeBrowserRootRowOpenURL), @(VibeBrowserRootRowPasteURL)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionActions, YES, 1, YES), expected);
    NSArray *noLink = @[@(VibeBrowserRootRowChooseFile), @(VibeBrowserRootRowOpenURL)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionActions, NO, 1, NO), noLink);
    for (NSInteger section = VibeBrowserRootSectionLocations; section < VibeBrowserRootSectionActions; section++) {
        XCTAssertFalse([VibeBrowserRootRows((VibeBrowserRootSection)section, YES, 1, YES)
                containsObject:@(VibeBrowserRootRowPasteURL)]);
    }
}

- (void)testTheRecentsSectionIsRecentsAlone {
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionRecents, YES, 3, NO), @[@(VibeBrowserRootRowRecents)]);
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionCount, YES, 3, NO), @[]);
}

#pragma mark - Recents

- (void)testTheRecentsURLsAreTheirPaths {
    NSArray *items = @[@{@"path": @"/a/Song.mp3", @"folder": @NO},
                       @{@"path": @"/b", @"folder": @YES},
                       @{@"folder": @NO},
                       @{@"path": @""},
                       @"not an item"];
    NSArray<NSURL *> *urls = VibeRecentItemURLs(items);
    XCTAssertEqual(urls.count, 2u);
    XCTAssertEqualObjects(urls[0].path, @"/a/Song.mp3");
    XCTAssertEqualObjects(urls[1].path, @"/b");
    XCTAssertTrue(urls[0].isFileURL);
    // From the recorded flag, never a stat of the path.
    XCTAssertFalse(urls[0].hasDirectoryPath);
    XCTAssertTrue(urls[1].hasDirectoryPath);
}

#pragma mark - A folder

- (void)testAFolderSaysWhyItShowsNothing {
    XCTAssertEqual(VibeBrowserFolderEmptyStateFor(3, 3, YES, YES), VibeBrowserFolderEmptyStateNone,
                   @"rows drawn outrank a relist or its failure");
    XCTAssertEqual(VibeBrowserFolderEmptyStateFor(3, 0, NO, NO), VibeBrowserFolderEmptyStateNoMatches);
    XCTAssertEqual(VibeBrowserFolderEmptyStateFor(0, 0, YES, YES), VibeBrowserFolderEmptyStateLoading);
    XCTAssertEqual(VibeBrowserFolderEmptyStateFor(0, 0, NO, YES), VibeBrowserFolderEmptyStateUnavailable);
    XCTAssertEqual(VibeBrowserFolderEmptyStateFor(0, 0, NO, NO), VibeBrowserFolderEmptyStateEmpty);
}

#pragma mark - A row's long press

- (void)testAFileOffersEveryAction {
    XCTAssertEqual(VibeBrowserRowActionsFor(NO, NO, NO, YES),
                   VibeBrowserRowActionPlay | VibeBrowserRowActionPlayInFolder | VibeBrowserRowActionAddToPlaylist
                           | VibeBrowserRowActionOpenFolder);
}

- (void)testAFolderOrAPlaylistFileHasNoPlayInFolder {
    VibeBrowserRowActions expected = VibeBrowserRowActionPlay | VibeBrowserRowActionAddToPlaylist
            | VibeBrowserRowActionOpenFolder;
    XCTAssertEqual(VibeBrowserRowActionsFor(YES, NO, NO, YES), expected);
    XCTAssertEqual(VibeBrowserRowActionsFor(NO, NO, YES, YES), expected);
}

- (void)testALinkHasNeitherFolderAction {
    XCTAssertEqual(VibeBrowserRowActionsFor(NO, NO, NO, NO),
                   VibeBrowserRowActionPlay | VibeBrowserRowActionAddToPlaylist);
}

- (void)testTheAddSheetOnlyAdds {
    XCTAssertEqual(VibeBrowserRowActionsFor(NO, YES, NO, YES),
                   VibeBrowserRowActionAddToPlaylist | VibeBrowserRowActionOpenFolder);
    XCTAssertEqual(VibeBrowserRowActionsFor(NO, YES, NO, NO), VibeBrowserRowActionAddToPlaylist);
}

@end
