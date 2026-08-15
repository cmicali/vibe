//
//  NSURLUtilTests.m
//
//  What a drop expands to: the folder walk's filtering, ordering and skips,
//  playlist files, and the sandbox grant an unreadable entry raises.
//

#import <XCTest/XCTest.h>

#import <limits.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

#import "NSURLUtilInternal.h"

@interface NSURLUtilTests : XCTestCase
@end

@implementation NSURLUtilTests {
    NSURL *_root;
}

- (void)setUp {
    [super setUp];
    _root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"VibeURLUtil-%@",
                                                                      NSUUID.UUID.UUIDString]]
                       isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_root
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    // The enumerator answers in resolved paths, and /var is a symlink to
    // /private/var — left unresolved, every path assertion compares two
    // spellings of the same directory. realpath, not
    // URLByResolvingSymlinksInPath, which leaves the temporary directory's
    // /var prefix exactly as it found it.
    char resolved[PATH_MAX];
    if (realpath(_root.fileSystemRepresentation, resolved)) {
        _root = [NSURL fileURLWithFileSystemRepresentation:resolved isDirectory:YES relativeToURL:nil];
    }
}

- (void)tearDown {
    [NSURLUtil setPlaylistFolderGrantHandler:nil];
    [self unlock:_root];
    [NSFileManager.defaultManager removeItemAtURL:_root error:nil];
    [super tearDown];
}

// Anything a denial test locked down has to be readable again before the
// removal, which lists as it goes. Each directory is unlocked before it is
// listed, so an execute-only one is not skipped along with its contents.
- (void)unlock:(NSURL *)url {
    chmod(url.fileSystemRepresentation, 0755);
    NSNumber *isDirectory = nil;
    [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    if (!isDirectory.boolValue) {
        return;
    }
    for (NSURL *child in [NSFileManager.defaultManager contentsOfDirectoryAtURL:url
                                                    includingPropertiesForKeys:nil
                                                                       options:0
                                                                         error:nil]) {
        [self unlock:child];
    }
}

#pragma mark - Fixtures

- (NSURL *)makeDirectory:(NSString *)relative {
    NSURL *url = [_root URLByAppendingPathComponent:relative isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:url
                                        withIntermediateDirectories:YES
                                                         attributes:nil
                                                              error:nil], @"%@", relative);
    return url;
}

- (NSURL *)makeFile:(NSString *)relative {
    NSURL *url = [_root URLByAppendingPathComponent:relative isDirectory:NO];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    // One byte, not none: expandAndFilterList: drops empty files, so a
    // zero-length fixture would vanish before any of these assertions.
    // testAnEmptyFileIsDropped covers that path deliberately.
    XCTAssertTrue([[NSData dataWithBytes:"\0" length:1] writeToURL:url atomically:YES], @"%@", relative);
    return url;
}

- (NSURL *)makeText:(NSString *)text at:(NSString *)relative {
    NSURL *url = [_root URLByAppendingPathComponent:relative isDirectory:NO];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    XCTAssertTrue([[text dataUsingEncoding:NSUTF8StringEncoding] writeToURL:url atomically:YES],
                  @"%@", relative);
    return url;
}

// Paths relative to the fixture root, which is what an assertion can read.
// Two spellings of the root are stripped: the folder walk answers in resolved
// paths, while playlist resolution standardizes, and standardizing is what
// drops the /private prefix again.
- (NSArray<NSString *> *)relativePaths:(NSArray<NSURL *> *)urls {
    NSArray<NSString *> *prefixes = @[[_root.path stringByAppendingString:@"/"],
                                      [_root.path.stringByStandardizingPath stringByAppendingString:@"/"]];
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) {
        NSString *name = url.path;
        for (NSString *prefix in prefixes) {
            if ([name hasPrefix:prefix]) {
                name = [name substringFromIndex:prefix.length];
                break;
            }
        }
        [names addObject:name];
    }
    return names;
}

- (NSArray<NSString *> *)expandAndFilter:(NSArray<NSURL *> *)list folderCount:(NSUInteger *)folderCount {
    return [self relativePaths:[NSURLUtil expandAndFilterList:list folderCount:folderCount]];
}

#pragma mark - The extension filter

// Every spelling the CFBundleDocumentTypes claim admits has to be here:
// com.microsoft.waveform-audio alone declares wav, wave AND bwf, and dropping
// one lets Finder offer Vibe a file the filter then silently discards.
- (void)testSupportedExtensionsCoverEveryClaimedSpelling {
    NSSet<NSString *> *supported = [NSURLUtil supportedExtensions];

    XCTAssertEqualObjects(supported, ([NSSet setWithArray:@[@"mp2", @"mp3", @"aac", @"aif", @"aiff",
                                                            @"wav", @"wave", @"bwf", @"flac",
                                                            @"m4a", @"mp4"]]));
    // OGG is not supported, and the playlist extensions are expanded rather
    // than played, so neither may leak into the filter.
    for (NSString *rejected in @[@"ogg", @"m3u", @"m3u8", @"cue", @"aifc", @"txt", @""]) {
        XCTAssertFalse([supported containsObject:rejected], @"%@", rejected);
    }
}

- (void)testTheFilterIsCaseInsensitiveAndDropsUnplayableFiles {
    [self makeFile:@"folder/Loud.MP3"];
    [self makeFile:@"folder/Quiet.FlAc"];
    [self makeFile:@"folder/notes.txt"];
    [self makeFile:@"folder/cover.jpg"];
    [self makeFile:@"folder/stream.ogg"];

    NSArray<NSString *> *files = [self relativePaths:
            [NSURLUtil expandDirectory:[self makeDirectory:@"folder"]]];

    XCTAssertEqualObjects(files, (@[@"folder/Loud.MP3", @"folder/Quiet.FlAc"]));
}

#pragma mark - The folder walk

// AppleDouble sidecars — "._Song.mp3", written by macOS on exFAT, SMB and USB
// volumes — pass the extension filter but hold resource-fork metadata rather
// than audio, and each one showed up as a duplicate, unplayable row.
- (void)testTheWalkSkipsAppleDoubleSidecarsAndHiddenFiles {
    [self makeFile:@"folder/Song.mp3"];
    [self makeFile:@"folder/._Song.mp3"];
    [self makeFile:@"folder/.hidden.mp3"];
    [self makeFile:@"folder/.hidden/buried.mp3"];

    NSArray<NSString *> *files = [self relativePaths:
            [NSURLUtil expandDirectory:[self makeDirectory:@"folder"]]];

    XCTAssertEqualObjects(files, (@[@"folder/Song.mp3"]));
}

- (void)testTheWalkSkipsPackageDescendants {
    [self makeFile:@"folder/Song.mp3"];
    [self makeFile:@"folder/Sampler.bundle/Contents/Resources/buried.mp3"];

    NSArray<NSString *> *files = [self relativePaths:
            [NSURLUtil expandDirectory:[self makeDirectory:@"folder"]]];

    XCTAssertEqualObjects(files, (@[@"folder/Song.mp3"]));
}

// The enumerator returns APFS hash order, which is effectively random, so the
// walk sorts by full path with Finder's comparator: numeric, and grouping each
// subfolder's files together.
- (void)testTheWalkSortsNumericallyByFullPath {
    [self makeFile:@"folder/track10.mp3"];
    [self makeFile:@"folder/track2.mp3"];
    [self makeFile:@"folder/track1.mp3"];
    [self makeFile:@"folder/b-disc/track2.mp3"];
    [self makeFile:@"folder/b-disc/track1.mp3"];
    [self makeFile:@"folder/a-disc/track1.mp3"];

    NSArray<NSString *> *files = [self relativePaths:
            [NSURLUtil expandDirectory:[self makeDirectory:@"folder"]]];

    XCTAssertEqualObjects(files, (@[@"folder/a-disc/track1.mp3",
                                    @"folder/b-disc/track1.mp3",
                                    @"folder/b-disc/track2.mp3",
                                    @"folder/track1.mp3",
                                    @"folder/track2.mp3",
                                    @"folder/track10.mp3"]));
}

- (void)testAnEmptyOrAudiolessFolderExpandsToNothing {
    [self makeFile:@"folder/notes.txt"];
    NSUInteger folderCount = 0;

    NSArray<NSString *> *files = [self expandAndFilter:@[[self makeDirectory:@"folder"],
                                                         [self makeDirectory:@"empty"]]
                                           folderCount:&folderCount];

    XCTAssertEqualObjects(files, @[]);
    XCTAssertEqual(folderCount, 2u);
}

#pragma mark - The top-level list

// hasDirectoryPath inspects only the trailing slash, so a directory URL built
// without isDirectory:YES — from an argv path, or some pasteboards — would be
// treated as a file and then silently dropped by the extension filter.
- (void)testADirectoryURLThatDoesNotLookLikeOneIsStillExpanded {
    [self makeFile:@"folder/Song.mp3"];
    NSURL *folder = [self makeDirectory:@"folder"];
    NSURL *misspelled = [NSURL fileURLWithPath:folder.path isDirectory:NO];
    XCTAssertFalse(misspelled.hasDirectoryPath);
    NSUInteger folderCount = 0;

    NSArray<NSString *> *files = [self expandAndFilter:@[misspelled] folderCount:&folderCount];

    XCTAssertEqualObjects(files, (@[@"folder/Song.mp3"]));
    XCTAssertEqual(folderCount, 1u);
}

- (void)testFolderCountCountsTopLevelFoldersOnly {
    [self makeFile:@"one/nested/deeper/Song.mp3"];
    [self makeFile:@"two/Song.mp3"];
    NSUInteger folderCount = 0;

    [self expandAndFilter:@[[self makeDirectory:@"one"],
                            [self makeDirectory:@"two"],
                            [self makeFile:@"loose.mp3"]]
              folderCount:&folderCount];

    XCTAssertEqual(folderCount, 2u);
}

- (void)testANullFolderCountIsAccepted {
    [self makeFile:@"folder/Song.mp3"];

    XCTAssertEqualObjects([self expandAndFilter:@[[self makeDirectory:@"folder"]] folderCount:NULL],
                          (@[@"folder/Song.mp3"]));
}

// An explicit multi-file drop keeps its pasteboard order — only a folder's own
// contents are sorted.
- (void)testAnExplicitFileSelectionKeepsItsOrder {
    NSArray<NSURL *> *picked = @[[self makeFile:@"c.mp3"],
                                 [self makeFile:@"a.mp3"],
                                 [self makeFile:@"b.mp3"]];

    XCTAssertEqualObjects([self expandAndFilter:picked folderCount:NULL],
                          (@[@"c.mp3", @"a.mp3", @"b.mp3"]));
}

// A zero-length file has an extension but nothing to decode, and handing one to
// AVAudioFile leaks a descriptor per attempt (NSURL+AudioOpen), so the funnel
// drops it here rather than seating an unplayable row.
- (void)testAnEmptyFileIsDropped {
    NSURL *empty = [_root URLByAppendingPathComponent:@"folder/empty.mp3" isDirectory:NO];
    [NSFileManager.defaultManager createDirectoryAtURL:empty.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:nil];
    XCTAssertTrue([[NSData data] writeToURL:empty atomically:YES]);
    [self makeFile:@"folder/real.mp3"];

    XCTAssertEqualObjects([self expandAndFilter:@[[self makeDirectory:@"folder"]] folderCount:NULL],
                          (@[@"folder/real.mp3"]));
    XCTAssertEqualObjects([self expandAndFilter:@[empty] folderCount:NULL], @[]);
}

- (void)testAMixedDropInterleavesFoldersWhereTheyWereDropped {
    [self makeFile:@"folder/b.mp3"];
    [self makeFile:@"folder/a.mp3"];

    NSArray<NSString *> *files = [self expandAndFilter:@[[self makeFile:@"first.mp3"],
                                                         [self makeDirectory:@"folder"],
                                                         [self makeFile:@"last.mp3"]]
                                           folderCount:NULL];

    XCTAssertEqualObjects(files, (@[@"first.mp3", @"folder/a.mp3", @"folder/b.mp3", @"last.mp3"]));
}

#pragma mark - Playlist files

- (void)testATopLevelPlaylistExpandsToItsEntriesInListOrder {
    [self makeFile:@"b.mp3"];
    [self makeFile:@"a.mp3"];
    [self makeFile:@"c.mp3"];
    NSURL *playlist = [self makeText:@"#EXTM3U\n#EXTINF:1,B\nb.mp3\na.mp3\nc.mp3\n" at:@"set.m3u"];

    XCTAssertEqualObjects([self expandAndFilter:@[playlist] folderCount:NULL],
                          (@[@"b.mp3", @"a.mp3", @"c.mp3"]));
}

- (void)testACueSheetExpandsLikeAnM3U {
    [self makeFile:@"side-a.wav"];
    [self makeFile:@"side-b.wav"];
    NSURL *sheet = [self makeText:@"FILE \"side-a.wav\" WAVE\n  TRACK 01 AUDIO\n"
                                   "FILE \"side-b.wav\" WAVE\n  TRACK 02 AUDIO\n"
                               at:@"album.cue"];

    XCTAssertEqualObjects([self expandAndFilter:@[sheet] folderCount:NULL],
                          (@[@"side-a.wav", @"side-b.wav"]));
}

// Only an explicitly opened playlist expands. One found inside a folder walk
// must be dropped by the extension filter — the walk already yields the
// folder's audio, and expanding it too would double every track.
- (void)testAPlaylistInsideADroppedFolderIsNotExpandedAgain {
    [self makeFile:@"folder/a.mp3"];
    [self makeFile:@"folder/b.mp3"];
    [self makeText:@"a.mp3\nb.mp3\n" at:@"folder/set.m3u"];

    XCTAssertEqualObjects([self expandAndFilter:@[[self makeDirectory:@"folder"]] folderCount:NULL],
                          (@[@"folder/a.mp3", @"folder/b.mp3"]));
}

- (void)testAnEntryThatIsSimplyMissingIsSkippedWithoutAskingForAGrant {
    [self makeFile:@"here.mp3"];
    NSURL *playlist = [self makeText:@"here.mp3\ngone.mp3\n" at:@"set.m3u"];
    __block NSUInteger asked = 0;
    [NSURLUtil setPlaylistFolderGrantHandler:^BOOL(NSURL *url) {
        asked++;
        return NO;
    }];

    XCTAssertEqualObjects([self expandAndFilter:@[playlist] folderCount:NULL], (@[@"here.mp3"]));
    // Missing is not denied: there is nothing a grant would rescue, and the
    // panel would be an interruption with no remedy behind it.
    XCTAssertEqual(asked, 0u);
}

- (void)testAReadablePlaylistNeverAsksForAGrant {
    [self makeFile:@"a.mp3"];
    NSURL *playlist = [self makeText:@"a.mp3\n" at:@"set.m3u"];
    __block NSUInteger asked = 0;
    [NSURLUtil setPlaylistFolderGrantHandler:^BOOL(NSURL *url) {
        asked++;
        return NO;
    }];

    XCTAssertEqualObjects([self expandAndFilter:@[playlist] folderCount:NULL], (@[@"a.mp3"]));
    XCTAssertEqual(asked, 0u);
}

// Opening a .m3u grants the .m3u alone, not the audio it names, so a denied
// entry is the one case worth interrupting the user for.
- (void)testADeniedEntryAsksOnceAndIsSkippedWhenTheGrantIsRefused {
    XCTSkipIf(geteuid() == 0, @"root reads through every permission bit, so nothing can be denied");
    [self makeFile:@"open.mp3"];
    NSURL *locked = [self makeFile:@"locked.mp3"];
    NSURL *playlist = [self makeText:@"open.mp3\nlocked.mp3\n" at:@"set.m3u"];
    chmod(locked.fileSystemRepresentation, 0000);
    __block NSUInteger asked = 0;
    __block NSURL *askedFor = nil;
    [NSURLUtil setPlaylistFolderGrantHandler:^BOOL(NSURL *url) {
        asked++;
        askedFor = url;
        return NO;
    }];

    XCTAssertEqualObjects([self expandAndFilter:@[playlist] folderCount:NULL], (@[@"open.mp3"]));
    XCTAssertEqual(asked, 1u);
    XCTAssertEqualObjects(askedFor.path, playlist.path);
}

// Granting is what extends the sandbox, so the entries are resolved again
// afterwards — the second pass is where the newly readable ones appear.
- (void)testAGrantedFolderIsResolvedAgainAndItsEntriesAppear {
    XCTSkipIf(geteuid() == 0, @"root reads through every permission bit, so nothing can be denied");
    [self makeFile:@"open.mp3"];
    NSURL *locked = [self makeFile:@"locked.mp3"];
    NSURL *playlist = [self makeText:@"open.mp3\nlocked.mp3\n" at:@"set.m3u"];
    chmod(locked.fileSystemRepresentation, 0000);
    __block NSUInteger asked = 0;
    [NSURLUtil setPlaylistFolderGrantHandler:^BOOL(NSURL *url) {
        asked++;
        chmod(locked.fileSystemRepresentation, 0644);
        return YES;
    }];

    XCTAssertEqualObjects([self expandAndFilter:@[playlist] folderCount:NULL],
                          (@[@"open.mp3", @"locked.mp3"]));
    XCTAssertEqual(asked, 1u);
}

// The re-resolve is not a formality: an entry written as a Windows absolute
// path resolves to nothing until the basename beside the playlist becomes
// readable, so the grant changes what the entry means, not just whether it can
// be opened. This is also the folder-denied case — the playlist file itself is
// readable while its folder is not, which is exactly the shape of a sandbox
// grant on a single opened .m3u, and an execute-only folder is the closest a
// chmod comes to it.
- (void)testAGrantOnADeniedFolderIsFollowedByASecondResolution {
    XCTSkipIf(geteuid() == 0, @"root reads through every permission bit, so nothing can be denied");
    NSURL *folder = [self makeDirectory:@"set"];
    NSURL *audio = [self makeFile:@"set/song.mp3"];
    NSURL *playlist = [self makeText:@"C:\\Music\\song.mp3\n" at:@"set/list.m3u"];
    chmod(audio.fileSystemRepresentation, 0000);
    chmod(folder.fileSystemRepresentation, 0111);
    __block NSUInteger asked = 0;
    [NSURLUtil setPlaylistFolderGrantHandler:^BOOL(NSURL *url) {
        asked++;
        chmod(audio.fileSystemRepresentation, 0644);
        chmod(folder.fileSystemRepresentation, 0755);
        return YES;
    }];

    XCTAssertEqualObjects([self expandAndFilter:@[playlist] folderCount:NULL], (@[@"set/song.mp3"]));
    XCTAssertEqual(asked, 1u);
}

- (void)testWithNoGrantHandlerInstalledADeniedEntryIsSimplySkipped {
    XCTSkipIf(geteuid() == 0, @"root reads through every permission bit, so nothing can be denied");
    [self makeFile:@"open.mp3"];
    NSURL *locked = [self makeFile:@"locked.mp3"];
    NSURL *playlist = [self makeText:@"open.mp3\nlocked.mp3\n" at:@"set.m3u"];
    chmod(locked.fileSystemRepresentation, 0000);

    XCTAssertEqualObjects([self expandAndFilter:@[playlist] folderCount:NULL], (@[@"open.mp3"]));
}

#pragma mark - Dataless files

- (void)testAMaterializedFileIsNotDataless {
    XCTAssertFalse([NSURLUtil isDatalessFile:[self makeFile:@"local.mp3"]]);
    // A stat that fails is unknown, not dataless.
    XCTAssertFalse([NSURLUtil isDatalessFile:[_root URLByAppendingPathComponent:@"gone.mp3"]]);
}

#pragma mark - Concurrency

// Folder walks run four wide, and callers hand the results straight into
// playlist state on main. Every drop must come back whole, matched to its own
// completion, on the main thread.
- (void)testConcurrentExpansionsEachDeliverTheirOwnResultOnMain {
    static const NSUInteger kDrops = 24;
    NSMutableArray<NSURL *> *folders = [NSMutableArray arrayWithCapacity:kDrops];
    for (NSUInteger i = 0; i < kDrops; i++) {
        NSString *name = [NSString stringWithFormat:@"drop%02lu", (unsigned long)i];
        for (NSUInteger track = 0; track < 5; track++) {
            [self makeFile:[NSString stringWithFormat:@"%@/track%lu.mp3", name, (unsigned long)track]];
        }
        [self makeFile:[NSString stringWithFormat:@"%@/notes.txt", name]];
        [folders addObject:[self makeDirectory:name]];
    }

    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    for (NSUInteger i = 0; i < kDrops; i++) {
        NSURL *folder = folders[i];
        XCTestExpectation *expectation = [self expectationWithDescription:folder.lastPathComponent];
        [expectations addObject:expectation];
        [NSURLUtil expandAndFilterList:@[folder] completion:^(NSArray<NSURL *> *files, NSUInteger folderCount) {
            XCTAssertTrue(NSThread.isMainThread);
            XCTAssertEqual(folderCount, 1u);
            XCTAssertEqual(files.count, 5u);
            for (NSURL *file in files) {
                XCTAssertEqualObjects(file.URLByDeletingLastPathComponent.path, folder.path);
            }
            [expectation fulfill];
        }];
    }

    [self waitForExpectations:expectations timeout:30];
}

// The handler is installed once at launch but read from every expansion
// worker, so the handoff takes a lock rather than assuming the install lands
// first. Whichever handler a walk sees, each denied playlist must ask exactly
// once and no ask may vanish.
- (void)testTheGrantHandlerCanBeReplacedWhileExpansionsRun {
    XCTSkipIf(geteuid() == 0, @"root reads through every permission bit, so nothing can be denied");
    static const NSUInteger kPlaylists = 24;
    NSMutableArray<NSURL *> *playlists = [NSMutableArray arrayWithCapacity:kPlaylists];
    for (NSUInteger i = 0; i < kPlaylists; i++) {
        NSString *name = [NSString stringWithFormat:@"set%02lu", (unsigned long)i];
        NSURL *locked = [self makeFile:[NSString stringWithFormat:@"%@/locked.mp3", name]];
        [playlists addObject:[self makeText:@"locked.mp3\n"
                                         at:[NSString stringWithFormat:@"%@/list.m3u", name]]];
        chmod(locked.fileSystemRepresentation, 0000);
    }
    __block atomic_uint asks = 0;
    BOOL (^refusing)(NSURL *) = ^BOOL(NSURL *url) {
        atomic_fetch_add(&asks, 1);
        return NO;
    };
    BOOL (^alsoRefusing)(NSURL *) = ^BOOL(NSURL *url) {
        atomic_fetch_add(&asks, 1);
        return NO;
    };
    [NSURLUtil setPlaylistFolderGrantHandler:refusing];

    NSMutableArray<XCTestExpectation *> *expectations = [NSMutableArray array];
    for (NSURL *playlist in playlists) {
        XCTestExpectation *expectation = [self expectationWithDescription:playlist.path];
        [expectations addObject:expectation];
        [NSURLUtil expandAndFilterList:@[playlist] completion:^(NSArray<NSURL *> *files, NSUInteger folderCount) {
            XCTAssertEqual(files.count, 0u);
            [expectation fulfill];
        }];
    }
    // Swapped underneath the running walks, which is the race the lock exists
    // for: an unguarded static here is a torn read of a block pointer.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSUInteger i = 0; i < 200; i++) {
            [NSURLUtil setPlaylistFolderGrantHandler:(i % 2) ? alsoRefusing : refusing];
        }
    });

    [self waitForExpectations:expectations timeout:30];
    XCTAssertEqual((NSUInteger)atomic_load(&asks), kPlaylists);
}

@end
