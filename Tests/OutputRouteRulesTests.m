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
        XCTAssertGreaterThan(VibeOutputRouteSymbolName(kAllKinds[i], nil).length, 0u);
    }
}

// On-device is the state the control exists to change, so it advertises the
// affordance rather than describing the speaker — the unknown route included.
- (void)testOnDeviceRoutesDrawTheAirPlayGlyph {
    NSString *airPlay = VibeOutputRouteSymbolName(VibeOutputRouteKindAirPlay, nil);
    XCTAssertEqualObjects(VibeOutputRouteSymbolName(VibeOutputRouteKindNone, nil), airPlay);
    XCTAssertEqualObjects(VibeOutputRouteSymbolName(VibeOutputRouteKindBuiltInSpeaker, nil), airPlay);
    XCTAssertEqualObjects(VibeOutputRouteSymbolName(VibeOutputRouteKindBuiltInReceiver, nil), airPlay);
}

// Once the audio is somewhere else, the glyph describes that somewhere.
- (void)testOffDeviceRoutesEachDrawTheirOwn {
    NSArray<NSString *> *symbols = @[
        VibeOutputRouteSymbolName(VibeOutputRouteKindWired, nil),
        VibeOutputRouteSymbolName(VibeOutputRouteKindBluetooth, nil),
        VibeOutputRouteSymbolName(VibeOutputRouteKindCarPlay, nil),
        VibeOutputRouteSymbolName(VibeOutputRouteKindOther, nil),
    ];
    XCTAssertEqual([NSSet setWithArray:symbols].count, symbols.count);
    XCTAssertFalse([symbols containsObject:
            VibeOutputRouteSymbolName(VibeOutputRouteKindBuiltInSpeaker, nil)]);
}

#pragma mark - The Bluetooth guess

static NSString *BluetoothSymbol(NSString *name) {
    return VibeOutputRouteSymbolName(VibeOutputRouteKindBluetooth, name);
}

// The possessive moves with the locale, so the match is anywhere in the name.
- (void)testDefaultNamesInEveryShapeDrawTheirProduct {
    XCTAssertEqualObjects(BluetoothSymbol(@"Chris's AirPods Pro"), @"airpodspro");
    XCTAssertEqualObjects(BluetoothSymbol(@"Chris’s AirPods Max"), @"airpodsmax");
    XCTAssertEqualObjects(BluetoothSymbol(@"AirPods de Chris"), @"airpods");
    XCTAssertEqualObjects(BluetoothSymbol(@"AirPods Pro de Chris"), @"airpodspro");
    XCTAssertEqualObjects(BluetoothSymbol(@"ChrisのAirPods Pro"), @"airpodspro");
    XCTAssertEqualObjects(BluetoothSymbol(@"AirPods Max von Chris #2"), @"airpodsmax");
    XCTAssertEqualObjects(BluetoothSymbol(@"Chris's Beats Studio Pro"), @"beats.headphones");
}

// Each name contains the next probe's, so a probe out of order draws plain
// earbuds for a Pro or a Max.
- (void)testTheLongerProductNameWins {
    XCTAssertEqualObjects(BluetoothSymbol(@"AirPods Pro"), @"airpodspro");
    XCTAssertEqualObjects(BluetoothSymbol(@"AirPods Max"), @"airpodsmax");
    XCTAssertEqualObjects(BluetoothSymbol(@"AirPods"), @"airpods");
}

// Recognising nothing is today's glyph, never a worse one.
- (void)testRenamedOrUnknownDevicesKeepTheGenericGlyph {
    NSString *generic = BluetoothSymbol(nil);
    XCTAssertEqualObjects(generic, @"hifispeaker.fill");
    XCTAssertEqualObjects(BluetoothSymbol(@""), generic);
    XCTAssertEqualObjects(BluetoothSymbol(@"Chris's earbuds"), generic);
    XCTAssertEqualObjects(BluetoothSymbol(@"Golf"), generic);
    XCTAssertEqualObjects(BluetoothSymbol(@"airpods"), generic);
}

// Only the Bluetooth row reads the name: every other kind already knows what
// it is, and USB-C Beats are still wired headphones.
- (void)testTheNameOnlyChangesTheBluetoothRow {
    for (size_t i = 0; i < sizeof(kAllKinds) / sizeof(kAllKinds[0]); i++) {
        if (kAllKinds[i] == VibeOutputRouteKindBluetooth) {
            continue;
        }
        XCTAssertEqualObjects(VibeOutputRouteSymbolName(kAllKinds[i], @"Chris's AirPods Pro"),
                              VibeOutputRouteSymbolName(kAllKinds[i], nil));
        XCTAssertEqualObjects(VibeOutputRouteSymbolName(kAllKinds[i], @"Beats"),
                              VibeOutputRouteSymbolName(kAllKinds[i], nil));
    }
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
