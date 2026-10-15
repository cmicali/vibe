// LocationStore over the process's in-memory defaults and real bookmarks of
// temp folders. A store of its own (initPrivate) reads what a relaunch reads.

#import "IOSShellTestCase.h"

#import "FilePaths.h"
#import "LocationStoreInternal.h"

@interface LocationStoreTests : IOSShellTestCase
@end

@implementation LocationStoreTests {
    NSUInteger _changes;
    id _observer;
}

- (void)setUp {
    [super setUp];
    _changes = 0;
    __weak LocationStoreTests *weakSelf = self;
    _observer = [NSNotificationCenter.defaultCenter addObserverForName:VibeSearchFoldersDidChangeNotification
                                                                object:nil queue:nil
                                                            usingBlock:^(NSNotification *note) {
        LocationStoreTests *strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_changes++;
        }
    }];
}

- (void)tearDown {
    [NSNotificationCenter.defaultCenter removeObserver:_observer];
    [super tearDown];
}

- (NSArray<NSString *> *)names:(LocationStore *)store {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *url in store.folderURLs) {
        [names addObject:url.lastPathComponent];
    }
    return names;
}

// The add posts once, and its mint lands the name and the bookmark together.
- (void)add:(NSURL *)url {
    NSUInteger before = _changes;
    XCTAssertTrue([LocationStore.shared addFolderURL:url]);
    XCTAssertTrue([self eventually:^BOOL { return self->_changes >= before + 2; }], @"%@ never minted", url);
}

#pragma mark - Coverage

- (void)testAFolderInsideALocationIsRefused {
    [self add:[self folder:@"Music"]];
    XCTAssertFalse([LocationStore.shared addFolderURL:[self folder:@"Music/Album"]]);
    XCTAssertFalse([LocationStore.shared addFolderURL:[self folder:@"Music"]], @"nor the same folder twice");
    XCTAssertEqualObjects([self names:LocationStore.shared], @[@"Music"]);
}

- (void)testAFolderThatCoversLocationsReplacesThemInPlace {
    [self add:[self folder:@"First"]];
    [self add:[self folder:@"Music/A"]];
    [self add:[self folder:@"Music/B"]];
    [self add:[self folder:@"Music"]];
    XCTAssertEqualObjects([self names:LocationStore.shared], (@[@"First", @"Music"]));
}

- (void)testDocumentsIsARootAndNeverARow {
    NSURL *documents = LocationStore.containerDocumentsURL;
    XCTAssertFalse([LocationStore.shared addFolderURL:[documents URLByAppendingPathComponent:@"Music"
                                                                                  isDirectory:YES]]);
    [self add:[self folder:@"Music"]];
    XCTAssertEqualObjects(LocationStore.shared.searchRoots.lastObject, documents);
    XCTAssertEqual(LocationStore.shared.searchRoots.count, 2u);
}

- (void)testAGrantIsTheLongestCoveringLocation {
    NSURL *music = [self folder:@"Music"];
    [self add:music];
    NSURL *song = [self file:@"Music/Album/Song.mp3"];
    LocationGrant *grant = [LocationStore.shared grantCoveringURL:song];
    XCTAssertEqualObjects(VibeComparablePath(grant.rootURL.path), VibeComparablePath(music.path));
    XCTAssertNil([LocationStore.shared grantCoveringURL:[self file:@"Elsewhere/Song.mp3"]]);
}

#pragma mark - Naming

- (void)testAFolderIsNamedWithoutTheDisk {
    LocationStore.deviceModelName = @"iPad";
    XCTAssertEqualObjects([LocationStore displayNameForFolderURL:LocationStore.containerDocumentsURL],
                          @"On My iPad");
    NSURL *folder = [self folder:@"Some Folder"];
    XCTAssertEqualObjects([LocationStore displayNameForFolderURL:folder], @"Some Folder");
    [self add:folder];
    XCTAssertEqualObjects([LocationStore displayNameForFolderURL:folder], @"Some Folder",
                          @"a location by the name resolved with its bookmark");
}

#pragma mark - Persistence

- (void)testARelaunchRestoresTheLocationsInTheirOrder {
    [self add:[self folder:@"B"]];
    [self add:[self folder:@"A"]];
    [self add:[self folder:@"C"]];
    [LocationStore.shared removeFolderAtIndex:2];
    LocationStore *relaunched = [[LocationStore alloc] initPrivate];
    [relaunched restorePersistedFolders];
    XCTAssertTrue([self eventually:^BOOL { return relaunched.folderURLs.count == 2; }]);
    [self settle];
    XCTAssertEqualObjects([self names:relaunched], (@[@"B", @"A"]));
}

- (void)testARelaunchDropsAFolderThatNoLongerResolves {
    [self add:[self folder:@"Kept"]];
    [self add:[self folder:@"Gone"]];
    [NSFileManager.defaultManager removeItemAtURL:[self.root URLByAppendingPathComponent:@"Gone"] error:NULL];
    LocationStore *relaunched = [[LocationStore alloc] initPrivate];
    [relaunched restorePersistedFolders];
    XCTAssertTrue([self eventually:^BOOL { return relaunched.folderURLs.count == 1; }]);
    [self settle];
    XCTAssertEqualObjects([self names:relaunched], @[@"Kept"]);
}

- (void)testRemovingEveryLocationForgetsTheKey {
    [self add:[self folder:@"A"]];
    [LocationStore.shared removeFolderAtIndex:0];
    [LocationStore.shared removeFolderAtIndex:3];
    XCTAssertEqualObjects(LocationStore.shared.folderURLs, @[]);
    LocationStore *relaunched = [[LocationStore alloc] initPrivate];
    [relaunched restorePersistedFolders];
    [self settle];
    XCTAssertEqualObjects(relaunched.folderURLs, @[]);
}

@end
