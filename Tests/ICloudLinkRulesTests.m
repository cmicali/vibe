//
//  ICloudLinkRulesTests.m
//
//  Open URL's iCloud Drive share links: which links are iCloud's, what a
//  lookup's answer says, the download address, and how long a lookup is
//  reused. Then what LinkStore makes of iCloud's answers over HTTPStub
//  (ICloudLinkStoreTests): the lookup before each request and its resends, a
//  lookup again for an expired address, the checksum as the version, and the
//  shares that open nothing.
//

#import <XCTest/XCTest.h>

#include <stdatomic.h>

#import "HTTPStub.h"
#import "ICloudLinkRules.h"
#import "LinkRules.h"
#import "LinkStoreTestCase.h"
#import "PlayableExtensions.h"

@interface ICloudLinkRulesTests : XCTestCase
@end

static NSString *NameWithDisposition(NSString *url, NSString *disposition, NSString *extension) {
    return VibeLinkFileName([NSURL URLWithString:url], disposition, extension, PlayableExtensions.lookup);
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

// The client looks it up. The link itself is fetched from nowhere.
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

// Never a crash, and never the server's failure.
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

// A field of another type than its record's is no field.
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

// ${f} takes the name, percent-encoded, and the signature's items are kept as
// they came.
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

// The lookup's name names the link's file, as iCloud's own echo of it would.
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

// By age alone, never by the address's expiry: that is in iCloud's clock.
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

@interface ICloudLinkStoreTests : LinkStoreTestCase
@end

static NSString *const kICloudLink = @"https://www.icloud.com/iclouddrive/0FakeShareID0000000000000#Song_One";
// The path the client posts its lookup to.
static NSString *LookupPath(void) {
    return [NSURL URLWithString:kVibeICloudLinkLookupURL].path;
}

// A version as the record keeps it: the checksum as a strong ETag.
static NSString *ETag(NSString *checksum) {
    return [NSString stringWithFormat:@"\"%@\"", checksum];
}
static NSString *const kOtherChecksum = @"AZaYl5aVlJOSkZCPjo2Mi4qJiIeG";

static NSData *JSONData(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
}

// A lookup's answer naming `bytes` under `checksum`, its address signed with
// `signature` and valid for 15 minutes.
static NSData *LookupOf(NSData *bytes, NSString *checksum, NSString *signature) {
    long long expiry = (long long)NSDate.date.timeIntervalSince1970 + 900;
    return JSONData(ICloudLookup(checksum, (long long)bytes.length, @"Song One", @"flac",
                                 ICloudAddress(checksum, expiry, signature)));
}

// The path a checksum's file is served at, with the name iCloud's own
// address carries.
static NSString *ICloudPath(NSString *checksum) {
    return [NSString stringWithFormat:@"/B/%@/Song One.flac", checksum];
}

// iCloud's two hosts on the stub: the lookup, and the file at the address it
// names. cvws sends no ETag, Last-Modified when it signed the address, and
// the name in ${f} back as the file's.
@implementation ICloudLinkStoreTests

- (void)serveICloud:(NSData *)bytes checksum:(NSString *)checksum {
    [_stub answerHost:@"ckdatabasews.icloud.com"];
    [_stub answerHost:@"cvws.icloud-content.com"];
    [self serve:LookupOf(bytes, checksum, @"first") at:LookupPath()
        headers:@{@"Content-Type": @"application/json"}];
    [self serve:bytes at:ICloudPath(checksum) headers:@{
        @"Content-Type": @"audio/flac",
        @"Last-Modified": kModified,
        @"Content-Disposition": @"attachment; filename=\"Song%20One.flac\"; filename*=UTF-8''Song%20One.flac",
    }];
}

- (void)queueLookup:(NSData *)answer {
    [_stub queueStep:[HTTPStubStep status:200 headers:@{@"Content-Type": @"application/json"} body:answer]
             forPath:LookupPath()];
}

- (NSURL *)resolveICloud {
    NSError *error = nil;
    NSURL *file = [self resolve:kICloudLink error:&error];
    XCTAssertNotNil(file, @"%@", error);
    return file;
}

- (void)testAnICloudLinkIsLookedUpThenProbedThenStreamed {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    XCTAssertEqualObjects(file.lastPathComponent, @"Song One.flac", @"the lookup's name, by iCloud's echo");
    XCTAssertTrue(IsPlaceholder(file));
    XCTAssertEqual(StatOf(file).st_size, 200000);
    XCTAssertEqual(StatOf(file).st_mtimespec.tv_sec, kICloudModified, @"the record's mtime, not Last-Modified");

    NSDictionary *record = [self recordOf:file];
    XCTAssertEqualObjects(record[@"url"], kICloudLink, @"the share link, never the signed address");
    XCTAssertEqualObjects(record[@"version"], ETag(kChecksum));
    XCTAssertEqualObjects(record[@"modified"], @(kICloudModified));
    XCTAssertNil(record[@"lastModified"], @"when the address was signed");
    XCTAssertEqualObjects(record[@"host"], @"www.icloud.com");
    XCTAssertEqualObjects(record[@"ranges"], @YES);

    NSArray<NSURLRequest *> *requests = _stub.requests;
    XCTAssertEqual(requests.count, 2u);
    XCTAssertEqualObjects(requests[0].URL.absoluteString, kVibeICloudLinkLookupURL);
    XCTAssertEqualObjects(requests[0].HTTPMethod, @"POST");
    XCTAssertEqualObjects([requests[0] valueForHTTPHeaderField:@"Content-Type"], @"text/plain");
    XCTAssertEqualObjects([requests[0] valueForHTTPHeaderField:@"Origin"], @"https://www.icloud.com");
    XCTAssertEqualObjects(requests[1].URL.host, @"cvws.icloud-content.com");
    XCTAssertEqualObjects(requests[1].URL.path, ICloudPath(kChecksum));
    XCTAssertTrue([requests[1].URL.query containsString:@"s=first"]);
    XCTAssertEqualObjects([requests[1] valueForHTTPHeaderField:@"Range"], @"bytes=0-15");

    NSError *error = nil;
    XCTAssertEqualObjects([_store readPlaceholderAtURL:file offset:1000 length:64 error:&error],
                          [bytes subdataWithRange:NSMakeRange(1000, 64)], @"a tag read: %@", error);
    NSString *key = file.cacheKey;
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    XCTAssertEqualObjects(file.cacheKey, key, @"the install keeps the record's mtime");
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 1u, @"every request reuses the probe's lookup");
}

// An address can expire mid-download. Its refusal is looked up again, and
// the resend goes on from the byte it reached, under the same checksum.
- (void)testAnExpiredAddressIsLookedUpAgainAndResumes {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self queueLookup:LookupOf(bytes, kChecksum, @"second")];
    [self dropNextAnswerTo:ICloudPath(kChecksum) after:100000 partOf:file];
    [_stub queueStep:[HTTPStubStep status:410 headers:@{@"Content-Type": @"text/plain"}
                                      body:[@"Gone" dataUsingEncoding:NSUTF8StringEncoding]]
             forPath:ICloudPath(kChecksum)];
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    XCTAssertEqualObjects([self recordOf:file][@"version"], ETag(kChecksum));

    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 2u, @"one lookup again");
    NSArray<NSURLRequest *> *fetches = [self requestsTo:ICloudPath(kChecksum) since:1];
    XCTAssertEqual(fetches.count, 3u, @"the download, the refused resend, and the resend");
    XCTAssertNil([fetches[0] valueForHTTPHeaderField:@"Range"]);
    XCTAssertEqualObjects([fetches[1] valueForHTTPHeaderField:@"Range"], @"bytes=100000-");
    XCTAssertTrue([fetches[1].URL.query containsString:@"s=first"]);
    XCTAssertEqualObjects([fetches[2] valueForHTTPHeaderField:@"Range"], @"bytes=100000-");
    XCTAssertTrue([fetches[2].URL.query containsString:@"s=second"], @"the fresh address");
}

// The fresh address's own refusal is no expiry. The read fails as denied.
- (void)testAnAddressRefusedAfterALookupAgainFails {
    NSData *bytes = FlacBytes(4000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self queueLookup:LookupOf(bytes, kChecksum, @"second")];
    for (NSUInteger i = 0; i < 2; i++) {
        [_stub queueStep:[HTTPStubStep status:403 headers:nil body:nil] forPath:ICloudPath(kChecksum)];
    }
    NSError *error = nil;
    XCTAssertNil([_store readPlaceholderAtURL:file offset:0 length:64 error:&error]);
    XCTAssertEqualObjects(error.userInfo[VibeHTTPErrorStatusCodeKey], @403, @"%@", error);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 2u, @"looked up again once, not twice");
}

// A refreshed lookup naming another checksum is another file. The bytes
// written are of the first, so the download fails and its part goes.
- (void)testAnotherChecksumMidDownloadFails {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    NSData *changed = FlacBytes(210000);
    [self serve:changed at:ICloudPath(kOtherChecksum) headers:@{@"Content-Type": @"audio/flac"}];
    [self queueLookup:LookupOf(changed, kOtherChecksum, @"second")];
    [self dropNextAnswerTo:ICloudPath(kChecksum) after:100000 partOf:file];
    [_stub queueStep:[HTTPStubStep status:410 headers:nil body:nil] forPath:ICloudPath(kChecksum)];
    NSError *error = nil;
    XCTAssertFalse([self fetch:file error:&error]);
    XCTAssertEqualObjects(error.domain, VibeHTTPErrorDomain);
    XCTAssertEqual(error.code, VibeHTTPErrorVersionChanged);
    XCTAssertTrue(IsPlaceholder(file));
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:[NSURLUtil remotePlaceholderPartURL:file].path]);
}

// A relaunch looks the share up afresh. Its address and Last-Modified are
// new, but the checksum is the same, so the download is kept.
- (void)testAKeptDownloadSurvivesARelaunchsFreshLookup {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self fetchExpectingSuccess:file];
    NSString *key = file.cacheKey;
    ino_t inode = StatOf(file).st_ino;

    [self relaunch];
    [self queueLookup:LookupOf(bytes, kChecksum, @"second")];
    [_stub queueStep:[HTTPStubStep changeHeaders:@{@"Last-Modified": @"Thu, 22 Oct 2015 07:28:00 GMT"}]
             forPath:ICloudPath(kChecksum)];
    NSUInteger fetched = [_stub requestsToPath:ICloudPath(kChecksum)].count;
    XCTAssertEqualObjects([self resolveICloud], file);
    XCTAssertTrue(IsDownloaded(file));
    XCTAssertEqual(StatOf(file).st_ino, inode);
    XCTAssertEqualObjects(file.cacheKey, key);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 2u);
    NSArray<NSURLRequest *> *sent = [self requestsTo:ICloudPath(kChecksum) since:fetched];
    XCTAssertEqual(sent.count, 1u, @"the probe alone");
    XCTAssertEqualObjects([sent.firstObject valueForHTTPHeaderField:@"Range"], @"bytes=0-15");
}

// A relaunch's lookup naming another checksum opens another version.
- (void)testAnotherChecksumOnAFreshLookupIsAnotherVersion {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self fetchExpectingSuccess:file];

    // The same size and mtime: only the checksum tells.
    NSMutableData *changed = [FlacBytes(200000) mutableCopy];
    ((uint8_t *)changed.mutableBytes)[100] ^= 0xFF;
    [self serve:changed at:ICloudPath(kOtherChecksum) headers:@{@"Content-Type": @"audio/flac"}];
    [self relaunch];
    [self queueLookup:LookupOf(changed, kOtherChecksum, @"second")];
    XCTAssertEqualObjects([self resolveICloud], file);
    XCTAssertTrue(IsPlaceholder(file));
    XCTAssertEqualObjects([self recordOf:file][@"version"], ETag(kOtherChecksum));
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], changed);
}

// Every request waiting on a lookup shares the one in flight.
- (void)testConcurrentRequestsShareOneLookup {
    NSData *bytes = FlacBytes(4000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self relaunch];
    dispatch_semaphore_t gate = [self gate];
    [_stub queueStep:[HTTPStubStep stallAfter:1 gate:gate] forPath:LookupPath()];
    dispatch_group_t reads = dispatch_group_create();
    __block atomic_int read = 0;
    LinkStore *store = _store;
    for (NSUInteger i = 0; i < 4; i++) {
        dispatch_group_async(reads, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSData *data = [store readPlaceholderAtURL:file offset:i * 100 length:100 error:NULL];
            if ([data isEqualToData:[bytes subdataWithRange:NSMakeRange(i * 100, 100)]]) {
                atomic_fetch_add(&read, 1);
            }
        });
    }
    [self waitUntil:^BOOL {
        return [self->_stub requestsToPath:LookupPath()].count == 2;
    }];
    usleep(50000);
    dispatch_semaphore_signal(gate);
    XCTAssertEqual(dispatch_group_wait(reads, dispatch_time(DISPATCH_TIME_NOW,
                                                            (int64_t)(VIBE_TEST_HANG_TIMEOUT * NSEC_PER_SEC))), 0);
    XCTAssertEqual(atomic_load(&read), 4);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 2u, @"the resolve's, then one for all four reads");
}

- (void)testAShareForInvitedPeopleSendsNothingToTheFile {
    NSData *bytes = FlacBytes(4000);
    [self serveICloud:bytes checksum:kChecksum];
    NSMutableDictionary *invited = ICloudLookup(kChecksum, 4000, @"Song One", @"flac",
                                                ICloudAddress(kChecksum, 0, @"x"));
    ICloudResult(invited)[@"requireAppleLogin"] = @YES;
    [self queueLookup:JSONData(invited)];
    XCTAssertEqual([self failureOf:kICloudLink], VibeLinkErrorICloudPrivate);
    XCTAssertEqual(_stub.requests.count, 1u, @"the lookup alone");
    XCTAssertEqualObjects([self linkDirectories], @[]);
}

- (void)testAFolderShareIsRefused {
    NSData *bytes = FlacBytes(4000);
    [self serveICloud:bytes checksum:kChecksum];
    NSMutableDictionary *folder = ICloudLookup(kChecksum, 4000, @"Songs", @"",
                                               ICloudAddress(kChecksum, 0, @"x"));
    ICloudResult(folder)[@"rootRecord"][@"recordType"] = @"folder";
    [self queueLookup:JSONData(folder)];
    XCTAssertEqual([self failureOf:kICloudLink], VibeLinkErrorICloudFolder);
    XCTAssertEqual(_stub.requests.count, 1u);
}

// Neither is the server's failure.
- (void)testAGoneShareAndAnUnreadableAnswerFailClearly {
    [self serveICloud:FlacBytes(4000) checksum:kChecksum];
    [self queueLookup:JSONData(@{@"results": @[@{@"serverErrorCode": @"NOT_FOUND", @"requireAppleLogin": @NO}]})];
    XCTAssertEqual([self failureOf:kICloudLink], VibeLinkErrorNotFound);
    [self queueLookup:[@"<html>" dataUsingEncoding:NSUTF8StringEncoding]];
    XCTAssertEqual([self failureOf:kICloudLink], VibeLinkErrorICloudUnreadable);
    [_stub queueStep:[HTTPStubStep status:500 headers:nil body:nil] forPath:LookupPath()];
    NSError *error = nil;
    XCTAssertNil([self resolve:kICloudLink error:&error]);
    XCTAssertEqual(error.code, VibeLinkErrorServer);
    XCTAssertEqualObjects(error.userInfo[VibeHTTPErrorStatusCodeKey], @500);
    XCTAssertEqual([_stub requestsToPath:ICloudPath(kChecksum)].count, 0u);
}

- (void)failNextLookups:(NSUInteger)count code:(NSInteger)code {
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil];
    for (NSUInteger i = 0; i < count; i++) {
        [_stub queueStep:[HTTPStubStep failWithError:error] forPath:LookupPath()];
    }
}

// Offline, a downloaded share still opens. The lookup is what fails, once
// its two resends have failed too.
- (void)testAnUnreachableLookupOpensTheDownload {
    [self serveICloud:FlacBytes(4000) checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self fetchExpectingSuccess:file];
    [self relaunch];
    [self failNextLookups:3 code:NSURLErrorNotConnectedToInternet];
    XCTAssertEqualObjects([self resolveICloud], file);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 4u, @"the first open's, then three");

    [self relaunch];
    [self failNextLookups:3 code:NSURLErrorNotConnectedToInternet];
    [NSFileManager.defaultManager removeItemAtURL:_root error:NULL];
    XCTAssertEqual([self failureOf:kICloudLink], VibeLinkErrorUnreachable);
}

// A dropped connection and a throttle are sent again, as a request's are.
// A download's resend waiting on its lookup then goes on.
- (void)testALookupThatDropsOrIsThrottledIsSentAgain {
    NSData *bytes = FlacBytes(200000);
    [self serveICloud:bytes checksum:kChecksum];
    [self failNextLookups:2 code:NSURLErrorNetworkConnectionLost];
    NSURL *file = [self resolveICloud];
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 3u);

    // The download's resend after a drop needs a lookup again, which is
    // throttled, then answered.
    [self relaunch];
    [self queueLookup:LookupOf(bytes, kChecksum, @"first")];
    [_stub queueStep:[HTTPStubStep status:503 headers:@{@"Retry-After": @"1"} body:nil] forPath:LookupPath()];
    NSUInteger lookups = [_stub requestsToPath:LookupPath()].count;
    [self dropNextAnswerTo:ICloudPath(kChecksum) after:100000 partOf:file];
    [_stub queueStep:[HTTPStubStep status:410 headers:nil body:nil] forPath:ICloudPath(kChecksum)];
    [self fetchExpectingSuccess:file];
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:file], bytes);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, lookups + 3, @"the first, the throttled, and its resend");
}

// A lookup the replaced sessions answer is handed to its waiters, and not
// kept: it names the old server's address.
- (void)testALookupFromReplacedSessionsIsNotKept {
    NSData *bytes = FlacBytes(4000);
    [self serveICloud:bytes checksum:kChecksum];
    NSURL *file = [self resolveICloud];
    [self relaunch];
    dispatch_semaphore_t gate = [self gate];
    [_stub queueStep:[HTTPStubStep stallAfter:1 gate:gate] forPath:LookupPath()];
    LinkStore *store = _store;
    __block NSData *read = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"read"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        read = [store readPlaceholderAtURL:file offset:0 length:64 error:NULL];
        [done fulfill];
    });
    [self waitUntil:^BOOL {
        return [self->_stub requestsToPath:LookupPath()].count == 2;
    }];
    [_client useSessionConfiguration:_stub.configuration];
    dispatch_semaphore_signal(gate);
    [self waitForExpectations:@[done] timeout:VIBE_TEST_HANG_TIMEOUT];
    XCTAssertEqualObjects(read, [bytes subdataWithRange:NSMakeRange(0, 64)], @"its waiter still has it");

    XCTAssertNotNil([_store readPlaceholderAtURL:file offset:64 length:64 error:NULL]);
    XCTAssertEqual([_stub requestsToPath:LookupPath()].count, 3u, @"the next request looks up again");
}

@end
