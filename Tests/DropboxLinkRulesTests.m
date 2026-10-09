//
//  DropboxLinkRulesTests.m
//
//  Open URL's Dropbox share links: which links get dl=1, that the share-link
//  rewrite asks this file, and that LinkStore opens one (DropboxLinkStoreTests).
//

#import <XCTest/XCTest.h>

#import "DropboxLinkRules.h"
#import "LinkRules.h"
#import "LinkStoreTestCase.h"

@interface DropboxLinkRulesTests : XCTestCase
@end

@implementation DropboxLinkRulesTests

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
        @"https://www.dropbox.com/scl/fi/5b8vg9wzcs/122-Basti-Pieper-I-Love-You.aif?rlkey=iobgi14c49&dl=0":
            @"https://www.dropbox.com/scl/fi/5b8vg9wzcs/122-Basti-Pieper-I-Love-You.aif?rlkey=iobgi14c49&dl=1",
    };
    [cases enumerateKeysAndObjectsUsingBlock:^(NSString *link, NSString *expected, BOOL *stop) {
        XCTAssertEqualObjects(VibeDropboxLinkDownloadURL([NSURL URLWithString:link]).absoluteString, expected, @"%@", link);
    }];
}

- (void)testAnythingButAFileShareLinkIsNotOne {
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
        XCTAssertNil(VibeDropboxLinkDownloadURL([NSURL URLWithString:string]), @"%@", string);
    }
}

- (void)testTheShareLinkRewriteAsksThisFile {
    NSURL *link = [NSURL URLWithString:@"https://www.dropbox.com/s/abc123/Song.mp3?dl=0"];
    XCTAssertEqualObjects(VibeLinkDirectDownloadURL(link).absoluteString,
                          @"https://www.dropbox.com/s/abc123/Song.mp3?dl=1");
    NSURL *folder = [NSURL URLWithString:@"https://www.dropbox.com/sh/abc/folder?dl=0"];
    XCTAssertEqualObjects(VibeLinkDirectDownloadURL(folder), folder, @"fetched as typed");
}

@end

// A Dropbox link through the real LinkStore, over HTTPStub answering Dropbox's
// host.
@interface DropboxLinkStoreTests : LinkStoreTestCase
@end

@implementation DropboxLinkStoreTests

- (void)testADropboxShareLinkAsksForTheFile {
    [_stub answerHost:@"www.dropbox.com"];
    NSMutableData *bytes = [FlacBytes(4000) mutableCopy];
    memcpy(bytes.mutableBytes, "ID3", 3);
    [self serve:bytes at:@"/scl/fi/abc123/Song.mp3" headers:@{@"ETag": @"\"v1\""}];
    NSError *error = nil;
    NSURL *file = [self resolve:@"https://www.dropbox.com/scl/fi/abc123/Song.mp3?rlkey=k1&dl=0" error:&error];
    XCTAssertNotNil(file, @"%@", error);
    XCTAssertEqualObjects(file.lastPathComponent, @"Song.mp3");
    NSURLComponents *sent = [NSURLComponents componentsWithURL:_stub.requests.firstObject.URL resolvingAgainstBaseURL:NO];
    XCTAssertEqualObjects(sent.query, @"rlkey=k1&dl=1");
    XCTAssertEqualObjects([self recordOf:file][@"url"],
                          @"https://www.dropbox.com/scl/fi/abc123/Song.mp3?rlkey=k1&dl=1");
}

@end
