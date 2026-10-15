// RecentsStore over the process's in-memory defaults and real bookmarks of
// temp folders.

#import "IOSShellTestCase.h"

#import "RecentsStore.h"

@interface RecentsStoreTests : IOSShellTestCase
@end

@implementation RecentsStoreTests

static NSDictionary *VibeRecent(NSString *path) {
    return @{@"path": path, @"folder": @NO, @"location": @"Here"};
}

- (NSArray<NSString *> *)paths {
    return [RecentsStore.shared.recentItems valueForKey:@"path"];
}

- (void)testTheNewestRecordIsFirstAndAPickTogetherKeepsItsOrder {
    [RecentsStore.shared recordRecentItems:@[VibeRecent(@"/old")]];
    [RecentsStore.shared recordRecentItems:@[VibeRecent(@"/first"), VibeRecent(@"/second")]];
    XCTAssertEqualObjects(self.paths, (@[@"/first", @"/second", @"/old"]));
}

- (void)testAPathAlreadyListedMovesToTheTop {
    [RecentsStore.shared recordRecentItems:@[VibeRecent(@"/a"), VibeRecent(@"/b"), VibeRecent(@"/c")]];
    [RecentsStore.shared recordRecentItems:@[VibeRecent(@"/c")]];
    XCTAssertEqualObjects(self.paths, (@[@"/c", @"/a", @"/b"]));
}

- (void)testTheListKeepsTheNewestFifty {
    for (NSUInteger i = 0; i < 60; i++) {
        [RecentsStore.shared recordRecentItems:@[VibeRecent([NSString stringWithFormat:@"/%lu", (unsigned long)i])]];
    }
    XCTAssertEqual(self.paths.count, 50u);
    XCTAssertEqualObjects(self.paths.firstObject, @"/59");
    XCTAssertEqualObjects(self.paths.lastObject, @"/10");
}

- (void)testAMalformedStoredItemIsDroppedAtTheNextRecord {
    [NSUserDefaults.standardUserDefaults setObject:@[@"junk", @{@"folder": @YES}, VibeRecent(@"/kept")]
                                            forKey:@"VibeiOSRecentItems"];
    [RecentsStore.shared recordRecentItems:@[VibeRecent(@"/new")]];
    XCTAssertEqualObjects(self.paths, (@[@"/new", @"/kept"]));
}

- (void)testClearingEmptiesTheList {
    [RecentsStore.shared recordRecentItems:@[VibeRecent(@"/a")]];
    [RecentsStore.shared clearRecentItems];
    XCTAssertEqualObjects(RecentsStore.shared.recentItems, @[]);
}

- (NSURL *)resolve:(NSDictionary *)item {
    XCTestExpectation *resolved = [self expectationWithDescription:@"resolved"];
    __block NSURL *answer = nil;
    [RecentsStore.shared resolveRecentItem:item completion:^(NSURL *url) {
        XCTAssertTrue(NSThread.isMainThread);
        answer = url;
        [resolved fulfill];
    }];
    [self waitForExpectations:@[resolved] timeout:VIBE_TEST_HANG_TIMEOUT];
    return answer;
}

- (void)testARecentResolvesThroughItsBookmark {
    NSURL *folder = [self folder:@"Album"];
    NSData *bookmark = [folder bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil
                                         relativeToURL:nil error:NULL];
    NSURL *url = [self resolve:@{@"path": @"/moved/elsewhere", @"bookmark": bookmark, @"folder": @YES}];
    XCTAssertEqualObjects(url.URLByStandardizingPath.path.lastPathComponent, @"Album");
}

- (void)testARecentWithoutABookmarkFallsBackToItsPathWhileSomethingIsThere {
    NSURL *song = [self file:@"Song.mp3"];
    NSURL *url = [self resolve:@{@"path": song.path, @"folder": @NO}];
    XCTAssertEqualObjects(url.path, song.path);
    XCTAssertFalse(url.hasDirectoryPath);
    NSURL *folder = [self folder:@"Album"];
    NSURL *folderURL = [self resolve:@{@"path": folder.path, @"folder": @YES}];
    XCTAssertTrue(folderURL.hasDirectoryPath);
    XCTAssertNil([self resolve:@{@"path": [self.root.path stringByAppendingPathComponent:@"gone.mp3"]}]);
}

@end
