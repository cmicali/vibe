//
// Which play failures a shell shows. The line is StringRulesTests'.
//

#import <XCTest/XCTest.h>

#import "AudioErrorRules.h"

@interface AudioErrorRulesTests : XCTestCase
@end

@implementation AudioErrorRulesTests

static NSError *VibeErr(NSString *domain, NSInteger code) {
    return [NSError errorWithDomain:domain code:code userInfo:nil];
}

- (void)testOnlyNotPlayingInOurDomainIsBenign {
    XCTAssertTrue(VibePlayErrorIsBenign(VibeErr(VibeAudioErrorDomain(), VibeAudioErrorNotPlaying)));
    XCTAssertFalse(VibePlayErrorIsBenign(VibeErr(NSPOSIXErrorDomain, VibeAudioErrorNotPlaying)));
    for (NSNumber *code in @[@(VibeAudioErrorFileOpenFailed), @(VibeAudioErrorFileOpenTimedOut),
                             @(VibeAudioErrorEngineStartFailed), @(VibeAudioErrorDeviceUnavailable),
                             @(VibeAudioErrorDeviceInUse), @(VibeAudioErrorConnectionLost), @9999]) {
        XCTAssertFalse(VibePlayErrorIsBenign(VibeErr(VibeAudioErrorDomain(), code.integerValue)));
    }
}

- (void)testTrackErrorsMatchURLRatherThanURLObjectIdentity {
    NSURL *url = [NSURL fileURLWithPath:@"/a.wav"];
    NSError *error = [NSError errorWithDomain:VibeAudioErrorDomain() code:VibeAudioErrorFileOpenFailed
                                    userInfo:@{kVibeAudioErrorTrackURLKey: url}];
    XCTAssertTrue(VibePlayErrorMatchesCurrentURL(error, [NSURL fileURLWithPath:@"/a.wav"]));
    XCTAssertFalse(VibePlayErrorMatchesCurrentURL(error, [NSURL fileURLWithPath:@"/b.wav"]));
    XCTAssertFalse(VibePlayErrorMatchesCurrentURL(error, nil));
}

- (void)testGraphErrorsWithoutURLSurviveTheShellURLFilter {
    for (NSNumber *code in @[@(VibeAudioErrorEngineStartFailed), @(VibeAudioErrorDeviceUnavailable)]) {
        NSError *error = VibeErr(VibeAudioErrorDomain(), code.integerValue);
        XCTAssertTrue(VibePlayErrorMatchesCurrentURL(error, nil));
        XCTAssertTrue(VibePlayErrorMatchesCurrentURL(error, [NSURL fileURLWithPath:@"/a.wav"]));
    }
}

@end
