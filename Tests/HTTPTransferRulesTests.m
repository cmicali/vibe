//
//  HTTPTransferRulesTests.m
//
//  The HTTP transfer's decisions that need no network: when to resend, and
//  the size and version a response's headers state.
//

#import <XCTest/XCTest.h>

#import "HTTPTransferRules.h"

@interface HTTPTransferRulesTests : XCTestCase
@end

@implementation HTTPTransferRulesTests

- (void)testThrottlingIsRetriedAfterACappedDelay {
    XCTAssertEqual(VibeHTTPRetryDelay(429, @"3"), 3.0);
    XCTAssertEqual(VibeHTTPRetryDelay(429, nil), 1.0);
    XCTAssertEqual(VibeHTTPRetryDelay(429, @"0"), 1.0);
    XCTAssertEqual(VibeHTTPRetryDelay(429, @"soon"), 1.0);
    XCTAssertEqual(VibeHTTPRetryDelay(503, @"300"), 10.0);
    XCTAssertLessThan(VibeHTTPRetryDelay(409, @"3"), 0);
    XCTAssertLessThan(VibeHTTPRetryDelay(500, nil), 0);
    XCTAssertLessThan(VibeHTTPRetryDelay(404, nil), 0);
}

- (void)testOnlyALostLinkIsAConnectionError {
    for (NSNumber *code in @[@(NSURLErrorTimedOut), @(NSURLErrorNetworkConnectionLost),
                             @(NSURLErrorNotConnectedToInternet), @(NSURLErrorCannotConnectToHost),
                             @(NSURLErrorCannotFindHost), @(NSURLErrorDNSLookupFailed)]) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:code.integerValue userInfo:nil];
        XCTAssertTrue(VibeHTTPIsConnectionError(error), @"%@", code);
    }
    for (NSNumber *code in @[@(NSURLErrorCancelled), @(NSURLErrorSecureConnectionFailed),
                             @(NSURLErrorBadServerResponse), @(NSURLErrorAppTransportSecurityRequiresSecureConnection)]) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:code.integerValue userInfo:nil];
        XCTAssertFalse(VibeHTTPIsConnectionError(error), @"%@", code);
    }
    XCTAssertFalse(VibeHTTPIsConnectionError([NSError errorWithDomain:NSPOSIXErrorDomain
                                                                 code:NSURLErrorTimedOut userInfo:nil]));
    XCTAssertFalse(VibeHTTPIsConnectionError(nil));
}

- (void)testALengthIsDigitsOnly {
    XCTAssertEqual(VibeHTTPParseLength(@"4000"), 4000);
    XCTAssertEqual(VibeHTTPParseLength(@" 0 "), 0);
    XCTAssertEqual(VibeHTTPParseLength(@"9223372036854775807"), INT64_MAX);
    XCTAssertEqual(VibeHTTPParseLength(@"9223372036854775808"), -1);
    XCTAssertEqual(VibeHTTPParseLength(@"-1"), -1);
    XCTAssertEqual(VibeHTTPParseLength(@"12a"), -1);
    XCTAssertEqual(VibeHTTPParseLength(@"1 2"), -1);
    XCTAssertEqual(VibeHTTPParseLength(@""), -1);
    XCTAssertEqual(VibeHTTPParseLength(nil), -1);
}

- (void)testAContentRangeStatesItsTotal {
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes 0-15/4000"), 4000);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes 3999-3999/4000"), 4000);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"Bytes 0-0/1"), 1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes */4000"), 4000);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@" bytes  0-15/4000 "), 4000);
}

- (void)testAnUnknownOrMalformedContentRangeStatesNoTotal {
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes 0-15/*"), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes */*"), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes 0-15"), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes 15/4000"), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes 16-15/4000"), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes 0-4000/4000"), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes a-b/4000"), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"bytes 0-15/-4000"), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"items 0-15/4000"), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@"0-15/4000"), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(@""), -1);
    XCTAssertEqual(VibeHTTPContentRangeTotal(nil), -1);
}

- (void)testThePartialAnswerSizesByContentRangeAndTheWholeByContentLength {
    XCTAssertEqual(VibeHTTPSizeFromHeaders(206, @"bytes 0-15/4000", @"16", nil), 4000);
    XCTAssertEqual(VibeHTTPSizeFromHeaders(206, nil, @"16", nil), -1);
    XCTAssertEqual(VibeHTTPSizeFromHeaders(200, nil, @"4000", nil), 4000);
    XCTAssertEqual(VibeHTTPSizeFromHeaders(200, @"bytes 0-15/9999", @"4000", nil), 4000);
    XCTAssertEqual(VibeHTTPSizeFromHeaders(200, nil, nil, nil), -1);
    XCTAssertEqual(VibeHTTPSizeFromHeaders(404, @"bytes 0-15/4000", @"4000", nil), -1);
    XCTAssertEqual(VibeHTTPSizeFromHeaders(416, @"bytes */4000", nil, nil), -1);
}

- (void)testAnEncodedLengthIsNotTheFilesSize {
    XCTAssertEqual(VibeHTTPSizeFromHeaders(200, nil, @"4000", @"gzip"), -1);
    XCTAssertEqual(VibeHTTPSizeFromHeaders(200, nil, @"4000", @"br"), -1);
    XCTAssertEqual(VibeHTTPSizeFromHeaders(200, nil, @"4000", @"identity"), 4000);
    XCTAssertEqual(VibeHTTPSizeFromHeaders(200, nil, @"4000", @"Identity"), 4000);
    XCTAssertEqual(VibeHTTPSizeFromHeaders(200, nil, @"4000", @""), 4000);
    // A range's total is the file's, whatever the encoding of the bytes sent.
    XCTAssertEqual(VibeHTTPSizeFromHeaders(206, @"bytes 0-15/4000", @"16", @"gzip"), 4000);
}

- (void)testAStrongETagNamesTheVersion {
    XCTAssertEqualObjects(VibeHTTPVersionFromHeaders(@"\"abc\"", @"Wed, 21 Oct 2015 07:28:00 GMT"), @"\"abc\"");
    XCTAssertEqualObjects(VibeHTTPVersionFromHeaders(@" \"abc\" ", nil), @"\"abc\"");
}

- (void)testWithNoStrongETagLastModifiedNamesTheVersion {
    NSString *modified = @"Wed, 21 Oct 2015 07:28:00 GMT";
    XCTAssertEqualObjects(VibeHTTPVersionFromHeaders(@"W/\"abc\"", modified), modified);
    XCTAssertEqualObjects(VibeHTTPVersionFromHeaders(nil, modified), modified);
    XCTAssertEqualObjects(VibeHTTPVersionFromHeaders(@"", modified), modified);
    XCTAssertNil(VibeHTTPVersionFromHeaders(@"W/\"abc\"", nil));
    XCTAssertNil(VibeHTTPVersionFromHeaders(nil, @" "));
    XCTAssertNil(VibeHTTPVersionFromHeaders(nil, nil));
    XCTAssertNil(VibeHTTPVersionFromHeaders(@"w/\"abc\"", nil), @"weak in either case");
    XCTAssertEqualObjects(VibeHTTPVersionFromHeaders(@"\"W/abc\"", nil), @"\"W/abc\"", @"a quoted W/ is strong");
}

- (void)testTheSameSizeAndDateUnderAnotherETagIsTheSameFile {
    NSString *modified = @"Wed, 21 Oct 2015 07:28:00 GMT";
    XCTAssertTrue(VibeHTTPIsSameFileUnderAnotherETag(4000, modified, 4000, modified));
    XCTAssertTrue(VibeHTTPIsSameFileUnderAnotherETag(4000, modified, 4000, @" Wed, 21 Oct 2015 07:28:00 GMT "));
    XCTAssertFalse(VibeHTTPIsSameFileUnderAnotherETag(4000, modified, 4001, modified));
    XCTAssertFalse(VibeHTTPIsSameFileUnderAnotherETag(4000, modified, 4000, @"Thu, 22 Oct 2015 07:28:00 GMT"));
    XCTAssertFalse(VibeHTTPIsSameFileUnderAnotherETag(4000, nil, 4000, nil), @"no date proves nothing");
    XCTAssertFalse(VibeHTTPIsSameFileUnderAnotherETag(4000, modified, 4000, nil));
    XCTAssertFalse(VibeHTTPIsSameFileUnderAnotherETag(4000, @" ", 4000, @" "));
    XCTAssertFalse(VibeHTTPIsSameFileUnderAnotherETag(-1, modified, -1, modified), @"no size proves nothing");
}

@end
