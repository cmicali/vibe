//
//  BrowserRulesTests.m
//  VibeTests
//
//  The Files tab's decisions: the root's rows, and the URLs Recents names. The
//  header ships only in VibeiOS but is Foundation-only, so it compiles here.
//

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

@end
