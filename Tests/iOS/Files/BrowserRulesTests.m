
#import <XCTest/XCTest.h>

#import "BrowserRules.h"
#import "FilesTabRules.h"

@interface BrowserRulesTests : XCTestCase
@end

@implementation BrowserRulesTests

#pragma mark - The root's rows

- (void)testALocationRowMapsToItsIndexInTheStoreAfterTheSources {
    for (NSUInteger sources = 1; sources <= 2; sources++) {
        NSMutableArray<NSNumber *> *indexes = [NSMutableArray array];
        for (NSUInteger row = 0; row <= sources + 3; row++) {
            NSUInteger index = VibeBrowserLocationIndex(row, sources, 3);
            BOOL location = row >= sources && row < sources + 3;
            XCTAssertEqual(index == NSNotFound, !location, @"row %lu, sources %lu", (unsigned long)row,
                           (unsigned long)sources);
            if (location) {
                [indexes addObject:@(index)];
            }
        }
        XCTAssertEqualObjects(indexes, (@[@0, @1, @2]));
    }
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
    XCTAssertEqual(VibeFilesTabRowActionsFor(NO, NO, NO, YES),
                   VibeFilesTabRowActionPlay | VibeFilesTabRowActionPlayInFolder | VibeFilesTabRowActionAddToPlaylist
                           | VibeFilesTabRowActionOpenFolder);
}

- (void)testAFolderOrAPlaylistFileHasNoPlayInFolder {
    VibeFilesTabRowActions expected = VibeFilesTabRowActionPlay | VibeFilesTabRowActionAddToPlaylist
            | VibeFilesTabRowActionOpenFolder;
    XCTAssertEqual(VibeFilesTabRowActionsFor(YES, NO, NO, YES), expected);
    XCTAssertEqual(VibeFilesTabRowActionsFor(NO, NO, YES, YES), expected);
}

- (void)testALinkHasNeitherFolderAction {
    XCTAssertEqual(VibeFilesTabRowActionsFor(NO, NO, NO, NO),
                   VibeFilesTabRowActionPlay | VibeFilesTabRowActionAddToPlaylist);
}

- (void)testTheAddSheetOnlyAdds {
    XCTAssertEqual(VibeFilesTabRowActionsFor(NO, YES, NO, YES),
                   VibeFilesTabRowActionAddToPlaylist | VibeFilesTabRowActionOpenFolder);
    XCTAssertEqual(VibeFilesTabRowActionsFor(NO, YES, NO, NO), VibeFilesTabRowActionAddToPlaylist);
}

#pragma mark - A row's tile

- (void)testAPlaylistNameTakesThePlaylistTileWhateverItsCase {
    XCTAssertTrue(VibeBrowserIsPlaylistName(@"Live.cue"));
    XCTAssertTrue(VibeBrowserIsPlaylistName(@"/Music/Mix.M3U8"));
    XCTAssertFalse(VibeBrowserIsPlaylistName(@"Song.flac"));
    XCTAssertFalse(VibeBrowserIsPlaylistName(@"cue"));
    XCTAssertFalse(VibeBrowserIsPlaylistName(nil));
}

@end
