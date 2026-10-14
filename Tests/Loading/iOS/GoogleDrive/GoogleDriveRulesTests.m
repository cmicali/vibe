#import <XCTest/XCTest.h>

#import "GoogleDriveRules.h"

@interface GoogleDriveRulesTests : XCTestCase
@end

@implementation GoogleDriveRulesTests

#pragma mark - OAuth

- (void)testTheRedirectIsTheClientIDReversed {
    NSString *clientID = @"123-abc.apps.googleusercontent.com";
    XCTAssertEqualObjects(VibeGoogleDriveCallbackScheme(clientID), @"com.googleusercontent.apps.123-abc");
    XCTAssertEqualObjects(VibeGoogleDriveRedirectURI(clientID), @"com.googleusercontent.apps.123-abc:/oauth2redirect");
}

- (void)testTheSignInAsksForReadOnlyDriveWithPKCE {
    NSURL *authorize = VibeGoogleDriveAuthorizeURL(@"123-abc.apps.googleusercontent.com", @"challenge", @"state1");
    NSURLComponents *components = [NSURLComponents componentsWithURL:authorize resolvingAgainstBaseURL:NO];
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        query[item.name] = item.value;
    }
    XCTAssertEqualObjects(components.host, @"accounts.google.com");
    XCTAssertEqualObjects(query[@"scope"], @"https://www.googleapis.com/auth/drive.readonly");
    XCTAssertEqualObjects(query[@"code_challenge"], @"challenge");
    XCTAssertEqualObjects(query[@"code_challenge_method"], @"S256");
    XCTAssertEqualObjects(query[@"response_type"], @"code");
    XCTAssertEqualObjects(query[@"state"], @"state1");
    XCTAssertEqualObjects(query[@"redirect_uri"], @"com.googleusercontent.apps.123-abc:/oauth2redirect");
    XCTAssertNil(query[@"client_secret"], @"an installed app has none");
}

#pragma mark - Wire

- (void)testAQueryValueIsPercentEncodedWhole {
    NSURL *url = VibeGoogleDriveURL(@"files", @{@"q": @"'a+b' in parents", @"fields": @"files(id,name)"});
    XCTAssertEqualObjects(url.host, @"www.googleapis.com");
    XCTAssertEqualObjects(url.path, @"/drive/v3/files");
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    XCTAssertEqualObjects(components.percentEncodedQuery, @"fields=files%28id%2Cname%29&q=%27a%2Bb%27%20in%20parents");
    XCTAssertEqualObjects(components.queryItems.lastObject.value, @"'a+b' in parents");
}

// VibeAccountQueryString's TRAP: every other script's letters are encoded
// too.
- (void)testANonASCIIQueryIsEncoded {
    NSURL *url = VibeGoogleDriveURL(@"files", @{@"q": VibeGoogleDriveSearchQuery(@"Beyoncé 日本")});
    XCTAssertNotNil(url);
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    XCTAssertTrue([components.percentEncodedQuery canBeConvertedToEncoding:NSASCIIStringEncoding]);
    XCTAssertEqualObjects(components.queryItems.firstObject.value, @"name contains 'Beyoncé 日本' and trashed = false");
}

- (void)testAQueryLiteralEscapesQuotesAndBackslashes {
    XCTAssertEqualObjects(VibeGoogleDriveQueryLiteral(@"Rock 'n' Roll"), @"Rock \\'n\\' Roll");
    XCTAssertEqualObjects(VibeGoogleDriveQueryLiteral(@"a\\b"), @"a\\\\b");
    XCTAssertEqualObjects(VibeGoogleDriveSearchQuery(@"it's"), @"name contains 'it\\'s' and trashed = false");
    XCTAssertEqualObjects(VibeGoogleDriveChildrenQuery(@"root"), @"'root' in parents and trashed = false");
}

- (void)testAnErrorSummaryNamesTheReasonAndTheMessage {
    NSDictionary *api = @{@"error": @{@"code": @403, @"message": @"Rate Limit Exceeded",
                                      @"errors": @[@{@"reason": @"rateLimitExceeded"}]}};
    XCTAssertEqualObjects(VibeGoogleDriveErrorSummary(403, api), @"rateLimitExceeded: Rate Limit Exceeded");
    NSDictionary *oauth = @{@"error": @"invalid_grant", @"error_description": @"Token has been expired or revoked."};
    XCTAssertEqualObjects(VibeGoogleDriveErrorSummary(400, oauth), @"invalid_grant: Token has been expired or revoked.");
    XCTAssertEqualObjects(VibeGoogleDriveErrorSummary(502, nil), @"HTTP 502");
}

// A 403 for the file or a policy stands; only a rate limit waits.
- (void)testOnlyARateLimitOrAPassingServerErrorIsAThrottle {
    NSDictionary *limited = @{@"error": @{@"errors": @[@{@"reason": @"userRateLimitExceeded"}]}};
    NSDictionary *denied = @{@"error": @{@"errors": @[@{@"reason": @"cannotDownloadFile"}]}};
    XCTAssertTrue(VibeGoogleDriveIsThrottle(403, limited));
    XCTAssertFalse(VibeGoogleDriveIsThrottle(403, denied));
    XCTAssertFalse(VibeGoogleDriveIsThrottle(403, nil));
    XCTAssertTrue(VibeGoogleDriveIsThrottle(429, nil));
    XCTAssertTrue(VibeGoogleDriveIsThrottle(503, nil));
    XCTAssertTrue(VibeGoogleDriveIsThrottle(500, nil));
    XCTAssertFalse(VibeGoogleDriveIsThrottle(404, nil));
}

#pragma mark - Entries

- (void)testASizeIsReadFromTheStringTheAPIWrites {
    XCTAssertEqual(VibeGoogleDriveSizeOf(@{@"size": @"1234567890123"}), 1234567890123LL);
    XCTAssertEqual(VibeGoogleDriveSizeOf(@{@"size": @42}), 42);
    XCTAssertEqual(VibeGoogleDriveSizeOf(@{@"size": @"0"}), 0);
    XCTAssertEqual(VibeGoogleDriveSizeOf(@{@"size": @"12abc"}), -1);
    XCTAssertEqual(VibeGoogleDriveSizeOf(@{}), -1);
    XCTAssertEqual(VibeGoogleDriveSizeOf(nil), -1);
}

- (void)testTheVersionIsTheChecksumElseTheHeadRevision {
    XCTAssertEqualObjects(VibeGoogleDriveVersionOf((@{@"md5Checksum": @"abc", @"headRevisionId": @"r1"})), @"abc");
    XCTAssertEqualObjects(VibeGoogleDriveVersionOf(@{@"headRevisionId": @"r1"}), @"r1");
    XCTAssertNil(VibeGoogleDriveVersionOf(@{@"md5Checksum": @""}));
    XCTAssertNil(VibeGoogleDriveVersionOf(nil));
}

- (void)testFoldersAndMirroredFilesAreKept {
    NSSet *playable = [NSSet setWithArray:@[@"flac"]];
    XCTAssertTrue(VibeGoogleDriveEntryIsMirrored((@{@"id": @"f", @"name": @"Live",
                                                   @"mimeType": kVibeGoogleDriveFolderType}), playable));
    XCTAssertTrue(VibeGoogleDriveEntryIsMirrored((@{@"id": @"a", @"name": @"a.flac", @"size": @"5"}), playable));
    XCTAssertTrue(VibeGoogleDriveEntryIsMirrored((@{@"id": @"c", @"name": @"a.cue", @"size": @"5"}), playable));
    XCTAssertFalse(VibeGoogleDriveEntryIsMirrored((@{@"id": @"s", @"name": @"b.flac",
                                                    @"mimeType": @"application/vnd.google-apps.shortcut"}), playable),
                   @"a shortcut has no bytes of its own");
    XCTAssertFalse(VibeGoogleDriveEntryIsMirrored((@{@"id": @"d", @"name": @"Notes",
                                                    @"mimeType": @"application/vnd.google-apps.document"}), playable));
    XCTAssertFalse(VibeGoogleDriveEntryIsMirrored((@{@"name": @"noid.flac"}), playable));
}

- (void)testSearchKeepsFoldersAndPlayableFilesUpToTheLimit {
    NSSet *playable = [NSSet setWithArray:@[@"flac"]];
    NSDictionary *result = @{@"files": @[
        @{@"id": @"1", @"name": @"a.flac", @"size": @"5"},
        @{@"id": @"2", @"name": @"a.cue", @"size": @"5"},
        @{@"id": @"3", @"name": @"cover.jpg", @"size": @"5"},
        @{@"id": @"4", @"name": @"m", @"mimeType": kVibeGoogleDriveFolderType},
        @{@"id": @"6", @"name": @"c.flac", @"mimeType": @"application/vnd.google-apps.shortcut"},
        @{@"id": @"5", @"name": @"b.flac", @"size": @"5"},
    ]};
    XCTAssertEqualObjects([VibeGoogleDriveSearchEntries(result, playable, 10) valueForKey:@"id"], (@[@"1", @"4", @"5"]));
    XCTAssertEqualObjects([VibeGoogleDriveSearchEntries(result, playable, 2) valueForKey:@"id"], (@[@"1", @"4"]));
    XCTAssertEqualObjects(VibeGoogleDriveSearchEntries(nil, playable, 10), @[]);
}

#pragma mark - Local names

- (void)testADriveNameBecomesAFileName {
    XCTAssertEqualObjects(VibeGoogleDriveLocalBaseName(@"AC/DC - Live.flac", NO), @"AC-DC - Live.flac");
    XCTAssertEqualObjects(VibeGoogleDriveLocalBaseName(@"..hidden.mp3", NO), @"hidden.mp3");
    XCTAssertEqualObjects(VibeGoogleDriveLocalBaseName(@"...", YES), @"_");
    NSString *longStem = [@"" stringByPaddingToLength:300 withString:@"é" startingAtIndex:0];
    NSString *cut = VibeGoogleDriveLocalBaseName([longStem stringByAppendingString:@".flac"], NO);
    XCTAssertLessThanOrEqual([cut lengthOfBytesUsingEncoding:NSUTF8StringEncoding], kVibeGoogleDriveNameMaxBytes);
    XCTAssertEqualObjects(cut.pathExtension, @"flac", @"the extension survives the cut");
}

- (void)testACopyIsNumberedBeforeAFilesExtension {
    XCTAssertEqualObjects(VibeGoogleDriveCopyName(@"Song.mp3", 1, NO), @"Song.mp3");
    XCTAssertEqualObjects(VibeGoogleDriveCopyName(@"Song.mp3", 2, NO), @"Song (2).mp3");
    XCTAssertEqualObjects(VibeGoogleDriveCopyName(@"Live v1.0", 3, YES), @"Live v1.0 (3)");
    XCTAssertEqualObjects(VibeGoogleDriveCopyBase(@"Song (2).mp3", NO), @"Song.mp3");
    XCTAssertEqualObjects(VibeGoogleDriveCopyBase(@"Live v1.0 (3)", YES), @"Live v1.0");
    XCTAssertEqualObjects(VibeGoogleDriveCopyBase(@"Song (live).mp3", NO), @"Song (live).mp3");
}

// Two files of one name: the first in id order takes the name, the second its
// copy, and a listing in another order keeps both where they were.
- (void)testSlotsAreStableAcrossListingOrder {
    NSArray *entries = @[@{@"id": @"b", @"name": @"Song.mp3"},
                         @{@"id": @"a", @"name": @"Song.mp3"},
                         @{@"id": @"c", @"name": @"song.MP3"}];
    NSDictionary *first = VibeGoogleDriveSlots(entries, @{});
    XCTAssertEqualObjects(first[@"a"], @"Song.mp3");
    XCTAssertEqualObjects(first[@"b"], @"Song (2).mp3");
    XCTAssertEqualObjects(first[@"c"], @"song (3).MP3", @"case folds: one volume would merge them");
    NSDictionary *again = VibeGoogleDriveSlots(entries.reverseObjectEnumerator.allObjects, first);
    XCTAssertEqualObjects(again, first);
    // The plain name's owner leaves; the copy keeps its copy name.
    NSDictionary *after = VibeGoogleDriveSlots(@[entries[0]], first);
    XCTAssertEqualObjects(after[@"b"], @"Song (2).mp3");
}

- (void)testARenamedEntryTakesANewSlot {
    NSDictionary *previous = @{@"a": @"Old.mp3"};
    NSDictionary *slots = VibeGoogleDriveSlots(@[@{@"id": @"a", @"name": @"New.mp3"}], previous);
    XCTAssertEqualObjects(slots[@"a"], @"New.mp3");
    // A file literally named like a copy keeps that name.
    slots = VibeGoogleDriveSlots(@[@{@"id": @"x", @"name": @"Song (2).mp3"}], @{@"x": @"Song (2).mp3"});
    XCTAssertEqualObjects(slots[@"x"], @"Song (2).mp3");
}

- (void)testAFolderAndAFileOfOneNameShareNoSlot {
    NSDictionary *slots = VibeGoogleDriveSlots(@[@{@"id": @"d", @"name": @"Live", @"mimeType": kVibeGoogleDriveFolderType},
                                                 @{@"id": @"f", @"name": @"Live"}], @{});
    XCTAssertEqualObjects(slots[@"d"], @"Live");
    XCTAssertEqualObjects(slots[@"f"], @"Live (2)");
}

#pragma mark - The cache key

- (void)testANewVersionIsAlwaysDatedPastTheOld {
    XCTAssertEqual(VibeGoogleDriveStamp(2000, NO, 0), 2000, @"new here: Drive's date");
    XCTAssertEqual(VibeGoogleDriveStamp(2000, YES, 1000), 2000, @"a later date stands");
    XCTAssertEqual(VibeGoogleDriveStamp(1000, YES, 1000), 1001, @"a kept date moves on");
    XCTAssertEqual(VibeGoogleDriveStamp(1000, YES, 1001), 1002, @"and on again");
    XCTAssertEqual(VibeGoogleDriveStamp(500, YES, 1001), 1002, @"an older revision still moves the key");
    XCTAssertEqual(VibeGoogleDriveStamp(-1, NO, 0), 0);
}

@end
