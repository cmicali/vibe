//
// The grant-coverage rule. It decides both whether a folder needs a bookmark
// of its own and whether background work (folder art) may touch a folder
// at all, so a false NO silently costs a feature and a false YES walks into a
// denial.
//

#import <XCTest/XCTest.h>

#import "FolderAccessManager.h"

#import <pwd.h>

@interface FolderAccessCoverageTests : XCTestCase
@end

@implementation FolderAccessCoverageTests {
    NSArray<NSString *> *_granted;
}

- (void)setUp {
    _granted = @[@"/Users/someone/Albums", @"/Volumes/Backup/Music"];
}

- (void)testExactAndDescendantPathsAreCovered {
    XCTAssertTrue([FolderAccessManager path:@"/Users/someone/Albums" isCoveredByAnyOf:_granted]);
    XCTAssertTrue([FolderAccessManager path:@"/Users/someone/Albums/Disc 1" isCoveredByAnyOf:_granted]);
    XCTAssertTrue([FolderAccessManager path:@"/Volumes/Backup/Music/2024" isCoveredByAnyOf:_granted]);
}

- (void)testUnrelatedAndSiblingPathsAreNot {
    XCTAssertFalse([FolderAccessManager path:@"/Users/someone" isCoveredByAnyOf:_granted]);
    XCTAssertFalse([FolderAccessManager path:@"/Users/someone/Downloads" isCoveredByAnyOf:_granted]);
    // A prefix match on the string, not on the path: AlbumsOld is its own folder.
    XCTAssertFalse([FolderAccessManager path:@"/Users/someone/AlbumsOld" isCoveredByAnyOf:_granted]);
    XCTAssertFalse([FolderAccessManager path:@"" isCoveredByAnyOf:_granted]);
}

// Deliberately NOT NSHomeDirectoryForUser: inside the sandbox that answers with
// the container, so the rule under test would compare against a path no music
// ever sits under — and this suite, being host-less and unsandboxed, would
// still pass and hide it. getpwuid gives the same on-disk home in both.
static NSString *RealHome(void) {
    struct passwd *entry = getpwuid(getuid());
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->pw_dir
                                                                     length:strlen(entry->pw_dir)];
}

- (void)testMusicFolderIsCoveredWithoutAGrant {
    NSString *music = [RealHome() stringByAppendingPathComponent:@"Music"];
    XCTAssertTrue([FolderAccessManager path:music isCoveredByAnyOf:@[]]);
    XCTAssertTrue([FolderAccessManager path:[music stringByAppendingPathComponent:@"Live Sets"]
                            isCoveredByAnyOf:@[]]);
}

- (void)testTheStandingMusicGrantUsesTheOnDiskHome {
    XCTAssertEqualObjects(FolderAccessManager.realHomeDirectory, RealHome());
}

#pragma mark - The read test's spelling

// canReadInsideDirectory: is handed a directory taken off a track URL, which
// carries whatever spelling its opener supplied, so it folds case where the
// auto-add's duplicate check must not.

- (void)testReadCoverageFoldsCaseWhereTheAddCheckDoesNot {
    XCTAssertTrue([FolderAccessManager readablePath:@"/Users/someone/albums/Disc 1"
                                   isCoveredByAnyOf:_granted]);
    XCTAssertFalse([FolderAccessManager path:@"/Users/someone/albums/Disc 1"
                            isCoveredByAnyOf:_granted]);
}

- (void)testReadCoverageStillRejectsASibling {
    XCTAssertFalse([FolderAccessManager readablePath:@"/Users/someone/AlbumsOld"
                                    isCoveredByAnyOf:_granted]);
    XCTAssertFalse([FolderAccessManager readablePath:@"/Users/someone"
                                    isCoveredByAnyOf:_granted]);
}

#pragma mark - Alias spellings

// One directory, two spellings: which one reaches the grant list depends on how
// the file was opened, so both sides normalize before comparing.

- (void)testPrivatePrefixMatchesEitherWay {
    XCTAssertTrue([FolderAccessManager path:@"/private/tmp/set/Album"
                           isCoveredByAnyOf:@[@"/tmp/set"]]);
    XCTAssertTrue([FolderAccessManager path:@"/tmp/set/Album"
                           isCoveredByAnyOf:@[@"/private/tmp/set"]]);
    XCTAssertTrue([FolderAccessManager path:@"/private/var/folders/x/Album"
                           isCoveredByAnyOf:@[@"/var/folders/x"]]);
}

- (void)testDataVolumeFirmlinkMatchesEitherWay {
    XCTAssertTrue([FolderAccessManager path:@"/System/Volumes/Data/Users/someone/Albums/Disc 1"
                           isCoveredByAnyOf:_granted]);
    XCTAssertTrue([FolderAccessManager path:@"/Users/someone/Albums/Disc 1"
                           isCoveredByAnyOf:@[@"/System/Volumes/Data/Users/someone/Albums"]]);
}

- (void)testAliasStrippingDoesNotSwallowRealFolderNames {
    // A folder literally named "private" at the root, and one whose name merely
    // starts with the prefix, are not aliases of anything.
    XCTAssertFalse([FolderAccessManager path:@"/privateer/tmp/set" isCoveredByAnyOf:@[@"/tmp/set"]]);
    XCTAssertFalse([FolderAccessManager path:@"/Users/someone/private/tmp"
                            isCoveredByAnyOf:@[@"/tmp"]]);
    XCTAssertFalse([FolderAccessManager path:@"/private/Users/someone/Albums"
                            isCoveredByAnyOf:@[@"/Users/someone/Albums"]]);
}

- (void)testStoredBookmarkDoesNotAuthorizeUntilItsScopeStarts {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *key = @"VibeGrantedFolders";
    id previous = [defaults objectForKey:key];
    [self addTeardownBlock:^{
        if (previous) {
            [defaults setObject:previous forKey:key];
        }
        else {
            [defaults removeObjectForKey:key];
        }
    }];
    NSString *path = @"/Users/someone/Downloads/Stored Grant";
    [defaults setObject:@[@{@"path": path, @"bookmark": [@"invalid" dataUsingEncoding:NSUTF8StringEncoding]}]
                  forKey:key];

    FolderAccessManager *manager = [[FolderAccessManager alloc] init];
    XCTAssertEqualObjects([manager.grantedFolders valueForKey:@"path"], (@[path]));
    XCTAssertFalse([manager canReadInsideDirectory:path]);
    // Nothing has been tried yet, so the row is pending rather than failed.
    XCTAssertEqual(manager.grantedFolders.firstObject.state, VibeGrantedFolderStateRestoring);

    XCTestExpectation *finished = [self expectationWithDescription:@"restore finished"];
    [manager restoreGrantedAccessWithCompletion:^{
        [finished fulfill];
    }];
    // Comfortably past the manager's own 2s restore deadline: an equal timeout
    // races that fallback timer rather than waiting for it.
    [self waitForExpectations:@[finished] timeout:5.0];
    XCTAssertFalse([manager canReadInsideDirectory:path]);
}

// The bookmark blob is garbage, so restoration fails and the row must survive
// it — reported as unavailable rather than dropped, since a grant is also
// unresolvable while its volume is merely unplugged.
- (void)testFailedRestoreKeepsTheRowAndReportsItUnavailable {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *key = @"VibeGrantedFolders";
    id previous = [defaults objectForKey:key];
    [self addTeardownBlock:^{
        if (previous) {
            [defaults setObject:previous forKey:key];
        }
        else {
            [defaults removeObjectForKey:key];
        }
    }];
    NSString *path = @"/Users/someone/Music Archive";
    [defaults setObject:@[@{@"path": path, @"bookmark": [@"invalid" dataUsingEncoding:NSUTF8StringEncoding]}]
                  forKey:key];

    FolderAccessManager *manager = [[FolderAccessManager alloc] init];
    XCTestExpectation *finished = [self expectationWithDescription:@"restore finished"];
    [manager restoreGrantedAccessWithCompletion:^{
        [finished fulfill];
    }];
    [self waitForExpectations:@[finished] timeout:5.0];

    XCTAssertEqual(manager.grantedFolders.count, 1u);
    XCTAssertEqualObjects(manager.grantedFolders.firstObject.path, path);
    XCTAssertEqual(manager.grantedFolders.firstObject.state, VibeGrantedFolderStateUnavailable);
    XCTAssertEqualObjects([defaults arrayForKey:key].firstObject[@"path"], path);
}

@end
