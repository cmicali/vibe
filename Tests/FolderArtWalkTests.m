//
// What a folder open hands the resolver. The walk touches every entry anyway,
// so the cover comes out of it for free, and this is the handoff that makes a
// first open show art at all: without it the feature degrades to the three stat
// probes a lone file uses.
//

#import <XCTest/XCTest.h>

#import "AppSettings.h"
#import "FolderArtResolverInternal.h"
#import "NSURLUtilInternal.h"

@interface FolderArtWalkTests : XCTestCase
@end

@implementation FolderArtWalkTests {
    NSURL *_root;
}

- (void)setUp {
    [super setUp];
    _root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"VibeFolderArtWalk-%@",
                                                                      NSUUID.UUID.UUIDString]]
                       isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_root
                           withIntermediateDirectories:YES attributes:nil error:nil];
    // The enumerator answers in resolved paths, and /var is a symlink to
    // /private/var, so an unresolved root compares two spellings of one
    // directory.
    char resolved[PATH_MAX];
    if (realpath(_root.fileSystemRepresentation, resolved)) {
        _root = [NSURL fileURLWithFileSystemRepresentation:resolved isDirectory:YES relativeToURL:nil];
    }
    // The walk hands its harvest to whoever installed the handler rather than
    // reaching for the resolver itself, so the app wires the two together at
    // launch (AppDelegate). That wiring is what is under test; make it here,
    // against a clean resolver.
    [NSURLUtil setWalkedDirectoriesHandler:^(NSSet<NSString *> *directories,
                                             NSDictionary<NSString *, NSString *> *artFilenameByDirectory) {
        [FolderArtResolver.sharedInstance noteListedDirectories:directories
                                     artFilenameByDirectory:artFilenameByDirectory];
    }];
    [FolderArtResolver.sharedInstance invalidate];
}

- (void)tearDown {
    [NSURLUtil setWalkedDirectoriesHandler:nil];
    [NSFileManager.defaultManager removeItemAtURL:_root error:nil];
    [FolderArtResolver.sharedInstance invalidate];
    [super tearDown];
}

#pragma mark - Fixtures

- (NSString *)makeDirectory:(NSString *)name {
    NSURL *url = name.length > 0 ? [_root URLByAppendingPathComponent:name isDirectory:YES] : _root;
    [NSFileManager.defaultManager createDirectoryAtURL:url
                           withIntermediateDirectories:YES attributes:nil error:nil];
    return url.path;
}

- (void)makeFile:(NSString *)relativePath {
    NSURL *url = [_root URLByAppendingPathComponent:relativePath];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:nil];
    [NSData.data writeToURL:url atomically:YES];
}

- (NSString *)settledFor:(NSString *)directory {
    return [FolderArtResolver.sharedInstance settledArtPathForDirectory:directory];
}

#pragma mark - The harvest

// The whole point of harvesting from the walk: names the lone-file stat probes
// never ask about are found anyway, for no I/O of the resolver's own.
- (void)testAWalkSettlesACoverTheProbesWouldMiss {
    NSString *directory = [self makeDirectory:@"Album"];
    [self makeFile:@"Album/track.mp3"];
    [self makeFile:@"Album/cover.png"];

    [NSURLUtil expandDirectory:_root sortedBy:VibeFolderOpenSortName];

    XCTAssertEqualObjects([self settledFor:directory],
                          [directory stringByAppendingPathComponent:@"cover.png"]);
}

// The rank lookup folds case, so the harvest keeps the spelling the disk
// carries rather than a lower-cased guess — that is what the decode must open.
- (void)testTheHarvestKeepsTheOnDiskSpelling {
    NSString *directory = [self makeDirectory:@"Shouty"];
    [self makeFile:@"Shouty/track.mp3"];
    [self makeFile:@"Shouty/FRONT.PNG"];

    [NSURLUtil expandDirectory:_root sortedBy:VibeFolderOpenSortName];

    XCTAssertEqualObjects([self settledFor:directory],
                          [directory stringByAppendingPathComponent:@"FRONT.PNG"]);
}

- (void)testTheBestRankedCoverWinsWithinAFolder {
    NSString *directory = [self makeDirectory:@"Several"];
    [self makeFile:@"Several/track.mp3"];
    [self makeFile:@"Several/album.jpg"];
    [self makeFile:@"Several/cover.jpg"];
    [self makeFile:@"Several/front.png"];

    [NSURLUtil expandDirectory:_root sortedBy:VibeFolderOpenSortName];

    XCTAssertEqualObjects([self settledFor:directory],
                          [directory stringByAppendingPathComponent:@"cover.jpg"]);
}

// A folder with audio and no cover settles as having none, which stops it being
// probed later: the answer costs nothing to record and saves three stats for
// every track in it.
- (void)testAFolderWithAudioAndNoCoverIsSettledAsHavingNone {
    NSString *directory = [self makeDirectory:@"Bare"];
    [self makeFile:@"Bare/track.mp3"];

    [NSURLUtil expandDirectory:_root sortedBy:VibeFolderOpenSortName];

    XCTAssertEqualObjects([self settledFor:directory], @"");
}

// Each directory answers for itself: the resolver is keyed to the folder the
// audio file lives in, and nothing inherits from a parent.
- (void)testEachAudioBearingSubfolderIsSettledIndependently {
    NSString *one = [self makeDirectory:@"Multi/CD1"];
    NSString *two = [self makeDirectory:@"Multi/CD2"];
    [self makeFile:@"Multi/CD1/track.mp3"];
    [self makeFile:@"Multi/CD1/cover.jpg"];
    [self makeFile:@"Multi/CD2/track.mp3"];

    [NSURLUtil expandDirectory:_root sortedBy:VibeFolderOpenSortName];

    XCTAssertEqualObjects([self settledFor:one], [one stringByAppendingPathComponent:@"cover.jpg"]);
    XCTAssertEqualObjects([self settledFor:two], @"", @"no cover of its own, and none inherited");
}

// No track will ever ask about a folder that contributes no playable audio, so
// it is not recorded: the history is bounded, and an entry spent on it would
// evict one that matters.
- (void)testAFolderWithoutAudioIsNotRecorded {
    NSString *artOnly = [self makeDirectory:@"Scans"];
    [self makeFile:@"Scans/cover.jpg"];
    [self makeFile:@"track.mp3"];

    [NSURLUtil expandDirectory:_root sortedBy:VibeFolderOpenSortName];

    XCTAssertNil([self settledFor:artOnly]);
}

- (void)testANonCoverImageIsNotMistakenForOne {
    NSString *directory = [self makeDirectory:@"Sleeve"];
    [self makeFile:@"Sleeve/track.mp3"];
    [self makeFile:@"Sleeve/back.jpg"];
    [self makeFile:@"Sleeve/scan-cover.jpg"];
    [self makeFile:@"Sleeve/folder art.jpg"];

    [NSURLUtil expandDirectory:_root sortedBy:VibeFolderOpenSortName];

    XCTAssertEqualObjects([self settledFor:directory], @"");
}

// The harvest is a fact about the folder, not about the setting, so it is
// recorded whether or not the fallback is switched on: switching it on later
// then gets this answer rather than the lone file's guesswork.
- (void)testTheHarvestIsRecordedEvenWithTheSettingOff {
    BOOL previous = AppSettings.sharedInstance.useFolderArt;
    [self addTeardownBlock:^{
        AppSettings.sharedInstance.useFolderArt = previous;
    }];
    AppSettings.sharedInstance.useFolderArt = NO;

    NSString *directory = [self makeDirectory:@"OffAlbum"];
    [self makeFile:@"OffAlbum/track.mp3"];
    [self makeFile:@"OffAlbum/cover.jpg"];

    [NSURLUtil expandDirectory:_root sortedBy:VibeFolderOpenSortName];

    XCTAssertEqualObjects([self settledFor:directory],
                          [directory stringByAppendingPathComponent:@"cover.jpg"]);
}

@end
