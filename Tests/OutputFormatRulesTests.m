//
// Bit-perfect output: the source depth decode, the rate and depth rules, the
// device eligibility allowlist and the status fold.
//

#import <XCTest/XCTest.h>

#import "../Vibe/Audio/Mac/Devices/OutputFormatRules.h"

static AudioStreamBasicDescription PCM(double rate, UInt32 bits, BOOL isFloat) {
    AudioStreamBasicDescription d = {0};
    d.mSampleRate = rate;
    d.mFormatID = kAudioFormatLinearPCM;
    d.mFormatFlags = isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger;
    d.mBitsPerChannel = bits;
    d.mChannelsPerFrame = 2;
    return d;
}

static AudioStreamBasicDescription Compressed(UInt32 formatID, UInt32 flags, double rate) {
    AudioStreamBasicDescription d = {0};
    d.mSampleRate = rate;
    d.mFormatID = formatID;
    d.mFormatFlags = flags;
    d.mChannelsPerFrame = 2;
    return d;
}

static AudioStreamRangedDescription RangedFormat(double rate, UInt32 bits, BOOL isFloat) {
    AudioStreamRangedDescription r;
    r.mFormat = PCM(rate, bits, isFloat);
    r.mSampleRateRange.mMinimum = rate;
    r.mSampleRateRange.mMaximum = rate;
    return r;
}

// The devices probed while planning, verbatim: every one float32 only.
static const double kSpeakerRates[] = { 44100, 48000, 88200, 96000 };
static const double kAirPodsRates[] = { 24000, 48000 };

static NSUInteger FloatListForRates(const double *rates, NSUInteger count,
                                    AudioStreamRangedDescription *out) {
    for (NSUInteger i = 0; i < count; i++) {
        out[i] = RangedFormat(rates[i], 32, YES);
    }
    return count;
}

// A USB-DAC-shaped list: i16/i24/i32 at 44.1/48/96/192.
static NSUInteger USBDACList(AudioStreamRangedDescription *out) {
    static const double rates[] = { 44100, 48000, 96000, 192000 };
    static const UInt32 depths[] = { 16, 24, 32 };
    NSUInteger n = 0;
    for (NSUInteger r = 0; r < 4; r++) {
        for (NSUInteger d = 0; d < 3; d++) {
            out[n++] = RangedFormat(rates[r], depths[d], NO);
        }
    }
    return n;
}

@interface OutputFormatRulesTests : XCTestCase
@end

@implementation OutputFormatRulesTests

#pragma mark - Source depth

- (void)testPCMDepthIsBitsPerChannel {
    XCTAssertEqual(VibeSourceBitDepth(PCM(44100, 16, NO)), 16u);
    XCTAssertEqual(VibeSourceBitDepth(PCM(96000, 24, NO)), 24u);
    XCTAssertEqual(VibeSourceBitDepth(PCM(96000, 32, NO)), 32u);
    XCTAssertEqual(VibeSourceBitDepth(PCM(48000, 32, YES)), 32u);
}

- (void)testLosslessCompressedDepthRidesTheSourceFlags {
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_16BitSourceData, 44100)), 16u);
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_20BitSourceData, 44100)), 20u);
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatFLAC, kAppleLosslessFormatFlag_24BitSourceData, 96000)), 24u);
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatFLAC, kAppleLosslessFormatFlag_32BitSourceData, 96000)), 32u);
    // Flags that say nothing: assumed 24, never 0 (which would read as lossy).
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatFLAC, 0, 44100)), 24u);
}

- (void)testLossySourcesHaveNoDepthAndAreNotLossless {
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatMPEGLayer3, 0, 44100)), 0u);
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatMPEG4AAC, 0, 44100)), 0u);
    XCTAssertFalse(VibeSourceIsLossless(Compressed(kAudioFormatMPEGLayer3, 0, 44100)));
    XCTAssertTrue(VibeSourceIsLossless(PCM(44100, 16, NO)));
    XCTAssertTrue(VibeSourceIsLossless(Compressed(kAudioFormatFLAC, 3, 44100)));
    XCTAssertTrue(VibeSourceIsLossless(Compressed(kAudioFormatAppleLossless, 1, 44100)));
}

#pragma mark - Satisfaction

- (void)testFloat32SatisfiesUpTo24Bits {
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 32, YES), PCM(44100, 16, NO)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(96000, 32, YES), PCM(96000, 24, NO)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(96000, 32, YES), PCM(96000, 32, NO)));
}

- (void)testIntegerDepthMustReachTheSource {
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 24, NO), PCM(44100, 16, NO)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 24, NO), PCM(44100, 24, NO)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(44100, 16, NO), PCM(44100, 24, NO)));
}

- (void)testRateMismatchNeverSatisfies {
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(48000, 32, YES), PCM(44100, 16, NO)));
}

- (void)testLossySourceIsSatisfiedByAnythingAtItsRate {
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 16, NO), Compressed(kAudioFormatMPEGLayer3, 0, 44100)));
}

#pragma mark - The rate rule

- (void)testExactRateWins {
    AudioStreamRangedDescription list[8];
    NSUInteger n = FloatListForRates(kSpeakerRates, 4, list);
    XCTAssertEqual(VibeBitPerfectTargetRate(44100, list, (UInt32)n), 44100);
    XCTAssertEqual(VibeBitPerfectTargetRate(96000, list, (UInt32)n), 96000);
}

- (void)testSmallestIntegerMultipleWhenExactIsMissing {
    AudioStreamRangedDescription list[8];
    NSUInteger n = FloatListForRates(kSpeakerRates, 4, list);
    XCTAssertEqual(VibeBitPerfectTargetRate(22050, list, (UInt32)n), 44100);
    XCTAssertEqual(VibeBitPerfectTargetRate(24000, list, (UInt32)n), 48000);
}

- (void)testNothingOfferedIsZero {
    AudioStreamRangedDescription speakers[8];
    NSUInteger n = FloatListForRates(kSpeakerRates, 4, speakers);
    XCTAssertEqual(VibeBitPerfectTargetRate(176400, speakers, (UInt32)n), 0);
    AudioStreamRangedDescription airpods[4];
    NSUInteger m = FloatListForRates(kAirPodsRates, 2, airpods);
    XCTAssertEqual(VibeBitPerfectTargetRate(44100, airpods, (UInt32)m), 0);
    XCTAssertEqual(VibeBitPerfectTargetRate(0, airpods, (UInt32)m), 0);
}

- (void)testARangedFormatOffersEveryRateInsideIt {
    AudioStreamRangedDescription ranged = RangedFormat(0, 32, YES);
    ranged.mSampleRateRange.mMinimum = 8000;
    ranged.mSampleRateRange.mMaximum = 192000;
    XCTAssertEqual(VibeBitPerfectTargetRate(88200, &ranged, 1), 88200);
    XCTAssertEqual(VibeBitPerfectTargetRate(384000, &ranged, 1), 0);
}

#pragma mark - The depth rule, as-is

- (void)testSixteenBitSourceChoosesI16EvenOverACurrentI32 {
    AudioStreamRangedDescription dac[16];
    UInt32 n = (UInt32)USBDACList(dac);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(PCM(44100, 16, NO), 44100, dac, n, &chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 16u);
    XCTAssertFalse(VibePhysicalFormatIsFloat(chosen));
    XCTAssertEqual(chosen.mSampleRate, 44100);
}

- (void)testTwentyFourBitSourceChoosesI24 {
    AudioStreamRangedDescription dac[16];
    UInt32 n = (UInt32)USBDACList(dac);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(PCM(96000, 24, NO), 96000, dac, n, &chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 24u);
    XCTAssertEqual(chosen.mSampleRate, 96000);
}

- (void)testOddDepthsTakeTheSmallestAbove {
    AudioStreamRangedDescription dac[16];
    UInt32 n = (UInt32)USBDACList(dac);
    AudioStreamBasicDescription chosen = {0};
    // 20-bit ALAC → i24, the smallest above.
    XCTAssertTrue(VibeBitPerfectChooseFormat(Compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_20BitSourceData, 44100),
            44100, dac, n, &chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 24u);
    // A lossy source takes 24.
    XCTAssertTrue(VibeBitPerfectChooseFormat(Compressed(kAudioFormatMPEGLayer3, 0, 44100), 44100, dac, n, &chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 24u);
}

- (void)testSourceDeeperThanTheDACTakesTheDeepestAndFailsSatisfaction {
    AudioStreamRangedDescription dac[16];
    UInt32 n = 0;
    static const double rates[] = { 44100, 96000 };
    for (NSUInteger r = 0; r < 2; r++) {
        dac[n++] = RangedFormat(rates[r], 16, NO);
        dac[n++] = RangedFormat(rates[r], 24, NO);
    }
    AudioStreamBasicDescription chosen = {0};
    // Nothing >= 32 is offered: the rule refuses to go below the source, so the
    // caller falls back to what the device has and reports DepthInsufficient.
    XCTAssertFalse(VibeBitPerfectChooseFormat(PCM(96000, 32, NO), 96000, dac, n, &chosen));
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(96000, 24, NO), PCM(96000, 32, NO)));
}

- (void)testFloatOnlyDevicesChooseFloat32 {
    AudioStreamRangedDescription speakers[8];
    UInt32 n = (UInt32)FloatListForRates(kSpeakerRates, 4, speakers);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(PCM(96000, 24, NO), 96000, speakers, n, &chosen));
    XCTAssertTrue(VibePhysicalFormatIsFloat(chosen));
    XCTAssertEqual(chosen.mSampleRate, 96000);
}

- (void)testNothingAtTheRateIsNo {
    AudioStreamRangedDescription dac[16];
    UInt32 n = (UInt32)USBDACList(dac);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertFalse(VibeBitPerfectChooseFormat(PCM(88200, 24, NO), 88200, dac, n, &chosen));
}

#pragma mark - Eligibility

// Every SDK transport, one assertion each, so moving one between the sides is
// a deliberate test edit. The System Output policy is not a transport: it is
// the absence of a chosen device, refused before this rule is asked.
- (void)testTheAllowlist {
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeBuiltIn));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypePCI));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeUSB));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeFireWire));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeThunderbolt));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeHDMI));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeDisplayPort));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeAVB));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeVirtual));
}

- (void)testEverythingRemoteCompressedOrResampledIsOut {
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeUnknown));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeBluetooth));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeBluetoothLE));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeAirPlay));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeContinuityCaptureWired));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeContinuityCaptureWireless));
    // kAudioDeviceTransportTypeRemoteScreen / RemoteStreaming, spelled as
    // their codes: CI's older SDK does not declare them, and the rule refuses
    // them through its default branch either way.
    XCTAssertFalse(VibeBitPerfectDeviceEligible('rscr'));
    XCTAssertFalse(VibeBitPerfectDeviceEligible('rstr'));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeAggregate));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeAutoAggregate));
}

- (void)testOnlyVirtualIsNeverHogged {
    XCTAssertFalse(VibeBitPerfectShouldHog(kAudioDeviceTransportTypeVirtual));
    XCTAssertTrue(VibeBitPerfectShouldHog(kAudioDeviceTransportTypeUSB));
    XCTAssertTrue(VibeBitPerfectShouldHog(kAudioDeviceTransportTypeBuiltIn));
}

#pragma mark - The fold

// Everything perfect; each test below breaks one input and expects the fold
// to name it.
static VibeBitPerfectReport Perfect(void) {
    return (VibeBitPerfectReport){
        .enabled = YES, .eligibleDevice = YES, .hasTrack = YES, .fxGraph = NO,
        .rateExact = YES, .switched = YES, .depthOK = YES, .softwareVolume = 1.0f,
        .hogWanted = YES, .exclusive = YES, .sourceLossless = YES,
    };
}

- (void)testEverythingPerfectIsActive {
    XCTAssertEqual(VibeBitPerfectFold(Perfect()), VibeBitPerfectStatusActive);
}

// One assertion per adjacent pair of the priority order, so a reorder fails:
// each report carries every breaker below it in the order as well.
- (void)testFoldPriority {
    VibeBitPerfectReport r = Perfect();
    r.sourceLossless = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusSourceLossy);
    r.exclusive = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusExclusiveRefused);
    r.softwareVolume = 0.5f;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusVolumeScaled);
    r.depthOK = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusDepthInsufficient);
    r.switched = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusSwitchFailed);
    r.rateExact = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusRateUnsupported);
    r.hasTrack = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusIdle);
    r.fxGraph = YES;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusFXGraphPresent);
    r.eligibleDevice = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusOff);
    VibeBitPerfectReport off = Perfect();
    off.enabled = NO;
    XCTAssertEqual(VibeBitPerfectFold(off), VibeBitPerfectStatusOff);
}

- (void)testAnUnhoggedVirtualDeviceCanStillBeActive {
    VibeBitPerfectReport r = Perfect();
    r.hogWanted = NO;
    r.exclusive = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusActive);
}

@end
