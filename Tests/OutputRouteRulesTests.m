//
//  OutputRouteRulesTests.m
//  VibeTests
//


#import <XCTest/XCTest.h>

#import "../Vibe/Audio/iOS/OutputRouteRules.h"

static const VibeOutputRouteKind kAllKinds[] = {
    VibeOutputRouteKindNone,
    VibeOutputRouteKindBuiltInSpeaker,
    VibeOutputRouteKindBuiltInReceiver,
    VibeOutputRouteKindWired,
    VibeOutputRouteKindBluetooth,
    VibeOutputRouteKindAirPlay,
    VibeOutputRouteKindCarPlay,
    VibeOutputRouteKindOther,
};

@interface OutputRouteRulesTests : XCTestCase
@end

@implementation OutputRouteRulesTests

#pragma mark - The fold onto the recovery kind

// The fold IS the guarantee: an external kind folding to BuiltIn would fire the
// unplugged-headphones pause when AirPods connect.
- (void)testExternalKindsFoldToExternal {
    XCTAssertEqual(VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindWired),
                   VibeAudioSessionOutputRouteExternal);
    XCTAssertEqual(VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindBluetooth),
                   VibeAudioSessionOutputRouteExternal);
    XCTAssertEqual(VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindAirPlay),
                   VibeAudioSessionOutputRouteExternal);
    XCTAssertEqual(VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindCarPlay),
                   VibeAudioSessionOutputRouteExternal);
    XCTAssertEqual(VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindOther),
                   VibeAudioSessionOutputRouteExternal);
}

- (void)testBuiltInKindsFoldToBuiltIn {
    XCTAssertEqual(VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindBuiltInSpeaker),
                   VibeAudioSessionOutputRouteBuiltIn);
    XCTAssertEqual(VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindBuiltInReceiver),
                   VibeAudioSessionOutputRouteBuiltIn);
}

- (void)testNoOutputsFoldsToNone {
    XCTAssertEqual(VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindNone),
                   VibeAudioSessionOutputRouteNone);
}

// The transition the fold has to keep producing, spelled out end to end: an
// external route falling back to the built-in speaker is headphone loss.
- (void)testFoldedHeadphoneLossStillPauses {
    XCTAssertEqual(VibeAudioSessionConfigurationActionForRoutes(
            VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindWired),
            VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindBuiltInSpeaker),
            NO, NO, NO), VibeAudioSessionConfigurationActionPause);
}

- (void)testFoldedBluetoothConnectionKeepsPlaying {
    XCTAssertEqual(VibeAudioSessionConfigurationActionForRoutes(
            VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindBuiltInSpeaker),
            VibeAudioSessionOutputRouteKindForRouteKind(VibeOutputRouteKindBluetooth),
            NO, NO, NO), VibeAudioSessionConfigurationActionRecover);
}

#pragma mark - The glyph

- (void)testEveryKindHasASymbol {
    for (size_t i = 0; i < sizeof(kAllKinds) / sizeof(kAllKinds[0]); i++) {
        XCTAssertGreaterThan(VibeOutputRouteSymbolName(kAllKinds[i]).length, 0u);
    }
}

// On-device is the state the control exists to change, so it advertises the
// affordance rather than describing the speaker — the unknown route included.
- (void)testOnDeviceRoutesDrawTheAirPlayGlyph {
    NSString *airPlay = VibeOutputRouteSymbolName(VibeOutputRouteKindAirPlay);
    XCTAssertEqualObjects(VibeOutputRouteSymbolName(VibeOutputRouteKindNone), airPlay);
    XCTAssertEqualObjects(VibeOutputRouteSymbolName(VibeOutputRouteKindBuiltInSpeaker), airPlay);
    XCTAssertEqualObjects(VibeOutputRouteSymbolName(VibeOutputRouteKindBuiltInReceiver), airPlay);
}

// Once the audio is somewhere else, the glyph describes that somewhere.
- (void)testOffDeviceRoutesEachDrawTheirOwn {
    NSArray<NSString *> *symbols = @[
        VibeOutputRouteSymbolName(VibeOutputRouteKindWired),
        VibeOutputRouteSymbolName(VibeOutputRouteKindBluetooth),
        VibeOutputRouteSymbolName(VibeOutputRouteKindCarPlay),
        VibeOutputRouteSymbolName(VibeOutputRouteKindOther),
    ];
    XCTAssertEqual([NSSet setWithArray:symbols].count, symbols.count);
    XCTAssertFalse([symbols containsObject:
            VibeOutputRouteSymbolName(VibeOutputRouteKindBuiltInSpeaker)]);
}

#pragma mark - The device name

- (void)testBuiltInRoutesHideTheDeviceName {
    XCTAssertFalse(VibeOutputRouteShowsDeviceName(VibeOutputRouteKindNone, @"iPhone"));
    XCTAssertFalse(VibeOutputRouteShowsDeviceName(VibeOutputRouteKindBuiltInSpeaker, @"Speaker"));
    XCTAssertFalse(VibeOutputRouteShowsDeviceName(VibeOutputRouteKindBuiltInReceiver, @"Receiver"));
}

- (void)testExternalRoutesShowTheDeviceName {
    XCTAssertTrue(VibeOutputRouteShowsDeviceName(VibeOutputRouteKindWired, @"Headphones"));
    XCTAssertTrue(VibeOutputRouteShowsDeviceName(VibeOutputRouteKindBluetooth, @"AirPods Pro"));
    XCTAssertTrue(VibeOutputRouteShowsDeviceName(VibeOutputRouteKindAirPlay, @"Living Room"));
    XCTAssertTrue(VibeOutputRouteShowsDeviceName(VibeOutputRouteKindCarPlay, @"Golf"));
    XCTAssertTrue(VibeOutputRouteShowsDeviceName(VibeOutputRouteKindOther, @"Display"));
}

- (void)testAbsentOrBlankNameIsNeverShown {
    for (size_t i = 0; i < sizeof(kAllKinds) / sizeof(kAllKinds[0]); i++) {
        XCTAssertFalse(VibeOutputRouteShowsDeviceName(kAllKinds[i], nil));
        XCTAssertFalse(VibeOutputRouteShowsDeviceName(kAllKinds[i], @""));
        XCTAssertFalse(VibeOutputRouteShowsDeviceName(kAllKinds[i], @"  \n "));
    }
}

@end
