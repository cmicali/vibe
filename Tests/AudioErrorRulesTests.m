//
// The inline status line for a play failure: one mapping, both platforms.
//

#import <XCTest/XCTest.h>

#import "AudioErrorRules.h"

@interface AudioErrorRulesTests : XCTestCase
@end

@implementation AudioErrorRulesTests

static NSError *VibeErr(NSString *domain, NSInteger code) {
    return [NSError errorWithDomain:domain code:code userInfo:nil];
}

#pragma mark - The mapped codes

- (void)testEachCodeMapsToItsOwnLine {
    NSArray<NSNumber *> *codes = @[@(VibeAudioErrorFileOpenTimedOut),
                                   @(VibeAudioErrorFileOpenFailed),
                                   @(VibeAudioErrorEngineStartFailed),
                                   @(VibeAudioErrorDeviceUnavailable)];
    NSMutableSet<NSString *> *lines = [NSMutableSet set];
    for (NSNumber *code in codes) {
        NSString *line = VibeStatusForPlayError(VibeErr(kVibeAudioErrorDomain, code.integerValue));
        XCTAssertGreaterThan(line.length, 0u);
        XCTAssertNotEqualObjects(line, VibeStatusForPlayError(VibeErr(@"other.domain", 1)),
                                 @"a mapped code must not fall through to the generic line");
        [lines addObject:line];
    }
    XCTAssertEqual(lines.count, codes.count, @"the four mapped codes must not share a line");
}

#pragma mark - Everything else is the generic line

- (void)testNotPlayingFallsThroughToGeneric {
    // Filtered on the way in as a benign no-op, so it should never be given its
    // own wording here.
    XCTAssertEqualObjects(VibeStatusForPlayError(VibeErr(kVibeAudioErrorDomain,
                                                         VibeAudioErrorNotPlaying)),
                          VibeStatusForPlayError(VibeErr(@"other.domain", 1)));
}

- (void)testUnknownCodeInOurDomainIsGeneric {
    XCTAssertEqualObjects(VibeStatusForPlayError(VibeErr(kVibeAudioErrorDomain, 9999)),
                          VibeStatusForPlayError(VibeErr(@"other.domain", 1)));
}

- (void)testForeignDomainSharingACodeIsGeneric {
    // NSPOSIXErrorDomain code 1 collides numerically with VibeAudioErrorFileOpenFailed.
    XCTAssertEqualObjects(VibeStatusForPlayError(VibeErr(NSPOSIXErrorDomain,
                                                         VibeAudioErrorFileOpenFailed)),
                          VibeStatusForPlayError(VibeErr(@"other.domain", 1)));
}

- (void)testNilDomainIsGenericRatherThanACrash {
    XCTAssertEqualObjects(VibeStatusForPlayError([NSError errorWithDomain:@"" code:0 userInfo:nil]),
                          VibeStatusForPlayError(VibeErr(@"other.domain", 1)));
}

@end
