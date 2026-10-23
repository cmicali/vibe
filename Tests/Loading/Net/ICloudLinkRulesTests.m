
#import <XCTest/XCTest.h>

#import "HTTPStub.h"
#import "ICloudLinkRules.h"
#import "LinkRules.h"

@interface ICloudLinkRulesTests : XCTestCase
@end

static NSString *NameWithDisposition(NSString *url, NSString *disposition, NSString *extension) {
    return VibeLinkFileName([NSURL URLWithString:url], disposition, extension, [NSSet setWithObject:extension]);
}

static NSString *ShortGUID(NSString *url) {
    return VibeICloudLinkShortGUID([NSURL URLWithString:url]);
}

static NSString *const kChecksum = @"AQIDBAUGBwgJCgsMDQ4PEBESExQV";

static NSMutableDictionary *Lookup(void) {
    return ICloudLookup(kChecksum, 526387929, @"Song One", @"flac",
                        ICloudAddress(kChecksum, 1791587082, @"signature"));
}

static VibeLinkError FileOf(id answer, NSDictionary **file) {
    // Through JSON, as the lookup's answer arrives.
    NSData *json = [answer isKindOfClass:NSDictionary.class] || [answer isKindOfClass:NSArray.class]
            ? [NSJSONSerialization dataWithJSONObject:answer options:0 error:NULL] : nil;
    return VibeICloudLinkFileOfLookup(json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL] : answer,
                                      file);
}

@implementation ICloudLinkRulesTests

- (void)testAnICloudDriveLinkNamesItsShare {
    NSString *guid = @"0b9AbCdEfGhIjKlMnOpQrStUv";
    NSString *link = [@"https://www.icloud.com/iclouddrive/" stringByAppendingString:guid];
    XCTAssertEqualObjects(ShortGUID(link), guid);
    XCTAssertEqualObjects(ShortGUID([link stringByAppendingString:@"#Song_One_%5BCD2%5D"]), guid, @"the name");
    XCTAssertEqualObjects(ShortGUID([link stringByAppendingString:@"?x=1#Song"]), guid, @"a query");
    XCTAssertEqualObjects(ShortGUID([link stringByAppendingString:@"/"]), guid, @"a trailing slash");
    XCTAssertEqualObjects(ShortGUID([@"https://icloud.com/iclouddrive/" stringByAppendingString:guid]), guid);
    XCTAssertEqualObjects(ShortGUID([@"https://WWW.iCloud.com/iclouddrive/" stringByAppendingString:guid]), guid);
    XCTAssertEqualObjects(ShortGUID(@"https://www.icloud.com/iclouddrive/a-b_c"), @"a-b_c");
}

- (void)testAnythingElseIsNoICloudDriveLink {
    for (NSString *url in @[@"https://www.icloud.com/iclouddrive/",
                            @"https://www.icloud.com/iclouddrive",
                            @"https://www.icloud.com/iclouddrive/abc/def",
                            @"https://www.icloud.com/iclouddrive/abc.def",
                            @"https://www.icloud.com/iclouddrive/abc%2Fdef",
                            @"https://www.icloud.com/iclouddrive/ab%20c",
                            @"https://www.icloud.com/photos/0b9AbCdEfGhIjKlMnOpQrStUv",
                            @"https://www.icloud.com/0b9AbCdEfGhIjKlMnOpQrStUv",
                            @"https://www.icloud.com.example.com/iclouddrive/0b9AbCdEfGhIjKlMnOpQrStUv",
                            @"https://example.com/iclouddrive/0b9AbCdEfGhIjKlMnOpQrStUv",
                            @"https://beta.icloud.com/iclouddrive/0b9AbCdEfGhIjKlMnOpQrStUv"]) {
        XCTAssertNil(ShortGUID(url), @"%@", url);
    }
    XCTAssertNil(VibeICloudLinkShortGUID(nil));
}

- (void)testAnICloudDriveLinkIsAcceptedAndNotRewritten {
    NSURL *link = [NSURL URLWithString:@"https://www.icloud.com/iclouddrive/0b9AbCdEfGhIjKlMnOpQrStUv#Song"];
    XCTAssertEqual(VibeLinkURLAcceptance(link), VibeLinkErrorNone);
    XCTAssertEqualObjects(VibeLinkDirectDownloadURL(link), link);
    XCTAssertTrue(VibeLinkRequestIsAllowed(nil, [NSURL URLWithString:kVibeICloudLinkLookupURL]));
    XCTAssertTrue(VibeLinkRequestIsAllowed(nil, [NSURL URLWithString:@"https://cvws.icloud-content.com/B/x/y"]));
}

- (void)testTheLookupBodyNamesTheShare {
    NSDictionary *body = [NSJSONSerialization JSONObjectWithData:VibeICloudLinkLookupBody(@"abc") options:0 error:NULL];
    XCTAssertEqualObjects(body, (@{@"shortGUIDs": @[@{@"value": @"abc"}]}));
}

- (void)testALookupNamesItsFile {
    NSDictionary *file = nil;
    XCTAssertEqual(FileOf(Lookup(), &file), VibeLinkErrorNone);
    XCTAssertEqualObjects(file[@"checksum"], kChecksum);
    XCTAssertEqualObjects(file[@"size"], @526387929);
    XCTAssertEqualObjects(file[@"modified"], @(kICloudModified));
    XCTAssertEqualObjects(file[@"name"], @"Song One.flac");
    XCTAssertEqualObjects([file[@"url"] absoluteString],
                          [ICloudAddress(kChecksum, 1791587082, @"signature")
                           stringByReplacingOccurrencesOfString:@"${f}" withString:@"Song%20One.flac"]);
    XCTAssertEqual(file.count, 5u, @"nothing else, the owner least of all");
}

// The size as a string, as one probe saw it. A missing mtime is left out. A
// name with no extension is the bare name. One with none is Link.
- (void)testALookupReadsTheShapesAFieldMayTake {
    NSMutableDictionary *lookup = Lookup();
    NSMutableDictionary *fields = ICloudResult(lookup)[@"rootRecord"][@"fields"];
    fields[@"size"] = @{@"value": @"4096", @"type": @"STRING"};
    [fields removeObjectForKey:@"mtime"];
    [fields removeObjectForKey:@"extension"];
    NSDictionary *file = nil;
    XCTAssertEqual(FileOf(lookup, &file), VibeLinkErrorNone);
    XCTAssertEqualObjects(file[@"size"], @4096);
    XCTAssertNil(file[@"modified"]);
    XCTAssertEqualObjects(file[@"name"], @"Song One");

    [fields removeObjectForKey:@"size"];
    [fields removeObjectForKey:@"encryptedBasename"];
    XCTAssertEqual(FileOf(lookup, &file), VibeLinkErrorNone, @"the content's own size");
    XCTAssertEqualObjects(file[@"size"], @526387929);
    XCTAssertEqualObjects(file[@"name"], @"Link");
}

- (void)testAShareForInvitedPeopleIsPrivate {
    NSMutableDictionary *login = Lookup();
    ICloudResult(login)[@"requireAppleLogin"] = @YES;
    XCTAssertEqual(FileOf(login, NULL), VibeLinkErrorICloudPrivate);

    NSMutableDictionary *anonymous = Lookup();
    [ICloudResult(anonymous) removeObjectForKey:@"anonymousPublicAccess"];
    XCTAssertEqual(FileOf(anonymous, NULL), VibeLinkErrorICloudPrivate);

    for (NSString *code in @[@"ACCESS_DENIED", @"AUTHENTICATION_REQUIRED", @"AUTHENTICATION_FAILED"]) {
        NSDictionary *refused = @{@"results": @[@{@"serverErrorCode": code, @"requireAppleLogin": @NO}]};
        XCTAssertEqual(FileOf(refused, NULL), VibeLinkErrorICloudPrivate, @"%@", code);
    }
}

// Measured: a share id nobody holds answers NOT_FOUND, and an empty one
// BAD_REQUEST.
- (void)testAShareThatIsGoneIsNotFound {
    NSDictionary *gone = @{@"results": @[@{@"shortGUID": @{@"value": @"0aaa"}, @"reason": @"Cannot resolve shortGUID",
                                           @"serverErrorCode": @"NOT_FOUND", @"requireAppleLogin": @NO}]};
    XCTAssertEqual(FileOf(gone, NULL), VibeLinkErrorNotFound);
    NSDictionary *bad = @{@"results": @[@{@"serverErrorCode": @"BAD_REQUEST", @"requireAppleLogin": @NO}]};
    XCTAssertEqual(FileOf(bad, NULL), VibeLinkErrorICloudUnreadable);
}

- (void)testAFolderShareIsAFolder {
    NSMutableDictionary *folder = Lookup();
    ICloudResult(folder)[@"rootRecord"][@"recordType"] = @"folder";
    NSDictionary *file = @{};
    XCTAssertEqual(FileOf(folder, &file), VibeLinkErrorICloudFolder);
    XCTAssertNil(file);
}

- (void)testAnyOtherAnswerIsUnreadable {
    NSMutableArray *answers = [NSMutableArray arrayWithObjects:@[], @{}, @"text", @{@"results": @[]},
                               @{@"results": @"x"}, @{@"results": @[@"x"]}, @{@"results": @[@{}]}, nil];
    void (^change)(void (^)(NSMutableDictionary *result, NSMutableDictionary *fields)) = ^(void (^edit)(NSMutableDictionary *, NSMutableDictionary *)) {
        NSMutableDictionary *lookup = Lookup();
        NSMutableDictionary *result = ICloudResult(lookup);
        edit(result, result[@"rootRecord"][@"fields"]);
        [answers addObject:lookup];
    };
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) { [result removeObjectForKey:@"rootRecord"]; });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) { result[@"rootRecord"] = @"x"; });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) { result[@"rootRecord"][@"recordType"] = @3; });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) { result[@"rootRecord"][@"fields"] = @"x"; });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) { [fields removeObjectForKey:@"fileContent"]; });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) { fields[@"fileContent"] = @{@"value": @"x"}; });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) { fields[@"fileContent"] = @[]; });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) {
        fields[@"fileContent"] = @{@"value": @{@"downloadURL": @"https://cvws.icloud-content.com/B/x/${f}"}};
    });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) {
        fields[@"fileContent"] = @{@"value": @{@"fileChecksum": kChecksum, @"size": @1}};
    });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) {
        fields[@"fileContent"] = @{@"value": @{@"fileChecksum": @7, @"size": @1, @"downloadURL": @"https://a/${f}"}};
    });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) {
        fields[@"fileContent"] = @{@"value": @{@"fileChecksum": kChecksum, @"size": @1, @"downloadURL": @"not a url"}};
    });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) {
        [fields removeObjectForKey:@"size"];
        fields[@"fileContent"] = @{@"value": @{@"fileChecksum": kChecksum, @"downloadURL": @"https://a/${f}"}};
    });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) {
        fields[@"size"] = @{@"value": @"12ab"};
        fields[@"fileContent"] = @{@"value": @{@"fileChecksum": kChecksum, @"size": @"x", @"downloadURL": @"https://a/${f}"}};
    });
    change(^(NSMutableDictionary *result, NSMutableDictionary *fields) { result[@"serverErrorCode"] = @7; });
    for (id answer in answers) {
        NSDictionary *file = @{};
        XCTAssertEqual(FileOf(answer, &file), VibeLinkErrorICloudUnreadable, @"%@", answer);
        XCTAssertNil(file);
    }
    XCTAssertEqual(VibeICloudLinkFileOfLookup(nil, NULL), VibeLinkErrorICloudUnreadable);
}

- (void)testAFieldOfAnotherShapeIsIgnored {
    NSMutableDictionary *lookup = Lookup();
    NSMutableDictionary *fields = ICloudResult(lookup)[@"rootRecord"][@"fields"];
    fields[@"mtime"] = @"yesterday";
    fields[@"extension"] = @{@"value": @4};
    fields[@"encryptedBasename"] = @{@"value": @"%%% not base64"};
    NSDictionary *file = nil;
    XCTAssertEqual(FileOf(lookup, &file), VibeLinkErrorNone);
    XCTAssertNil(file[@"modified"]);
    XCTAssertEqualObjects(file[@"name"], @"Link");
}

- (void)testTheDownloadAddressCarriesTheName {
    NSString *address = @"https://cvws.icloud-content.com/B/AbC-dEf/${f}?o=A_b&e=1791587082&s=x%2By";
    NSURL *url = VibeICloudLinkDownloadURL(address, @"Café / Mix [CD2].flac");
    XCTAssertEqualObjects(url.absoluteString, @"https://cvws.icloud-content.com/B/AbC-dEf/"
                          @"Caf%C3%A9%20%2F%20Mix%20%5BCD2%5D.flac?o=A_b&e=1791587082&s=x%2By");
    XCTAssertEqualObjects(VibeICloudLinkDownloadURL(@"https://a.example/x?e=1", @"n.mp3").absoluteString,
                          @"https://a.example/x?e=1", @"no ${f} leaves the address");
    XCTAssertNil(VibeICloudLinkDownloadURL(@"", @"n.mp3"));
    XCTAssertNil(VibeICloudLinkDownloadURL(nil, @"n.mp3"));
    XCTAssertNil(VibeICloudLinkDownloadURL(@"https://a.example/${f}", @""));
    XCTAssertNil(VibeICloudLinkDownloadURL(@"not an address/${f}", @"n.mp3"));
    XCTAssertNil(VibeICloudLinkDownloadURL(@"http://cvws.icloud-content.com/B/x/${f}", @"n.mp3"), @"https only");
}

- (void)testTheLookupsNameNamesTheFile {
    NSString *link = @"https://www.icloud.com/iclouddrive/0b9AbCdEf#Song";
    NSString *echo = @"attachment; filename=\"Song%20One%20%5BCD2%5D.flac\"; "
                     @"filename*=UTF-8''Song%20One%20%5BCD2%5D.flac";
    XCTAssertEqualObjects(NameWithDisposition(link, echo, @"flac"), @"Song One [CD2].flac");
    XCTAssertEqualObjects(NameWithDisposition(link, VibeICloudLinkContentDisposition(@"Song One [CD2].flac"), @"flac"),
                          @"Song One [CD2].flac");
    XCTAssertEqualObjects(NameWithDisposition(link, VibeICloudLinkContentDisposition(@"Café; a=b \"x\".flac"), @"flac"),
                          @"Café; a=b \"x\".flac", @"a separator in the name stays encoded");
}

- (void)testAnAddressIsSentForTenMinutes {
    NSTimeInterval at = 1000000;
    XCTAssertTrue(VibeICloudLinkAddressIsFresh(at, at));
    XCTAssertTrue(VibeICloudLinkAddressIsFresh(at, at + 599));
    XCTAssertFalse(VibeICloudLinkAddressIsFresh(at, at + 600), @"ten minutes old");
    XCTAssertFalse(VibeICloudLinkAddressIsFresh(at, at - 1), @"from before its lookup");
}

// Measured: an expired address answers 410 Gone, and a signature that does
// not match answers 400.
- (void)testARefusedAddressMayHaveExpired {
    for (NSNumber *status in @[@400, @401, @403, @410]) {
        XCTAssertTrue(VibeICloudLinkStatusIsStaleAddress(status.integerValue), @"%@", status);
    }
    for (NSNumber *status in @[@200, @206, @404, @416, @429, @500, @503]) {
        XCTAssertFalse(VibeICloudLinkStatusIsStaleAddress(status.integerValue), @"%@", status);
    }
}

@end
