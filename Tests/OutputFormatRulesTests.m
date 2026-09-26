//
// Bit-perfect output: the source depth decode, the rate and depth rules, the
// device eligibility allowlist and the status fold.
//

#import <XCTest/XCTest.h>
#import <objc/runtime.h>

#import "../Vibe/Audio/Mac/Devices/OutputFormatRules.h"
#import "../Vibe/Audio/AudioOutputUnitInternal.h"
#import "AppSettings.h"
#import "AppSettings+Mac.h"
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

// AudioFileHandle's processing format: float32 at the file's rate.
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

- (void)testEncodedPhysicalFormatsCannotConfirmUnchangedPCM {
    AudioStreamBasicDescription encoded = PCM(48000, 16, NO);
    encoded.mFormatID = kAudioFormat60958AC3;
    XCTAssertFalse(VibePhysicalFormatSatisfies(encoded, PCM(48000, 16, NO), Decode(48000)));
}

- (void)testLossySourceIsSatisfiedByAnythingAtItsRate {
    XCTAssertTrue(VibePhysicalFormatSatisfies(PCM(44100, 16, NO), Compressed(kAudioFormatMPEGLayer3, 0, 44100), Decode(44100)));
}

#pragma mark - The rate rule

- (void)testExactRateWins {
    AudioStreamRangedDescription list[8];
    NSUInteger n = FloatListForRates(kSpeakerRates, 4, list);
    XCTAssertEqual(VibeBitPerfectTargetRate(44100, 2, list, (UInt32)n), 44100);
    XCTAssertEqual(VibeBitPerfectTargetRate(96000, 2, list, (UInt32)n), 96000);
}

- (void)testEncodedOffersCannotHideAUsablePCMRate {
    AudioStreamRangedDescription list[] = { RangedFormat(48000, 16, NO),
        RangedFormat(96000, 24, NO) };
    list[0].mFormat.mFormatID = kAudioFormat60958AC3;
    double rate = VibeBitPerfectTargetRate(48000, 2, list, 2);
    XCTAssertEqual(rate, 96000);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(PCM(48000, 24, NO), rate, list, 2, &chosen));
    XCTAssertEqual(chosen.mFormatID, kAudioFormatLinearPCM);
    XCTAssertEqual(VibeBitPerfectTargetRate(48000, 2, list, 1), 0);
}

- (void)testNarrowChannelOffersCannotHideAUsablePCMRate {
    AudioStreamRangedDescription formats[] = { RangedFormat(48000, 16, NO),
        RangedFormat(96000, 24, NO) };
    formats[0].mFormat.mChannelsPerFrame = 1;
    double rate = VibeBitPerfectTargetRate(48000, 2, formats, 2);
    XCTAssertEqual(rate, 96000);
    AudioStreamBasicDescription chosen = {0};
    XCTAssertTrue(VibeBitPerfectChooseFormat(PCM(48000, 16, NO), rate, formats, 2, &chosen));
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
    AudioStreamRangedDescription list[] = { RangedFormat(384000, 32, YES),
        RangedFormat(192000, 32, YES), RangedFormat(44100, 32, YES) };
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
    AudioStreamRangedDescription ranged = RangedFormat(0, 32, YES);
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
    AudioFormatID lossless[] = { kAudioFormatAppleLossless, kAudioFormatFLAC };
    for (NSUInteger i = 0; i < sizeof(lossless) / sizeof(lossless[0]); i++) {
        XCTAssertTrue(VibeBitPerfectChooseFormat(Compressed(lossless[i], 0, 44100), 44100, dac, n, &chosen));
        XCTAssertEqual(chosen.mBitsPerChannel, 24u); // unknown lossless depth retains its 24-bit assumption
    }
}

// A lossy source reaches the device as its float32 decode: the float format
// first, else the widest integer, never 16 bits for being lossy.
- (void)testLossySourcesPreferFloatThenTheWidestInteger {
    AudioFormatID codecs[] = { kAudioFormatMPEGLayer2, kAudioFormatMPEGLayer3, kAudioFormatMPEG4AAC };
    AudioStreamRangedDescription formats[] = { RangedFormat(44100, 16, NO),
        RangedFormat(44100, 24, NO), RangedFormat(44100, 32, NO), RangedFormat(44100, 32, YES) };
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

- (void)testFormatChoiceMustCarryEverySourceChannel {
    AudioStreamBasicDescription source = PCM(48000, 16, NO), chosen = {0};
    AudioStreamRangedDescription formats[] = { RangedFormat(48000, 16, NO),
        RangedFormat(48000, 24, NO), RangedFormat(48000, 32, YES) };
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
    AudioStreamBasicDescription original = PCM(48000, 24, NO);
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

#pragma mark - Carrying remembered modes to a new USB port

static NSString *const kModesKey = @"AudioPlayer.outputModesByDeviceUID";

// Removed rather than restored: writing a value back would materialize a key
// that was never there (Tests/CLAUDE.md). The guard restores the domain at exit.
- (void)withModeStore:(NSDictionary *)store run:(void (^)(void))block {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:store forKey:kModesKey];
    block();
    [defaults removeObjectForKey:kModesKey];
}

- (void)testCarryCopiesModesToTheNewPortAndLeavesTheOldPortIntact {
    [self withModeStore:@{@"port-a": @{@"bitPerfect": @YES, @"exclusive": @YES}} run:^{
        AppSettings *settings = AppSettings.sharedInstance;
        [settings carryOutputModesFromDeviceUID:@"port-a" toDeviceUID:@"port-b"];
        XCTAssertTrue([settings bitPerfectOutputForDeviceUID:@"port-b"]);
        XCTAssertTrue([settings exclusiveOutputForDeviceUID:@"port-b"]);
        // Copied, not moved: plugged back into the first port it still has them.
        XCTAssertTrue([settings bitPerfectOutputForDeviceUID:@"port-a"]);
    }];
}

// Modes someone already chose for that exact unit are a choice; a carry is a
// guess, and must never overwrite a choice.
- (void)testCarryNeverOverwritesModesAlreadyChosenForTheDestination {
    [self withModeStore:@{@"port-a": @{@"bitPerfect": @YES},
                          @"port-b": @{@"exclusive": @YES}} run:^{
        AppSettings *settings = AppSettings.sharedInstance;
        [settings carryOutputModesFromDeviceUID:@"port-a" toDeviceUID:@"port-b"];
        XCTAssertFalse([settings bitPerfectOutputForDeviceUID:@"port-b"]);
        XCTAssertTrue([settings exclusiveOutputForDeviceUID:@"port-b"]);
    }];
}

- (void)testCarryIgnoresEmptyOrIdenticalUIDs {
    [self withModeStore:@{@"port-a": @{@"bitPerfect": @YES}} run:^{
        AppSettings *settings = AppSettings.sharedInstance;
        [settings carryOutputModesFromDeviceUID:@"" toDeviceUID:@"port-b"];
        [settings carryOutputModesFromDeviceUID:@"port-a" toDeviceUID:@""];
        [settings carryOutputModesFromDeviceUID:@"port-a" toDeviceUID:@"port-a"];
        XCTAssertFalse([settings bitPerfectOutputForDeviceUID:@"port-b"]);
        XCTAssertEqual([[NSUserDefaults.standardUserDefaults dictionaryForKey:kModesKey] count], 1u);
    }];
}

// A class-compliant USB interface's device UID is its USB location, so the same
// iD4 on another port has a new UID but the same model UID.
- (void)testSavedDeviceIsFoundByModelUIDWhenMovedToAnotherPort {
    AudioDevice *moved = [[AudioDevice alloc] initWithName:@"Audient iD4"
            uid:@"AppleUSBAudioEngine:Audient:Audient iD4:1100000:1,2"
            modelUID:@"Audient iD4:2708:0009" deviceId:7 isSystemDefault:NO
            transportType:kAudioDeviceTransportTypeUSB];
    AudioDevice *found = [AudioDeviceManager
            deviceForUID:@"AppleUSBAudioEngine:Audient:Audient iD4:2100000:1,2"
                modelUID:@"Audient iD4:2708:0009" name:@"Audient iD4" inDevices:@[moved]];
    XCTAssertEqual(found, moved);
}

// The model UID outranks the name because it tells apart two models that share
// a name; the name cannot. Otherwise the wrong one could inherit exclusive.
- (void)testModelUIDOutranksAMatchingName {
    AudioDevice *impostor = [[AudioDevice alloc] initWithName:@"Audient iD4" uid:@"other"
            modelUID:@"Someone Else:1234:0001" deviceId:1 isSystemDefault:NO
            transportType:kAudioDeviceTransportTypeUSB];
    AudioDevice *real = [[AudioDevice alloc] initWithName:@"Audient iD4" uid:@"new-port"
            modelUID:@"Audient iD4:2708:0009" deviceId:2 isSystemDefault:NO
            transportType:kAudioDeviceTransportTypeUSB];
    AudioDevice *found = [AudioDeviceManager deviceForUID:@"old-port" modelUID:@"Audient iD4:2708:0009"
                                                     name:@"Audient iD4" inDevices:@[impostor, real]];
    XCTAssertEqual(found, real);
}

// Device UID is still the most specific answer and wins over a model match.
- (void)testDeviceUIDOutranksModelUID {
    AudioDevice *sibling = [[AudioDevice alloc] initWithName:@"Audient iD4" uid:@"port-a"
            modelUID:@"Audient iD4:2708:0009" deviceId:1 isSystemDefault:NO
            transportType:kAudioDeviceTransportTypeUSB];
    AudioDevice *exact = [[AudioDevice alloc] initWithName:@"Audient iD4" uid:@"port-b"
            modelUID:@"Audient iD4:2708:0009" deviceId:2 isSystemDefault:NO
            transportType:kAudioDeviceTransportTypeUSB];
    AudioDevice *found = [AudioDeviceManager deviceForUID:@"port-b" modelUID:@"Audient iD4:2708:0009"
                                                     name:@"Audient iD4" inDevices:@[sibling, exact]];
    XCTAssertEqual(found, exact);
}

// An empty model UID must never match a device that also reports none.
- (void)testEmptyModelUIDNeverMatches {
    AudioDevice *unnamed = [[AudioDevice alloc] initWithName:@"Virtual" uid:@"v"
            modelUID:@"" deviceId:1 isSystemDefault:NO transportType:kAudioDeviceTransportTypeVirtual];
    XCTAssertNil([AudioDeviceManager deviceForUID:@"gone" modelUID:@"" name:@"" inDevices:@[unnamed]]);
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
    AudioDeviceManager *manager = [self managerWithSnapshot:nil];
    XCTestExpectation *resolved = [self expectationWithDescription:@"no match"];
    __block NSUInteger deliveries = 0;
    [manager resolveOutputDeviceForUID:@"missing" name:@"DAC" completion:^(AudioDevice *answer) {
        XCTAssertNil(answer);
        deliveries++;
        [resolved fulfill];
    }];
    [self refresh:manager snapshot:nil published:NO];
    XCTAssertEqual(deliveries, 0u, @"Unknown discovery must not disable an armed mode");
    [self refresh:manager snapshot:@[] published:YES];
    [self waitForExpectations:@[resolved] timeout:2];
    [self refresh:manager snapshot:@[] published:YES];
    XCTAssertEqual(deliveries, 1u);
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
    XCTAssertTrue(VibeCanBindSavedOutputDevice(NO, NO, YES, YES, NO)); // engine up, fade done
    XCTAssertFalse(VibeCanBindSavedOutputDevice(NO, NO, YES, YES, YES)); // pause fade still audible
}

#pragma mark - Device liveness, asked of the device rather than the snapshot

- (void)testADeviceThatAnswersDeadIsGone {
    XCTAssertTrue(VibeDeviceIsConfirmedDead(noErr, 0));
    XCTAssertFalse(VibeDeviceIsConfirmedDead(noErr, 1));
}

// An unplugged device's id no longer names an object at all.
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

#pragma mark - The hosted output unit's render callback

// The HAL's side of one IO cycle: one float buffer per channel, prefilled so
// silence is a write, not an absence.
static AudioBufferList *VibeTestIOBuffers(UInt32 channels, UInt32 frames, float fill) {
    AudioBufferList *list = calloc(1, sizeof(AudioBufferList) + (channels - 1) * sizeof(AudioBuffer));
    list->mNumberBuffers = channels;
    for (UInt32 c = 0; c < channels; c++) {
        float *samples = malloc(frames * sizeof(float));
        for (UInt32 f = 0; f < frames; f++) {
            samples[f] = fill;
        }
        list->mBuffers[c].mNumberChannels = 1;
        list->mBuffers[c].mDataByteSize = frames * (UInt32)sizeof(float);
        list->mBuffers[c].mData = samples;
    }
    return list;
}

static void VibeTestFreeIOBuffers(AudioBufferList *list) {
    for (UInt32 c = 0; c < list->mNumberBuffers; c++) {
        free(list->mBuffers[c].mData);
    }
    free(list);
}

// The engine's pattern: frame n of channel c is (n + 1)(c + 1), n counted
// across every call, so a slice that dropped or repeated a frame shows.
static float VibeTestPattern(uint64_t frame, UInt32 channel) {
    return (float)(frame + 1) * (float)(channel + 1);
}

// Samples of `data` that do not carry the pattern from `firstFrame` (silence,
// with `silence`) in the format's channels, or are not zero in any wider one.
static NSUInteger VibeTestMismatches(AudioBufferList *data, UInt32 channels, UInt32 frames, uint64_t firstFrame, BOOL silence) {
    NSUInteger mismatches = 0;
    for (UInt32 c = 0; c < data->mNumberBuffers; c++) {
        const float *samples = data->mBuffers[c].mData;
        for (UInt32 f = 0; f < frames; f++) {
            float expected = (silence || c >= channels) ? 0 : VibeTestPattern(firstFrame + f, c);
            mismatches += samples[f] != expected;
        }
    }
    return mismatches;
}

typedef struct {
    uint64_t rendered;   // frames the proc has produced
    NSUInteger calls;
    NSUInteger failures; // leading calls that fail
    UInt32 maxFrames;    // the largest cycle this proc accepts, as the pipeline's slicing bounds it
    OSStatus complaint;
} VibeTestEngine;

static OSStatus VibeTestRenderProc(void *refCon, const AudioTimeStamp *timestamp, UInt32 frameCount, AudioBufferList *buffer) {
    VibeTestEngine *engine = refCon;
    engine->calls++;
    if (engine->calls <= engine->failures) {
        return -3;
    }
    if (frameCount == 0 || frameCount > engine->maxFrames || buffer->mNumberBuffers < 2) {
        engine->complaint = -1;
        return -1;
    }
    // As the pipeline does: the first two buffers carry the signal, and a
    // wider device's further buffers are left silent.
    for (UInt32 c = 0; c < buffer->mNumberBuffers; c++) {
        if (buffer->mBuffers[c].mDataByteSize != frameCount * sizeof(float)) {
            engine->complaint = -2;
            return -2;
        }
        float *out = buffer->mBuffers[c].mData;
        for (UInt32 f = 0; f < frameCount; f++) {
            out[f] = c < 2 ? VibeTestPattern(engine->rendered + f, c) : 0;
        }
    }
    engine->rendered += frameCount;
    return noErr;
}

static OSStatus VibeTestCycle(VibeOutputUnitState *state, AudioBufferList *data, UInt32 frames,
                              AudioUnitRenderActionFlags *flags, UInt64 hostTime) {
    AudioTimeStamp stamp = {0};
    stamp.mSampleTime = (Float64)hostTime;
    stamp.mHostTime = hostTime;
    stamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    return VibeOutputUnitRender(state, flags, &stamp, 0, frames, data);
}

- (void)testOutputUnitCallbackWritesSilenceWhileTheGateIsClosed {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    AudioBufferList *data = VibeTestIOBuffers(2, 512, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 512, &flags, 42), noErr);
    XCTAssertTrue(flags & kAudioUnitRenderAction_OutputIsSilence);
    XCTAssertEqual(engine.calls, 0u);
    XCTAssertEqual(VibeTestMismatches(data, 2, 512, 0, YES), 0u);
    XCTAssertEqual(atomic_load(&state.dropouts), 0ull);
    XCTAssertEqual(atomic_load(&state.inRender), 0);
    VibeTestFreeIOBuffers(data);
}

- (void)testOutputUnitCallbackHandsTheProcTheWholeCycle {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    atomic_store(&state.gate, 1);
    uint64_t total = 0;
    UInt64 cycle = 0;
    for (NSNumber *pull in @[@63, @512, @4096, @8192, @63]) {
        UInt32 frames = pull.unsignedIntValue;
        AudioBufferList *data = VibeTestIOBuffers(2, frames, 0.5f);
        AudioUnitRenderActionFlags flags = 0;
        XCTAssertEqual(VibeTestCycle(&state, data, frames, &flags, ++cycle), noErr);
        XCTAssertFalse(flags & kAudioUnitRenderAction_OutputIsSilence);
        XCTAssertEqual(VibeTestMismatches(data, 2, frames, total, NO), 0u, @"%u-frame pull", frames);
        total += frames;
        VibeTestFreeIOBuffers(data);
    }
    XCTAssertEqual(engine.complaint, noErr);
    XCTAssertEqual(engine.rendered, total);
    XCTAssertEqual(engine.calls, 5u); // one call per cycle, the 8192-frame one included
    XCTAssertEqual(atomic_load(&state.dropouts), 0ull);
}

// clear_render_counters' seam: the cumulative counters restart from zero and
// keep counting, and nothing else in the state moves.
- (void)testOutputUnitCountersClearAndRestart {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    atomic_store(&state.gate, 1);
    for (UInt64 cycle = 1; cycle <= 3; cycle++) {
        AudioBufferList *data = VibeTestIOBuffers(2, 256, 0.5f);
        AudioUnitRenderActionFlags flags = 0;
        XCTAssertEqual(VibeTestCycle(&state, data, 256, &flags, cycle), noErr);
        VibeTestFreeIOBuffers(data);
    }
    XCTAssertEqual(atomic_load(&state.cycles), 3ull);
    XCTAssertGreaterThan(atomic_load(&state.renderNanos), 0ull);
    XCTAssertGreaterThan(atomic_load(&state.renderMaxNanos), 0ull);
    atomic_store(&state.dropouts, 7);
    VibeOutputUnitStateClearCounters(&state);
    XCTAssertEqual(atomic_load(&state.cycles), 0ull);
    XCTAssertEqual(atomic_load(&state.renderNanos), 0ull);
    XCTAssertEqual(atomic_load(&state.renderMaxNanos), 0ull);
    XCTAssertEqual(atomic_load(&state.dropouts), 0ull);
    XCTAssertEqual(atomic_load(&state.gate), 1);
    XCTAssertEqual(state.channels, 2u);
    AudioBufferList *data = VibeTestIOBuffers(2, 256, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 256, &flags, 4), noErr);
    VibeTestFreeIOBuffers(data);
    XCTAssertEqual(atomic_load(&state.cycles), 1ull);
    XCTAssertEqual(engine.calls, 4u);
}

- (void)testOutputUnitCallbackHandsTheProcEveryBuffer {
    // A four-output interface pulling the stereo pipeline: the proc sees all
    // four buffers, writes the first two and leaves the rest silent.
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    atomic_store(&state.gate, 1);
    AudioBufferList *data = VibeTestIOBuffers(4, 256, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 256, &flags, 1), noErr);
    XCTAssertEqual(VibeTestMismatches(data, 2, 256, 0, NO), 0u);
    XCTAssertEqual(engine.calls, 1u);
    VibeTestFreeIOBuffers(data);
}

- (void)testOutputUnitCallbackWritesSilenceWhenTheHalOffersFewerBuffersThanTheFormat {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    atomic_store(&state.gate, 1);
    AudioBufferList *data = VibeTestIOBuffers(1, 256, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 256, &flags, 1), noErr);
    XCTAssertTrue(flags & kAudioUnitRenderAction_OutputIsSilence);
    XCTAssertEqual(VibeTestMismatches(data, 1, 256, 0, YES), 0u);
    XCTAssertEqual(engine.calls, 0u);
    XCTAssertEqual(atomic_load(&state.dropouts), 0ull);
    VibeTestFreeIOBuffers(data);
}

- (void)testOutputUnitCallbackWritesSilenceAndCountsADropoutWhenTheProcFails {
    VibeTestEngine engine = { .maxFrames = 8192, .failures = 2 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    atomic_store(&state.gate, 1);
    AudioBufferList *data = VibeTestIOBuffers(2, 1024, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 1024, &flags, 1), noErr);
    XCTAssertTrue(flags & kAudioUnitRenderAction_OutputIsSilence);
    XCTAssertEqual(VibeTestMismatches(data, 2, 1024, 0, YES), 0u);
    XCTAssertEqual(engine.calls, 1u); // asked once: the proc never refuses, it renders or it fails
    XCTAssertEqual(atomic_load(&state.dropouts), 1ull);
    // The next cycle drops again, one dropout per cycle; the one after, with
    // the proc rendering, is exact and continues the count from zero frames.
    flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 1024, &flags, 2), noErr);
    XCTAssertEqual(atomic_load(&state.dropouts), 2ull);
    engine.failures = 0;
    flags = 0;
    XCTAssertEqual(VibeTestCycle(&state, data, 1024, &flags, 3), noErr);
    XCTAssertFalse(flags & kAudioUnitRenderAction_OutputIsSilence);
    XCTAssertEqual(VibeTestMismatches(data, 2, 1024, 0, NO), 0u);
    XCTAssertEqual(atomic_load(&state.dropouts), 2ull);
    VibeTestFreeIOBuffers(data);
}

- (void)testOutputUnitCallbackCountsItsCostOnlyWhileTheGateIsOpen {
    VibeTestEngine engine = { .maxFrames = 8192 };
    VibeOutputUnitState state = {0};
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, VibeTestRenderProc, &engine));
    AudioBufferList *data = VibeTestIOBuffers(2, 512, 0.5f);
    AudioUnitRenderActionFlags flags = 0;
    // A closed gate writes silence and is not a rendered cycle.
    XCTAssertEqual(VibeTestCycle(&state, data, 512, &flags, 1), noErr);
    XCTAssertEqual(atomic_load(&state.cycles), 0ull);
    XCTAssertEqual(atomic_load(&state.renderNanos), 0ull);
    atomic_store(&state.gate, 1);
    for (UInt64 cycle = 2; cycle <= 3; cycle++) {
        flags = 0;
        XCTAssertEqual(VibeTestCycle(&state, data, 512, &flags, cycle), noErr);
    }
    uint64_t nanos = atomic_load(&state.renderNanos), longest = atomic_load(&state.renderMaxNanos);
    XCTAssertEqual(atomic_load(&state.cycles), 2ull);
    XCTAssertGreaterThan(nanos, 0ull);
    XCTAssertGreaterThanOrEqual(longest * 2, nanos);
    XCTAssertLessThanOrEqual(longest, nanos);
    VibeTestFreeIOBuffers(data);
}

- (void)testOutputUnitRefusesAFormatWithoutChannels {
    VibeOutputUnitState state = {0};
    XCTAssertFalse(VibeOutputUnitStateInitialize(&state, 0, NULL, NULL));
    XCTAssertTrue(VibeOutputUnitStateInitialize(&state, 2, NULL, NULL));
}

// Runs `body` with the unit's HAL start replaced; the original is back after,
// whatever the body asserted.
static void VibeWithHALStart(OSStatus (^start)(void), void (^body)(void)) {
    Method method = class_getInstanceMethod(AudioOutputUnit.class, @selector(halStartUnit));
    IMP replacement = imp_implementationWithBlock(^OSStatus(id receiver) { return start(); });
    IMP original = method_setImplementation(method, replacement);
    @try {
        body();
    } @finally {
        method_setImplementation(method, original);
        imp_removeBlock(replacement);
    }
}

static int32_t VibeGate(AudioOutputUnit *unit) {
    return atomic_load_explicit(&unit.state->gate, memory_order_seq_cst);
}

// #53: the player queue asks for a start and goes on; the device's IO thread
// is waited for on the unit's own queue. A stop closes the gate at once, even
// with that wait still in progress.
- (void)testAStartReturnsBeforeTheDeviceHasStartedAndAStopClosesTheGateAtOnce {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    XCTAssertNotNil(unit);
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    VibeWithHALStart(^OSStatus {
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        return noErr;
    }, ^{
        uint64_t began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        [unit start];
        XCTAssertLessThan((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1e6, 20.0, @"the start waited for the device");
        XCTAssertTrue(unit.running);
        XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0);
        XCTAssertEqual(VibeGate(unit), 1, @"the gate opens before the device starts, so its first cycle renders");
        [unit stop];
        XCTAssertEqual(VibeGate(unit), 0, @"a stop closes the gate before it returns");
        XCTAssertFalse(unit.running);
        dispatch_semaphore_signal(release);
        [unit waitUntilIdle];
        XCTAssertEqual(VibeGate(unit), 0);
    });
}

// A start that a later stop or start supersedes before the unit's queue reaches
// it never runs: a unit still headed for the previous device or format must
// never pull the pipeline the player has already moved on.
- (void)testAStartSupersededBeforeItRunsNeverStartsTheDevice {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    __block int starts = 0;
    VibeWithHALStart(^OSStatus {
        if (++starts == 1) {
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        }
        return noErr;
    }, ^{
        [unit start];
        XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), 0);
        [unit stop];
        [unit start]; // superseded by the stop below before the queue reaches it
        [unit stop];
        [unit start]; // the one that owns the unit
        dispatch_semaphore_signal(release);
        [unit waitUntilIdle];
        XCTAssertEqual(starts, 2, @"the superseded start reached the device");
        XCTAssertEqual(VibeGate(unit), 1);
        XCTAssertTrue(unit.running);
        [unit stop];
        [unit waitUntilIdle];
        XCTAssertEqual(VibeGate(unit), 0);
    });
}

// A refusal arrives later, through the handler, with the generation of the
// start it refused; a stop after it makes that generation stale, which is how
// the player tells a refusal it must act on from a moot one.
- (void)testARefusedStartReportsItsGenerationAndLeavesTheGateClosed {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    __block NSError *reported = nil;
    __block uint64_t reportedGeneration = 0;
    __block BOOL reportedBind = YES;
    unit.failureHandler = ^(NSError *error, uint64_t runGeneration, BOOL bindRefused) {
        reported = error;
        reportedGeneration = runGeneration;
        reportedBind = bindRefused;
    };
    VibeWithHALStart(^OSStatus { return kAudioHardwareNotRunningError; }, ^{
        [unit start];
        [unit waitUntilIdle];
        XCTAssertNotNil(reported);
        XCTAssertEqual(reported.code, kAudioHardwareNotRunningError);
        XCTAssertFalse(reportedBind);
        XCTAssertEqual(reportedGeneration, unit.runGeneration, @"nothing superseded this start");
        XCTAssertEqual(VibeGate(unit), 0);
        [unit stop];
        XCTAssertNotEqual(reportedGeneration, unit.runGeneration, @"a stop makes the refusal moot");
    });
}

// A device the HAL no longer knows is refused at once, before anything is
// queued, and the unit keeps no claim to it.
- (void)testABindToADeviceTheHALDoesNotKnowIsRefusedAtOnce {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    XCTAssertNotEqual([unit bindToDevice:(AudioDeviceID)0x7FFFFFF0], noErr);
    XCTAssertEqual(unit.deviceID, kAudioObjectUnknown);
}

- (void)testOutputUnitIsUnboundAtInitAndStopsSafelyBeforeAnyStart {
    AudioOutputUnit *unit = [[AudioOutputUnit alloc] init];
    XCTAssertNotNil(unit);
    XCTAssertEqual(unit.deviceID, kAudioObjectUnknown);
    XCTAssertNil(unit.format);
    XCTAssertFalse(unit.running);
    XCTAssertEqual(unit.dropouts, 0ull);
    XCTAssertEqual(unit.renderCycles, 0ull);
    XCTAssertEqual(unit.renderMeanMicroseconds, 0.0);
    XCTAssertEqual(unit.renderMaxMicroseconds, 0.0);
    [unit stop];
    XCTAssertFalse(unit.running);
}

@end
