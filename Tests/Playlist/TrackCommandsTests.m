#import <XCTest/XCTest.h>

#import <sys/stat.h>

#import "PlaceholderFiles.h"
#import "TrackCommands.h"

@interface TrackCommandsTests : XCTestCase
@end

@implementation TrackCommandsTests {
    NSURL *_root;
}

- (void)setUp {
    [super setUp];
    _root = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:@"TrackCommandsTests-%@",
                                                                      NSUUID.UUID.UUIDString]]
                       isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:_root
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
}

- (void)tearDown {
    [PlaceholderFiles setRemotePlaceholderRoots:@[]];
    [NSFileManager.defaultManager removeItemAtURL:_root error:nil];
    [super tearDown];
}

- (NSURL *)makeFile:(NSString *)relative {
    NSURL *url = [_root URLByAppendingPathComponent:relative isDirectory:NO];
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    XCTAssertTrue([[NSData dataWithBytes:"\0" length:1] writeToURL:url atomically:YES], @"%@", relative);
    return url;
}

// Copy Files and a drag out of the playlist hand no remote placeholder to
// another app. A download under the root, a file elsewhere, and an unreadable
// file elsewhere are handed out.
- (void)testOnlyARemotePlaceholderIsNeverHandedOut {
    NSURL *placeholder = [self makeFile:@"remote/aa/link.mp3"];
    NSURL *download = [self makeFile:@"remote/bb/kept.mp3"];
    NSURL *local = [self makeFile:@"music/local.mp3"];
    NSURL *unreadable = [self makeFile:@"music/locked.mp3"];
    chmod(placeholder.fileSystemRepresentation, 0000);
    chmod(unreadable.fileSystemRepresentation, 0000);
    [PlaceholderFiles setRemotePlaceholderRoots:@[[_root URLByAppendingPathComponent:@"remote" isDirectory:YES]]];

    XCTAssertFalse([TrackCommands handsOutURL:placeholder]);
    XCTAssertTrue([TrackCommands handsOutURL:download]);
    XCTAssertTrue([TrackCommands handsOutURL:local]);
    XCTAssertTrue([TrackCommands handsOutURL:unreadable]);
    XCTAssertFalse([TrackCommands handsOutURL:[NSURL URLWithString:@"https://example.com/a.mp3"]]);
    XCTAssertFalse([TrackCommands handsOutURL:nil]);

    // With no root, nothing is a placeholder.
    [PlaceholderFiles setRemotePlaceholderRoots:@[]];
    XCTAssertTrue([TrackCommands handsOutURL:placeholder]);
}

@end
