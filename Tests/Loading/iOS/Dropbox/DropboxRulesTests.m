
#import <XCTest/XCTest.h>

#include <fcntl.h>
#include <unistd.h>

#import "DropboxRules.h"
#import "PlaceholderFiles.h"

@interface DropboxRulesTests : XCTestCase
@end

@implementation DropboxRulesTests

- (void)tearDown {
    [PlaceholderFiles setRemotePlaceholderRoots:@[]];
    [super tearDown];
}

- (void)testRedirectIsTheUnregisteredAppScheme {
    XCTAssertEqualObjects(VibeDropboxRedirectURI(@"abc123"), @"db-abc123://2/token");
    NSURL *authorize = VibeDropboxAuthorizeURL(@"abc123", @"challenge", @"state1");
    NSURLComponents *components = [NSURLComponents componentsWithURL:authorize resolvingAgainstBaseURL:NO];
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        query[item.name] = item.value;
    }
    XCTAssertEqualObjects(query[@"redirect_uri"], @"db-abc123://2/token");
    XCTAssertEqualObjects(query[@"code_challenge_method"], @"S256");
    XCTAssertEqualObjects(query[@"token_access_type"], @"offline");
    XCTAssertEqualObjects(query[@"state"], @"state1");
}

// The argument header must be ASCII (DropboxRules.h).
- (void)testAPIArgHeaderEscapesEveryNonASCIICharacter {
    NSString *header = VibeDropboxAPIArgHeader(@{@"path": @"/Café/日本 🎵.flac"});
    XCTAssertNotNil([header dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:NO]);
    XCTAssertTrue([header containsString:@"Caf\\u00e9"]);
    XCTAssertTrue([header containsString:@"\\u65e5\\u672c"]);
    // A character outside the BMP goes as its surrogate pair, as JSON spells it.
    XCTAssertTrue([header containsString:@"\\ud83c\\udfb5"]);
    XCTAssertTrue([header containsString:@"/Caf"]);

    NSData *ascii = [header dataUsingEncoding:NSASCIIStringEncoding];
    NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:ascii options:0 error:NULL];
    XCTAssertEqualObjects(decoded[@"path"], @"/Café/日本 🎵.flac");
}

- (void)testOnlyAnExpiredTokenIsRetriedWithARefresh {
    NSDictionary *expired = @{@"error_summary": @"expired_access_token/..",
                              @"error": @{@".tag": @"expired_access_token"}};
    NSDictionary *invalid = @{@"error_summary": @"invalid_access_token/..",
                              @"error": @{@".tag": @"invalid_access_token"}};
    XCTAssertTrue(VibeDropboxIsExpiredAccessToken(401, expired));
    XCTAssertFalse(VibeDropboxIsExpiredAccessToken(401, invalid));
    XCTAssertFalse(VibeDropboxIsExpiredAccessToken(400, expired));
    XCTAssertTrue(VibeDropboxIsExpiredAccessToken(401, @{@"error_summary": @"expired_access_token/"}));
}

- (void)testThrottlingIsRetriedAfterACappedDelay {
    XCTAssertEqual(VibeHTTPRetryDelay(429, @"3"), 3.0);
    XCTAssertEqual(VibeHTTPRetryDelay(429, nil), 1.0);
    XCTAssertEqual(VibeHTTPRetryDelay(503, @"300"), 10.0);
    XCTAssertLessThan(VibeHTTPRetryDelay(409, @"3"), 0);
    XCTAssertLessThan(VibeHTTPRetryDelay(500, nil), 0);
}

- (void)testAComponentLandsOnTheExistingSpelling {
    XCTAssertEqualObjects(VibeDropboxLocalName(@"music", VibeAccountNameIndex(@[@"Podcasts", @"Music"])), @"Music");
    XCTAssertEqualObjects(VibeDropboxLocalName(@"CAFÉ", VibeAccountNameIndex(@[@"café"])), @"café");
    // A decomposed name read back from disk still finds the composed one.
    XCTAssertEqualObjects(VibeDropboxLocalName(@"Cafe\u0301", VibeAccountNameIndex(@[@"Café"])), @"Café");
    XCTAssertEqualObjects(VibeDropboxLocalName(@"New", VibeAccountNameIndex(@[@"Music"])), @"New");
}

- (void)testEntryKinds {
    XCTAssertEqual(VibeDropboxEntryKindOf(@{@".tag": @"file"}), VibeDropboxEntryKindFile);
    XCTAssertEqual(VibeDropboxEntryKindOf(@{@".tag": @"folder"}), VibeDropboxEntryKindFolder);
    XCTAssertEqual(VibeDropboxEntryKindOf(@{@".tag": @"deleted"}), VibeDropboxEntryKindDeleted);
    XCTAssertEqual(VibeDropboxEntryKindOf(@{}), VibeDropboxEntryKindUnknown);
}

- (void)testPathComponentsDropEmptySegments {
    XCTAssertEqualObjects(VibeDropboxPathComponents(@""), @[]);
    XCTAssertEqualObjects(VibeDropboxPathComponents(@"/Music//Album/"), (@[@"Music", @"Album"]));
}

- (void)testTheVersionIsSizePlusModifiedTime {
    XCTAssertTrue(VibeDropboxLocalMatchesEntry(100, 1000, 100, 1000));
    XCTAssertFalse(VibeDropboxLocalMatchesEntry(100, 1000, 101, 1000));
    XCTAssertFalse(VibeDropboxLocalMatchesEntry(100, 1000, 100, 1001));
    // An entry with no readable timestamp never matches, so it is refreshed.
    XCTAssertFalse(VibeDropboxLocalMatchesEntry(100, -1, 100, -1));
}

- (void)testSearchKeepsFoldersAndPlayableFilesOnly {
    NSSet *playable = [NSSet setWithArray:@[@"flac"]];
    NSDictionary *(^match)(NSDictionary *) = ^NSDictionary *(NSDictionary *entry) {
        return @{@"metadata": @{@".tag": @"metadata", @"metadata": entry}};
    };
    NSDictionary *result = @{@"matches": @[
        match(@{@".tag": @"file", @"name": @"a.flac", @"path_lower": @"/m/a.flac"}),
        match(@{@".tag": @"file", @"name": @"a.cue", @"path_lower": @"/m/a.cue"}),
        match(@{@".tag": @"file", @"name": @"B.CUE", @"path_lower": @"/m/b.cue"}),
        match(@{@".tag": @"file", @"name": @"cover.jpg", @"path_lower": @"/m/cover.jpg"}),
        match(@{@".tag": @"folder", @"name": @"m", @"path_lower": @"/m"}),
        match(@{@".tag": @"file", @"name": @"nopath.flac"}),
        @{@"metadata": @{@".tag": @"other"}},
    ]};
    NSArray *entries = VibeDropboxSearchEntries(result, playable);
    XCTAssertEqualObjects([entries valueForKey:@"path_lower"], (@[@"/m/a.flac", @"/m"]));
    XCTAssertEqualObjects(VibeDropboxSearchEntries(nil, playable), @[]);
}

- (void)testParentPaths {
    XCTAssertEqualObjects(VibeDropboxParentPath(@"/a.flac"), @"");
    XCTAssertEqualObjects(VibeDropboxParentPath(@"/music/album/a.flac"), @"/music/album");
}

#pragma mark - PlaceholderFiles' remote placeholders

- (NSURL *)makeFileWithMode:(mode_t)mode size:(off_t)size {
    return [self makeFileWithMode:mode size:size in:NSTemporaryDirectory()];
}

- (NSURL *)makeFileWithMode:(mode_t)mode size:(off_t)size in:(NSString *)directory {
    NSString *path = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"placeholder-%@.flac", NSUUID.UUID.UUIDString]];
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
    XCTAssertGreaterThanOrEqual(fd, 0);
    ftruncate(fd, size);
    fchmod(fd, mode);
    close(fd);
    NSURL *url = [NSURL fileURLWithPath:path];
    [self addTeardownBlock:^{
        unlink(path.fileSystemRepresentation);
    }];
    return url;
}

- (void)testAnUnreadableFileIsAPlaceholderOnlyUnderTheBackendsRoot {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
    [self addTeardownBlock:^{
        [NSFileManager.defaultManager removeItemAtPath:root error:NULL];
    }];
    NSURL *placeholder = [self makeFileWithMode:0 size:1 << 20 in:root];
    NSURL *ordinary = [self makeFileWithMode:0644 size:1 << 20 in:root];
    NSURL *outside = [self makeFileWithMode:0 size:1 << 20];

    XCTAssertFalse([PlaceholderFiles isDatalessFile:placeholder], @"the mac never installs a backend");
    XCTAssertFalse([PlaceholderFiles isRemotePlaceholderFile:placeholder]);

    [PlaceholderFiles setRemotePlaceholderRoots:@[[NSURL fileURLWithPath:root isDirectory:YES]]];
    // An unreadable file elsewhere is merely unreadable: no backend serves it.
    XCTAssertFalse([PlaceholderFiles isDatalessFile:outside]);
    XCTAssertFalse([PlaceholderFiles isRemotePlaceholderFile:outside]);
    XCTAssertTrue([PlaceholderFiles isDatalessFile:placeholder]);
    XCTAssertTrue([PlaceholderFiles isRemotePlaceholderFile:placeholder]);
    XCTAssertFalse([PlaceholderFiles isDatalessFile:ordinary]);
    XCTAssertFalse([PlaceholderFiles isRemotePlaceholderFile:ordinary]);

    // It cannot be read past: the guarantee that nothing decodes zeros.
    XCTAssertLessThan(open(placeholder.fileSystemRepresentation, O_RDONLY), 0);
    XCTAssertEqual(errno, EACCES);
}

- (void)testThePartFileIsAHiddenSibling {
    NSURL *url = [NSURL fileURLWithPath:@"/mirror/Album/01 Song.flac"];
    XCTAssertEqualObjects([PlaceholderFiles remotePlaceholderPartURL:url].path,
                          @"/mirror/Album/.01 Song.flac.vibe-download");
}

@end
