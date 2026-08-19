//
// The grant-coverage rule. It decides both whether a folder needs a bookmark
// of its own and whether background work (folder art) may touch a folder
// at all, so a false NO silently costs a feature and a false YES walks into a
// denial.
//

#import <XCTest/XCTest.h>

#import "FolderAccessManager.h"
#import "FolderAccessManagerInternal.h"
#import "FolderAccessRules.h"

#import <pwd.h>

@interface BlockingFolderAccessManager : FolderAccessManager
@property (atomic, copy) void (^didStartRestoration)(NSUInteger count);
@property (atomic, copy) void (^didStartStoredRestoration)(NSDictionary *stored);
@property (atomic, copy) NSSet<NSString *> *immediatelySuccessfulPaths;
@property (atomic, copy) NSSet<NSData *> *immediatelySuccessfulBookmarks;
@property (atomic, copy) NSSet<NSData *> *dedicatedGateBookmarks;
- (void)releaseOneRestoration;
- (void)releaseRestorationWithBookmark:(NSData *)bookmark;
- (NSUInteger)activeRestorationCount;
- (NSUInteger)peakRestorationCount;
- (NSUInteger)startedRestorationCount;
- (NSArray<NSString *> *)startedRestorationPaths;
- (NSArray<NSData *> *)startedRestorationBookmarks;
@end

@implementation BlockingFolderAccessManager {
    NSLock *_restorationStateLock;
    dispatch_semaphore_t _restorationGate;
    NSUInteger _activeRestorationCount;
    NSUInteger _peakRestorationCount;
    NSUInteger _startedRestorationCount;
    NSMutableArray<NSString *> *_startedRestorationPaths;
    NSMutableArray<NSData *> *_startedRestorationBookmarks;
    NSMutableDictionary<NSData *, dispatch_semaphore_t> *_restorationGates;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _restorationStateLock = [NSLock new];
        _restorationGate = dispatch_semaphore_create(0);
        _startedRestorationPaths = [NSMutableArray array];
        _startedRestorationBookmarks = [NSMutableArray array];
        _restorationGates = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSDictionary *)resolveStoredEntry:(NSDictionary *)stored {
    NSString *path = stored[@"path"];
    NSData *bookmark = stored[@"bookmark"];
    [_restorationStateLock lock];
    _activeRestorationCount++;
    _startedRestorationCount++;
    _peakRestorationCount = MAX(_peakRestorationCount, _activeRestorationCount);
    [_startedRestorationPaths addObject:path];
    [_startedRestorationBookmarks addObject:bookmark];
    dispatch_semaphore_t gate = _restorationGate;
    if ([self.dedicatedGateBookmarks containsObject:bookmark]) {
        gate = _restorationGates[bookmark];
        if (!gate) {
            gate = dispatch_semaphore_create(0);
            _restorationGates[bookmark] = gate;
        }
    }
    NSUInteger started = _startedRestorationCount;
    [_restorationStateLock unlock];

    void (^didStart)(NSUInteger) = self.didStartRestoration;
    if (didStart) {
        didStart(started);
    }
    void (^didStartStored)(NSDictionary *) = self.didStartStoredRestoration;
    if (didStartStored) {
        didStartStored(stored);
    }
    BOOL succeeds = [self.immediatelySuccessfulPaths containsObject:path]
            || [self.immediatelySuccessfulBookmarks containsObject:bookmark];
    if (!succeeds) {
        dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    }

    [_restorationStateLock lock];
    _activeRestorationCount--;
    [_restorationStateLock unlock];
    return succeeds ? @{ @"accessedURL": [NSURL fileURLWithPath:path],
                          @"bookmark": stored[@"bookmark"] } : nil;
}

- (void)releaseOneRestoration {
    dispatch_semaphore_signal(_restorationGate);
}

- (void)releaseRestorationWithBookmark:(NSData *)bookmark {
    [_restorationStateLock lock];
    dispatch_semaphore_t gate = _restorationGates[bookmark];
    if (!gate) {
        gate = dispatch_semaphore_create(0);
        _restorationGates[bookmark] = gate;
    }
    [_restorationStateLock unlock];
    dispatch_semaphore_signal(gate);
}

- (NSUInteger)activeRestorationCount {
    [_restorationStateLock lock];
    NSUInteger count = _activeRestorationCount;
    [_restorationStateLock unlock];
    return count;
}

- (NSUInteger)peakRestorationCount {
    [_restorationStateLock lock];
    NSUInteger count = _peakRestorationCount;
    [_restorationStateLock unlock];
    return count;
}

- (NSUInteger)startedRestorationCount {
    [_restorationStateLock lock];
    NSUInteger count = _startedRestorationCount;
    [_restorationStateLock unlock];
    return count;
}

- (NSArray<NSString *> *)startedRestorationPaths {
    [_restorationStateLock lock];
    NSArray<NSString *> *paths = [_startedRestorationPaths copy];
    [_restorationStateLock unlock];
    return paths;
}

- (NSArray<NSData *> *)startedRestorationBookmarks {
    [_restorationStateLock lock];
    NSArray<NSData *> *bookmarks = [_startedRestorationBookmarks copy];
    [_restorationStateLock unlock];
    return bookmarks;
}

@end

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

- (void)testRestorationIsBoundedAndPromotesAGrantNeededByAnOpen {
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

    NSUInteger concurrencyLimit = (NSUInteger)VibeFolderAccessRestoreConcurrencyLimit;
    NSUInteger utilityWorkerCount = concurrencyLimit - 1;
    NSUInteger restoreCount = concurrencyLimit + 3;
    NSMutableArray<NSDictionary *> *stored = [NSMutableArray arrayWithCapacity:restoreCount];
    for (NSUInteger index = 0; index < restoreCount; index++) {
        NSString *path = [NSString stringWithFormat:@"/Volumes/Restore-%lu", (unsigned long)index];
        NSData *bookmark = [[NSString stringWithFormat:@"bookmark-%lu", (unsigned long)index]
                dataUsingEncoding:NSUTF8StringEncoding];
        [stored addObject:@{@"path": path, @"bookmark": bookmark}];
    }
    [defaults setObject:stored forKey:key];

    BlockingFolderAccessManager *manager = [BlockingFolderAccessManager new];
    XCTestExpectation *initialWorkers = [self expectationWithDescription:@"bounded workers started"];
    initialWorkers.expectedFulfillmentCount = utilityWorkerCount;
    XCTestExpectation *nextWorker = [self expectationWithDescription:@"prioritized worker started"];
    manager.didStartRestoration = ^(NSUInteger count) {
        if (count <= utilityWorkerCount) {
            [initialWorkers fulfill];
        }
        else if (count == concurrencyLimit) {
            [nextWorker fulfill];
        }
    };

    XCTestExpectation *allSettled = [self expectationWithDescription:@"all restores settled"];
    [manager restoreGrantedAccessWithCompletion:^{
        [allSettled fulfill];
    }];
    [self waitForExpectations:@[initialWorkers] timeout:2.0];
    XCTAssertEqual(manager.activeRestorationCount, utilityWorkerCount);
    XCTAssertEqual(manager.peakRestorationCount, utilityWorkerCount);

    NSArray<NSString *> *started = manager.startedRestorationPaths;
    NSString *targetPath;
    for (NSDictionary *entry in stored) {
        if (![started containsObject:entry[@"path"]]) {
            targetPath = entry[@"path"];
            break;
        }
    }
    XCTAssertNotNil(targetPath);
    XCTestExpectation *targetSettled = [self expectationWithDescription:@"target restore settled"];
    NSURL *targetFile = [NSURL fileURLWithPath:[targetPath stringByAppendingPathComponent:@"Album/file.mp3"]];
    [manager awaitRestoredAccessForURLs:@[targetFile] completion:^{
        [targetSettled fulfill];
    }];

    [self waitForExpectations:@[nextWorker] timeout:2.0];
    XCTAssertEqualObjects(manager.startedRestorationPaths.lastObject, targetPath);
    XCTAssertEqual(manager.activeRestorationCount, concurrencyLimit);

    for (NSUInteger index = 0; index < restoreCount; index++) {
        [manager releaseOneRestoration];
    }
    [self waitForExpectations:@[targetSettled, allSettled] timeout:2.0];
    XCTAssertEqual(manager.startedRestorationCount, restoreCount);
    XCTAssertEqual(manager.activeRestorationCount, 0u);
    XCTAssertEqual(manager.peakRestorationCount, concurrencyLimit);
}

- (void)testNestedOpenPromotesSpecificGrantAndIgnoresStillRestoringParent {
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

    NSUInteger utilityWorkerCount =
            (NSUInteger)VibeFolderAccessRestoreConcurrencyLimit - 1;
    NSMutableArray<NSDictionary *> *stored = [NSMutableArray array];
    for (NSUInteger index = 0; index < utilityWorkerCount; index++) {
        NSString *path = [NSString stringWithFormat:@"/Volumes/Blocked-%lu",
                                                    (unsigned long)index];
        [stored addObject:@{ @"path": path,
                             @"bookmark": [path dataUsingEncoding:NSUTF8StringEncoding] }];
    }
    NSString *parentPath = @"/Volumes/Remembered Library";
    NSString *childPath = [parentPath stringByAppendingPathComponent:@"Current"];
    [stored addObject:@{ @"path": parentPath,
                         @"bookmark": [@"parent" dataUsingEncoding:NSUTF8StringEncoding] }];
    [stored addObject:@{ @"path": childPath,
                         @"bookmark": [@"child" dataUsingEncoding:NSUTF8StringEncoding] }];
    [defaults setObject:stored forKey:key];

    BlockingFolderAccessManager *manager = [BlockingFolderAccessManager new];
    manager.immediatelySuccessfulPaths = [NSSet setWithObject:childPath];
    XCTestExpectation *initialWorkers =
            [self expectationWithDescription:@"utility workers blocked"];
    initialWorkers.expectedFulfillmentCount = utilityWorkerCount;
    manager.didStartRestoration = ^(NSUInteger count) {
        if (count <= utilityWorkerCount) {
            [initialWorkers fulfill];
        }
    };

    XCTestExpectation *allSettled = [self expectationWithDescription:@"all restores settled"];
    [manager restoreGrantedAccessWithCompletion:^{
        [allSettled fulfill];
    }];
    [self waitForExpectations:@[initialWorkers] timeout:2.0];

    XCTestExpectation *openReleased =
            [self expectationWithDescription:@"nested active grant released open"];
    NSURL *file = [NSURL fileURLWithPath:
            [childPath stringByAppendingPathComponent:@"Album/file.mp3"]];
    [manager awaitRestoredAccessForURLs:@[file] completion:^{
        [openReleased fulfill];
    }];
    // The manager's deadline is two seconds; this must be the child grant
    // settling, not the fallback timer.
    [self waitForExpectations:@[openReleased] timeout:1.5];

    NSArray<NSString *> *started = manager.startedRestorationPaths;
    XCTAssertEqualObjects(started.lastObject, childPath);
    XCTAssertFalse([started containsObject:parentPath]);
    XCTAssertEqual(manager.activeRestorationCount, utilityWorkerCount);

    NSUInteger blockedCount = stored.count - manager.immediatelySuccessfulPaths.count;
    for (NSUInteger index = 0; index < blockedCount; index++) {
        [manager releaseOneRestoration];
    }
    [self waitForExpectations:@[allSettled] timeout:2.0];
    XCTAssertEqual(manager.startedRestorationCount, stored.count);
    XCTAssertEqual(manager.activeRestorationCount, 0u);
}

- (void)testRemovedQueuedChildDoesNotTakeUrgentLaneFromCoveringParent {
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

    NSUInteger utilityWorkerCount =
            (NSUInteger)VibeFolderAccessRestoreConcurrencyLimit - 1;
    NSMutableArray<NSDictionary *> *stored = [NSMutableArray array];
    for (NSUInteger index = 0; index < utilityWorkerCount; index++) {
        NSString *path = [NSString stringWithFormat:@"/Volumes/Blocked-Remove-%lu",
                                                    (unsigned long)index];
        [stored addObject:@{ @"path": path,
                             @"bookmark": [path dataUsingEncoding:NSUTF8StringEncoding] }];
    }
    NSString *parentPath = @"/Volumes/Remembered Parent";
    NSString *childPath = [parentPath stringByAppendingPathComponent:@"Removed Child"];
    [stored addObject:@{ @"path": parentPath,
                         @"bookmark": [@"parent" dataUsingEncoding:NSUTF8StringEncoding] }];
    [stored addObject:@{ @"path": childPath,
                         @"bookmark": [@"child" dataUsingEncoding:NSUTF8StringEncoding] }];
    [defaults setObject:stored forKey:key];

    BlockingFolderAccessManager *manager = [BlockingFolderAccessManager new];
    manager.immediatelySuccessfulPaths = [NSSet setWithObject:parentPath];
    XCTestExpectation *initialWorkers =
            [self expectationWithDescription:@"utility workers blocked"];
    initialWorkers.expectedFulfillmentCount = utilityWorkerCount;
    manager.didStartRestoration = ^(NSUInteger count) {
        if (count <= utilityWorkerCount) {
            [initialWorkers fulfill];
        }
    };

    XCTestExpectation *allSettled = [self expectationWithDescription:@"all restores settled"];
    [manager restoreGrantedAccessWithCompletion:^{
        [allSettled fulfill];
    }];
    [self waitForExpectations:@[initialWorkers] timeout:2.0];
    XCTAssertFalse([manager.startedRestorationPaths containsObject:parentPath]);
    XCTAssertFalse([manager.startedRestorationPaths containsObject:childPath]);

    [manager removeFoldersAtIndexes:
            [NSIndexSet indexSetWithIndex:stored.count - 1]];
    XCTestExpectation *openReleased =
            [self expectationWithDescription:@"covering parent released open"];
    NSURL *file = [NSURL fileURLWithPath:
            [childPath stringByAppendingPathComponent:@"Album/file.mp3"]];
    [manager awaitRestoredAccessForURLs:@[file] completion:^{
        [openReleased fulfill];
    }];
    // The removed child still has cleanup work in the utility queue, but it
    // must not occupy the urgent lane or force this open to its two-second
    // deadline.
    [self waitForExpectations:@[openReleased] timeout:1.5];

    NSArray<NSString *> *started = manager.startedRestorationPaths;
    XCTAssertEqualObjects(started.lastObject, parentPath);
    XCTAssertFalse([started containsObject:childPath]);
    XCTAssertEqual(manager.activeRestorationCount, utilityWorkerCount);
    XCTAssertLessThanOrEqual(manager.peakRestorationCount,
                             (NSUInteger)VibeFolderAccessRestoreConcurrencyLimit);

    NSUInteger blockedCount = stored.count - manager.immediatelySuccessfulPaths.count;
    for (NSUInteger index = 0; index < blockedCount; index++) {
        [manager releaseOneRestoration];
    }
    [self waitForExpectations:@[allSettled] timeout:2.0];
    XCTAssertEqual(manager.startedRestorationCount, stored.count);
    XCTAssertEqual(manager.activeRestorationCount, 0u);
    XCTAssertLessThanOrEqual(manager.peakRestorationCount,
                             (NSUInteger)VibeFolderAccessRestoreConcurrencyLimit);
}

- (void)testRemovingAlreadyPromotedChildWithdrawsItsUrgentAdmission {
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

    NSUInteger utilityWorkerCount =
            (NSUInteger)VibeFolderAccessRestoreConcurrencyLimit - 1;
    NSMutableArray<NSDictionary *> *stored = [NSMutableArray array];
    for (NSUInteger index = 0; index < utilityWorkerCount; index++) {
        NSString *path = [NSString stringWithFormat:@"/Volumes/Urgent-Utility-%lu",
                                                    (unsigned long)index];
        [stored addObject:@{ @"path": path,
                             @"bookmark": [path dataUsingEncoding:NSUTF8StringEncoding] }];
    }
    NSString *urgentBlockerPath = @"/Volumes/Urgent Blocker";
    NSData *urgentBlockerBookmark = [@"urgent-blocker" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *parentPath = @"/Volumes/Urgent Parent";
    NSData *parentBookmark = [@"urgent-parent" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *childPath = [parentPath stringByAppendingPathComponent:@"Removed Child"];
    NSData *childBookmark = [@"urgent-child" dataUsingEncoding:NSUTF8StringEncoding];
    [stored addObject:@{ @"path": urgentBlockerPath,
                         @"bookmark": urgentBlockerBookmark }];
    [stored addObject:@{ @"path": parentPath, @"bookmark": parentBookmark }];
    [stored addObject:@{ @"path": childPath, @"bookmark": childBookmark }];
    [defaults setObject:stored forKey:key];

    BlockingFolderAccessManager *manager = [BlockingFolderAccessManager new];
    manager.immediatelySuccessfulBookmarks = [NSSet setWithObject:parentBookmark];
    manager.dedicatedGateBookmarks = [NSSet setWithObjects:urgentBlockerBookmark,
                                                               childBookmark, nil];
    XCTestExpectation *initialWorkers =
            [self expectationWithDescription:@"utility workers blocked"];
    initialWorkers.expectedFulfillmentCount = utilityWorkerCount;
    XCTestExpectation *urgentBlockerStarted =
            [self expectationWithDescription:@"urgent lane occupied"];
    XCTestExpectation *parentStarted =
            [self expectationWithDescription:@"covering parent entered urgent lane"];
    manager.didStartRestoration = ^(NSUInteger count) {
        if (count <= utilityWorkerCount) {
            [initialWorkers fulfill];
        }
    };
    manager.didStartStoredRestoration = ^(NSDictionary *entry) {
        NSData *bookmark = entry[@"bookmark"];
        if ([bookmark isEqual:urgentBlockerBookmark]) {
            [urgentBlockerStarted fulfill];
        }
        else if ([bookmark isEqual:parentBookmark]) {
            [parentStarted fulfill];
        }
    };

    XCTestExpectation *allSettled = [self expectationWithDescription:@"all restores settled"];
    [manager restoreGrantedAccessWithCompletion:^{
        [allSettled fulfill];
    }];
    [self waitForExpectations:@[initialWorkers] timeout:2.0];

    XCTestExpectation *blockerReleased =
            [self expectationWithDescription:@"urgent blocker settled"];
    NSURL *blockerFile = [NSURL fileURLWithPath:
            [urgentBlockerPath stringByAppendingPathComponent:@"file.mp3"]];
    [manager awaitRestoredAccessForURLs:@[blockerFile] completion:^{
        [blockerReleased fulfill];
    }];
    [self waitForExpectations:@[urgentBlockerStarted] timeout:1.0];

    XCTestExpectation *openReleased =
            [self expectationWithDescription:@"covering parent released open"];
    NSURL *childFile = [NSURL fileURLWithPath:
            [childPath stringByAppendingPathComponent:@"Album/file.mp3"]];
    [manager awaitRestoredAccessForURLs:@[childFile] completion:^{
        [openReleased fulfill];
    }];
    // The child is now admitted behind the executing urgent blocker. Removal
    // must withdraw that admission before the parent is enqueued.
    [manager removeFoldersAtIndexes:
            [NSIndexSet indexSetWithIndex:stored.count - 1]];
    [manager releaseRestorationWithBookmark:urgentBlockerBookmark];
    [self waitForExpectations:@[blockerReleased, parentStarted, openReleased]
                      timeout:1.5];

    NSArray<NSData *> *started = manager.startedRestorationBookmarks;
    XCTAssertEqualObjects(started.lastObject, parentBookmark);
    XCTAssertFalse([started containsObject:childBookmark]);
    XCTAssertLessThanOrEqual(manager.peakRestorationCount,
                             (NSUInteger)VibeFolderAccessRestoreConcurrencyLimit);

    [manager releaseRestorationWithBookmark:childBookmark];
    for (NSUInteger index = 0; index < utilityWorkerCount; index++) {
        [manager releaseOneRestoration];
    }
    [self waitForExpectations:@[allSettled] timeout:2.0];
    XCTAssertEqual(manager.startedRestorationCount, stored.count);
    XCTAssertEqual(manager.activeRestorationCount, 0u);
    XCTAssertLessThanOrEqual(manager.peakRestorationCount,
                             (NSUInteger)VibeFolderAccessRestoreConcurrencyLimit);
}

- (void)testRemovingOneDuplicateStillWaitsForTheSurvivingRestoration {
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

    NSUInteger utilityWorkerCount =
            (NSUInteger)VibeFolderAccessRestoreConcurrencyLimit - 1;
    NSMutableArray<NSDictionary *> *stored = [NSMutableArray array];
    for (NSUInteger index = 0; index < utilityWorkerCount; index++) {
        NSString *path = [NSString stringWithFormat:@"/Volumes/Duplicate-Utility-%lu",
                                                    (unsigned long)index];
        [stored addObject:@{ @"path": path,
                             @"bookmark": [path dataUsingEncoding:NSUTF8StringEncoding] }];
    }
    NSString *duplicatePath = @"/Volumes/Duplicate Library";
    NSData *removedBookmark = [@"duplicate-removed" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *survivingBookmark = [@"duplicate-surviving" dataUsingEncoding:NSUTF8StringEncoding];
    [stored addObject:@{ @"path": duplicatePath, @"bookmark": removedBookmark }];
    [stored addObject:@{ @"path": duplicatePath, @"bookmark": survivingBookmark }];
    [defaults setObject:stored forKey:key];

    BlockingFolderAccessManager *manager = [BlockingFolderAccessManager new];
    manager.immediatelySuccessfulBookmarks = [NSSet setWithObject:survivingBookmark];
    XCTestExpectation *initialWorkers =
            [self expectationWithDescription:@"utility workers blocked"];
    initialWorkers.expectedFulfillmentCount = utilityWorkerCount;
    manager.didStartRestoration = ^(NSUInteger count) {
        if (count <= utilityWorkerCount) {
            [initialWorkers fulfill];
        }
    };

    XCTestExpectation *allSettled = [self expectationWithDescription:@"all restores settled"];
    [manager restoreGrantedAccessWithCompletion:^{
        [allSettled fulfill];
    }];
    [self waitForExpectations:@[initialWorkers] timeout:2.0];
    [manager removeFoldersAtIndexes:
            [NSIndexSet indexSetWithIndex:utilityWorkerCount]];

    XCTestExpectation *openReleased =
            [self expectationWithDescription:@"surviving duplicate released open"];
    NSURL *file = [NSURL fileURLWithPath:
            [duplicatePath stringByAppendingPathComponent:@"Album/file.mp3"]];
    [manager awaitRestoredAccessForURLs:@[file] completion:^{
        [openReleased fulfill];
    }];
    [self waitForExpectations:@[openReleased] timeout:1.5];

    XCTAssertEqualObjects(manager.startedRestorationBookmarks.lastObject,
                          survivingBookmark);
    XCTAssertFalse([manager.startedRestorationBookmarks containsObject:removedBookmark]);
    XCTAssertEqual(manager.grantedFolders.lastObject.state,
                   VibeGrantedFolderStateActive);

    for (NSUInteger index = 0; index <= utilityWorkerCount; index++) {
        [manager releaseOneRestoration];
    }
    [self waitForExpectations:@[allSettled] timeout:2.0];
    XCTAssertEqual(manager.startedRestorationCount, stored.count);
    XCTAssertEqual(manager.activeRestorationCount, 0u);
}

- (void)testDuplicateBookmarksRestoreTheirOwnRows {
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

    NSString *path = @"/Volumes/Identical Duplicate";
    NSData *bookmark = [@"identical-duplicate" dataUsingEncoding:NSUTF8StringEncoding];
    [defaults setObject:@[@{ @"path": path, @"bookmark": bookmark },
                          @{ @"path": path, @"bookmark": bookmark }]
                  forKey:key];

    BlockingFolderAccessManager *manager = [BlockingFolderAccessManager new];
    manager.immediatelySuccessfulBookmarks = [NSSet setWithObject:bookmark];
    XCTestExpectation *allSettled = [self expectationWithDescription:@"duplicates settled"];
    [manager restoreGrantedAccessWithCompletion:^{
        [allSettled fulfill];
    }];
    [self waitForExpectations:@[allSettled] timeout:2.0];

    XCTAssertEqual(manager.grantedFolders.count, 2u);
    for (VibeGrantedFolder *folder in manager.grantedFolders) {
        XCTAssertEqual(folder.state, VibeGrantedFolderStateActive);
    }
}

- (void)testReactivatedAliasIsNotOverwrittenByItsOldRestoration {
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

    NSUInteger utilityWorkerCount =
            (NSUInteger)VibeFolderAccessRestoreConcurrencyLimit - 1;
    NSMutableArray<NSDictionary *> *stored = [NSMutableArray array];
    for (NSUInteger index = 0; index < utilityWorkerCount; index++) {
        NSString *path = [NSString stringWithFormat:@"/Volumes/Reactivate-Utility-%lu",
                                                    (unsigned long)index];
        [stored addObject:@{ @"path": path,
                             @"bookmark": [path dataUsingEncoding:NSUTF8StringEncoding] }];
    }
    NSString *oldPath = @"/private/tmp/Vibe Reactivated";
    NSString *newPath = @"/tmp/Vibe Reactivated";
    NSData *bookmark = [@"reactivated" dataUsingEncoding:NSUTF8StringEncoding];
    [stored addObject:@{ @"path": oldPath, @"bookmark": bookmark }];
    [defaults setObject:stored forKey:key];

    BlockingFolderAccessManager *manager = [BlockingFolderAccessManager new];
    manager.immediatelySuccessfulBookmarks = [NSSet setWithObject:bookmark];
    XCTestExpectation *initialWorkers =
            [self expectationWithDescription:@"utility workers blocked"];
    initialWorkers.expectedFulfillmentCount = utilityWorkerCount;
    manager.didStartRestoration = ^(NSUInteger count) {
        if (count <= utilityWorkerCount) {
            [initialWorkers fulfill];
        }
    };

    XCTestExpectation *allSettled = [self expectationWithDescription:@"all restores settled"];
    [manager restoreGrantedAccessWithCompletion:^{
        [allSettled fulfill];
    }];
    [self waitForExpectations:@[initialWorkers] timeout:2.0];
    [manager mergeAdditions:@[@{ @"path": newPath, @"bookmark": bookmark }]];

    for (NSUInteger index = 0; index < utilityWorkerCount; index++) {
        [manager releaseOneRestoration];
    }
    [self waitForExpectations:@[allSettled] timeout:2.0];

    NSDictionary *persisted = [defaults arrayForKey:key].lastObject;
    XCTAssertEqualObjects(persisted[@"path"], newPath);
    XCTAssertEqualObjects(persisted[@"bookmark"], bookmark);
    XCTAssertEqualObjects(manager.grantedFolders.lastObject.path, newPath);
    XCTAssertEqual(manager.grantedFolders.lastObject.state,
                   VibeGrantedFolderStateActive);
}


#pragma mark - The path rules themselves

// FolderAccessRules.h, reached without the manager, the sandbox or defaults.

- (void)testFolderCoverageMatchesTheFolderAndItsDescendants {
    XCTAssertTrue(VibePathIsUnderFolder(@"/Volumes/Music", @"/Volumes/Music"));
    XCTAssertTrue(VibePathIsUnderFolder(@"/Volumes/Music/Set/a.mp3", @"/Volumes/Music"));
    // A sibling whose name merely starts the same is not covered.
    XCTAssertFalse(VibePathIsUnderFolder(@"/Volumes/Music2/a.mp3", @"/Volumes/Music"));
    XCTAssertFalse(VibePathIsUnderFolder(@"/Volumes", @"/Volumes/Music"));
    XCTAssertFalse(VibePathIsUnderFolder(@"", @"/Volumes/Music"));
    XCTAssertFalse(VibePathIsUnderFolder(@"/Volumes/Music", @""));
}

// The canonical form must NOT match a differently-cased spelling: on a
// case-sensitive volume those are genuinely different folders, and treating
// them as one would skip a bookmark the app needs.
- (void)testCanonicalFolderCoverageIsCaseSensitive {
    XCTAssertFalse(VibePathIsUnderFolder(@"/Volumes/music/a.mp3", @"/Volumes/Music"));
}

// The uncanonical form errs the other way, which is the safe direction: an
// open spelled differently by Launch Services still waits for the grant it
// probably needs.
- (void)testUncanonicalFolderCoverageIsCaseInsensitive {
    XCTAssertTrue(VibeUncanonicalPathIsUnderFolder(@"/Volumes/music/a.mp3", @"/Volumes/Music"));
    XCTAssertTrue(VibeUncanonicalPathIsUnderFolder(@"/VOLUMES/MUSIC", @"/Volumes/Music"));
    XCTAssertFalse(VibeUncanonicalPathIsUnderFolder(@"/Volumes/Music2/a.mp3", @"/Volumes/Music"));
    XCTAssertFalse(VibeUncanonicalPathIsUnderFolder(@"", @"/Volumes/Music"));
}

@end
