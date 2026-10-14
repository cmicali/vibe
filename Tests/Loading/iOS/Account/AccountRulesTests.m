#import <XCTest/XCTest.h>

#import "AccountRules.h"

@interface AccountRulesTests : XCTestCase
@end

@implementation AccountRulesTests

// RFC 7636 appendix B.
- (void)testCodeChallengeMatchesTheRFCVector {
    XCTAssertEqualObjects(VibeAccountCodeChallenge(@"dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                          @"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
}

- (void)testBase64URLHasNoPaddingOrUnsafeCharacters {
    const unsigned char bytes[] = {0xfb, 0xff, 0xbf, 0x01};
    NSString *encoded = VibeAccountBase64URL([NSData dataWithBytes:bytes length:sizeof bytes]);
    XCTAssertEqualObjects(encoded, @"-_-_AQ");
}

- (void)testAuthorizationCodeRequiresTheStateWeSent {
    NSString *reason = nil;
    NSURL *good = [NSURL URLWithString:@"db-k://2/token?code=C0DE&state=s1"];
    XCTAssertEqualObjects(VibeAccountAuthorizationCode(good, @"s1", &reason), @"C0DE");

    NSURL *forged = [NSURL URLWithString:@"db-k://2/token?code=C0DE&state=other"];
    XCTAssertNil(VibeAccountAuthorizationCode(forged, @"s1", &reason));
    XCTAssertEqualObjects(reason, @"state mismatch");

    NSURL *denied = [NSURL URLWithString:@"db-k://2/token?error=access_denied&error_description=The+user+said+no&state=s1"];
    XCTAssertNil(VibeAccountAuthorizationCode(denied, @"s1", &reason));
    XCTAssertEqualObjects(reason, @"The+user+said+no");
}

- (void)testFormBodyPercentEncodesReservedCharacters {
    NSData *body = VibeAccountFormBody(@{@"redirect_uri": @"db-k://2/token", @"a": @"x y"});
    NSString *text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects(text, @"a=x%20y&redirect_uri=db-k%3A%2F%2F2%2Ftoken");
}

- (void)testOnlyARevokedGrantUnlinks {
    NSDictionary *revoked = @{@"error": @"invalid_grant", @"error_description": @"refresh token is invalid or revoked"};
    XCTAssertTrue(VibeAccountIsRevokedGrant(400, revoked));
    XCTAssertFalse(VibeAccountIsRevokedGrant(400, nil));
    XCTAssertFalse(VibeAccountIsRevokedGrant(400, @{@"error": @"invalid_request"}));
    XCTAssertFalse(VibeAccountIsRevokedGrant(401, revoked));
}

- (void)testOnlyAudioAndPlaylistFilesAreMirrored {
    NSSet *playable = [NSSet setWithArray:@[@"flac", @"mp3"]];
    XCTAssertTrue(VibeAccountNameIsMirrored(@"01 Song.FLAC", playable));
    XCTAssertTrue(VibeAccountNameIsMirrored(@"Album.cue", playable));
    XCTAssertTrue(VibeAccountNameIsMirrored(@"Mix.M3U", playable));
    XCTAssertTrue(VibeAccountNameIsMirrored(@"Mix.m3u8", playable));
    XCTAssertFalse(VibeAccountNameIsMirrored(@"cover.jpg", playable));
    XCTAssertFalse(VibeAccountNameIsMirrored(@".hidden.mp3", playable));
    XCTAssertFalse(VibeAccountNameIsMirrored(@"notes", playable));
}

- (void)testAComponentLandsOnTheExistingSpelling {
    XCTAssertEqualObjects(VibeAccountLocalName(@"music", VibeAccountNameIndex(@[@"Podcasts", @"Music"])), @"Music");
    XCTAssertEqualObjects(VibeAccountLocalName(@"CAFÉ", VibeAccountNameIndex(@[@"café"])), @"café");
    // A decomposed name read back from disk still finds the composed one.
    XCTAssertEqualObjects(VibeAccountLocalName(@"Cafe\u0301", VibeAccountNameIndex(@[@"Café"])), @"Café");
    XCTAssertEqualObjects(VibeAccountLocalName(@"New", VibeAccountNameIndex(@[@"Music"])), @"New");
}

- (void)testASavedDownloadBudgetIsOneOfTheChoices {
    XCTAssertEqual(kVibeAccountDownloadBudgets[VibeAccountDownloadBudgetIndex(0)], 10000L * 1000 * 1000);
    for (size_t i = 0; i < kVibeAccountDownloadBudgetCount; i++) {
        XCTAssertEqual(VibeAccountDownloadBudgetIndex(kVibeAccountDownloadBudgets[i]), i);
        XCTAssertTrue(i == 0 || kVibeAccountDownloadBudgets[i] > kVibeAccountDownloadBudgets[i - 1], @"smallest first");
    }
    XCTAssertEqual(kVibeAccountDownloadBudgets[VibeAccountDownloadBudgetIndex(3000L * 1000 * 1000)], 2000L * 1000 * 1000);
    XCTAssertEqual(kVibeAccountDownloadBudgets[VibeAccountDownloadBudgetIndex(NSIntegerMax)], 50000L * 1000 * 1000);
    XCTAssertEqual(kVibeAccountDownloadBudgets[VibeAccountDownloadBudgetIndex(-1)], 10000L * 1000 * 1000);
}

@end
