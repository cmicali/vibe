//
//  DropboxRulesTests.m
//
//  The Dropbox decisions that need no network: PKCE, the wire encodings,
//  entry reading and the version check; and NSURLUtil's remote placeholder
//  rule, which the mirror's files are judged by.
//

#import <XCTest/XCTest.h>

#include <fcntl.h>
#include <unistd.h>

#import "DropboxRules.h"
#import "NSURLUtil.h"

@interface DropboxRulesTests : XCTestCase
@end

@implementation DropboxRulesTests

- (void)tearDown {
    [NSURLUtil setRemotePlaceholderRoot:nil];
    [super tearDown];
}

// RFC 7636 appendix B.
- (void)testCodeChallengeMatchesTheRFCVector {
    XCTAssertEqualObjects(VibeDropboxCodeChallenge(@"dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                          @"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
}

- (void)testBase64URLHasNoPaddingOrUnsafeCharacters {
    const unsigned char bytes[] = {0xfb, 0xff, 0xbf, 0x01};
    NSString *encoded = VibeDropboxBase64URL([NSData dataWithBytes:bytes length:sizeof bytes]);
    XCTAssertEqualObjects(encoded, @"-_-_AQ");
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

- (void)testAuthorizationCodeRequiresTheStateWeSent {
    NSString *reason = nil;
    NSURL *good = [NSURL URLWithString:@"db-k://2/token?code=C0DE&state=s1"];
    XCTAssertEqualObjects(VibeDropboxAuthorizationCode(good, @"s1", &reason), @"C0DE");

    NSURL *forged = [NSURL URLWithString:@"db-k://2/token?code=C0DE&state=other"];
    XCTAssertNil(VibeDropboxAuthorizationCode(forged, @"s1", &reason));
    XCTAssertEqualObjects(reason, @"state mismatch");

    NSURL *denied = [NSURL URLWithString:@"db-k://2/token?error=access_denied&error_description=The+user+said+no&state=s1"];
    XCTAssertNil(VibeDropboxAuthorizationCode(denied, @"s1", &reason));
    XCTAssertEqualObjects(reason, @"The+user+said+no");
}

- (void)testFormBodyPercentEncodesReservedCharacters {
    NSData *body = VibeDropboxFormBody(@{@"redirect_uri": @"db-k://2/token", @"a": @"x y"});
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(text, @"a=x%20y&redirect_uri=db-k%3A%2F%2F2%2Ftoken");
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

- (void)testOnlyARevokedGrantUnlinks {
    NSDictionary *revoked = @{@"error": @"invalid_grant", @"error_description": @"refresh token is invalid or revoked"};
    XCTAssertTrue(VibeDropboxIsRevokedGrant(400, revoked));
    XCTAssertFalse(VibeDropboxIsRevokedGrant(400, nil));
    XCTAssertFalse(VibeDropboxIsRevokedGrant(400, @{@"error": @"invalid_request"}));
    XCTAssertFalse(VibeDropboxIsRevokedGrant(401, revoked));
}

- (void)testThrottlingIsRetriedAfterACappedDelay {
    XCTAssertEqual(VibeDropboxRetryDelay(429, @"3"), 3.0);
    XCTAssertEqual(VibeDropboxRetryDelay(429, nil), 1.0);
    XCTAssertEqual(VibeDropboxRetryDelay(503, @"300"), 10.0);
    XCTAssertLessThan(VibeDropboxRetryDelay(409, @"3"), 0);
    XCTAssertLessThan(VibeDropboxRetryDelay(500, nil), 0);
}

- (void)testTimestampsParseAsUTCSeconds {
    XCTAssertEqual(VibeDropboxParseTimestamp(@"2015-05-12T15:50:38Z"), (time_t)1431445838);
    XCTAssertEqual(VibeDropboxParseTimestamp(@"2015-05-12 15:50:38"), (time_t)-1);
    XCTAssertEqual(VibeDropboxParseTimestamp(@"2015-05-12T15:50:38Zjunk"), (time_t)-1);
    XCTAssertEqual(VibeDropboxParseTimestamp(nil), (time_t)-1);
}

- (void)testEntryKinds {
    XCTAssertEqual(VibeDropboxEntryKindOf(@{@".tag": @"file"}), VibeDropboxEntryKindFile);
    XCTAssertEqual(VibeDropboxEntryKindOf(@{@".tag": @"folder"}), VibeDropboxEntryKindFolder);
    XCTAssertEqual(VibeDropboxEntryKindOf(@{@".tag": @"deleted"}), VibeDropboxEntryKindDeleted);
    XCTAssertEqual(VibeDropboxEntryKindOf(@{}), VibeDropboxEntryKindUnknown);
}

- (void)testOnlyAudioAndPlaylistFilesAreMirrored {
    NSSet *playable = [NSSet setWithArray:@[@"flac", @"mp3"]];
    XCTAssertTrue(VibeDropboxNameIsMirrored(@"01 Song.FLAC", playable));
    XCTAssertTrue(VibeDropboxNameIsMirrored(@"Album.cue", playable));
    XCTAssertTrue(VibeDropboxNameIsMirrored(@"Mix.M3U", playable));
    XCTAssertTrue(VibeDropboxNameIsMirrored(@"Mix.m3u8", playable));
    XCTAssertFalse(VibeDropboxNameIsMirrored(@"cover.jpg", playable));
    XCTAssertFalse(VibeDropboxNameIsMirrored(@".hidden.mp3", playable));
    XCTAssertFalse(VibeDropboxNameIsMirrored(@"notes", playable));
}

// One Dropbox folder, two spellings, one directory (DropboxRules.h).
- (void)testAComponentLandsOnTheExistingSpelling {
    XCTAssertEqualObjects(VibeDropboxLocalName(@"music", VibeDropboxNameIndex(@[@"Podcasts", @"Music"])), @"Music");
    XCTAssertEqualObjects(VibeDropboxLocalName(@"CAFÉ", VibeDropboxNameIndex(@[@"café"])), @"café");
    // A decomposed name read back from disk still finds the composed one.
    XCTAssertEqualObjects(VibeDropboxLocalName(@"Cafe\u0301", VibeDropboxNameIndex(@[@"Café"])), @"Café");
    XCTAssertEqualObjects(VibeDropboxLocalName(@"New", VibeDropboxNameIndex(@[@"Music"])), @"New");
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

#pragma mark - NSURLUtil's remote placeholders

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

    XCTAssertFalse([NSURLUtil isDatalessFile:placeholder], @"the mac never installs a backend");
    XCTAssertFalse([NSURLUtil isRemotePlaceholderFile:placeholder]);

    [NSURLUtil setRemotePlaceholderRoot:[NSURL fileURLWithPath:root isDirectory:YES]];
    // An unreadable file elsewhere is merely unreadable: no backend serves it.
    XCTAssertFalse([NSURLUtil isDatalessFile:outside]);
    XCTAssertFalse([NSURLUtil isRemotePlaceholderFile:outside]);
    XCTAssertTrue([NSURLUtil isDatalessFile:placeholder]);
    XCTAssertTrue([NSURLUtil isRemotePlaceholderFile:placeholder]);
    XCTAssertFalse([NSURLUtil isDatalessFile:ordinary]);
    XCTAssertFalse([NSURLUtil isRemotePlaceholderFile:ordinary]);

    // It cannot be read past: the guarantee that nothing decodes zeros.
    XCTAssertLessThan(open(placeholder.fileSystemRepresentation, O_RDONLY), 0);
    XCTAssertEqual(errno, EACCES);
}

- (void)testThePartFileIsAHiddenSibling {
    NSURL *url = [NSURL fileURLWithPath:@"/mirror/Album/01 Song.flac"];
    XCTAssertEqualObjects([NSURLUtil remotePlaceholderPartURL:url].path,
                          @"/mirror/Album/.01 Song.flac.vibe-download");
}

// A saved budget is one of the choices: absent, 10 GB; off the list, the
// nearest.
- (void)testASavedDownloadBudgetIsOneOfTheChoices {
    XCTAssertEqual(kVibeDropboxDownloadBudgets[VibeDropboxDownloadBudgetIndex(0)], 10000L * 1000 * 1000);
    for (size_t i = 0; i < kVibeDropboxDownloadBudgetCount; i++) {
        XCTAssertEqual(VibeDropboxDownloadBudgetIndex(kVibeDropboxDownloadBudgets[i]), i);
        XCTAssertTrue(i == 0 || kVibeDropboxDownloadBudgets[i] > kVibeDropboxDownloadBudgets[i - 1], @"smallest first");
    }
    XCTAssertEqual(kVibeDropboxDownloadBudgets[VibeDropboxDownloadBudgetIndex(3000L * 1000 * 1000)], 2000L * 1000 * 1000);
    XCTAssertEqual(kVibeDropboxDownloadBudgets[VibeDropboxDownloadBudgetIndex(NSIntegerMax)], 50000L * 1000 * 1000);
    XCTAssertEqual(kVibeDropboxDownloadBudgets[VibeDropboxDownloadBudgetIndex(-1)], 10000L * 1000 * 1000);
}

@end
