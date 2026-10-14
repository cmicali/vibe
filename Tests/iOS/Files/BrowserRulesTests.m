
#import <XCTest/XCTest.h>

#import "BrowserRules.h"

@interface BrowserRulesTests : XCTestCase
@end

@implementation BrowserRulesTests

#pragma mark - The root's rows

- (void)testTheLocationsAreTheSourcesThenTheGrantedFolders {
    NSArray *unlinked = @[@(VibeBrowserRootRowDevice), @(VibeBrowserRootRowLocation), @(VibeBrowserRootRowLocation)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionLocations, 0, 2, NO), unlinked);
    NSArray *linked = @[@(VibeBrowserRootRowDevice), @(VibeBrowserRootRowAccount), @(VibeBrowserRootRowLocation)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionLocations, 1, 1, YES), linked);
    NSArray *both = @[@(VibeBrowserRootRowDevice), @(VibeBrowserRootRowAccount), @(VibeBrowserRootRowAccount),
                      @(VibeBrowserRootRowLocation)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionLocations, 2, 1, NO), both);
}

- (void)testALocationRowMapsToItsIndexInTheStore {
    for (NSUInteger linked = 0; linked <= 2; linked++) {
        NSArray<NSNumber *> *rows = VibeBrowserRootRows(VibeBrowserRootSectionLocations, linked, 3, NO);
        NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
        for (NSUInteger row = 0; row <= rows.count; row++) {
            NSUInteger index = VibeBrowserRootLocationIndex(VibeBrowserRootSectionLocations, row, linked, 3);
            BOOL location = row < rows.count && rows[row].integerValue == VibeBrowserRootRowLocation;
            XCTAssertEqual(index == NSNotFound, !location, @"row %lu, linked %lu", (unsigned long)row,
                           (unsigned long)linked);
            if (location) {
                [indexes addObject:@(index)];
            }
        }
        XCTAssertEqualObjects(indexes, (@[@0, @1, @2]));
    }
    XCTAssertEqual(VibeBrowserRootLocationIndex(VibeBrowserRootSectionActions, 2, 0, 3), (NSUInteger)NSNotFound);
}

- (void)testAnAccountRowMapsToItsIndexAmongTheLinked {
    NSArray<NSNumber *> *rows = VibeBrowserRootRows(VibeBrowserRootSectionLocations, 2, 1, NO);
    NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
    for (NSUInteger row = 0; row <= rows.count; row++) {
        NSUInteger index = VibeBrowserRootAccountIndex(VibeBrowserRootSectionLocations, row, 2);
        BOOL account = row < rows.count && rows[row].integerValue == VibeBrowserRootRowAccount;
        XCTAssertEqual(index == NSNotFound, !account, @"row %lu", (unsigned long)row);
        if (account) {
            [indexes addObject:@(index)];
        }
    }
    XCTAssertEqualObjects(indexes, (@[@0, @1]));
    XCTAssertEqual(VibeBrowserRootAccountIndex(VibeBrowserRootSectionRecents, 1, 2), (NSUInteger)NSNotFound);
    XCTAssertEqual(VibeBrowserRootAccountIndex(VibeBrowserRootSectionLocations, 1, 0), (NSUInteger)NSNotFound);
}

- (void)testThePasteRowFollowsOpenURLOnlyWithALinkOnTheClipboard {
    NSArray *expected = @[@(VibeBrowserRootRowChooseFile), @(VibeBrowserRootRowOpenURL), @(VibeBrowserRootRowPasteURL)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionActions, 1, 1, YES), expected);
    NSArray *noLink = @[@(VibeBrowserRootRowChooseFile), @(VibeBrowserRootRowOpenURL)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionActions, 0, 1, NO), noLink);
    for (NSInteger section = VibeBrowserRootSectionLocations; section < VibeBrowserRootSectionActions; section++) {
        XCTAssertFalse([VibeBrowserRootRows((VibeBrowserRootSection)section, 1, 1, YES)
                containsObject:@(VibeBrowserRootRowPasteURL)]);
    }
}

- (void)testTheRecentsSectionIsRecentsAlone {
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionRecents, 1, 3, NO), @[@(VibeBrowserRootRowRecents)]);
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionCount, 1, 3, NO), @[]);
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

@end
