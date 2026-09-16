//
// Bit-perfect output: the source depth decode, the rate and depth rules, the
// device eligibility allowlist and the status fold.
//

#import <XCTest/XCTest.h>

#import "../Vibe/Audio/Mac/Devices/OutputFormatRules.h"
#import "AudioDeviceManager.h"
#import "CoreAudioUtil.h"

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

// AVAudioFile's processing format: float32 at the file's rate.
static AudioStreamBasicDescription Decode(double rate) {
    return PCM(rate, 32, YES);
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

@interface OutputFormatRulesTests : XCTestCase <AudioDeviceManagerObserver>
@end

@implementation OutputFormatRulesTests {
    NSArray<AudioDevice *> *_nextDeviceSnapshot;
    NSMutableArray<NSNumber *> *_deviceSweeps;
    NSMutableArray<dispatch_block_t> *_deviceRetries;
    dispatch_block_t _deviceChangeHandler;
}

- (void)audioOutputDevicesDidChange {
    if (_deviceChangeHandler) _deviceChangeHandler();
}

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
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 32, YES), PCM(44100, 16, NO), Decode(44100)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(96000, 32, YES), PCM(96000, 24, NO), Decode(96000)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(96000, 32, YES), PCM(96000, 32, NO), Decode(96000)));
}

// A float source is the same representation as a float output, whatever its
// storage width says; an integer output of any depth is a conversion.
- (void)testFloatSourceIsSatisfiedOnlyByFloatAtLeastAsWide {
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 32, YES), PCM(44100, 32, YES), Decode(44100)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(44100, 32, NO), PCM(44100, 32, YES), Decode(44100)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(44100, 24, NO), PCM(44100, 32, YES), Decode(44100)));
    // The float flag's bit is also ALAC's 16-bit depth flag: not a float source.
    XCTAssertFalse(VibeSourceIsFloat(Compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_16BitSourceData, 44100)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 16, NO),
            Compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_16BitSourceData, 44100), Decode(44100)));
}

- (void)testIntegerDepthMustReachTheSource {
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 24, NO), PCM(44100, 16, NO), Decode(44100)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 24, NO), PCM(44100, 24, NO), Decode(44100)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(44100, 16, NO), PCM(44100, 24, NO), Decode(44100)));
}

// The decode is float32 whatever the device: a 32-bit integer source loses
// its low bits there (measured), so an i32 device does not make it Active;
// a float64 decode would carry it, and a 24-bit source is carried by both.
- (void)testTheDecodeMustCarryTheSourceToo {
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(96000, 32, NO), PCM(96000, 32, NO), Decode(96000)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(96000, 32, NO),
            Compressed(kAudioFormatFLAC, kAppleLosslessFormatFlag_32BitSourceData, 96000), Decode(96000)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(96000, 32, NO), PCM(96000, 32, NO), PCM(96000, 64, YES)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(96000, 32, NO), PCM(96000, 24, NO), Decode(96000)));
    XCTAssertFalse(VibePCMFormatCarries(PCM(96000, 16, YES), PCM(96000, 16, NO))); // no such float carries anything
}

- (void)testRateMismatchNeverSatisfies {
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(48000, 32, YES), PCM(44100, 16, NO), Decode(44100)));
}

- (void)testLossySourceIsSatisfiedByAnythingAtItsRate {
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 16, NO), Compressed(kAudioFormatMPEGLayer3, 0, 44100), Decode(44100)));
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
    XCTAssertEqual(VibeBitPerfectTargetRate(32000, list, (UInt32)n), 96000);
}

- (void)testIntegerMultiplesAreNotLimitedToPowersOfTwoOrSixteen {
    AudioStreamRangedDescription list[] = { RangedFormat(384000, 32, YES),
        RangedFormat(192000, 32, YES), RangedFormat(44100, 32, YES) };
    XCTAssertEqual(VibeBitPerfectTargetRate(32000, list, 3), 192000); // 6x, despite larger rate first
    XCTAssertEqual(VibeBitPerfectTargetRate(4000, list, 1), 384000); // 96x
    XCTAssertEqual(VibeBitPerfectTargetRate(NAN, list, 3), 0);
    XCTAssertEqual(VibeBitPerfectTargetRate(INFINITY, list, 3), 0);
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
    ranged.mSampleRateRange = (AudioValueRange){ 70000, 100000 };
    XCTAssertEqual(VibeBitPerfectTargetRate(32000, &ranged, 1), 96000);
    ranged.mSampleRateRange = (AudioValueRange){ 70000, 95000 };
    XCTAssertEqual(VibeBitPerfectTargetRate(32000, &ranged, 1), 0);
    ranged.mSampleRateRange = (AudioValueRange){ 96000, 96000 };
    XCTAssertEqual(VibeBitPerfectTargetRate(32000, &ranged, 1), 96000);
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
    XCTAssertFalse(VibePhysicalFormatSatisfies(PCM(96000, 24, NO), PCM(96000, 32, NO), Decode(96000)));
}

- (void)testFloatSourcePrefersFloatAndTakesI32OnlyWithoutOne {
    AudioStreamRangedDescription list[20];
    UInt32 n = (UInt32)USBDACList(list);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(PCM(44100, 32, YES), 44100, list, n, &chosen));
    XCTAssertFalse(VibePhysicalFormatIsFloat(chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 32u);
    XCTAssertFalse(VibePhysicalFormatSatisfies(chosen, PCM(44100, 32, YES), Decode(44100)));
    list[n++] = RangedFormat(44100, 32, YES);
    XCTAssertTrue(VibeBitPerfectChooseFormat(PCM(44100, 32, YES), 44100, list, n, &chosen));
    XCTAssertTrue(VibePhysicalFormatIsFloat(chosen));
    XCTAssertTrue(VibePhysicalFormatSatisfies(chosen, PCM(44100, 32, YES), Decode(44100)));
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

#pragma mark - Gapless output compatibility

- (void)testSameRateDepthChangeNeedsAnOutputSwitchOnAnIntegerDAC {
    AudioStreamRangedDescription dac[16];
    UInt32 n = (UInt32)USBDACList(dac);
    AudioStreamBasicDescription first = {0}, next = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(PCM(44100, 16, NO), 44100, dac, n, &first));
    XCTAssertTrue(VibeBitPerfectChooseFormat(PCM(44100, 24, NO), 44100, dac, n, &next));
    XCTAssertTrue(VibeBitPerfectOutputNeedsSwitch(first, next, 44100));
    XCTAssertTrue(VibeBitPerfectOutputNeedsSwitch(next, first, 44100));
    XCTAssertFalse(VibeBitPerfectOutputNeedsSwitch(first, first, 44100));
}

- (void)testFloatOutputCanSpliceDifferentDepthsAndLossyFilesWithoutASwitch {
    AudioStreamRangedDescription device = RangedFormat(44100, 32, YES);
    AudioStreamBasicDescription sources[] = {
        PCM(44100, 16, NO), PCM(44100, 24, NO),
        Compressed(kAudioFormatMPEGLayer3, 0, 44100),
    };
    for (NSUInteger i = 0; i < sizeof(sources) / sizeof(sources[0]); i++) {
        AudioStreamBasicDescription chosen = {0};
        XCTAssertTrue(VibeBitPerfectChooseFormat(sources[i], 44100, &device, 1, &chosen));
        XCTAssertFalse(VibeBitPerfectOutputNeedsSwitch(device.mFormat, chosen, 44100));
    }
}

- (void)testStaleMixerRateRequiresASwitchEvenWhenThePhysicalFormatMatches {
    AudioStreamBasicDescription physical = PCM(48000, 32, YES);
    XCTAssertTrue(VibeBitPerfectOutputNeedsSwitch(physical, physical, 44100));
    XCTAssertFalse(VibeBitPerfectOutputNeedsSwitch(physical, physical, 48000));
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

- (void)testExclusiveOutputRequiresOptInAndAnEligibleNonDefaultPhysicalDevice {
    XCTAssertFalse(VibeBitPerfectShouldHog(NO, kAudioDeviceTransportTypeUSB, NO));
    XCTAssertFalse(VibeBitPerfectShouldHog(YES, kAudioDeviceTransportTypeBluetooth, NO));
    XCTAssertFalse(VibeBitPerfectShouldHog(YES, kAudioDeviceTransportTypeVirtual, NO));
    XCTAssertTrue(VibeBitPerfectShouldHog(YES, kAudioDeviceTransportTypeUSB, NO));
    XCTAssertTrue(VibeBitPerfectShouldHog(YES, kAudioDeviceTransportTypeBuiltIn, NO));
    XCTAssertFalse(VibeBitPerfectShouldHog(YES, kAudioDeviceTransportTypeUSB, YES));
    XCTAssertFalse(VibeBitPerfectShouldHog(YES, kAudioDeviceTransportTypeBuiltIn, YES));
}

#pragma mark - The fold

// Everything perfect; each test below breaks one input and expects the fold
// to name it.
static VibeBitPerfectReport Perfect(void) {
    return (VibeBitPerfectReport){
        .enabled = YES, .eligibleDevice = YES, .hasTrack = YES, .fxGraph = NO,
        .rateExact = YES, .formatConfirmed = YES, .channelsMatch = YES,
        .depthOK = YES, .softwareVolume = 1.0f, .balance = 0.5f,
        .hogWanted = YES, .exclusive = YES, .sourceLossless = YES,
    };
}

- (void)testEverythingPerfectIsActive {
    XCTAssertEqual(VibeBitPerfectFold(Perfect()), VibeBitPerfectStatusActive);
}

- (void)testFailedSwitchIsNotAnUnsupportedRate {
    VibeBitPerfectReport r = Perfect();
    r.rateExact = NO;
    r.formatConfirmed = NO; // the supported rate was requested but never reached
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusSwitchFailed);
    r.formatConfirmed = YES; // a confirmed fallback to an offered multiple
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusRateUnsupported);
}

- (void)testUnconfirmedOutputCannotBeActiveEvenAtTheRightRateAndUnityVolume {
    VibeBitPerfectReport r = Perfect();
    r.formatConfirmed = NO; // wrong route or a failed format/volume/mute read
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusSwitchFailed);
}

// The shell is told about a report only when it differs, so every field the
// shell renders must count — the volume is the one a user moves mid-track.
- (void)testReportEqualityCountsEveryRenderedField {
    XCTAssertTrue(VibeBitPerfectReportsEqual(Perfect(), Perfect()));
    VibeBitPerfectReport r = Perfect();
    r.softwareVolume = 0.5f;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.balance = 0;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.sampleRate = 96000;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.exclusive = NO;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.status = VibeBitPerfectStatusIdle;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.systemDefault = YES;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.channelsMatch = NO;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.muted = YES;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
}

- (void)testMuteAndChannelConversionEachPreventAnActiveReport {
    VibeBitPerfectReport r = Perfect();
    r.muted = YES; // volume is still exactly 1.0
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusMuted);
    r = Perfect();
    r.channelsMatch = NO; // rate, precision and every gain check still pass
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusChannelConversion);
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
    r.muted = YES;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusMuted);
    r.depthOK = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusDepthInsufficient);
    r.channelsMatch = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusChannelConversion);
    r.rateExact = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusRateUnsupported);
    r.formatConfirmed = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusSwitchFailed);
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

- (void)testBalanceAwayFromCenterPreventsActiveAtFullVolume {
    VibeBitPerfectReport r = Perfect();
    for (NSNumber *balance in @[@0.0f, @0.25f, @0.75f, @1.0f]) {
        r.balance = balance.floatValue;
        XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusVolumeScaled);
    }
    r.balance = 0.5f;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusActive);
}

- (void)testSharedOutputCanStillBeActive {
    VibeBitPerfectReport r = Perfect();
    r.hogWanted = NO;
    r.exclusive = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusActive);
}

#pragma mark - Device discovery and snapshot lifecycle

- (AudioDevice *)device:(NSInteger)identifier uid:(NSString *)uid name:(NSString *)name {
    return [[AudioDevice alloc] initWithName:name uid:uid deviceId:identifier isSystemDefault:NO transportType:kAudioDeviceTransportTypeUSB];
}

- (AudioDeviceManager *)managerWithSnapshot:(NSArray<AudioDevice *> *)snapshot {
    _nextDeviceSnapshot = snapshot;
    _deviceSweeps = [NSMutableArray array];
    _deviceRetries = [NSMutableArray array];
    XCTestExpectation *started = [self expectationWithDescription:@"initial enumeration"];
    AudioDeviceManager *manager = [[AudioDeviceManager alloc] initWithEnumerator:^NSArray *(BOOL partial) {
        @synchronized (self) {
            [self->_deviceSweeps addObject:@(partial)];
            if (self->_deviceSweeps.count == 1) [started fulfill];
            return self->_nextDeviceSnapshot;
        }
    } retryScheduler:^(NSTimeInterval delay, dispatch_block_t retry) {
        @synchronized (self) {
            XCTAssertEqual(delay, 2);
            [self->_deviceRetries addObject:[retry copy]];
        }
    }];
    [self waitForExpectations:@[started] timeout:2];
    [manager outputDevices]; // Initial setup has returned from the injected enumeration.
    return manager;
}

- (void)refresh:(AudioDeviceManager *)manager snapshot:(NSArray<AudioDevice *> *)snapshot published:(BOOL)expected {
    @synchronized (self) { _nextDeviceSnapshot = snapshot; }
    XCTestExpectation *done = [self expectationWithDescription:@"refresh completion"];
    [manager refreshOutputDevicesWithCompletion:^(BOOL published) {
        XCTAssertFalse(NSThread.isMainThread);
        XCTAssertEqual(published, expected);
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:2];
}

- (void)testUnpublishedSnapshotIsUnknownWhilePublishedEmptyMeansAbsent {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    XCTAssertEqual(manager.outputDevices.count, 0u);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:42]);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:-1]);
    [self refresh:manager snapshot:@[] published:YES];
    XCTAssertEqual(manager.outputDevices.count, 0u);
    XCTAssertTrue([manager knowsOutputDeviceIsAbsent:42]);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:-1], @"System Output is a policy, never a removed device");
}

- (void)testFailedRefreshRetainsPublishedDevicesAndTheirIdentity {
    AudioDevice *device = [self device:42 uid:@"usb" name:@"DAC"];
    AudioDeviceManager *manager = [self managerWithSnapshot:@[device]];
    [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqualObjects(manager.outputDevices, @[device]);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:42]);
    XCTAssertEqual([manager outputDeviceForId:42], device);
    [self refresh:manager snapshot:@[] published:YES];
    XCTAssertTrue([manager knowsOutputDeviceIsAbsent:42]);
    XCTAssertNil([manager outputDeviceForId:42]);
}

- (void)testPublishedDeviceArrayCannotBeMutatedThroughEnumerationResult {
    AudioDevice *device = [self device:42 uid:@"usb" name:@"DAC"];
    NSMutableArray *enumerated = [NSMutableArray arrayWithObject:device];
    AudioDeviceManager *manager = [self managerWithSnapshot:enumerated];
    [enumerated removeAllObjects];
    XCTAssertEqualObjects(manager.outputDevices, @[device]);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:42]);
}

- (void)testPartialSweepStartsAfterThreeFailuresAndSuccessResetsTheBudget {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    [self refresh:manager snapshot:nil published:NO];
    [self refresh:manager snapshot:nil published:NO];
    [self refresh:manager snapshot:@[] published:YES];
    [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqualObjects(_deviceSweeps, (@[@NO, @NO, @NO, @YES, @NO]));
    XCTAssertEqual(_deviceRetries.count, 1u, @"Repeated failures share the outstanding retry");
}

- (void)testEvenPartialEnumerationFailureCannotPublishFalseRemoval {
    AudioDevice *device = [self device:42 uid:@"usb" name:@"DAC"];
    AudioDeviceManager *manager = [self managerWithSnapshot:@[device]];
    for (NSUInteger i = 0; i < 5; i++) [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqualObjects(_deviceSweeps.lastObject, @YES);
    XCTAssertEqualObjects(manager.outputDevices, @[device]);
    XCTAssertFalse([manager knowsOutputDeviceIsAbsent:42]);
}

- (void)testPendingSavedDeviceLookupsDrainExactlyOnceAfterRecovery {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    AudioDevice *device = [self device:42 uid:@"usb" name:@"DAC"];
    XCTestExpectation *resolved = [self expectationWithDescription:@"both waiters"];
    resolved.expectedFulfillmentCount = 2;
    __block NSUInteger deliveries = 0;
    for (NSUInteger i = 0; i < 2; i++) {
        [manager resolveOutputDeviceForUID:@"usb" name:@"DAC" completion:^(AudioDevice *answer) {
            XCTAssertFalse(NSThread.isMainThread);
            XCTAssertEqual(answer, device);
            deliveries++;
            [resolved fulfill];
        }];
    }
    [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqual(deliveries, 0u);
    [self refresh:manager snapshot:@[device] published:YES];
    [self waitForExpectations:@[resolved] timeout:2];
    [self refresh:manager snapshot:@[] published:YES];
    XCTAssertEqual(deliveries, 2u);
}

- (void)testSavedDeviceResolutionPrefersUIDThenFallsBackToName {
    AudioDevice *a = [self device:1 uid:@"a" name:@"DAC"];
    AudioDevice *b = [self device:2 uid:@"b" name:@"DAC"];
    AudioDeviceManager *manager = [self managerWithSnapshot:@[a, b]];
    NSArray *cases = @[@[@"b", @"DAC", b], @[@"unknown", @"DAC", a], @[@"", @"DAC", a],
                       @[@"a", @"renamed", a], @[@"unknown", @"missing", NSNull.null]];
    XCTestExpectation *resolved = [self expectationWithDescription:@"UID/name resolutions"];
    resolved.expectedFulfillmentCount = cases.count;
    for (NSArray *row in cases) {
        [manager resolveOutputDeviceForUID:row[0] name:row[1] completion:^(AudioDevice *answer) {
            XCTAssertEqualObjects(answer ?: NSNull.null, row[2]);
            [resolved fulfill];
        }];
    }
    [self waitForExpectations:@[resolved] timeout:2];
}

- (void)testAuthoritativeEmptySnapshotCompletesAnUnmatchedLookup {
    AudioDeviceManager *manager = [self managerWithSnapshot:@[]];
    XCTestExpectation *resolved = [self expectationWithDescription:@"no match"];
    [manager resolveOutputDeviceForUID:@"missing" name:@"DAC" completion:^(AudioDevice *answer) {
        XCTAssertNil(answer);
        [resolved fulfill];
    }];
    [self waitForExpectations:@[resolved] timeout:2];
    XCTAssertEqual(_deviceRetries.count, 0u);
}

- (void)testRecoveryTimerPublishesBeforeMainThreadObserversRun {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    AudioDevice *device = [self device:42 uid:@"usb" name:@"DAC"];
    XCTestExpectation *notified = [self expectationWithDescription:@"recovery observer"];
    _deviceChangeHandler = ^{
        XCTAssertTrue(NSThread.isMainThread);
        XCTAssertEqualObjects(manager.outputDevices, @[device]);
        [notified fulfill];
    };
    [manager addObserver:self];
    @synchronized (self) { _nextDeviceSnapshot = @[device]; }
    dispatch_block_t retry = _deviceRetries.firstObject;
    retry();
    [self waitForExpectations:@[notified] timeout:2];
    [manager removeObserver:self];
    _deviceChangeHandler = nil;
    [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqual(_deviceRetries.count, 2u, @"Completed timer releases the retry slot");
}

#pragma mark - Deferred saved-device bind races

- (void)testSavedDeviceMayBindAtIdleOrSilentLaunchButNotUnderAnOutgoingFade {
    XCTAssertTrue(VibeCanBindSavedOutputDevice(YES, NO, NO));
    XCTAssertTrue(VibeCanBindSavedOutputDevice(YES, NO, YES));
    XCTAssertTrue(VibeCanBindSavedOutputDevice(NO, YES, NO));
    XCTAssertFalse(VibeCanBindSavedOutputDevice(NO, YES, YES));
    XCTAssertFalse(VibeCanBindSavedOutputDevice(NO, NO, YES)); // playing or paused
    XCTAssertFalse(VibeCanBindSavedOutputDevice(NO, NO, NO)); // paused engine may be idle-stopped
}

- (void)testSavedDeviceAnswerCannotOverwriteManualSelectionOrANewerPreference {
    XCTAssertTrue(VibeSavedOutputDeviceRequestIsCurrent(@"uid", @"DAC", [@"uid" mutableCopy], [@"DAC" mutableCopy]));
    XCTAssertTrue(VibeSavedOutputDeviceRequestIsCurrent(@"", @"DAC", @"", @"DAC"));
    XCTAssertFalse(VibeSavedOutputDeviceRequestIsCurrent(@"uid", @"DAC", nil, nil));
    XCTAssertFalse(VibeSavedOutputDeviceRequestIsCurrent(@"uid", @"DAC", @"other", @"DAC"));
    XCTAssertFalse(VibeSavedOutputDeviceRequestIsCurrent(@"uid", @"DAC", @"uid", @"other"));
}

#pragma mark - Format restore / exclusive release obligations

- (void)testSuccessfulDeviceCleanupClearsSlotWithoutAnAbsenceReadOrRetry {
    AudioDeviceID deviceID = 42;
    __block NSUInteger attempts = 0;
    XCTAssertTrue([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ attempts++; return YES; }
            isAbsent:^BOOL(AudioDeviceID identifier) { XCTFail(@"Successful write settled it"); return NO; }]);
    XCTAssertEqual(deviceID, kAudioObjectUnknown);
    XCTAssertEqual(attempts, 1u);
}

- (void)testDeviceCleanupRetriesOnceAndRetainsFailureForTheNextLeave {
    AudioDeviceID deviceID = 42;
    __block NSUInteger attempts = 0;
    BOOL (^unknownOrPresent)(AudioDeviceID) = ^BOOL(AudioDeviceID identifier) { XCTAssertEqual(identifier, 42u); return NO; };
    XCTAssertFalse([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ attempts++; return NO; } isAbsent:unknownOrPresent]);
    XCTAssertEqual(attempts, 2u);
    XCTAssertEqual(deviceID, 42u, @"An uncertain restore must not forget which device is owed");
    attempts = 0;
    XCTAssertTrue([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ return ++attempts == 2; } isAbsent:unknownOrPresent]);
    XCTAssertEqual(attempts, 2u);
    XCTAssertEqual(deviceID, kAudioObjectUnknown);
}

- (void)testConfirmedRemovalRetiresCleanupWhileUnknownDiscoveryKeepsIt {
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    AudioDeviceID deviceID = 42;
    BOOL (^absent)(AudioDeviceID) = ^BOOL(AudioDeviceID identifier) { return [manager knowsOutputDeviceIsAbsent:identifier]; };
    XCTAssertFalse([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ return NO; } isAbsent:absent]);
    XCTAssertEqual(deviceID, 42u);
    [self refresh:manager snapshot:@[] published:YES];
    __block NSUInteger attempts = 0;
    XCTAssertTrue([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ attempts++; return NO; } isAbsent:absent]);
    XCTAssertEqual(attempts, 1u);
    XCTAssertEqual(deviceID, kAudioObjectUnknown);
}

- (void)testEmptyDeviceObligationTouchesNoHardwareOrDiscovery {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    XCTAssertTrue([CoreAudioUtil releaseDeviceObligation:&deviceID attempt:^BOOL{ XCTFail(@"No device to restore"); return NO; }
            isAbsent:^BOOL(AudioDeviceID identifier) { XCTFail(@"No discovery needed"); return NO; }]);
}

@end
