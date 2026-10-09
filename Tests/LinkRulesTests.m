//
//  LinkRulesTests.m
//
//  Open URL's decisions that need no network: which addresses are fetched,
//  the audio check, the file name, the link's directory, the response headers
//  the probe reads, and the failure each outcome names.
//

#import <XCTest/XCTest.h>

#import "HTTPTransferClient.h"
#import "LinkRules.h"
#import "LinkStore.h"
#import "PlayableExtensions.h"
#import "VibeStrings.h"

@interface LinkRulesTests : XCTestCase
@end

static VibeLinkAcceptance Accept(NSString *string) {
    return VibeLinkURLAcceptance(VibeLinkURLFromString(string));
}

static NSData *Bytes(const void *bytes, NSUInteger length) {
    return [NSData dataWithBytes:bytes length:length];
}

static NSData *Text(NSString *text) {
    return [text dataUsingEncoding:NSASCIIStringEncoding];
}

static NSString *Audio(NSData *head, NSString *url, NSString *disposition, NSString *type) {
    return VibeLinkAudioExtension(head, [NSURL URLWithString:url], disposition, type, PlayableExtensions.lookup);
}

static NSString *Name(NSString *url, NSString *extension) {
    return VibeLinkFileName([NSURL URLWithString:url], extension, PlayableExtensions.lookup);
}

static NSUInteger UTF8Length(NSString *string) {
    return [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
}

static const uint8_t kID3[] = {'I', 'D', '3', 4, 0};
static const uint8_t kOgg[] = {'O', 'g', 'g', 'S', 0, 2};
static const uint8_t kFtyp[] = {0, 0, 0, 0x20, 'f', 't', 'y', 'p', 'M', '4', 'A', ' '};
static const uint8_t kWav[] = {'R', 'I', 'F', 'F', 1, 2, 3, 4, 'W', 'A', 'V', 'E'};
static const uint8_t kAiff[] = {'F', 'O', 'R', 'M', 1, 2, 3, 4, 'A', 'I', 'F', 'F'};
static const uint8_t kADTS[] = {0xFF, 0xF1, 0x50, 0x80};
static const uint8_t kLayer3[] = {0xFF, 0xFB, 0x90, 0x64};
static const uint8_t kFLAC[] = {'f', 'L', 'a', 'C', 0, 0, 0, 34};

@implementation LinkRulesTests

#pragma mark - Acceptance: schemes and shapes

- (void)testHTTPSReachesAnyHost {
    for (NSString *url in @[@"https://example.com/a.mp3", @"https://8.8.8.8/a.mp3",
                            @"https://134744072/a.mp3", @"https://[2001:4860:4860::8888]/a.mp3",
                            @"HTTPS://Example.COM/a.mp3", @"https://pi.local/a.mp3",
                            @"https://192.168.1.5/a.mp3", @"https://nas/a.mp3",
                            @"https://example.com:8443/a.mp3", @"https://user:pass@example.com/a.mp3"]) {
        XCTAssertEqual(Accept(url), VibeLinkAccepted, @"%@", url);
    }
}

- (void)testOtherSchemesAreRefused {
    for (NSString *url in @[@"ftp://example.com/a.mp3", @"ftp://192.168.1.5/a.mp3",
                            @"file:///Users/me/a.mp3", @"file://localhost/Users/me/a.mp3",
                            @"vibe://open?u=x", @"data:audio/mpeg;base64,AAAA",
                            @"webdav://nas/a.mp3", @"httpx://example.com/a.mp3", @"htp://example.com/a.mp3"]) {
        XCTAssertEqual(Accept(url), VibeLinkRefusedNotHTTP, @"%@", url);
    }
}

- (void)testWhatIsNotAURLIsInvalid {
    for (NSString *url in @[@"", @"   ", @"\n", @"example.com/a.mp3", @"/a.mp3", @"a.mp3",
                            @"https://", @"https:///a.mp3", @"http://", @"http:a.mp3",
                            @"//example.com/a.mp3", @"https://exa mple.com/a.mp3"]) {
        XCTAssertEqual(Accept(url), VibeLinkRefusedInvalid, @"%@", url);
    }
    XCTAssertEqual(VibeLinkURLAcceptance(nil), VibeLinkRefusedInvalid);
}

- (void)testTheSchemeMatchesInAnyCase {
    XCTAssertEqual(Accept(@"HTTP://pi.local/a.mp3"), VibeLinkAccepted);
    XCTAssertEqual(Accept(@"Http://example.com/a.mp3"), VibeLinkRefusedInsecurePublicHTTP);
    XCTAssertEqual(Accept(@"hTtPs://example.com/a.mp3"), VibeLinkAccepted);
}

- (void)testPortsAndUserInfoDoNotMoveTheVerdict {
    XCTAssertEqual(Accept(@"http://pi.local:8080/a.mp3"), VibeLinkAccepted);
    XCTAssertEqual(Accept(@"http://192.168.1.5:80/a.mp3"), VibeLinkAccepted);
    XCTAssertEqual(Accept(@"http://[::1]:8000/a.mp3"), VibeLinkAccepted);
    XCTAssertEqual(Accept(@"http://user:pass@pi.local/a.mp3"), VibeLinkAccepted);
    XCTAssertEqual(Accept(@"http://example.com:80/a.mp3"), VibeLinkRefusedInsecurePublicHTTP);
    XCTAssertEqual(Accept(@"http://user@8.8.8.8/a.mp3"), VibeLinkRefusedInsecurePublicHTTP);
}

// The host is what follows the '@', however local the user name looks.
- (void)testAUserNameIsNotTheHost {
    XCTAssertEqual(Accept(@"http://pi.local@8.8.8.8/a.mp3"), VibeLinkRefusedInsecurePublicHTTP);
    XCTAssertEqual(Accept(@"http://localhost:80@example.com/a.mp3"), VibeLinkRefusedInsecurePublicHTTP);
    XCTAssertEqual(Accept(@"http://example.com@nas/a.mp3"), VibeLinkAccepted);
}

- (void)testAPastedLinkLosesItsWhitespace {
    XCTAssertEqualObjects(VibeLinkURLFromString(@"  https://example.com/a.mp3\n").absoluteString,
                          @"https://example.com/a.mp3");
    XCTAssertEqualObjects(VibeLinkURLFromString(@"\thttps://example.com/a.mp3\r\n").absoluteString,
                          @"https://example.com/a.mp3");
    XCTAssertNil(VibeLinkURLFromString(@" \n "));
    XCTAssertNil(VibeLinkURLFromString(nil));
}

#pragma mark - Acceptance: the local network by name

- (void)testPlainHTTPReachesLocalNames {
    for (NSString *url in @[@"http://localhost/a.mp3", @"http://LOCALHOST/a.mp3", @"http://localhost./a.mp3",
                            @"http://pi.local/a.mp3", @"http://PI.LOCAL/a.mp3", @"http://pi.local./a.mp3",
                            @"http://a.b.local/a.mp3", @"http://box.localhost/a.mp3",
                            @"http://server.test/a.mp3", @"http://fake.vibe.test/a.mp3",
                            @"http://nas/a.mp3", @"http://NAS/a.mp3", @"http://nas./a.mp3",
                            @"http://my-nas_2/a.mp3", @"http://local/a.mp3", @"http://test/a.mp3"]) {
        XCTAssertEqual(Accept(url), VibeLinkAccepted, @"%@", url);
    }
}

- (void)testPlainHTTPToAPublicNameIsRefused {
    for (NSString *url in @[@"http://example.com/a.mp3", @"http://local.example.com/a.mp3",
                            @"http://example.local.com/a.mp3", @"http://notlocal/a.mp3.example.com",
                            @"http://pilocal/../x", @"http://x.locals/a.mp3", @"http://x.testing/a.mp3",
                            @"http://x.localhosts/a.mp3", @"http://xlocalhost.com/a.mp3",
                            @"http://localhost.example.com/a.mp3"]) {
        VibeLinkAcceptance verdict = Accept(url);
        NSURL *parsed = [NSURL URLWithString:url];
        BOOL unqualified = [parsed.host rangeOfString:@"."].location == NSNotFound;
        XCTAssertEqual(verdict, unqualified ? VibeLinkAccepted : VibeLinkRefusedInsecurePublicHTTP, @"%@", url);
    }
}

- (void)testHostIsLocalByName {
    for (NSString *host in @[@"localhost", @"LocalHost", @"localhost.", @"pi.local", @"pi.local.",
                             @"x.localhost", @"x.test", @"nas", @"NAS.", @"local", @".local"]) {
        XCTAssertTrue(VibeLinkHostIsLocal(host), @"%@", host);
    }
    for (NSString *host in @[@"example.com", @"local.com", @"x.locale", @"x.tests", @"localhost.com",
                             @"", @".", @"[]", @"not:an:address"]) {
        XCTAssertFalse(VibeLinkHostIsLocal(host), @"%@", host);
    }
    XCTAssertFalse(VibeLinkHostIsLocal(nil));
}

#pragma mark - Acceptance: IPv4

- (void)testPrivateIPv4RangesAndTheirEdges {
    NSDictionary<NSString *, NSNumber *> *cases = @{
        @"9.255.255.255": @NO,   @"10.0.0.0": @YES,     @"10.255.255.255": @YES, @"11.0.0.0": @NO,
        @"126.255.255.255": @NO, @"127.0.0.1": @YES,    @"127.255.255.255": @YES, @"128.0.0.0": @NO,
        @"172.15.255.255": @NO,  @"172.16.0.0": @YES,   @"172.20.1.1": @YES,
        @"172.31.255.255": @YES, @"172.32.0.0": @NO,
        @"192.167.255.255": @NO, @"192.168.0.0": @YES,  @"192.168.1.5": @YES,
        @"192.168.255.255": @YES, @"192.169.0.0": @NO,
        @"169.253.255.255": @NO, @"169.254.0.0": @YES,  @"169.254.255.255": @YES, @"169.255.0.0": @NO,
        @"0.0.0.0": @NO,         @"8.8.8.8": @NO,       @"100.64.0.1": @NO,      @"255.255.255.255": @NO,
        @"1.1.1.1": @NO,         @"193.168.1.1": @NO,
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSString *address, NSNumber *local, BOOL *stop) {
        XCTAssertEqual(VibeLinkHostIsLocal(address), local.boolValue, @"%@", address);
        NSString *url = [NSString stringWithFormat:@"http://%@/a.mp3", address];
        XCTAssertEqual(Accept(url), local.boolValue ? VibeLinkAccepted : VibeLinkRefusedInsecurePublicHTTP, @"%@", url);
        url = [NSString stringWithFormat:@"https://%@/a.mp3", address];
        XCTAssertEqual(Accept(url), VibeLinkAccepted, @"%@", url);
    }];
}

// The resolver reads a bare number, a short form and hex as IPv4 addresses.
- (void)testANumericHostIsReadAsTheResolverReadsIt {
    XCTAssertEqual(Accept(@"http://134744072/a.mp3"), VibeLinkRefusedInsecurePublicHTTP);   // 8.8.8.8
    XCTAssertEqual(Accept(@"http://0x8.8.8.8/a.mp3"), VibeLinkRefusedInsecurePublicHTTP);
    XCTAssertEqual(Accept(@"http://0x08080808/a.mp3"), VibeLinkRefusedInsecurePublicHTTP);
    XCTAssertEqual(Accept(@"http://8.8/a.mp3"), VibeLinkRefusedInsecurePublicHTTP);
    XCTAssertEqual(Accept(@"http://2130706433/a.mp3"), VibeLinkAccepted);                   // 127.0.0.1
    XCTAssertEqual(Accept(@"http://127.1/a.mp3"), VibeLinkAccepted);
    XCTAssertEqual(Accept(@"http://0x7f.1/a.mp3"), VibeLinkAccepted);
    XCTAssertEqual(Accept(@"http://10.1/a.mp3"), VibeLinkAccepted);
    XCTAssertEqual(Accept(@"http://192.168.1.5./a.mp3"), VibeLinkAccepted);
}

#pragma mark - Acceptance: IPv6

- (void)testIPv6RangesAndTheirEdges {
    NSDictionary<NSString *, NSNumber *> *cases = @{
        @"::1": @YES,          @"::": @NO,            @"::2": @NO,
        @"fbff::1": @NO,       @"fc00::": @YES,       @"fc00::1": @YES,  @"fd12:3456::1": @YES,
        @"fdff:ffff::1": @YES, @"fe00::1": @NO,       @"fe7f::1": @NO,
        @"fe80::": @YES,       @"fe80::1": @YES,      @"febf::1": @YES,  @"fec0::1": @NO,
        @"ff02::1": @NO,       @"2001:db8::1": @NO,   @"2001:4860:4860::8888": @NO,
        @"::ffff:10.0.0.1": @YES, @"::ffff:192.168.0.9": @YES, @"::ffff:8.8.8.8": @NO,
        @"FE80::1": @YES,      @"FD00::ABCD": @YES,
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSString *address, NSNumber *local, BOOL *stop) {
        XCTAssertEqual(VibeLinkHostIsLocal(address), local.boolValue, @"%@", address);
        NSString *bracketed = [NSString stringWithFormat:@"[%@]", address];
        XCTAssertEqual(VibeLinkHostIsLocal(bracketed), local.boolValue, @"%@", bracketed);
        NSString *url = [NSString stringWithFormat:@"http://[%@]/a.mp3", address];
        XCTAssertEqual(Accept(url), local.boolValue ? VibeLinkAccepted : VibeLinkRefusedInsecurePublicHTTP, @"%@", url);
        url = [NSString stringWithFormat:@"https://[%@]:443/a.mp3", address];
        XCTAssertEqual(Accept(url), VibeLinkAccepted, @"%@", url);
    }];
}

- (void)testAZoneIdIsIgnored {
    XCTAssertTrue(VibeLinkHostIsLocal(@"fe80::1%en0"));
    XCTAssertTrue(VibeLinkHostIsLocal(@"[fe80::1%en0]"));
    XCTAssertTrue(VibeLinkHostIsLocal(@"[fe80::1%25en0]"));
    XCTAssertFalse(VibeLinkHostIsLocal(@"2001:db8::1%en0"));
    XCTAssertEqual(Accept(@"http://[fe80::1%25en0]/a.mp3"), VibeLinkAccepted);
    XCTAssertEqual(Accept(@"http://[fe80::1%25en0]:8000/a.mp3"), VibeLinkAccepted);
}

#pragma mark - Acceptance: redirects

// Each hop is judged alone, by the same rule as the typed link.
- (void)testARedirectIsJudgedByTheSameRule {
    NSDictionary<NSString *, NSNumber *> *hops = @{
        @"https://dl.dropboxusercontent.com/cd/0/get/abc/file": @(VibeLinkAccepted),
        @"http://cdn.example.com/a.mp3": @(VibeLinkRefusedInsecurePublicHTTP),
        @"http://8.8.8.8/a.mp3": @(VibeLinkRefusedInsecurePublicHTTP),
        @"http://pi.local/a.mp3": @(VibeLinkAccepted),
        @"http://192.168.1.5/a.mp3": @(VibeLinkAccepted),
        @"ftp://example.com/a.mp3": @(VibeLinkRefusedNotHTTP),
        @"file:///etc/passwd": @(VibeLinkRefusedNotHTTP),
    };
    [hops enumerateKeysAndObjectsUsingBlock:^(NSString *hop, NSNumber *verdict, BOOL *stop) {
        XCTAssertEqual(VibeLinkURLAcceptance([NSURL URLWithString:hop]), verdict.integerValue, @"%@", hop);
    }];
}

#pragma mark - Dropbox

- (void)testADropboxShareLinkGetsDLOne {
    NSDictionary<NSString *, NSString *> *cases = @{
        @"https://www.dropbox.com/scl/fi/abc123/Song.flac?rlkey=xyz&dl=0":
            @"https://www.dropbox.com/scl/fi/abc123/Song.flac?rlkey=xyz&dl=1",
        @"https://www.dropbox.com/scl/fi/abc123/Song.flac?dl=0&rlkey=xyz&st=q1":
            @"https://www.dropbox.com/scl/fi/abc123/Song.flac?rlkey=xyz&st=q1&dl=1",
        @"https://www.dropbox.com/scl/fi/abc123/Song.flac?rlkey=xyz":
            @"https://www.dropbox.com/scl/fi/abc123/Song.flac?rlkey=xyz&dl=1",
        @"https://dropbox.com/s/abc123/Song.mp3":
            @"https://dropbox.com/s/abc123/Song.mp3?dl=1",
        @"https://www.dropbox.com/s/abc123/Song.mp3?dl=1":
            @"https://www.dropbox.com/s/abc123/Song.mp3?dl=1",
        @"https://WWW.DROPBOX.COM/s/abc123/Song.mp3?dl=0":
            @"https://WWW.DROPBOX.COM/s/abc123/Song.mp3?dl=1",
        @"https://www.dropbox.com/s/abc123/Song.mp3?dl=0&dl=0":
            @"https://www.dropbox.com/s/abc123/Song.mp3?dl=1",
        @"https://www.dropbox.com/s/abc123/My%20Song.mp3?dl=0#frag":
            @"https://www.dropbox.com/s/abc123/My%20Song.mp3?dl=1#frag",
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSString *link, NSString *expected, BOOL *stop) {
        XCTAssertEqualObjects(VibeLinkDirectDownloadURL([NSURL URLWithString:link]).absoluteString, expected, @"%@", link);
    }];
}

- (void)testOtherLinksAreUntouched {
    for (NSString *string in @[@"https://www.dropbox.com/scl/fo/abc/folder?rlkey=x&dl=0",
                               @"https://www.dropbox.com/sh/abc/folder?dl=0",
                               @"https://www.dropbox.com/home/Music?dl=0",
                               @"https://www.dropbox.com/s",
                               @"https://www.dropbox.com/scl/fi",
                               @"https://dl.dropboxusercontent.com/s/abc/Song.mp3",
                               @"https://dropbox.com.evil.example/s/abc/Song.mp3?dl=0",
                               @"https://notdropbox.com/s/abc/Song.mp3?dl=0",
                               @"https://example.com/s/abc/Song.mp3?dl=0",
                               @"https://example.com/scl/fi/abc/Song.mp3?dl=0"]) {
        NSURL *url = [NSURL URLWithString:string];
        XCTAssertEqualObjects(VibeLinkDirectDownloadURL(url), url, @"%@", string);
    }
}

#pragma mark - Audio check: magic

- (void)testMagicNamesEveryFormat {
    const uint8_t layer2[] = {0xFF, 0xFD, 0x90, 0x64};
    const uint8_t layer1[] = {0xFF, 0xFF, 0x90, 0x64};
    const uint8_t mpeg2[] = {0xFF, 0xF3, 0x90, 0x64};
    const uint8_t mpeg25[] = {0xFF, 0xE3, 0x90, 0x64};
    const uint8_t adtsCRC[] = {0xFF, 0xF9, 0x50, 0x80};
    const uint8_t adtsMPEG4CRC[] = {0xFF, 0xF0, 0x50, 0x80};
    const uint8_t adtsMPEG2CRC[] = {0xFF, 0xF8, 0x50, 0x80};
    const uint8_t w64[] = {'r', 'i', 'f', 'f', 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00};
    const uint8_t aifc[] = {'F', 'O', 'R', 'M', 1, 2, 3, 4, 'A', 'I', 'F', 'C'};
    const uint8_t caf[] = {'c', 'a', 'f', 'f', 0, 1, 0, 0};
    const uint8_t qt[] = {0, 0, 0, 0x14, 'f', 't', 'y', 'p', 'q', 't', ' ', ' '};

    NSDictionary<NSData *, NSString *> *cases = @{
        Bytes(kID3, sizeof kID3): @"mp3",
        Bytes(kLayer3, sizeof kLayer3): @"mp3",
        Bytes(layer2, sizeof layer2): @"mp2",
        Bytes(layer1, sizeof layer1): @"mp3",
        Bytes(mpeg2, sizeof mpeg2): @"mp3",
        Bytes(mpeg25, sizeof mpeg25): @"mp3",
        Bytes(kADTS, sizeof kADTS): @"aac",
        Bytes(adtsCRC, sizeof adtsCRC): @"aac",
        Bytes(adtsMPEG4CRC, sizeof adtsMPEG4CRC): @"aac",
        Bytes(adtsMPEG2CRC, sizeof adtsMPEG2CRC): @"aac",
        Bytes(kFLAC, sizeof kFLAC): @"flac",
        Bytes(kWav, sizeof kWav): @"wav",
        Bytes(w64, sizeof w64): @"w64",
        Bytes(kAiff, sizeof kAiff): @"aiff",
        Bytes(aifc, sizeof aifc): @"aiff",
        Bytes(kOgg, sizeof kOgg): @"ogg",
        Bytes(kFtyp, sizeof kFtyp): @"m4a",
        Bytes(qt, sizeof qt): @"m4a",
        Bytes(caf, sizeof caf): @"caf",
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSData *head, NSString *expected, BOOL *stop) {
        NSSet *family = nil;
        XCTAssertEqualObjects(VibeLinkExtensionOfMagic(head, &family), expected, @"%@", head);
        XCTAssertTrue([family containsObject:expected], @"%@", head);
        XCTAssertTrue([family isSubsetOfSet:PlayableExtensions.lookup], @"%@", family);
        XCTAssertEqualObjects(Audio(head, @"https://example.com/stream", nil, nil), expected, @"%@", head);
    }];
}

- (void)testNearMissesMatchNothing {
    const uint8_t sync[] = {0xFF};
    const uint8_t syncTwo[] = {0xFF, 0xFB};
    const uint8_t noSync[] = {0xFF, 0xDB, 0x90, 0x64};
    const uint8_t jpeg[] = {0xFF, 0xD8, 0xFF, 0xE0};
    const uint8_t reservedVersion[] = {0xFF, 0xEB, 0x90, 0x64};
    const uint8_t noLayer[] = {0xFF, 0xE0, 0x90, 0x64};
    const uint8_t badRate[] = {0xFF, 0xFB, 0x9C, 0x64};
    const uint8_t badBitrate[] = {0xFF, 0xFB, 0xF0, 0x64};
    const uint8_t idOnly[] = {'I', 'D'};
    const uint8_t id4[] = {'I', 'D', '4', 4};
    const uint8_t fla[] = {'f', 'L', 'a'};
    const uint8_t flacCase[] = {'f', 'l', 'a', 'c'};
    const uint8_t riffAVI[] = {'R', 'I', 'F', 'F', 1, 2, 3, 4, 'A', 'V', 'I', ' '};
    const uint8_t riffShort[] = {'R', 'I', 'F', 'F', 1, 2, 3, 4, 'W', 'A', 'V'};
    const uint8_t w64Off[] = {'r', 'i', 'f', 'f', 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x01};
    const uint8_t w64Short[] = {'r', 'i', 'f', 'f', 0x2E, 0x91, 0xCF, 0x11};
    const uint8_t formOther[] = {'F', 'O', 'R', 'M', 1, 2, 3, 4, '8', 'S', 'V', 'X'};
    const uint8_t oggCase[] = {'O', 'G', 'G', 'S'};
    const uint8_t ogg3[] = {'O', 'g', 'g'};
    const uint8_t ftypAtZero[] = {'f', 't', 'y', 'p', 'M', '4', 'A', ' '};
    const uint8_t ftypShort[] = {0, 0, 0, 0x20, 'f', 't', 'y'};
    const uint8_t cafSpace[] = {'c', 'a', 'f', ' '};
    for (NSData *head in @[Bytes(sync, sizeof sync), Bytes(syncTwo, sizeof syncTwo), Bytes(noSync, sizeof noSync),
                           Bytes(jpeg, sizeof jpeg), Bytes(reservedVersion, sizeof reservedVersion),
                           Bytes(noLayer, sizeof noLayer), Bytes(badRate, sizeof badRate),
                           Bytes(badBitrate, sizeof badBitrate), Bytes(idOnly, sizeof idOnly), Bytes(id4, sizeof id4),
                           Bytes(fla, sizeof fla), Bytes(flacCase, sizeof flacCase),
                           Bytes(riffAVI, sizeof riffAVI), Bytes(riffShort, sizeof riffShort),
                           Bytes(w64Off, sizeof w64Off), Bytes(w64Short, sizeof w64Short),
                           Bytes(formOther, sizeof formOther), Bytes(oggCase, sizeof oggCase), Bytes(ogg3, sizeof ogg3),
                           Bytes(ftypAtZero, sizeof ftypAtZero), Bytes(ftypShort, sizeof ftypShort),
                           Bytes(cafSpace, sizeof cafSpace), [NSData data],
                           Text(@"<!DOCTYPE html>"), Text(@"{\"error\":1}"), Text(@"%PDF-1.7")]) {
        NSSet *family = [NSSet setWithObject:@"sentinel"];
        XCTAssertNil(VibeLinkExtensionOfMagic(head, &family), @"%@", head);
        XCTAssertNil(family, @"%@", head);
    }
}

#pragma mark - Audio check: precedence

// The bytes win over every header and over an extension of another family.
- (void)testMagicOutranksTheHeadersAndAForeignExtension {
    XCTAssertEqualObjects(Audio(Bytes(kFLAC, sizeof kFLAC), @"https://example.com/song.mp3",
                                @"attachment; filename=\"song.wav\"", @"text/html"), @"flac");
    XCTAssertEqualObjects(Audio(Bytes(kOgg, sizeof kOgg), @"https://example.com/song.mp3", nil, @"audio/mpeg"), @"ogg");
    XCTAssertEqualObjects(Audio(Bytes(kADTS, sizeof kADTS), @"https://example.com/song.m4a", nil, nil), @"aac");
    XCTAssertEqualObjects(Audio(Bytes(kLayer3, sizeof kLayer3), @"https://example.com/song.aac", nil, nil), @"mp3");
}

- (void)testTheLinksExtensionPicksTheFamilysMember {
    const uint8_t m4b[] = {0, 0, 0, 0x20, 'f', 't', 'y', 'p', 'M', '4', 'B', ' '};
    NSDictionary<NSArray *, NSString *> *cases = @{
        @[Bytes(kOgg, sizeof kOgg), @"a.opus"]: @"opus",
        @[Bytes(kOgg, sizeof kOgg), @"a.oga"]: @"oga",
        @[Bytes(kOgg, sizeof kOgg), @"a.OGG"]: @"ogg",
        @[Bytes(m4b, sizeof m4b), @"book.M4B"]: @"m4b",
        @[Bytes(kFtyp, sizeof kFtyp), @"a.mp4"]: @"mp4",
        @[Bytes(kFtyp, sizeof kFtyp), @"a.m4r"]: @"m4r",
        @[Bytes(kFtyp, sizeof kFtyp), @"a.qta"]: @"qta",
        @[Bytes(kWav, sizeof kWav), @"a.wave"]: @"wave",
        @[Bytes(kWav, sizeof kWav), @"a.bwf"]: @"bwf",
        @[Bytes(kAiff, sizeof kAiff), @"a.aif"]: @"aif",
        @[Bytes(kADTS, sizeof kADTS), @"a.adts"]: @"adts",
        @[Bytes(kLayer3, sizeof kLayer3), @"a.mp2"]: @"mp2",
        @[Bytes(kID3, sizeof kID3), @"a.aac"]: @"aac",
        @[Bytes(kID3, sizeof kID3), @"a.adts"]: @"adts",
        @[Bytes(kID3, sizeof kID3), @"a.flac"]: @"flac",
        @[Bytes(kID3, sizeof kID3), @"a.mp2"]: @"mp2",
        @[Bytes(kID3, sizeof kID3), @"a.wav"]: @"mp3",
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSArray *input, NSString *expected, BOOL *stop) {
        NSString *url = [@"https://example.com/" stringByAppendingString:input[1]];
        XCTAssertEqualObjects(Audio(input[0], url, nil, nil), expected, @"%@", url);
    }];
}

- (void)testTheURLsMemberOutranksTheDispositionsMember {
    XCTAssertEqualObjects(Audio(Bytes(kOgg, sizeof kOgg), @"https://example.com/a.opus",
                                @"attachment; filename=a.oga", nil), @"opus");
    XCTAssertEqualObjects(Audio(Bytes(kOgg, sizeof kOgg), @"https://example.com/get",
                                @"attachment; filename=a.oga", nil), @"oga");
    XCTAssertEqualObjects(Audio(Bytes(kOgg, sizeof kOgg), @"https://example.com/a.mp3",
                                @"attachment; filename=a.opus", nil), @"opus");
    XCTAssertEqualObjects(Audio(Bytes(kOgg, sizeof kOgg), @"https://example.com/a.mp3",
                                @"attachment; filename=a.flac", @"audio/opus"), @"ogg");
}

- (void)testWithoutMagicTheExtensionThenTheNameThenTheType {
    const uint8_t zeros[] = {0, 1, 2, 3};
    NSData *none = Bytes(zeros, sizeof zeros);
    XCTAssertEqualObjects(Audio(none, @"https://example.com/a.FLAC", @"attachment; filename=a.wav", @"audio/mpeg"), @"flac");
    XCTAssertEqualObjects(Audio(none, @"https://example.com/a.flac?x=1.mp3", nil, nil), @"flac");
    XCTAssertEqualObjects(Audio(none, @"https://example.com/get?id=1", @"attachment; filename=a.wav", @"audio/mpeg"), @"wav");
    XCTAssertEqualObjects(Audio(none, @"https://example.com/a.txt", @"attachment; filename=a.wav", @"audio/mpeg"), @"wav");
    XCTAssertEqualObjects(Audio(none, @"https://example.com/a.txt", @"attachment; filename=a.pdf", @"audio/mpeg"), @"mp3");
    XCTAssertEqualObjects(Audio(none, @"https://example.com/get?id=1", nil, @"audio/mpeg; charset=binary"), @"mp3");
    XCTAssertNil(Audio(none, @"https://example.com/get", nil, @"application/octet-stream"));
    XCTAssertNil(Audio(none, @"https://example.com/get", nil, @"application/binary"));
    XCTAssertNil(Audio(none, @"https://example.com/notes.txt", nil, nil));
    XCTAssertNil(Audio(none, @"https://example.com/get", @"attachment; filename=unspecified", nil));
    XCTAssertNil(Audio([NSData data], @"https://example.com/get", nil, nil));
}

// A type or extension the platform cannot play is not audio there.
- (void)testOnlyThePlayableSetCounts {
    NSSet *noOpus = [NSSet setWithArray:@[@"mp3", @"flac"]];
    const uint8_t zeros[] = {0, 1};
    NSData *none = Bytes(zeros, sizeof zeros);
    NSURL *get = [NSURL URLWithString:@"https://example.com/get"];
    XCTAssertNil(VibeLinkAudioExtension(none, get, nil, @"audio/opus", noOpus));
    XCTAssertNil(VibeLinkAudioExtension(none, [NSURL URLWithString:@"https://example.com/a.opus"], nil, nil, noOpus));
    XCTAssertNil(VibeLinkAudioExtension(none, get, @"attachment; filename=a.opus", nil, noOpus));
    XCTAssertEqualObjects(VibeLinkAudioExtension(none, get, nil, @"audio/flac", noOpus), @"flac");
}

// A login page or a deleted share at a .mp3 address is not a track.
- (void)testHTMLWithoutMagicIsNotAudio {
    NSData *page = Text(@"<!DOCTYPE html><html>");
    XCTAssertNil(Audio(page, @"https://example.com/song.mp3", nil, @"text/html"));
    XCTAssertNil(Audio(page, @"https://example.com/song.mp3", nil, @"text/html; charset=utf-8"));
    XCTAssertNil(Audio(page, @"https://example.com/song", @"attachment; filename=song.mp3", @"TEXT/HTML"));
    XCTAssertNil(Audio(page, @"https://example.com/song", nil, @" text/html "));
    XCTAssertEqualObjects(Audio(page, @"https://example.com/song.mp3", nil, @"text/plain"), @"mp3");
    XCTAssertEqualObjects(Audio(page, @"https://example.com/song.mp3", nil, nil), @"mp3");
}

#pragma mark - Audio check: headers

- (void)testTheContentTypeMap {
    NSDictionary<NSString *, NSString *> *map = @{
        @"audio/mpeg": @"mp3", @"audio/mp3": @"mp3",
        @"audio/mp4": @"m4a", @"audio/x-m4a": @"m4a",
        @"audio/aac": @"aac", @"audio/aacp": @"aac", @"audio/x-aac": @"aac",
        @"audio/flac": @"flac", @"audio/x-flac": @"flac",
        @"audio/wav": @"wav", @"audio/x-wav": @"wav", @"audio/wave": @"wav", @"audio/vnd.wave": @"wav",
        @"audio/aiff": @"aiff", @"audio/x-aiff": @"aiff",
        @"audio/ogg": @"ogg", @"audio/opus": @"opus",
        @"AUDIO/MPEG": @"mp3", @" audio/flac ; charset=binary": @"flac", @"audio/ogg; codecs=opus": @"ogg",
    };
    [map enumerateKeysAndObjectsUsingBlock:^(NSString *type, NSString *extension, BOOL *stop) {
        XCTAssertEqualObjects(VibeLinkExtensionOfContentType(type), extension, @"%@", type);
        XCTAssertTrue([PlayableExtensions.lookup containsObject:extension], @"%@", extension);
    }];
    for (NSString *type in @[@"audio/x-unknown", @"video/mp4", @"application/ogg", @"application/octet-stream",
                             @"text/html", @"audio", @"", @";", @"audio/mpegx"]) {
        XCTAssertNil(VibeLinkExtensionOfContentType(type), @"%@", type);
    }
    XCTAssertNil(VibeLinkExtensionOfContentType(nil));
}

- (void)testTheDispositionsFileName {
    NSDictionary<NSString *, NSString *> *cases = @{
        @"attachment; filename=\"a b.mp3\"": @"a b.mp3",
        @"attachment; filename=plain.mp3": @"plain.mp3",
        @"attachment;filename=tight.mp3": @"tight.mp3",
        @"attachment; FILENAME=\"upper.mp3\"": @"upper.mp3",
        @"inline; filename=\"inline.flac\"": @"inline.flac",
        @"attachment; filename=\"fallback.mp3\"; filename*=UTF-8''na%C3%AFve.flac": @"naïve.flac",
        @"attachment; filename*=UTF-8''only%20ext.wav; filename=\"fallback.mp3\"": @"only ext.wav",
        @"attachment; filename*=utf-8'en'x.ogg": @"x.ogg",
        @"attachment; filename*=bad; filename=\"fallback.mp3\"": @"fallback.mp3",
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSString *header, NSString *expected, BOOL *stop) {
        XCTAssertEqualObjects(VibeLinkFilenameOfContentDisposition(header), expected, @"%@", header);
    }];
    for (NSString *header in @[@"inline", @"attachment", @"attachment; filename=", @"attachment; filename=\"\"", @""]) {
        XCTAssertNil(VibeLinkFilenameOfContentDisposition(header), @"%@", header);
    }
    XCTAssertNil(VibeLinkFilenameOfContentDisposition(nil));
}

#pragma mark - Naming

- (void)testTheNameIsTheDecodedLastComponent {
    XCTAssertEqualObjects(Name(@"https://example.com/music/My%20Song.mp3", @"mp3"), @"My Song.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/music/My%20Song.mp3/", @"mp3"), @"My Song.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/music//Song.mp3//", @"mp3"), @"Song.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/a/Caf%C3%A9.flac?x=1#t", @"flac"), @"Café.flac");
    XCTAssertEqualObjects(Name(@"https://example.com/%E6%97%A5%E6%9C%AC.m4a", @"m4a"), @"日本.m4a");
    XCTAssertEqualObjects(Name(@"https://example.com/50%25%20off.mp3", @"mp3"), @"50% off.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/bad%ZZname.mp3", @"mp3"), @"bad%ZZname.mp3");
    XCTAssertEqualObjects(Name(@"https://www.dropbox.com/scl/fi/abc/Song.flac?rlkey=x&dl=1", @"flac"), @"Song.flac");
    XCTAssertEqualObjects(Name(@"https://example.com/get?file=Song.mp3", @"mp3"), @"get.mp3");
}

- (void)testTheChosenExtensionIsForcedOnAndNotDoubled {
    XCTAssertEqualObjects(Name(@"https://example.com/song.mp3", @"mp3"), @"song.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/song.MP3", @"mp3"), @"song.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/song.mp3", @"flac"), @"song.flac");
    XCTAssertEqualObjects(Name(@"https://example.com/song.ogg", @"opus"), @"song.opus");
    XCTAssertEqualObjects(Name(@"https://example.com/song.mp3.mp3", @"mp3"), @"song.mp3.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/song.v2", @"m4a"), @"song.v2.m4a");
    XCTAssertEqualObjects(Name(@"https://example.com/song.txt", @"mp3"), @"song.txt.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/download", @"ogg"), @"download.ogg");
}

- (void)testSeparatorsControlsAndLeadingDotsAreCleaned {
    XCTAssertEqualObjects(Name(@"https://example.com/a%2Fb%3Ac.mp3", @"mp3"), @"a-b-c.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/a:b.mp3", @"mp3"), @"a-b.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/..hidden.mp3", @"mp3"), @"hidden.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/.%20.x.wav", @"wav"), @"x.wav");
    XCTAssertEqualObjects(Name(@"https://example.com/%20%20spaced%20%20.mp3", @"mp3"), @"spaced.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/line%0Abreak%00.mp3", @"mp3"), @"linebreak.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/del%7Fete%C2%85.mp3", @"mp3"), @"delete.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/a.b.c.mp3", @"mp3"), @"a.b.c.mp3");
}

// The joiners of an emoji sequence or a Persian word are format characters,
// not controls.
- (void)testJoinersSurvive {
    NSString *family = @"👨‍👩‍👧";
    NSString *encoded = [family stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    XCTAssertEqualObjects(Name([NSString stringWithFormat:@"https://example.com/%@.mp3", encoded], @"mp3"),
                          [family stringByAppendingString:@".mp3"]);
    NSString *persian = @"می‌خواهم";
    encoded = [persian stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    XCTAssertEqualObjects(Name([NSString stringWithFormat:@"https://example.com/%@.mp3", encoded], @"mp3"),
                          [persian stringByAppendingString:@".mp3"]);
}

- (void)testNothingLeftIsLink {
    XCTAssertEqualObjects(Name(@"https://example.com", @"mp3"), @"Link.mp3");
    XCTAssertEqualObjects(Name(@"https://example.com/", @"flac"), @"Link.flac");
    XCTAssertEqualObjects(Name(@"https://example.com/?a=b", @"flac"), @"Link.flac");
    XCTAssertEqualObjects(Name(@"https://example.com/...", @"wav"), @"Link.wav");
    XCTAssertEqualObjects(Name(@"https://example.com/%20", @"wav"), @"Link.wav");
    XCTAssertEqualObjects(Name(@"https://example.com/%0A%0D", @"ogg"), @"Link.ogg");
    XCTAssertEqualObjects(Name(@"https://example.com/.%20.mp3", @"mp3"), @"Link.mp3");
}

- (void)testALongNameIsCutToTwoHundredBytes {
    NSString *exact = [@"" stringByPaddingToLength:196 withString:@"a" startingAtIndex:0];
    NSString *name = Name([NSString stringWithFormat:@"https://example.com/%@.mp3", exact], @"mp3");
    XCTAssertEqual(UTF8Length(name), kVibeLinkNameMaxBytes);
    XCTAssertEqualObjects(name, [exact stringByAppendingString:@".mp3"]);

    NSString *ascii = [@"" stringByPaddingToLength:300 withString:@"a" startingAtIndex:0];
    name = Name([NSString stringWithFormat:@"https://example.com/%@.mp3", ascii], @"mp3");
    XCTAssertEqual(UTF8Length(name), kVibeLinkNameMaxBytes);
    XCTAssertTrue([name hasSuffix:@"a.mp3"]);

    name = Name([NSString stringWithFormat:@"https://example.com/%@.mp3", ascii], @"flac");
    XCTAssertEqual(UTF8Length(name), kVibeLinkNameMaxBytes);
    XCTAssertTrue([name hasSuffix:@"a.flac"]);
}

- (void)testACutNeverSplitsACharacter {
    // é is two bytes: 97 of them and ".flac" is 199, and a 98th would be 201.
    NSString *wide = [@"" stringByPaddingToLength:150 withString:@"é" startingAtIndex:0];
    NSString *encoded = [wide stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSString *name = Name([NSString stringWithFormat:@"https://example.com/%@.flac", encoded], @"flac");
    XCTAssertEqualObjects(name, [[wide substringToIndex:97] stringByAppendingString:@".flac"]);

    // 日 is three bytes: 65 of them and ".mp3" is 199.
    NSString *cjk = [@"" stringByPaddingToLength:100 withString:@"日" startingAtIndex:0];
    encoded = [cjk stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    name = Name([NSString stringWithFormat:@"https://example.com/%@.mp3", encoded], @"mp3");
    XCTAssertEqualObjects(name, [[cjk substringToIndex:65] stringByAppendingString:@".mp3"]);

    // A four-byte emoji is two UTF-16 units. Neither half may be left alone.
    // 49 of them and ".mp3" is 200.
    NSMutableString *notes = [NSMutableString string];
    for (int i = 0; i < 60; i++) [notes appendString:@"🎵"];
    encoded = [notes stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    name = Name([NSString stringWithFormat:@"https://example.com/%@.mp3", encoded], @"mp3");
    XCTAssertEqualObjects(name, [[notes substringToIndex:49 * 2] stringByAppendingString:@".mp3"]);

    // A base letter and its combining accent are one character.
    NSMutableString *combining = [NSMutableString string];
    for (int i = 0; i < 80; i++) [combining appendString:@"é"];
    encoded = [combining stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    name = Name([NSString stringWithFormat:@"https://example.com/%@.mp3", encoded], @"mp3");
    XCTAssertLessThanOrEqual(UTF8Length(name), kVibeLinkNameMaxBytes);
    XCTAssertEqual(name.stringByDeletingPathExtension.length % 2, 0u);
    XCTAssertTrue([combining hasPrefix:name.stringByDeletingPathExtension]);
}

- (void)testACutTrimsTheSpaceItLeaves {
    NSString *stem = [[@"" stringByPaddingToLength:195 withString:@"a" startingAtIndex:0] stringByAppendingString:@"%20bbbbbbbb"];
    NSString *name = Name([NSString stringWithFormat:@"https://example.com/%@.mp3", stem], @"mp3");
    XCTAssertEqualObjects(name, [[@"" stringByPaddingToLength:195 withString:@"a" startingAtIndex:0] stringByAppendingString:@".mp3"]);
}

#pragma mark - The link's directory

- (void)testTheDirectoryIsTheNormalizedURLsHash {
    // printf '%s' 'https://example.com/Song.mp3' | shasum
    NSURL *url = [NSURL URLWithString:@"https://example.com/Song.mp3"];
    XCTAssertEqualObjects(VibeLinkDirectoryName(url), @"f07de54197a3250f");
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    XCTAssertEqual([VibeLinkDirectoryName(url) rangeOfCharacterFromSet:hex.invertedSet].location, NSNotFound);
}

- (void)testNormalizingLowersSchemeAndHostAndDropsTheFragment {
    NSDictionary<NSString *, NSString *> *cases = @{
        @"HTTPS://Example.COM/Song.mp3": @"https://example.com/Song.mp3",
        @"https://example.com/Song.mp3#t=30": @"https://example.com/Song.mp3",
        @"https://example.com/Song.mp3#": @"https://example.com/Song.mp3",
        @"https://EXAMPLE.com/Song.mp3?A=B#x": @"https://example.com/Song.mp3?A=B",
        @"https://example.com:8443/Song.mp3": @"https://example.com:8443/Song.mp3",
        @"https://User:Pass@Example.com/Song.mp3": @"https://User:Pass@example.com/Song.mp3",
        @"https://example.com/My%20Song.mp3": @"https://example.com/My%20Song.mp3",
        @"http://[FE80::1]:8000/a.mp3": @"http://[fe80::1]:8000/a.mp3",
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSString *typed, NSString *normal, BOOL *stop) {
        XCTAssertEqualObjects(VibeLinkNormalizedURLString([NSURL URLWithString:typed]), normal, @"%@", typed);
    }];
    XCTAssertEqualObjects(VibeLinkDirectoryName([NSURL URLWithString:@"HTTPS://Example.COM/Song.mp3#t=30"]),
                          @"f07de54197a3250f");
}

// The path and the query are the server's to read, so their case stays.
- (void)testPathAndQueryKeepTheirCase {
    NSString *song = VibeLinkDirectoryName([NSURL URLWithString:@"https://example.com/Song.mp3"]);
    XCTAssertNotEqualObjects(VibeLinkDirectoryName([NSURL URLWithString:@"https://example.com/song.mp3"]), song);
    XCTAssertNotEqualObjects(VibeLinkDirectoryName([NSURL URLWithString:@"https://example.com/Song.mp3?v=2"]), song);
    XCTAssertNotEqualObjects(VibeLinkDirectoryName([NSURL URLWithString:@"http://example.com/Song.mp3"]), song);
    XCTAssertNotEqualObjects(VibeLinkDirectoryName([NSURL URLWithString:@"https://example.com:444/Song.mp3"]), song);
}

#pragma mark - Response headers

- (void)testContentRangeTotal {
    NSDictionary<NSString *, NSNumber *> *cases = @{
        @"bytes 0-15/12345": @12345,
        @"bytes */12345": @12345,
        @"bytes 0-0/1": @1,
        @"bytes */0": @0,
        @"Bytes 0-15/5000000000": @5000000000LL,
        @"BYTES 0-15/100": @100,
        @"  bytes 0-15/100  ": @100,
        @"bytes 0-15/ 100": @100,
        @"bytes 0-15/999999999999999999": @999999999999999999LL,
        @"bytes 0-15/*": @-1,
        @"bytes */*": @-1,
        @"bytes 0-15": @-1,
        @"bytes 0-15/": @-1,
        @"bytes 0-15/12a": @-1,
        @"bytes 0-15/1e5": @-1,
        @"bytes 0-15/-3": @-1,
        @"bytes 0-15/+3": @-1,
        @"bytes 0-15/1.5": @-1,
        @"bytes 0-15/9999999999999999999": @-1,
        @"bytes 0-15/١٢٣": @-1,
        @"items 0-15/100": @-1,
        @"/100": @-1,
        @"100": @-1,
        @"": @-1,
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSString *header, NSNumber *total, BOOL *stop) {
        XCTAssertEqual(VibeLinkContentRangeTotal(header), total.longLongValue, @"%@", header);
    }];
    XCTAssertEqual(VibeLinkContentRangeTotal(nil), -1);
}

- (void)testAWeakETagCountsAsAbsent {
    XCTAssertEqualObjects(VibeLinkStrongETag(@"\"abc\""), @"\"abc\"");
    XCTAssertEqualObjects(VibeLinkStrongETag(@"abc"), @"abc");
    XCTAssertEqualObjects(VibeLinkStrongETag(@"  \"abc\"  "), @"\"abc\"");
    XCTAssertEqualObjects(VibeLinkStrongETag(@"\"W/abc\""), @"\"W/abc\"");
    XCTAssertNil(VibeLinkStrongETag(@"W/\"abc\""));
    XCTAssertNil(VibeLinkStrongETag(@"w/\"abc\""));
    XCTAssertNil(VibeLinkStrongETag(@" W/\"abc\""));
    XCTAssertNil(VibeLinkStrongETag(@""));
    XCTAssertNil(VibeLinkStrongETag(@"   "));
    XCTAssertNil(VibeLinkStrongETag(nil));
}

- (void)testTheBudgetIsTwoGigabytes {
    XCTAssertEqual(kVibeLinkDownloadBudgetBytes, 2000000000);
}

#pragma mark - Pruning

- (void)testPruningTakesOldLinksNothingKeeps {
    NSTimeInterval now = 2000000000, day = 24 * 60 * 60;
    NSDictionary<NSString *, id> *records = @{
        @"old": @{@"opened": @(now - 31 * day)},
        @"kept": @{@"opened": @(now - 31 * day)},
        @"recent": @{@"opened": @(now - 29 * day)},
        @"edge": @{@"opened": @(now - 30 * day)},
        @"none": NSNull.null,
        @"unopened": @{@"url": @"https://example.com/a.mp3"},
        @"garbled": @{@"opened": @"yesterday"},
    };
    XCTAssertEqualObjects(VibeLinkDirectoriesToPrune(records, [NSSet setWithObject:@"kept"], now),
                          (@[@"garbled", @"none", @"old", @"unopened"]));
    XCTAssertEqualObjects(VibeLinkDirectoriesToPrune(@{}, [NSSet set], now), @[]);
    XCTAssertEqual(kVibeLinkPruneAgeSeconds, 30 * day);
}

#pragma mark - Failures

- (void)testEachAcceptanceNamesItsFailure {
    XCTAssertEqual(VibeLinkErrorOfAcceptance(VibeLinkAccepted), VibeLinkErrorNone);
    XCTAssertEqual(VibeLinkErrorOfAcceptance(VibeLinkRefusedInsecurePublicHTTP), VibeLinkErrorInsecure);
    XCTAssertEqual(VibeLinkErrorOfAcceptance(VibeLinkRefusedNotHTTP), VibeLinkErrorInvalid);
    XCTAssertEqual(VibeLinkErrorOfAcceptance(VibeLinkRefusedInvalid), VibeLinkErrorInvalid);
    XCTAssertEqual(VibeLinkErrorOfAcceptance((VibeLinkAcceptance)99), VibeLinkErrorInvalid);
}

- (void)testEachStatusNamesItsFailure {
    for (NSNumber *status in @[@200, @204, @206, @299]) {
        XCTAssertEqual(VibeLinkErrorOfStatus(status.integerValue), VibeLinkErrorNone, @"%@", status);
    }
    XCTAssertEqual(VibeLinkErrorOfStatus(401), VibeLinkErrorDenied);
    XCTAssertEqual(VibeLinkErrorOfStatus(403), VibeLinkErrorDenied);
    XCTAssertEqual(VibeLinkErrorOfStatus(404), VibeLinkErrorNotFound);
    XCTAssertEqual(VibeLinkErrorOfStatus(410), VibeLinkErrorNotFound);
    for (NSNumber *status in @[@0, @100, @199, @300, @302, @304, @400, @402, @405, @416, @429, @451,
                               @500, @502, @503, @599]) {
        XCTAssertEqual(VibeLinkErrorOfStatus(status.integerValue), VibeLinkErrorServer, @"%@", status);
    }
}

- (void)testEachNetworkErrorNamesItsFailure {
    NSError *(^url)(NSInteger) = ^NSError *(NSInteger code) {
        return [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil];
    };
    XCTAssertEqual(VibeLinkErrorOfNetworkError(nil, @"example.com"), VibeLinkErrorNone);
    XCTAssertEqual(VibeLinkErrorOfNetworkError(url(NSURLErrorCancelled), @"pi.local"), VibeLinkErrorNone);
    XCTAssertEqual(VibeLinkErrorOfNetworkError(url(NSURLErrorAppTransportSecurityRequiresSecureConnection), @"example.com"),
                   VibeLinkErrorInsecure);
    XCTAssertEqual(VibeLinkErrorOfNetworkError(url(NSURLErrorAppTransportSecurityRequiresSecureConnection), @"pi.local"),
                   VibeLinkErrorInsecure);
    XCTAssertEqual(VibeLinkErrorOfNetworkError(url(NSURLErrorBadURL), @"example.com"), VibeLinkErrorInvalid);
    XCTAssertEqual(VibeLinkErrorOfNetworkError(url(NSURLErrorUnsupportedURL), @"example.com"), VibeLinkErrorInvalid);

    for (NSNumber *code in @[@(NSURLErrorTimedOut), @(NSURLErrorCannotFindHost), @(NSURLErrorCannotConnectToHost),
                             @(NSURLErrorNetworkConnectionLost), @(NSURLErrorNotConnectedToInternet),
                             @(NSURLErrorDNSLookupFailed), @(NSURLErrorSecureConnectionFailed),
                             @(NSURLErrorServerCertificateUntrusted)]) {
        XCTAssertEqual(VibeLinkErrorOfNetworkError(url(code.integerValue), @"example.com"), VibeLinkErrorUnreachable, @"%@", code);
        XCTAssertEqual(VibeLinkErrorOfNetworkError(url(code.integerValue), @"pi.local"), VibeLinkErrorLocalNetwork, @"%@", code);
        XCTAssertEqual(VibeLinkErrorOfNetworkError(url(code.integerValue), @"192.168.1.5"), VibeLinkErrorLocalNetwork, @"%@", code);
        XCTAssertEqual(VibeLinkErrorOfNetworkError(url(code.integerValue), @"[fe80::1%en0]"), VibeLinkErrorLocalNetwork, @"%@", code);
        XCTAssertEqual(VibeLinkErrorOfNetworkError(url(code.integerValue), nil), VibeLinkErrorUnreachable, @"%@", code);
    }

    NSError *posix = [NSError errorWithDomain:NSPOSIXErrorDomain code:ECONNREFUSED userInfo:nil];
    XCTAssertEqual(VibeLinkErrorOfNetworkError(posix, @"nas"), VibeLinkErrorLocalNetwork);
    XCTAssertEqual(VibeLinkErrorOfNetworkError(posix, @"example.com"), VibeLinkErrorUnreachable);
    NSError *otherCancel = [NSError errorWithDomain:NSCocoaErrorDomain code:NSURLErrorCancelled userInfo:nil];
    XCTAssertEqual(VibeLinkErrorOfNetworkError(otherCancel, @"example.com"), VibeLinkErrorUnreachable);
}

- (void)testAMissingSizeIsALiveStreamOrNoSize {
    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{@"icy-name": @"Radio"}), VibeLinkErrorLiveStream);
    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{@"Icy-MetaInt": @"16000", @"Content-Type": @"text/plain"}),
                   VibeLinkErrorLiveStream);
    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{@"Transfer-Encoding": @"chunked", @"Content-Type": @"audio/mpeg"}),
                   VibeLinkErrorLiveStream);
    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{@"transfer-encoding": @"gzip, Chunked", @"content-type": @"audio/aacp"}),
                   VibeLinkErrorLiveStream);

    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{@"Transfer-Encoding": @"chunked", @"Content-Type": @"text/html"}),
                   VibeLinkErrorNoSize);
    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{@"Transfer-Encoding": @"chunked"}), VibeLinkErrorNoSize);
    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{@"Content-Type": @"audio/mpeg"}), VibeLinkErrorNoSize);
    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{@"Transfer-Encoding": @"identity", @"Content-Type": @"audio/mpeg"}),
                   VibeLinkErrorNoSize);
    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{@"X-Icy": @"1"}), VibeLinkErrorNoSize);
    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{@1: @"icy-", @"Content-Type": @2}), VibeLinkErrorNoSize);
    XCTAssertEqual(VibeLinkErrorOfMissingSize(@{}), VibeLinkErrorNoSize);
    XCTAssertEqual(VibeLinkErrorOfMissingSize(nil), VibeLinkErrorNoSize);
}

#pragma mark - What the shells show

static NSError *LinkError(VibeLinkError code, NSDictionary *info) {
    return [NSError errorWithDomain:VibeLinkErrorDomain code:code userInfo:info];
}

- (void)testEachFailureShowsItsOwnString {
    NSDictionary<NSNumber *, NSString *> *expected = @{
        @(VibeLinkErrorInvalid): STR_LINK_ERROR_INVALID,
        @(VibeLinkErrorInsecure): STR_LINK_ERROR_INSECURE,
        @(VibeLinkErrorUnreachable): STR_LINK_ERROR_UNREACHABLE,
        @(VibeLinkErrorLocalNetwork): STR_LINK_ERROR_LOCAL_NETWORK,
        @(VibeLinkErrorNotFound): STR_LINK_ERROR_NOT_FOUND,
        @(VibeLinkErrorDenied): STR_LINK_ERROR_DENIED,
        @(VibeLinkErrorNotAudio): STR_LINK_ERROR_NOT_AUDIO,
        @(VibeLinkErrorNoSize): STR_LINK_ERROR_NO_SIZE,
        @(VibeLinkErrorLiveStream): STR_LINK_ERROR_LIVE_STREAM,
    };
    for (NSNumber *code in expected) {
        XCTAssertEqualObjects([LinkStore messageForError:LinkError(code.integerValue, nil)], expected[code], @"%@", code);
    }
    NSMutableSet<NSString *> *distinct = [NSMutableSet setWithArray:expected.allValues];
    [distinct addObject:STR_LINK_ERROR_SERVER];
    XCTAssertEqual(distinct.count, expected.count + 1, @"no two failures share a message");
}

// The status goes into the message. A server error with no status still
// shows the server's message.
- (void)testAServerFailureNamesItsStatus {
    NSError *error = LinkError(VibeLinkErrorServer, @{VibeHTTPErrorStatusCodeKey: @503});
    NSString *with503 = [NSString stringWithFormat:STR_LINK_ERROR_SERVER, 503L];
    NSString *withNone = [NSString stringWithFormat:STR_LINK_ERROR_SERVER, 0L];
    XCTAssertEqualObjects([LinkStore messageForError:error], with503);
    XCTAssertTrue([[LinkStore messageForError:error] containsString:@"503"]);
    XCTAssertEqualObjects([LinkStore messageForError:LinkError(VibeLinkErrorServer, nil)], withNone);
}

// A disk failure is passed through as its POSIX error. It, a code from
// another domain, a code no shell names and nil all read as unreachable.
- (void)testAnythingElseReadsAsUnreachable {
    NSError *posix = [NSError errorWithDomain:NSPOSIXErrorDomain code:VibeLinkErrorDenied userInfo:nil];
    XCTAssertEqualObjects([LinkStore messageForError:posix], STR_LINK_ERROR_UNREACHABLE);
    NSError *network = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
    XCTAssertEqualObjects([LinkStore messageForError:network], STR_LINK_ERROR_UNREACHABLE);
    XCTAssertEqualObjects([LinkStore messageForError:LinkError(VibeLinkErrorNone, nil)], STR_LINK_ERROR_UNREACHABLE);
    XCTAssertEqualObjects([LinkStore messageForError:LinkError(99, nil)], STR_LINK_ERROR_UNREACHABLE);
    XCTAssertEqualObjects([LinkStore messageForError:LinkError(-1, nil)], STR_LINK_ERROR_UNREACHABLE);
    XCTAssertEqualObjects([LinkStore messageForError:nil], STR_LINK_ERROR_UNREACHABLE);
}

// Open with nothing typed is Cancel, not an invalid address.
- (void)testABlankEntryOpensNothing {
    for (NSString *text in @[@"", @" ", @"\t", @"\n", @" \r\n\t ", @"\u00A0\u2003"]) {
        XCTAssertTrue(VibeLinkTextIsBlank(text), @"%@", text.debugDescription);
    }
    XCTAssertTrue(VibeLinkTextIsBlank(nil));
    for (NSString *text in @[@"h", @" https://example.com/a.mp3 ", @"not a link", @"."]) {
        XCTAssertFalse(VibeLinkTextIsBlank(text), @"%@", text);
    }
    // What is not blank but parses as nothing is the invalid address's.
    XCTAssertEqual(Accept(@"not a link"), VibeLinkRefusedInvalid);
}

- (void)testPruningKeepsEveryRowAndRecentFile {
    NSURL *row = [NSURL fileURLWithPath:@"/links/aa/One.mp3"];
    NSURL *cueRow = [NSURL fileURLWithPath:@"/links/bb/Image.flac"];
    NSURL *recent = [NSURL fileURLWithPath:@"/links/cc/Two.mp3"];
    NSURL *web = [NSURL URLWithString:@"https://example.com/a.mp3"];
    NSSet *kept = VibeLinkKeptURLs(@[row, cueRow, cueRow, web], @[recent, row]);
    XCTAssertEqualObjects(kept, ([NSSet setWithObjects:row, cueRow, recent, nil]));
    XCTAssertEqualObjects(VibeLinkKeptURLs(@[], @[]), [NSSet set]);
}

@end
