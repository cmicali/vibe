//
//  AudioSessionRecoveryRulesTests.m
//  VibeTests
//


#import <XCTest/XCTest.h>

#import "../Vibe/Audio/iOS/AudioSessionRecoveryRules.h"

@interface AudioSessionRecoveryRulesTests : XCTestCase
@end

@implementation AudioSessionRecoveryRulesTests

- (void)testConfigurationFirstHeadphoneUnplugPauses {
    XCTAssertEqual(VibeAudioSessionConfigurationActionForRoutes(
            VibeAudioSessionOutputRouteExternal,
            VibeAudioSessionOutputRouteBuiltIn,
            NO, NO, NO), VibeAudioSessionConfigurationActionPause);
}

- (void)testDisappearingOutputPauses {
    XCTAssertEqual(VibeAudioSessionConfigurationActionForRoutes(
            VibeAudioSessionOutputRouteBuiltIn,
            VibeAudioSessionOutputRouteNone,
            NO, NO, NO), VibeAudioSessionConfigurationActionPause);
}

- (void)testNewAndChangedExternalRoutesRecover {
    XCTAssertEqual(VibeAudioSessionConfigurationActionForRoutes(
            VibeAudioSessionOutputRouteBuiltIn,
            VibeAudioSessionOutputRouteExternal,
            NO, NO, NO), VibeAudioSessionConfigurationActionRecover);
    XCTAssertEqual(VibeAudioSessionConfigurationActionForRoutes(
            VibeAudioSessionOutputRouteExternal,
            VibeAudioSessionOutputRouteExternal,
            NO, NO, NO), VibeAudioSessionConfigurationActionRecover);
}

- (void)testPriorSafetyVerdictBlocksConfigurationAction {
    XCTAssertEqual(VibeAudioSessionConfigurationActionForRoutes(
            VibeAudioSessionOutputRouteExternal,
            VibeAudioSessionOutputRouteBuiltIn,
            YES, NO, NO), VibeAudioSessionConfigurationActionIgnore);
    XCTAssertEqual(VibeAudioSessionConfigurationActionForRoutes(
            VibeAudioSessionOutputRouteBuiltIn,
            VibeAudioSessionOutputRouteBuiltIn,
            NO, NO, YES), VibeAudioSessionConfigurationActionIgnore);
}

- (void)testRouteFirstHeadphoneUnplugBlocksFollowingConfiguration {
    XCTAssertEqual(VibeAudioSessionConfigurationActionForRoutes(
            VibeAudioSessionOutputRouteBuiltIn,
            VibeAudioSessionOutputRouteBuiltIn,
            NO, YES, NO), VibeAudioSessionConfigurationActionIgnore);
}

- (void)testLatestUnblockedConfigurationRecoveryMayDeliver {
    XCTAssertTrue(VibeAudioSessionMayDeliverConfigurationRecovery(
            8, 8, NO, NO, NO));
}

- (void)testRouteLossInvalidatesAlreadyScheduledRecovery {
    XCTAssertFalse(VibeAudioSessionMayDeliverConfigurationRecovery(
            8, 9, NO, YES, NO));
}

- (void)testConfigurationChangeAfterRouteLossRemainsBlocked {
    XCTAssertFalse(VibeAudioSessionMayDeliverConfigurationRecovery(
            10, 10, NO, YES, NO));
}

- (void)testInterruptionAndMediaResetEachBlockRecovery {
    XCTAssertFalse(VibeAudioSessionMayDeliverConfigurationRecovery(
            4, 4, YES, NO, NO));
    XCTAssertFalse(VibeAudioSessionMayDeliverConfigurationRecovery(
            4, 4, NO, NO, YES));
}

- (void)testNewerConfigurationChangeCoalescesAnOlderOne {
    XCTAssertFalse(VibeAudioSessionMayDeliverConfigurationRecovery(
            12, 13, NO, NO, NO));
}

- (void)testAutomaticInterruptionResumePreservesSafetyVerdicts {
    XCTAssertTrue(VibeAudioSessionMayAutomaticallyResume(NO, NO, NO));
    XCTAssertFalse(VibeAudioSessionMayAutomaticallyResume(YES, NO, NO));
    XCTAssertFalse(VibeAudioSessionMayAutomaticallyResume(NO, YES, NO));
    XCTAssertFalse(VibeAudioSessionMayAutomaticallyResume(NO, NO, YES));
}

- (void)testConfigurationFirstHeadphoneLossBlocksAutomaticResume {
    VibeAudioSessionConfigurationAction action =
            VibeAudioSessionConfigurationActionForRoutes(
                    VibeAudioSessionOutputRouteExternal,
                    VibeAudioSessionOutputRouteBuiltIn,
                    NO, NO, NO);
    XCTAssertEqual(action, VibeAudioSessionConfigurationActionPause);
    XCTAssertFalse(VibeAudioSessionMayAutomaticallyResume(
            NO, action == VibeAudioSessionConfigurationActionPause, NO));
}

@end
