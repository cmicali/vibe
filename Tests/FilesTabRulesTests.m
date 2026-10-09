//
//  FilesTabRulesTests.m
//  VibeTests
//
//  The Files tab's decisions: the root's rows, what Recents names and offers
//  for a link, which open the next launch restores, and the recents a
//  launch's pruning keeps. The header ships only in VibeiOS but is
//  Foundation-only, so it compiles here.
//

#import <XCTest/XCTest.h>

#import "FilesTabRules.h"

@interface FilesTabRulesTests : XCTestCase
@end

static NSString *const kLinksRoot = @"/var/mobile/Containers/Data/Application/X/Library/Application Support/Links";

@implementation FilesTabRulesTests

#pragma mark - The root's rows

- (void)testOpenURLIsTheLastLocationsRowAfterBrowseFiles {
    NSArray *rows = VibeBrowserRootRows(VibeBrowserRootSectionLocations, YES, 2);
    NSArray *expected = @[@(VibeBrowserRootRowLocation), @(VibeBrowserRootRowLocation), @(VibeBrowserRootRowAddFolder),
                          @(VibeBrowserRootRowBrowseFiles), @(VibeBrowserRootRowOpenURL)];
    XCTAssertEqualObjects(rows, expected, @"a location's row is its index in the store");
}

- (void)testConnectDropboxIsOfferedOnlyUntilLinked {
    NSArray *unlinked = VibeBrowserRootRows(VibeBrowserRootSectionLocations, NO, 0);
    NSArray *expected = @[@(VibeBrowserRootRowConnectDropbox), @(VibeBrowserRootRowAddFolder),
                          @(VibeBrowserRootRowBrowseFiles), @(VibeBrowserRootRowOpenURL)];
    XCTAssertEqualObjects(unlinked, expected);
    XCTAssertFalse([VibeBrowserRootRows(VibeBrowserRootSectionLocations, YES, 0)
            containsObject:@(VibeBrowserRootRowConnectDropbox)]);
}

- (void)testTheSourcesAndRecentsSections {
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionSources, NO, 3), @[@(VibeBrowserRootRowDevice)]);
    NSArray *linked = @[@(VibeBrowserRootRowDevice), @(VibeBrowserRootRowDropbox)];
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionSources, YES, 3), linked);
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionRecents, YES, 3), @[@(VibeBrowserRootRowRecents)]);
    XCTAssertEqualObjects(VibeBrowserRootRows(VibeBrowserRootSectionCount, YES, 3), @[]);
}

#pragma mark - Recents

- (void)testALinkOffersNoFolderActions {
    NSString *link = [kLinksRoot stringByAppendingString:@"/0123456789abcdef/Song.mp3"];
    XCTAssertTrue(VibePathIsLink(link, kLinksRoot));
    XCTAssertFalse(VibeRecentOffersFolderActions(link, kLinksRoot), @"no Play in Folder, no Open Folder");
}

- (void)testAnythingElseOffersThem {
    XCTAssertTrue(VibeRecentOffersFolderActions(@"/var/mobile/Documents/Album/01.flac", kLinksRoot));
    XCTAssertTrue(VibeRecentOffersFolderActions([kLinksRoot stringByAppendingString:@" Old/a/Song.mp3"], kLinksRoot),
                  @"a sibling whose name starts with the root's is not under it");
    XCTAssertTrue(VibeRecentOffersFolderActions(@"/var/mobile/Documents/01.flac", nil), @"no root");
    XCTAssertTrue(VibeRecentOffersFolderActions(nil, kLinksRoot));
}

- (void)testALinkIsNamedByItsHost {
    NSDictionary *record = @{@"url": @"https://cdn.example.com/a/Song.mp3", @"host": @"cdn.example.com"};
    XCTAssertEqualObjects(VibeRecentLocationName(record, @"0123456789abcdef"), @"cdn.example.com");
}

- (void)testARecordWithNoHostIsNamedByItsURL {
    NSDictionary *record = @{@"url": @"https://Media.Example.org/Song.mp3"};
    XCTAssertEqualObjects(VibeRecentLocationName(record, @"0123456789abcdef"), @"media.example.org");
    XCTAssertEqualObjects(VibeRecentLocationName(@{@"host": @""}, @"0123456789abcdef"), @"0123456789abcdef");
    XCTAssertEqualObjects(VibeRecentLocationName(@{@"url": @"not a url"}, @"Folder"), @"Folder");
}

- (void)testAnythingElseIsNamedByItsFolder {
    XCTAssertEqualObjects(VibeRecentLocationName(nil, @"On My iPhone"), @"On My iPhone");
}

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
    XCTAssertTrue(urls[0].isFileURL, @"VibeLinkKeptURLs keeps only file URLs");
}

#pragma mark - The restored playlist

- (void)testAOneFileOpenKeepsAFolderBookmark {
    XCTAssertFalse(VibeFolderSessionPersistsBase(NO, NO, YES, NO), @"a mirror file too: it is not a link");
    XCTAssertTrue(VibeFolderSessionPersistsBase(NO, NO, NO, NO), @"over a file bookmark, or none");
}

- (void)testALinkOpenedAloneReplacesAFolderBookmark {
    XCTAssertTrue(VibeFolderSessionPersistsBase(NO, NO, YES, YES));
}

- (void)testAnOpenThatBroughtAFolderPersists {
    XCTAssertTrue(VibeFolderSessionPersistsBase(NO, YES, YES, NO));
}

- (void)testAnOpenInsideAOneOffPickKeepsTheSessions {
    XCTAssertFalse(VibeFolderSessionPersistsBase(YES, YES, NO, NO));
    XCTAssertFalse(VibeFolderSessionPersistsBase(YES, NO, NO, YES));
}

@end
