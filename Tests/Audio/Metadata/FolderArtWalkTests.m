//
// What a folder open hands the resolver. The walk touches every entry anyway,
// so the cover comes out of it for free; without this handoff a first open
// falls back to the three stat probes a lone file uses.
//

#import <XCTest/XCTest.h>

#import "AppSettings.h"
#import "AppSettings+Mac.h"
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
    // /private/var.
    char resolved[PATH_MAX];
    if (realpath(_root.fileSystemRepresentation, resolved)) {
        _root = [NSURL fileURLWithFileSystemRepresentation:resolved isDirectory:YES relativeToURL:nil];
    }
    // The walk never reaches for the resolver itself; AppDelegate installs
    // this same wiring at launch.
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

// Settling as none spares the folder's tracks the three stat probes later.
- (void)testAFolderWithAudioAndNoCoverIsSettledAsHavingNone {
    NSString *directory = [self makeDirectory:@"Bare"];
    [self makeFile:@"Bare/track.mp3"];

    [NSURLUtil expandDirectory:_root sortedBy:VibeFolderOpenSortName];

    XCTAssertEqualObjects([self settledFor:directory], @"");
}

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

// No track will ask about it, and in the bounded history an entry spent on it
// would evict one that matters.
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

// The harvest is a fact about the folder, not the setting: switching the
// fallback on later gets this answer rather than the lone file's probes.
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
