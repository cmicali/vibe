// FolderSession as itself: the real prologue, work queues, walk, bookmarks
// and landing, over folders in a temp root. A landing reaches main only when
// the test spins it, so two requests made in one turn race as a user's taps do.

#import "IOSShellTestCase.h"

#import "AudioTrack.h"
#import "DropboxClientInternal.h"
#import "DropboxMirror.h"
#import "DropboxStubProtocol.h"
#import "FavoritesStore.h"
#import "FilePaths.h"
#import "FolderSessionInternal.h"
#import "PlaylistRowTestSupport.h"
#import "LinkStore.h"
#import "LocationStore.h"
#import "RecentsStore.h"
#import "TestFilesystemGuard.h"

@interface FolderSessionRecorder : NSObject <FolderSessionDelegate>
// Each event as {kind, names, folder, selected, restored}.
@property (nonatomic, readonly) NSMutableArray<NSDictionary *> *events;
@end

@implementation FolderSessionRecorder

- (instancetype)init {
    self = [super init];
    if (self) {
        _events = [NSMutableArray array];
    }
    return self;
}

- (void)folderSession:(FolderSession *)session
        didOpenTracks:(NSArray<AudioTrack *> *)rows
            folderURL:(NSURL *)folderURL
          selectedURL:(NSURL *)selectedURL
             restored:(BOOL)restored {
    [_events addObject:@{@"kind": @"open", @"names": NamesOf(rows),
                         @"folder": folderURL.lastPathComponent ?: @"",
                         @"selected": selectedURL.lastPathComponent ?: @"",
                         @"restored": @(restored)}];
}

- (void)folderSession:(FolderSession *)session didAppendTracks:(NSArray<AudioTrack *> *)rows {
    [_events addObject:@{@"kind": @"append", @"names": NamesOf(rows)}];
}

- (void)folderSessionDidOpenEmptyFolder:(FolderSession *)session {
    [_events addObject:@{@"kind": @"empty"}];
}

- (void)folderSessionRestoreDidFail:(FolderSession *)session {
    [_events addObject:@{@"kind": @"restoreFailed"}];
}

- (void)folderSession:(FolderSession *)session
        needsFolderOfSheetAtURL:(NSURL *)sheetURL
                      appending:(BOOL)appending {
    [_events addObject:@{@"kind": @"needsFolder", @"names": sheetURL.lastPathComponent.stringByDeletingPathExtension}];
}

@end

@interface FolderSession (TestDrain)
- (void)drainQueues;
@end

@implementation FolderSession (TestDrain)

// Every work item submitted so far has finished, and with it its post to main.
- (void)drainQueues {
    dispatch_barrier_sync(_workQueue, ^{});
    dispatch_sync(_appendQueue, ^{});
}

@end

@interface FolderSessionTests : IOSShellTestCase
@end

@implementation FolderSessionTests {
    FolderSession *_session;
    FolderSessionRecorder *_recorder;
    // Each holds two songs, named for the folder.
    NSURL *_albumA;
    NSURL *_albumB;
    NSURL *_albumC;
    NSURL *_empty;
}

- (void)setUp {
    [super setUp];
    _recorder = [[FolderSessionRecorder alloc] init];
    _session = [self newSession];
    _albumA = [self album:@"A"];
    _albumB = [self album:@"B"];
    _albumC = [self album:@"C"];
    _empty = [self folder:@"Empty"];
    [self file:@"Empty/notes.txt"];
}

- (void)tearDown {
    [self drain];
    [_session clearSession];
    [super tearDown];
}

// Runs what the session's queues hold and then the landings they posted, so
// a negative check needs no fixed window.
- (void)drain {
    [_session drainQueues];
    VibeSpinFor(0);
}

- (FolderSession *)newSession {
    FolderSession *session = [[FolderSession alloc] init];
    session.delegate = _recorder;
    return session;
}

- (NSURL *)album:(NSString *)name {
    [self file:[name stringByAppendingPathComponent:[name stringByAppendingString:@"1.mp3"]]];
    [self file:[name stringByAppendingPathComponent:[name stringByAppendingString:@"2.mp3"]]];
    return [self folder:name];
}

- (NSDictionary *)waitForEvent:(NSUInteger)index {
    XCTAssertTrue([self eventually:^BOOL { return self->_recorder.events.count > index; }],
                  @"event %lu never arrived", (unsigned long)index);
    return _recorder.events.count > index ? _recorder.events[index] : nil;
}

- (void)land:(NSURL *)url {
    NSUInteger before = _recorder.events.count;
    [_session openURLs:@[url] openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:before][@"kind"], @"open");
}

- (NSData *)storedBase {
    return [NSUserDefaults.standardUserDefaults dataForKey:kFolderBookmarkKey];
}

- (NSArray *)storedAdditions {
    return [NSUserDefaults.standardUserDefaults arrayForKey:kAdditionBookmarksKey];
}

#pragma mark - Opening

- (void)testAFolderOpenBecomesTheBaseAndIsRemembered {
    [_session openURLs:@[_albumA] openInPlace:YES];
    NSDictionary *event = [self waitForEvent:0];
    XCTAssertEqualObjects(event[@"kind"], @"open");
    XCTAssertEqualObjects(event[@"names"], @"A1 A2");
    XCTAssertEqualObjects(event[@"folder"], @"A");
    XCTAssertEqualObjects(event[@"restored"], @NO);
    XCTAssertEqualObjects(_session.folderURL.lastPathComponent, @"A");
    XCTAssertEqualObjects(_session.folderDisplayName, @"A");
    XCTAssertEqual(_session.searchRoots.count, 1u);
    XCTAssertFalse(_session.hasAdditions);
    XCTAssertNotNil(self.storedBase);
    XCTAssertNil(self.storedAdditions);
    XCTAssertTrue([self eventually:^BOOL { return RecentsStore.shared.recentItems.count == 1; }]);
    NSDictionary *recent = RecentsStore.shared.recentItems.firstObject;
    XCTAssertEqualObjects(recent[@"path"], VibeComparablePath(_albumA.path));
    XCTAssertEqualObjects(recent[@"folder"], @YES);
    XCTAssertNotNil(recent[@"bookmark"]);
}

- (void)testAReplaceOvertakesAnOlderOpen {
    [_session openURLs:@[_albumA] openInPlace:YES];
    [_session openURLs:@[_albumB] openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:0][@"folder"], @"B");
    [self drain];
    XCTAssertEqual(_recorder.events.count, 1u, @"%@", _recorder.events);
    XCTAssertEqualObjects(_session.folderURL.lastPathComponent, @"B");
}

- (void)testOneDeliveryNamesEachTrackOnceAndARedundantURLIsNotPersisted {
    [_session openURLs:@[_albumA, _albumA] openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:0][@"names"], @"A1 A2");
    XCTAssertNotNil(self.storedBase);
    XCTAssertNil(self.storedAdditions);
}

- (void)testTheBaseIsTheFirstContributorEvenAFile {
    NSURL *song = [self file:@"Loose/Song.mp3"];
    [_session openURLs:@[song, _albumB] openInPlace:YES];
    NSDictionary *event = [self waitForEvent:0];
    XCTAssertEqualObjects(event[@"names"], @"Song B1 B2");
    XCTAssertEqualObjects(event[@"folder"], @"");
    XCTAssertNil(_session.folderURL);
    XCTAssertNil(_session.folderDisplayName);
    XCTAssertEqualObjects([_session.searchRoots valueForKey:@"lastPathComponent"], @[@"B"]);
    // The folder behind it persists as an addition, never as the base.
    NSURL *base = [NSURL URLByResolvingBookmarkData:self.storedBase options:0 relativeToURL:nil
                                bookmarkDataIsStale:NULL error:NULL];
    XCTAssertEqualObjects(base.lastPathComponent, @"Song.mp3");
    XCTAssertEqual(self.storedAdditions.count, 1u);
}

- (void)testAFileOpenedAloneWithNoCoveringRootIsOneTrack {
    NSURL *song = [_albumA URLByAppendingPathComponent:@"A2.mp3"];
    [_session openURL:song inFolder:YES];
    NSDictionary *event = [self waitForEvent:0];
    XCTAssertEqualObjects(event[@"names"], @"A2");
    XCTAssertEqualObjects(event[@"folder"], @"");
    XCTAssertEqualObjects(event[@"selected"], @"");
}

- (void)testAFileOpenedInItsFolderUnderALocationExpandsSelected {
    XCTAssertTrue([LocationStore.shared addFolderURL:_albumA]);
    NSURL *song = [_albumA URLByAppendingPathComponent:@"A2.mp3"];
    [_session openURL:song inFolder:YES];
    NSDictionary *event = [self waitForEvent:0];
    XCTAssertEqualObjects(event[@"names"], @"A1 A2");
    XCTAssertEqualObjects(event[@"folder"], @"A");
    XCTAssertEqualObjects(event[@"selected"], @"A2.mp3");
}

- (void)testAnInboxCopyIsOneTrackAndNeverBookmarked {
    NSURL *song = [_albumA URLByAppendingPathComponent:@"A1.mp3"];
    XCTAssertTrue([LocationStore.shared addFolderURL:_albumA]);
    [_session openURLs:@[song] openInPlace:NO];
    XCTAssertEqualObjects([self waitForEvent:0][@"names"], @"A1");
    XCTAssertNil(self.storedBase, @"an inbox copy is never bookmarked");
}

- (void)testAnOpenThatFindsNothingReportsAnEmptyFolder {
    [_session openURLs:@[_empty] openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:0][@"kind"], @"empty");
    XCTAssertNil(_session.folderURL);
    XCTAssertNil(self.storedBase);
}

#pragma mark - Adding

- (void)testAnAddAppendsAndPersistsBesideTheBase {
    [self land:_albumA];
    [_session addURLs:@[_albumB]];
    NSDictionary *event = [self waitForEvent:1];
    XCTAssertEqualObjects(event[@"kind"], @"append");
    XCTAssertEqualObjects(event[@"names"], @"B1 B2");
    XCTAssertTrue(_session.hasAdditions);
    XCTAssertEqualObjects(_session.folderURL.lastPathComponent, @"A", @"an Add never moves the base");
    XCTAssertEqualObjects([_session.searchRoots valueForKey:@"lastPathComponent"], (@[@"A", @"B"]));
    XCTAssertEqual(self.storedAdditions.count, 1u);
}

- (void)testAnAddedFileIsOneTrackNeverItsDirectory {
    XCTAssertTrue([LocationStore.shared addFolderURL:_albumB]);
    [self land:_albumA];
    [_session addURLs:@[[_albumB URLByAppendingPathComponent:@"B2.mp3"]]];
    XCTAssertEqualObjects([self waitForEvent:1][@"names"], @"B2");
    XCTAssertEqualObjects([_session.searchRoots valueForKey:@"lastPathComponent"], @[@"A"],
                          @"a single added file is a scope, not a root");
}

- (void)testAnAppendThatFindsNothingIsStillDelivered {
    [self land:_albumA];
    [_session addURLs:@[_empty]];
    NSDictionary *event = [self waitForEvent:1];
    XCTAssertEqualObjects(event[@"kind"], @"append");
    XCTAssertEqualObjects(event[@"names"], @"");
    XCTAssertFalse(_session.hasAdditions);
}

- (void)testAnAddOntoNothingIsPromotedToAnOpen {
    [_session addURLs:@[_albumA]];
    NSDictionary *event = [self waitForEvent:0];
    XCTAssertEqualObjects(event[@"kind"], @"open");
    XCTAssertEqualObjects(event[@"folder"], @"A");
    XCTAssertFalse(_session.hasAdditions);
}

// TRAP: only the first promotes. Two promotions would supersede each other.
- (void)testOnlyTheFirstAddOntoNothingPromotesAndTheRestAppendAfterIt {
    [_session addURLs:@[_albumA]];
    [_session addURLs:@[_albumB]];
    [_session addURLs:@[_albumC]];
    XCTAssertEqualObjects([self waitForEvent:0][@"kind"], @"open");
    XCTAssertEqualObjects([self waitForEvent:1][@"names"], @"B1 B2");
    XCTAssertEqualObjects([self waitForEvent:2][@"names"], @"C1 C2");
    XCTAssertEqualObjects(_recorder.events[1][@"kind"], @"append");
    XCTAssertEqualObjects(_recorder.events[2][@"kind"], @"append");
}

// TRAP: a promotion is not a supersession. A token taken before it is still
// the user's.
- (void)testATokenTakenBeforeAPromotionStillLands {
    uint64_t token = [_session addRequestToken];
    [_session addURLs:@[_albumA]];
    [_session addURLs:@[_albumB] token:token];
    XCTAssertEqualObjects([self waitForEvent:0][@"kind"], @"open");
    NSDictionary *event = [self waitForEvent:1];
    XCTAssertEqualObjects(event[@"kind"], @"append");
    XCTAssertEqualObjects(event[@"names"], @"B1 B2");
}

- (void)testAnAddWhoseTokenAReplaceOvertookIsDropped {
    [self land:_albumA];
    uint64_t token = [_session addRequestToken];
    [_session openURLs:@[_albumB] openInPlace:YES];
    [_session addURLs:@[_albumC] token:token];
    XCTAssertEqualObjects([self waitForEvent:1][@"folder"], @"B");
    [self drain];
    XCTAssertEqual(_recorder.events.count, 2u, @"%@", _recorder.events);
    XCTAssertFalse(_session.hasAdditions);
}

- (void)testAReplaceReleasesTheParkedAddsOntoItsOwnPlaylist {
    [_session addURLs:@[_albumA]];
    [_session addURLs:@[_albumB]];
    [_session openURLs:@[_albumC] openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:0][@"folder"], @"C");
    NSDictionary *event = [self waitForEvent:1];
    XCTAssertEqualObjects(event[@"kind"], @"append");
    XCTAssertEqualObjects(event[@"names"], @"B1 B2");
    [self drain];
    XCTAssertEqual(_recorder.events.count, 2u, @"the superseded promotion never lands: %@", _recorder.events);
}

// TRAP: an empty open settles its generation, or Add is dead for the session.
- (void)testAnEmptyOpenLeavesAddWorkingOnThePlaylistStanding {
    [self land:_albumA];
    [_session openURLs:@[_empty] openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:1][@"kind"], @"empty");
    XCTAssertEqualObjects(_session.folderURL.lastPathComponent, @"A");
    [_session addURLs:@[_albumB]];
    XCTAssertEqualObjects([self waitForEvent:2][@"kind"], @"append");
}

- (void)testAnEmptyOpenOntoNothingLeavesTheNextAddPromoted {
    [_session openURLs:@[_empty] openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:0][@"kind"], @"empty");
    [_session addURLs:@[_albumA]];
    XCTAssertEqualObjects([self waitForEvent:1][@"kind"], @"open");
}

- (void)testACancelledOpenNeverLandsAndAddStillWorks {
    [self land:_albumA];
    [_session openURLs:@[_albumB] openInPlace:YES];
    [_session cancelOpen];
    [self drain];
    XCTAssertEqual(_recorder.events.count, 1u, @"%@", _recorder.events);
    XCTAssertEqualObjects(_session.folderURL.lastPathComponent, @"A");
    [_session addURLs:@[_albumC]];
    XCTAssertEqualObjects([self waitForEvent:1][@"kind"], @"append");
}

- (void)testClearingForgetsTheSessionAndItsKeys {
    [self land:_albumA];
    _session.persistedTrackKey = @"/A/A1.mp3";
    [_session clearSession];
    XCTAssertNil(_session.folderURL);
    XCTAssertEqualObjects(_session.searchRoots, @[]);
    XCTAssertNil(self.storedBase);
    XCTAssertNil(_session.persistedTrackKey);
    XCTAssertFalse([_session restorePersistedFolder]);
    [_session addURLs:@[_albumB]];
    XCTAssertEqualObjects([self waitForEvent:1][@"kind"], @"open", @"an Add after a clear opens");
    XCTAssertEqual(RecentsStore.shared.recentItems.count, 2u, @"a clear keeps the recents");
}

#pragma mark - The restored playlist

- (void)testARelaunchRestoresTheBaseThenItsAdditions {
    [self land:_albumA];
    [_session addURLs:@[_albumB]];
    XCTAssertEqualObjects([self waitForEvent:1][@"kind"], @"append");
    _session.persistedTrackKey = @"key";

    FolderSession *relaunched = [self newSession];
    XCTAssertTrue([relaunched restorePersistedFolder]);
    NSDictionary *event = [self waitForEvent:2];
    XCTAssertEqualObjects(event[@"kind"], @"open");
    XCTAssertEqualObjects(event[@"names"], @"A1 A2 B1 B2");
    XCTAssertEqualObjects(event[@"folder"], @"A");
    XCTAssertEqualObjects(event[@"restored"], @YES);
    XCTAssertTrue(relaunched.hasAdditions);
    XCTAssertEqualObjects(relaunched.persistedTrackKey, @"key");
    XCTAssertEqual(RecentsStore.shared.recentItems.count, 2u, @"a restore records nothing");
    [relaunched clearSession];
}

- (void)testARestoreKeepsTheSurvivorsWhenTheBaseIsGone {
    [self land:_albumA];
    [_session addURLs:@[_albumB]];
    XCTAssertEqualObjects([self waitForEvent:1][@"kind"], @"append");
    [NSFileManager.defaultManager removeItemAtURL:_albumA error:NULL];

    FolderSession *relaunched = [self newSession];
    XCTAssertTrue([relaunched restorePersistedFolder]);
    NSDictionary *event = [self waitForEvent:2];
    XCTAssertEqualObjects(event[@"names"], @"B1 B2");
    XCTAssertEqualObjects(event[@"folder"], @"B", @"the first survivor becomes the base");
    NSURL *base = [NSURL URLByResolvingBookmarkData:self.storedBase options:0 relativeToURL:nil
                                bookmarkDataIsStale:NULL error:NULL];
    XCTAssertEqualObjects(base.lastPathComponent, @"B");
    XCTAssertNil(self.storedAdditions);
    [relaunched clearSession];
}

- (void)testARestoreWithNothingResolvableFailsAndForgetsTheKeys {
    [NSUserDefaults.standardUserDefaults setObject:[@"not a bookmark" dataUsingEncoding:NSUTF8StringEncoding]
                                            forKey:kFolderBookmarkKey];
    XCTAssertTrue([_session restorePersistedFolder]);
    XCTAssertEqualObjects([self waitForEvent:0][@"kind"], @"restoreFailed");
    XCTAssertNil(self.storedBase);
}

- (void)testARestoreWhoseFoldersEmptiedFailsButKeepsTheKeys {
    [self land:_albumA];
    for (NSString *name in @[@"A1.mp3", @"A2.mp3"]) {
        [NSFileManager.defaultManager removeItemAtURL:[_albumA URLByAppendingPathComponent:name] error:NULL];
    }
    FolderSession *relaunched = [self newSession];
    XCTAssertTrue([relaunched restorePersistedFolder]);
    XCTAssertEqualObjects([self waitForEvent:1][@"kind"], @"restoreFailed");
    XCTAssertNotNil(self.storedBase);
}

#pragma mark - What becomes the bookmark

- (void)testAnInboxCopyLeavesTheBookmarkAndMakesLaterAddsSessionOnly {
    [self land:_albumA];
    NSData *base = self.storedBase;
    [_session openURLs:@[[self file:@"Inbox/Copy.mp3"]] openInPlace:NO];
    XCTAssertEqualObjects([self waitForEvent:1][@"names"], @"Copy");
    [_session addURLs:@[_albumB]];
    XCTAssertEqualObjects([self waitForEvent:2][@"kind"], @"append");
    XCTAssertEqualObjects(self.storedBase, base);
    XCTAssertNil(self.storedAdditions);
}

- (void)testAOneFileOpenKeepsAFolderBookmark {
    [self land:_albumA];
    NSData *base = self.storedBase;
    [_session openURL:[self file:@"Loose/Song.mp3"] inFolder:NO];
    XCTAssertEqualObjects([self waitForEvent:1][@"names"], @"Song");
    XCTAssertEqualObjects(self.storedBase, base);
}

- (void)testALinkOpenedAloneIsPersistedAsAOneFileBase {
    [self land:_albumA];
    NSURL *links = LinkStore.shared.rootURL;
    NSURL *link = [links URLByAppendingPathComponent:@"hash/Stream.mp3"];
    [NSFileManager.defaultManager createDirectoryAtURL:link.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:NULL];
    [[NSData dataWithBytes:"x" length:1] writeToURL:link atomically:YES];
    [_session openURL:link inFolder:YES];
    NSDictionary *event = [self waitForEvent:1];
    XCTAssertEqualObjects(event[@"names"], @"Stream", @"a link never expands to its hashed folder");
    NSURL *base = [NSURL URLByResolvingBookmarkData:self.storedBase options:0 relativeToURL:nil
                                bookmarkDataIsStale:NULL error:NULL];
    XCTAssertEqualObjects(base.lastPathComponent, @"Stream.mp3");
    [NSFileManager.defaultManager removeItemAtURL:link.URLByDeletingLastPathComponent error:NULL];
}

#pragma mark - Recents

- (void)testAnOpenOfMoreThanFiveRecordsTheFolderTheyShare {
    XCTAssertTrue([LocationStore.shared addFolderURL:[self folder:@"Library"]]);
    NSMutableArray<NSURL *> *albums = [NSMutableArray array];
    for (NSUInteger i = 0; i < 6; i++) {
        NSString *name = [NSString stringWithFormat:@"Library/Album%lu", (unsigned long)i];
        [self file:[name stringByAppendingPathComponent:@"Song.mp3"]];
        [albums addObject:[self folder:name]];
    }
    [_session openURLs:albums openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:0][@"kind"], @"open");
    XCTAssertTrue([self eventually:^BOOL { return RecentsStore.shared.recentItems.count > 0; }]);
    NSArray *recents = RecentsStore.shared.recentItems;
    XCTAssertEqual(recents.count, 1u);
    XCTAssertEqualObjects(recents.firstObject[@"path"],
                          VibeComparablePath([self.root URLByAppendingPathComponent:@"Library"].path));
    XCTAssertEqualObjects(recents.firstObject[@"folder"], @YES);
    XCTAssertEqualObjects(recents.firstObject[@"location"], self.root.lastPathComponent,
                          @"named by the folder it sits in");
}

- (void)testAnOpenOfFiveRecordsEachNewestFirstInPickOrder {
    [_session openURLs:@[_albumA, _albumB] openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:0][@"kind"], @"open");
    XCTAssertTrue([self eventually:^BOOL { return RecentsStore.shared.recentItems.count == 2; }]);
    NSArray *paths = [RecentsStore.shared.recentItems valueForKey:@"path"];
    XCTAssertEqualObjects(paths, (@[VibeComparablePath(_albumA.path), VibeComparablePath(_albumB.path)]));
}

#pragma mark - Starring

- (void)testTheOpenFolderIsBookmarkedForTheStar {
    [self land:_albumA];
    XCTestExpectation *minted = [self expectationWithDescription:@"minted"];
    [_session bookmarkOpenFolderWithCompletion:^(NSURL *folderURL, NSData *bookmark) {
        XCTAssertEqualObjects(folderURL.lastPathComponent, @"A");
        XCTAssertNotNil(bookmark);
        [minted fulfill];
    }];
    [self waitForExpectations:@[minted] timeout:VIBE_TEST_HANG_TIMEOUT];
}

- (void)testAOneFileBaseHasNothingToStar {
    [_session openURL:[self file:@"Loose/Song.mp3"] inFolder:NO];
    XCTAssertEqualObjects([self waitForEvent:0][@"kind"], @"open");
    __block BOOL answered = NO;
    [_session bookmarkOpenFolderWithCompletion:^(NSURL *folderURL, NSData *bookmark) {
        XCTAssertNil(folderURL);
        XCTAssertNil(bookmark);
        answered = YES;
    }];
    XCTAssertTrue(answered, @"answered at once");
}

#pragma mark - Dropbox

// The process's mirror, linked for this test alone, over the Dropbox stub.
- (void)testAMirrorFolderNothingListedIsListedBeforeItIsRead {
    __block NSUInteger listings = 0;
    os_unfair_lock_lock(&sStubLock);
    sStubHandler = ^DropboxStubResponse(NSURLRequest *request, NSDictionary *json) {
        NSString *path = request.URL.path;
        if ([path isEqualToString:@"/oauth2/token"]) {
            return DropboxStubJSON(200, @{@"access_token": @"A1", @"expires_in": @14400});
        }
        if ([path isEqualToString:@"/2/files/list_folder"]
                && [[json[@"path"] lowercaseString] isEqualToString:@"/music"]) {
            @synchronized (self) {
                listings++;
            }
            NSDictionary *song = @{@".tag": @"file", @"name": @"Song.mp3", @"path_display": @"/Music/Song.mp3",
                                   @"id": @"id:song", @"path_lower": @"/music/song.mp3", @"size": @1000,
                                   @"server_modified": @"2020-01-02T03:04:05Z"};
            return DropboxStubJSON(200, @{@"entries": @[song], @"cursor": @"c", @"has_more": @NO});
        }
        return DropboxStubJSON(409, @{@"error_summary": @"path/not_found/"});
    };
    os_unfair_lock_unlock(&sStubLock);
    DropboxMirror *mirror = DropboxMirror.shared;
    [mirror.client adoptRefreshToken:@"R1" accountID:@"dbid:folder-session"];
    NSURL *music = [mirror.accountURL URLByAppendingPathComponent:@"Music" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:music withIntermediateDirectories:YES
                                            attributes:nil error:NULL];

    [_session openURLs:@[music] openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:0][@"names"], @"Song");
    [_session openURLs:@[music] openInPlace:YES];
    XCTAssertEqualObjects([self waitForEvent:1][@"names"], @"Song");
    @synchronized (self) {
        XCTAssertEqual(listings, 1u, @"a folder already listed is read from disk");
    }

    [_session clearSession];
    [mirror.client signOut];
    os_unfair_lock_lock(&sStubLock);
    sStubHandler = nil;
    os_unfair_lock_unlock(&sStubLock);
}

@end
