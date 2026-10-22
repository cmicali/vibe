#import <XCTest/XCTest.h>

#import "OutputFormatRules.h"

static AudioStreamBasicDescription VibePCM(double rate, UInt32 bits, BOOL isFloat) {
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

// AudioFileHandle's processing format: float32 at the file's rate.
static AudioStreamBasicDescription Decode(double rate) {
    return VibePCM(rate, 32, YES);
}

// A format a device offers at exactly `rate`: stereo PCM of `bits`, integer
// or float.
static AudioStreamRangedDescription VibeRangedPCMFormat(double rate, UInt32 bits, BOOL isFloat) {
    AudioStreamRangedDescription r = {0};
    r.mFormat.mSampleRate = rate;
    r.mFormat.mFormatID = kAudioFormatLinearPCM;
    r.mFormat.mFormatFlags = isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger;
    r.mFormat.mBitsPerChannel = bits;
    r.mFormat.mChannelsPerFrame = 2;
    r.mSampleRateRange.mMinimum = rate;
    r.mSampleRateRange.mMaximum = rate;
    return r;
}

// Representative float-only device rate lists.
static const double kSpeakerRates[] = { 44100, 48000, 88200, 96000 };
static const double kAirPodsRates[] = { 24000, 48000 };

static NSUInteger FloatListForRates(const double *rates, NSUInteger count,
                                    AudioStreamRangedDescription *out) {
    for (NSUInteger i = 0; i < count; i++) {
        out[i] = VibeRangedPCMFormat(rates[i], 32, YES);
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
            out[n++] = VibeRangedPCMFormat(rates[r], depths[d], NO);
        }
    }
    return n;
}

@interface OutputFormatRulesTests : XCTestCase
@end

@implementation OutputFormatRulesTests

#pragma mark - Output routing

- (void)testStereoCanUseTheFirstPairOfAWiderDevice {
    const SInt32 quad[] = {0, 1, -1, -1};
    const SInt32 hdmi[] = {0, 1, -1, -1, -1, -1, -1, -1};
    XCTAssertTrue(VibeBitPerfectChannelMapPreservesSource(quad, 4, 2, 1, 4));
    XCTAssertTrue(VibeBitPerfectChannelMapPreservesSource(quad, 4, 2, 1, 2)); // separate stereo streams
    XCTAssertTrue(VibeBitPerfectChannelMapPreservesSource(hdmi, 8, 2, 1, 8));
    const SInt32 secondPair[] = {-1, -1, 0, 1};
    XCTAssertTrue(VibeBitPerfectChannelMapPreservesSource(secondPair, 4, 2, 3, 2));
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(secondPair, 4, 2, 1, 2));
}

- (void)testRoutingRejectsSwapsMissingChannelsAndDuplicatedOutputs {
    const SInt32 altered[][4] = {{1, 0, -1, -1}, {0, -1, -1, -1},
                               {0, 1, 0, 1}, {0, 1, 2, 3}, {0, 0, -1, -1}};
    for (NSUInteger i = 0; i < sizeof(altered) / sizeof(altered[0]); i++) {
        XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(altered[i], 4, 2, 1, 4));
    }
    const SInt32 stereo[] = {0, 1};
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(stereo, 2, 6, 1, 2));
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(stereo, 2, 1, 1, 2)); // mono duplicated
}

- (void)testRoutingRequiresACompleteMapAndAStreamContainingEverySourceChannel {
    const SInt32 stereo[] = {0, 1};
    XCTAssertTrue(VibeBitPerfectChannelMapPreservesSource(stereo, 2, 2, 1, 2));
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(NULL, 2, 2, 1, 2));
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(stereo, 0, 2, 1, 2));
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(stereo, 2, 0, 1, 2));
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(stereo, 2, 2, 0, 2));
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(stereo, 2, 2, 1, 1));
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(stereo, 2, 2, 2, 2));
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(stereo, 2, 2, UINT32_MAX, 2));
    XCTAssertFalse(VibeBitPerfectChannelMapPreservesSource(stereo, 2, 2, 1, UINT32_MAX));
}

#pragma mark - Source depth

- (void)testPCMDepthIsBitsPerChannel {
    XCTAssertEqual(VibeSourceBitDepth(VibePCM(44100, 16, NO)), 16u);
    XCTAssertEqual(VibeSourceBitDepth(VibePCM(96000, 24, NO)), 24u);
    XCTAssertEqual(VibeSourceBitDepth(VibePCM(96000, 32, NO)), 32u);
    XCTAssertEqual(VibeSourceBitDepth(VibePCM(48000, 32, YES)), 32u);
}

- (void)testLosslessCompressedDepthRidesTheSourceFlags {
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_16BitSourceData, 44100)), 16u);
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_20BitSourceData, 44100)), 20u);
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatFLAC, kAppleLosslessFormatFlag_24BitSourceData, 96000)), 24u);
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatFLAC, kAppleLosslessFormatFlag_32BitSourceData, 96000)), 32u);
    // Flags that say nothing: assumed 24, never 0 (which would read as lossy).
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatFLAC, 0, 44100)), 24u);
}

- (void)testLossySourcesHaveNoDepth {
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatMPEGLayer3, 0, 44100)), 0u);
    XCTAssertEqual(VibeSourceBitDepth(Compressed(kAudioFormatMPEG4AAC, 0, 44100)), 0u);
}

#pragma mark - Satisfaction

- (void)testFloat32SatisfiesUpTo24Bits {
    XCTAssertTrue(VibePhysicalFormatSatisfies(VibePCM(44100, 32, YES), VibePCM(44100, 16, NO), Decode(44100)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(VibePCM(96000, 32, YES), VibePCM(96000, 24, NO), Decode(96000)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(VibePCM(96000, 32, YES), VibePCM(96000, 32, NO), Decode(96000)));
}

// A float source is the same representation as a float output, whatever its
// storage width says; an integer output of any depth is a conversion.
- (void)testFloatSourceIsSatisfiedOnlyByFloatAtLeastAsWide {
    XCTAssertTrue(VibePhysicalFormatSatisfies(VibePCM(44100, 32, YES), VibePCM(44100, 32, YES), Decode(44100)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(VibePCM(44100, 32, NO), VibePCM(44100, 32, YES), Decode(44100)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(VibePCM(44100, 24, NO), VibePCM(44100, 32, YES), Decode(44100)));
    // The float flag's bit is also ALAC's 16-bit depth flag: not a float source.
    XCTAssertFalse(VibeSourceIsFloat(Compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_16BitSourceData, 44100)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(VibePCM(44100, 16, NO),
            Compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_16BitSourceData, 44100), Decode(44100)));
}

- (void)testIntegerDepthMustReachTheSource {
    XCTAssertTrue(VibePhysicalFormatSatisfies(VibePCM(44100, 24, NO), VibePCM(44100, 16, NO), Decode(44100)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(VibePCM(44100, 24, NO), VibePCM(44100, 24, NO), Decode(44100)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(VibePCM(44100, 16, NO), VibePCM(44100, 24, NO), Decode(44100)));
}

// An integer source needs enough decode precision before device depth matters.
// Float32 cannot preserve every int32 value. Float64 can.
- (void)testTheDecodeMustCarryTheSourceToo {
    XCTAssertFalse(VibePhysicalFormatSatisfies(VibePCM(96000, 32, NO), VibePCM(96000, 32, NO), Decode(96000)));
    XCTAssertFalse(VibePhysicalFormatSatisfies(VibePCM(96000, 32, NO),
            Compressed(kAudioFormatFLAC, kAppleLosslessFormatFlag_32BitSourceData, 96000), Decode(96000)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(VibePCM(96000, 32, NO), VibePCM(96000, 32, NO), VibePCM(96000, 64, YES)));
    XCTAssertTrue(VibePhysicalFormatSatisfies(VibePCM(96000, 32, NO), VibePCM(96000, 24, NO), Decode(96000)));
    XCTAssertFalse(VibePCMFormatCarries(VibePCM(96000, 16, YES), VibePCM(96000, 16, NO))); // no such float carries anything
}

- (void)testRateMismatchNeverSatisfies {
    XCTAssertFalse(VibePhysicalFormatSatisfies(VibePCM(48000, 32, YES), VibePCM(44100, 16, NO), Decode(44100)));
}

- (void)testEncodedPhysicalFormatsCannotConfirmUnchangedPCM {
    AudioStreamBasicDescription encoded = VibePCM(48000, 16, NO);
    encoded.mFormatID = kAudioFormat60958AC3;
    XCTAssertFalse(VibePhysicalFormatSatisfies(encoded, VibePCM(48000, 16, NO), Decode(48000)));
}

- (void)testLossySourceIsSatisfiedByAnythingAtItsRate {
    XCTAssertTrue(VibePhysicalFormatSatisfies(VibePCM(44100, 16, NO), Compressed(kAudioFormatMPEGLayer3, 0, 44100), Decode(44100)));
}

#pragma mark - The rate rule

- (void)testExactRateWins {
    AudioStreamRangedDescription list[8];
    NSUInteger n = FloatListForRates(kSpeakerRates, 4, list);
    XCTAssertEqual(VibeBitPerfectTargetRate(44100, 2, list, (UInt32)n), 44100);
    XCTAssertEqual(VibeBitPerfectTargetRate(96000, 2, list, (UInt32)n), 96000);
}

- (void)testEncodedOffersCannotHideAUsablePCMRate {
    AudioStreamRangedDescription list[] = { VibeRangedPCMFormat(48000, 16, NO),
        VibeRangedPCMFormat(96000, 24, NO) };
    list[0].mFormat.mFormatID = kAudioFormat60958AC3;
    double rate = VibeBitPerfectTargetRate(48000, 2, list, 2);
    XCTAssertEqual(rate, 96000);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(48000, 24, NO), rate, list, 2, &chosen));
    XCTAssertEqual(chosen.mFormatID, kAudioFormatLinearPCM);
    XCTAssertEqual(VibeBitPerfectTargetRate(48000, 2, list, 1), 0);
}

- (void)testNarrowChannelOffersCannotHideAUsablePCMRate {
    AudioStreamRangedDescription formats[] = { VibeRangedPCMFormat(48000, 16, NO),
        VibeRangedPCMFormat(96000, 24, NO) };
    formats[0].mFormat.mChannelsPerFrame = 1;
    double rate = VibeBitPerfectTargetRate(48000, 2, formats, 2);
    XCTAssertEqual(rate, 96000);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(48000, 16, NO), rate, formats, 2, &chosen));
    XCTAssertEqual(chosen.mChannelsPerFrame, 2u);
    XCTAssertEqual(VibeBitPerfectTargetRate(48000, 2, formats, 1), 0);
    XCTAssertEqual(VibeBitPerfectTargetRate(48000, 1, formats, 2), 48000);
}

- (void)testSmallestIntegerMultipleWhenExactIsMissing {
    AudioStreamRangedDescription list[8];
    NSUInteger n = FloatListForRates(kSpeakerRates, 4, list);
    XCTAssertEqual(VibeBitPerfectTargetRate(22050, 2, list, (UInt32)n), 44100);
    XCTAssertEqual(VibeBitPerfectTargetRate(24000, 2, list, (UInt32)n), 48000);
    XCTAssertEqual(VibeBitPerfectTargetRate(32000, 2, list, (UInt32)n), 96000);
}

- (void)testIntegerMultiplesAreNotLimitedToPowersOfTwoOrSixteen {
    AudioStreamRangedDescription list[] = { VibeRangedPCMFormat(384000, 32, YES),
        VibeRangedPCMFormat(192000, 32, YES), VibeRangedPCMFormat(44100, 32, YES) };
    XCTAssertEqual(VibeBitPerfectTargetRate(32000, 2, list, 3), 192000); // 6x, despite larger rate first
    XCTAssertEqual(VibeBitPerfectTargetRate(4000, 2, list, 1), 384000); // 96x
    XCTAssertEqual(VibeBitPerfectTargetRate(NAN, 2, list, 3), 0);
    XCTAssertEqual(VibeBitPerfectTargetRate(INFINITY, 2, list, 3), 0);
}

- (void)testNothingOfferedIsZero {
    AudioStreamRangedDescription speakers[8];
    NSUInteger n = FloatListForRates(kSpeakerRates, 4, speakers);
    XCTAssertEqual(VibeBitPerfectTargetRate(176400, 2, speakers, (UInt32)n), 0);
    AudioStreamRangedDescription airpods[4];
    NSUInteger m = FloatListForRates(kAirPodsRates, 2, airpods);
    XCTAssertEqual(VibeBitPerfectTargetRate(44100, 2, airpods, (UInt32)m), 0);
    XCTAssertEqual(VibeBitPerfectTargetRate(0, 2, airpods, (UInt32)m), 0);
}

- (void)testARangedFormatOffersEveryRateInsideIt {
    AudioStreamRangedDescription ranged = VibeRangedPCMFormat(0, 32, YES);
    ranged.mSampleRateRange.mMinimum = 8000;
    ranged.mSampleRateRange.mMaximum = 192000;
    XCTAssertEqual(VibeBitPerfectTargetRate(88200, 2, &ranged, 1), 88200);
    XCTAssertEqual(VibeBitPerfectTargetRate(384000, 2, &ranged, 1), 0);
    ranged.mSampleRateRange = (AudioValueRange){ 70000, 100000 };
    XCTAssertEqual(VibeBitPerfectTargetRate(32000, 2, &ranged, 1), 96000);
    ranged.mSampleRateRange = (AudioValueRange){ 70000, 95000 };
    XCTAssertEqual(VibeBitPerfectTargetRate(32000, 2, &ranged, 1), 0);
    ranged.mSampleRateRange = (AudioValueRange){ 96000, 96000 };
    XCTAssertEqual(VibeBitPerfectTargetRate(32000, 2, &ranged, 1), 96000);
}

#pragma mark - The depth rule, as-is

- (void)testIntegerSourcesTakeTheWidestIntegerDepth {
    AudioStreamRangedDescription dac[16];
    UInt32 n = (UInt32)USBDACList(dac);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(44100, 16, NO), 44100, dac, n, &chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 32u);
    XCTAssertFalse(VibePhysicalFormatIsFloat(chosen));
    XCTAssertEqual(chosen.mSampleRate, 44100);
    XCTAssertTrue(VibePhysicalFormatSatisfies(chosen, VibePCM(44100, 16, NO), Decode(44100)));
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(96000, 24, NO), 96000, dac, n, &chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 32u);
    XCTAssertEqual(chosen.mSampleRate, 96000);

    // USBDACList opens with 44.1 kHz at 16 and 24 bits.
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(44100, 16, NO), 44100, dac, 2, &chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 24u);
    XCTAssertFalse(VibePhysicalFormatIsFloat(chosen));
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(44100, 16, NO), 44100, dac, 1, &chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 16u, @"16 bits when that is all the device offers");
}

- (void)testOddAndUnknownLosslessDepthsNeverGoBelowTheSource {
    AudioStreamRangedDescription formats[16];
    USBDACList(formats); // the first two: 44.1 kHz at 16 and 24 bits
    AudioStreamBasicDescription chosen = {0};
    AudioStreamBasicDescription twenty = Compressed(kAudioFormatAppleLossless, kAppleLosslessFormatFlag_20BitSourceData, 44100);
    XCTAssertTrue(VibeBitPerfectChooseFormat(twenty, 44100, formats, 2, &chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 24u);
    XCTAssertFalse(VibeBitPerfectChooseFormat(twenty, 44100, formats, 1, &chosen), @"16 bits cannot carry 20");
    AudioFormatID lossless[] = { kAudioFormatAppleLossless, kAudioFormatFLAC };
    for (NSUInteger i = 0; i < sizeof(lossless) / sizeof(lossless[0]); i++) {
        XCTAssertTrue(VibeBitPerfectChooseFormat(Compressed(lossless[i], 0, 44100), 44100, formats, 2, &chosen));
        XCTAssertEqual(chosen.mBitsPerChannel, 24u);
        // An unknown lossless depth keeps its 24-bit assumption.
        XCTAssertFalse(VibeBitPerfectChooseFormat(Compressed(lossless[i], 0, 44100), 44100, formats, 1, &chosen));
    }
}

// A lossy source reaches the device as its float32 decode: the float format
// first, else the widest integer, never 16 bits for being lossy.
- (void)testLossySourcesPreferFloatThenTheWidestInteger {
    AudioFormatID codecs[] = { kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer3, kAudioFormatMPEG4AAC };
    AudioStreamRangedDescription formats[] = { VibeRangedPCMFormat(44100, 16, NO),
        VibeRangedPCMFormat(44100, 24, NO), VibeRangedPCMFormat(44100, 32, NO), VibeRangedPCMFormat(44100, 32, YES) };
    for (NSUInteger i = 0; i < sizeof(codecs) / sizeof(codecs[0]); i++) {
        AudioStreamBasicDescription source = Compressed(codecs[i], 0, 44100), chosen = {0};
        XCTAssertTrue(VibeBitPerfectChooseFormat(source, 44100, formats, 4, &chosen));
        XCTAssertEqual(chosen.mBitsPerChannel, 32u);
        XCTAssertTrue(VibePhysicalFormatIsFloat(chosen));
        XCTAssertEqual(chosen.mSampleRate, 44100);

        XCTAssertTrue(VibeBitPerfectChooseFormat(source, 44100, formats, 3, &chosen));
        XCTAssertEqual(chosen.mBitsPerChannel, 32u);
        XCTAssertFalse(VibePhysicalFormatIsFloat(chosen));

        XCTAssertTrue(VibeBitPerfectChooseFormat(source, 44100, formats, 2, &chosen));
        XCTAssertEqual(chosen.mBitsPerChannel, 24u);
        XCTAssertFalse(VibePhysicalFormatIsFloat(chosen));

        XCTAssertTrue(VibeBitPerfectChooseFormat(source, 44100, formats, 1, &chosen));
        XCTAssertEqual(chosen.mBitsPerChannel, 16u);
        XCTAssertFalse(VibePhysicalFormatIsFloat(chosen));
    }
}

- (void)testSourceDeeperThanTheDACTakesTheDeepestAndFailsSatisfaction {
    AudioStreamRangedDescription dac[16];
    UInt32 n = 0;
    static const double rates[] = { 44100, 96000 };
    for (NSUInteger r = 0; r < 2; r++) {
        dac[n++] = VibeRangedPCMFormat(rates[r], 16, NO);
        dac[n++] = VibeRangedPCMFormat(rates[r], 24, NO);
    }
    AudioStreamBasicDescription chosen = {0};
    // Nothing >= 32 is offered: the rule refuses to go below the source, so the
    // caller falls back to what the device has and reports DepthInsufficient.
    XCTAssertFalse(VibeBitPerfectChooseFormat(VibePCM(96000, 32, NO), 96000, dac, n, &chosen));
    XCTAssertFalse(VibePhysicalFormatSatisfies(VibePCM(96000, 24, NO), VibePCM(96000, 32, NO), Decode(96000)));
}

- (void)testFloatSourcePrefersFloatAndTakesI32OnlyWithoutOne {
    AudioStreamRangedDescription list[20];
    UInt32 n = (UInt32)USBDACList(list);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(44100, 32, YES), 44100, list, n, &chosen));
    XCTAssertFalse(VibePhysicalFormatIsFloat(chosen));
    XCTAssertEqual(chosen.mBitsPerChannel, 32u);
    XCTAssertFalse(VibePhysicalFormatSatisfies(chosen, VibePCM(44100, 32, YES), Decode(44100)));
    list[n++] = VibeRangedPCMFormat(44100, 32, YES);
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(44100, 32, YES), 44100, list, n, &chosen));
    XCTAssertTrue(VibePhysicalFormatIsFloat(chosen));
    XCTAssertTrue(VibePhysicalFormatSatisfies(chosen, VibePCM(44100, 32, YES), Decode(44100)));
}

- (void)testFloatOnlyDevicesChooseFloat32 {
    AudioStreamRangedDescription speakers[8];
    UInt32 n = (UInt32)FloatListForRates(kSpeakerRates, 4, speakers);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(96000, 24, NO), 96000, speakers, n, &chosen));
    XCTAssertTrue(VibePhysicalFormatIsFloat(chosen));
    XCTAssertEqual(chosen.mSampleRate, 96000);
}

- (void)testNothingAtTheRateIsNo {
    AudioStreamRangedDescription dac[16];
    UInt32 n = (UInt32)USBDACList(dac);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertFalse(VibeBitPerfectChooseFormat(VibePCM(88200, 24, NO), 88200, dac, n, &chosen));
}

- (void)testFormatChoiceMustCarryEverySourceChannel {
    AudioStreamBasicDescription source = VibePCM(48000, 16, NO), chosen = {0};
    AudioStreamRangedDescription formats[] = { VibeRangedPCMFormat(48000, 16, NO),
        VibeRangedPCMFormat(48000, 24, NO), VibeRangedPCMFormat(48000, 32, YES) };
    formats[0].mFormat.mChannelsPerFrame = 1;
    XCTAssertTrue(VibeBitPerfectChooseFormat(source, 48000, formats, 3, &chosen));
    XCTAssertEqual(chosen.mChannelsPerFrame, 2u);
    XCTAssertEqual(chosen.mBitsPerChannel, 24u);

    formats[1].mFormat.mChannelsPerFrame = 1;
    formats[2].mFormat.mChannelsPerFrame = 4;
    XCTAssertTrue(VibeBitPerfectChooseFormat(source, 48000, formats, 3, &chosen));
    XCTAssertEqual(chosen.mChannelsPerFrame, 4u);
    XCTAssertTrue(VibePhysicalFormatIsFloat(chosen));
    XCTAssertFalse(VibeBitPerfectChooseFormat(source, 48000, formats, 2, &chosen));
}

#pragma mark - Gapless output compatibility

- (void)testPhysicalFormatConfirmationChecksTheCompleteSampleRepresentation {
    AudioStreamBasicDescription original = VibePCM(48000, 24, NO);
    original.mFormatFlags |= kAudioFormatFlagIsPacked;
    original.mBytesPerFrame = original.mBytesPerPacket = 6;
    original.mFramesPerPacket = 1;
    XCTAssertTrue(VibePhysicalFormatsEquivalent(original, original));

    AudioStreamBasicDescription changed = original;
    changed.mFormatFlags ^= kAudioFormatFlagIsBigEndian;
    XCTAssertFalse(VibePhysicalFormatsEquivalent(original, changed));
    changed = original;
    changed.mFormatFlags ^= kAudioFormatFlagIsSignedInteger;
    XCTAssertFalse(VibePhysicalFormatsEquivalent(original, changed));
    changed = original;
    changed.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh;
    changed.mBytesPerFrame = changed.mBytesPerPacket = 8;
    XCTAssertTrue(VibeBitPerfectOutputNeedsSwitch(changed, original, 48000));
    changed = original;
    changed.mBytesPerFrame = 8;
    XCTAssertFalse(VibePhysicalFormatsEquivalent(original, changed));
    changed = original;
    changed.mBytesPerPacket = 12;
    XCTAssertFalse(VibePhysicalFormatsEquivalent(original, changed));
    changed = original;
    changed.mFramesPerPacket = 2;
    XCTAssertFalse(VibePhysicalFormatsEquivalent(original, changed));
    changed = original;
    changed.mFormatID = kAudioFormat60958AC3;
    XCTAssertFalse(VibePhysicalFormatsEquivalent(original, changed));
}

// A gapless splice between them can arm.
- (void)testSixteenAndTwentyFourBitTracksShareAFormatOnAnIntegerDAC {
    AudioStreamRangedDescription dac[16];
    UInt32 n = (UInt32)USBDACList(dac);
    AudioStreamBasicDescription first = {0}, next = {0}, other = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(44100, 16, NO), 44100, dac, n, &first));
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(44100, 24, NO), 44100, dac, n, &next));
    XCTAssertFalse(VibeBitPerfectOutputNeedsSwitch(first, next, 44100));
    XCTAssertFalse(VibeBitPerfectOutputNeedsSwitch(next, first, 44100));
    XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(48000, 16, NO), 48000, dac, n, &other));
    XCTAssertTrue(VibeBitPerfectOutputNeedsSwitch(first, other, 44100), @"another rate still switches");
}

- (void)testFloatOutputCanSpliceDifferentDepthsAndLossyFilesWithoutASwitch {
    AudioStreamRangedDescription device = VibeRangedPCMFormat(44100, 32, YES);
    AudioStreamBasicDescription sources[] = {
        VibePCM(44100, 16, NO), VibePCM(44100, 24, NO),
        Compressed(kAudioFormatMPEGLayer3, 0, 44100),
    };
    for (NSUInteger i = 0; i < sizeof(sources) / sizeof(sources[0]); i++) {
        AudioStreamBasicDescription chosen = {0};
        XCTAssertTrue(VibeBitPerfectChooseFormat(sources[i], 44100, &device, 1, &chosen));
        XCTAssertFalse(VibeBitPerfectOutputNeedsSwitch(device.mFormat, chosen, 44100));
    }
}

// 16 and 24-bit files at one rate take the same widest integer depth. So a
// 24-bit track that follows a 16-bit one needs no switch, and the gapless
// splice joins them.
- (void)testIntegerOutputSplicesSixteenAndTwentyFourBitFilesWithoutASwitch {
    AudioStreamRangedDescription dac[16];
    UInt32 counts[] = {(UInt32)USBDACList(dac), 2}; // every format, then only 44.1 kHz at 16 and 24 bits
    for (int i = 0; i < 2; i++) {
        AudioStreamBasicDescription first = {0}, next = {0};
        XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(44100, 16, NO), 44100, dac, counts[i], &first));
        XCTAssertTrue(VibeBitPerfectChooseFormat(VibePCM(44100, 24, NO), 44100, dac, counts[i], &next));
        XCTAssertFalse(VibeBitPerfectOutputNeedsSwitch(first, next, 44100), @"%u formats", (unsigned)counts[i]);
    }
}

- (void)testStaleMixerRateRequiresASwitchEvenWhenThePhysicalFormatMatches {
    AudioStreamBasicDescription physical = VibePCM(48000, 32, YES);
    XCTAssertTrue(VibeBitPerfectOutputNeedsSwitch(physical, physical, 44100));
    XCTAssertFalse(VibeBitPerfectOutputNeedsSwitch(physical, physical, 48000));
}

#pragma mark - Eligibility

// Every SDK transport, one assertion each, so moving one between the sides is
// a deliberate test edit. The System Output policy is not a transport: it is
// the absence of a chosen device, refused before this rule is asked.
- (void)testTheAllowlist {
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeBuiltIn, NO));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypePCI, NO));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeUSB, NO));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeFireWire, NO));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeThunderbolt, NO));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeHDMI, NO));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeDisplayPort, NO));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeAVB, NO));
    XCTAssertTrue(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeVirtual, NO));
}

- (void)testEverythingRemoteCompressedOrResampledIsOut {
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeUnknown, NO));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeBluetooth, NO));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeBluetoothLE, NO));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeAirPlay, NO));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeContinuityCaptureWired, NO));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeContinuityCaptureWireless, NO));
    // kAudioDeviceTransportTypeRemoteScreen / RemoteStreaming, spelled as
    // their codes: CI's older SDK does not declare them, and the rule refuses
    // them through its default branch either way.
    XCTAssertFalse(VibeBitPerfectDeviceEligible('rscr', NO));
    XCTAssertFalse(VibeBitPerfectDeviceEligible('rstr', NO));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeAggregate, NO));
    XCTAssertFalse(VibeBitPerfectDeviceEligible(kAudioDeviceTransportTypeAutoAggregate, NO));
}

- (void)testTestingOverrideAdmitsEveryTransport {
    const UInt32 transports[] = {kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
        kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeUnknown,
        kAudioDeviceTransportTypeUSB, 'new!'};
    for (NSUInteger i = 0; i < sizeof(transports) / sizeof(transports[0]); i++) {
        XCTAssertTrue(VibeBitPerfectDeviceEligible(transports[i], YES));
    }
}

#pragma mark - The fold

// Everything perfect; each test below breaks one input and expects the fold
// to name it.
static VibeBitPerfectReport Perfect(void) {
    return (VibeBitPerfectReport){
        .enabled = YES, .eligibleDevice = YES, .hasTrack = YES,
        .rateExact = YES, .formatConfirmed = YES, .channelsMatch = YES,
        .depthOK = YES, .softwareVolume = 1.0f, .balance = 0.5f, .playerVolume = 1.0f,
        .hogWanted = YES, .exclusive = YES, .sourceBits = 16,
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
    r.channelsMatch = NO;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.muted = YES;
    XCTAssertFalse(VibeBitPerfectReportsEqual(Perfect(), r));
    r = Perfect();
    r.playerVolume = 0.5f;
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
    r.sourceBits = 0;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusSourceLossy);
    r.exclusive = NO;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusExclusiveRefused);
    r.playerVolume = 0.5f;
    XCTAssertEqual(VibeBitPerfectFold(r), VibeBitPerfectStatusVolumeScaled);
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

#pragma mark - Deferred saved-device bind races

// Arguments: stopped, loading, paused, outputRunning, audioActive.
- (void)testSavedDeviceMayBindAtIdleOrSilentLaunchButNotUnderAnOutgoingFade {
    XCTAssertTrue(VibeCanBindSavedOutputDevice(YES, NO, NO, NO, NO));
    XCTAssertTrue(VibeCanBindSavedOutputDevice(YES, NO, NO, YES, NO));
    XCTAssertTrue(VibeCanBindSavedOutputDevice(NO, YES, NO, NO, NO));
    XCTAssertFalse(VibeCanBindSavedOutputDevice(NO, YES, NO, YES, YES)); // under an outgoing fade
}

- (void)testSavedDeviceNeverBindsUnderPlayback {
    XCTAssertFalse(VibeCanBindSavedOutputDevice(NO, NO, NO, YES, YES));
}

// A vanished device parks playback as Paused, so this is the case that decides
// whether it can be re-adopted when it comes back without waiting for a stop.
- (void)testSavedDeviceBindsOnceAPauseHasSettledButNotDuringItsFade {
    XCTAssertTrue(VibeCanBindSavedOutputDevice(NO, NO, YES, NO, NO));  // idle-stopped
    XCTAssertTrue(VibeCanBindSavedOutputDevice(NO, NO, YES, YES, NO)); // output running, fade done
    XCTAssertFalse(VibeCanBindSavedOutputDevice(NO, NO, YES, YES, YES)); // pause fade still audible
}

#pragma mark - Device liveness, asked of the device rather than the snapshot

- (void)testADeviceThatAnswersDeadIsGone {
    XCTAssertTrue(VibeDeviceIsConfirmedDead(noErr, 0));
    XCTAssertFalse(VibeDeviceIsConfirmedDead(noErr, 1));
}

- (void)testAnObjectThatNoLongerExistsIsGone {
    XCTAssertTrue(VibeDeviceIsConfirmedDead(kAudioHardwareBadObjectError, 1));
}

// The trap: a false removal persists System Output. A read that failed for any
// other reason says nothing about the device, so it must never read as dead.
- (void)testAnyOtherFailedReadIsUnknownNeverDead {
    XCTAssertFalse(VibeDeviceIsConfirmedDead(kAudioHardwareNotRunningError, 0));
    XCTAssertFalse(VibeDeviceIsConfirmedDead(kAudioHardwareUnknownPropertyError, 0));
    XCTAssertFalse(VibeDeviceIsConfirmedDead(kAudioHardwareUnspecifiedError, 0));
}

@end
