//
//  OutputFormatRules.h
//  Vibe
//
//  Bit-perfect output's decisions, as static inlines so the host-less suite
//  reaches them without a HAL: what a source's word length is, which of a
//  device's formats carries it unchanged, whether a device may be driven at
//  all, and how the reasons fold into the one status the header and Settings
//  show. The mechanism they serve is AudioPlayer+Devices.m.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/AudioHardwareBase.h>

typedef NS_ENUM(NSInteger, VibeBitPerfectStatus) {
    // The setting is off, or the device is ineligible — defensive: the shell
    // never lets the two coincide.
    VibeBitPerfectStatusOff,
    // On, device chosen, nothing playing.
    VibeBitPerfectStatusIdle,
    VibeBitPerfectStatusActive,
    // The device does not offer the file's rate; a multiple was used when it
    // offered one.
    VibeBitPerfectStatusRateUnsupported,
    // The HAL did not take the format in time.
    VibeBitPerfectStatusSwitchFailed,
    VibeBitPerfectStatusDepthInsufficient,
    // Software volume below 1.0.
    VibeBitPerfectStatusVolumeScaled,
    // Hog held by another process.
    VibeBitPerfectStatusExclusiveRefused,
    // Everything held, but the file is lossy: the decoded audio is delivered
    // unchanged.
    VibeBitPerfectStatusSourceLossy,
    // This run was launched with the FX graph; the mode is inert until relaunch.
    VibeBitPerfectStatusFXGraphPresent,
};

// Every input to the fold plus what it produced, so the caption, the glyph
// and dump_state read one snapshot and cannot disagree about why.
typedef struct {
    VibeBitPerfectStatus status;
    double sampleRate;      // the device's, after the switch
    UInt32 bitsPerChannel;  // the physical format's; 32 for float
    BOOL isFloat;
    float softwareVolume;
    // The fold's inputs.
    BOOL enabled;
    BOOL eligibleDevice;
    BOOL hasTrack;
    BOOL fxGraph;
    BOOL rateExact;
    BOOL switched;
    BOOL depthOK;
    BOOL hogWanted;
    BOOL exclusive;
    BOOL sourceLossless;
} VibeBitPerfectReport;

static const UInt32 kVibeBitPerfectAssumedLosslessDepth = 24;

// PCM: mBitsPerChannel. ALAC and FLAC: the kAppleLosslessFormatFlag_*
// source-depth flags, or 24 assumed when the flags say nothing. Lossy and
// unknown: 0, meaning "no native depth to honor" — which is also what makes a
// source lossless below, so the two cannot list different formats.
static inline UInt32 VibeSourceBitDepth(AudioStreamBasicDescription source) {
    if (source.mFormatID == kAudioFormatLinearPCM) {
        return source.mBitsPerChannel;
    }
    if (source.mFormatID == kAudioFormatAppleLossless || source.mFormatID == kAudioFormatFLAC) {
        switch (source.mFormatFlags) {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16;
            case kAppleLosslessFormatFlag_20BitSourceData: return 20;
            case kAppleLosslessFormatFlag_24BitSourceData: return 24;
            case kAppleLosslessFormatFlag_32BitSourceData: return 32;
            default: return kVibeBitPerfectAssumedLosslessDepth;
        }
    }
    return 0;
}

static inline BOOL VibeSourceIsLossless(AudioStreamBasicDescription source) {
    return VibeSourceBitDepth(source) > 0;
}

static inline BOOL VibePhysicalFormatIsFloat(AudioStreamBasicDescription format) {
    return (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
}

// YES when `physical` delivers `source` unchanged: same rate, and float32 or
// an integer depth >= the source's. The report's depth check, not the
// chooser's preference. A lossy source (depth 0) is satisfied by anything at
// its rate.
static inline BOOL VibePhysicalFormatSatisfies(AudioStreamBasicDescription physical,
                                               AudioStreamBasicDescription source) {
    if (physical.mSampleRate != source.mSampleRate) {
        return NO;
    }
    UInt32 depth = VibeSourceBitDepth(source);
    if (VibePhysicalFormatIsFloat(physical)) {
        return depth <= 24; // float32's significand
    }
    return physical.mBitsPerChannel >= depth;
}

// Whether the mode may drive a chosen device: its transport carries bits
// unchanged — an ALLOWLIST. Bluetooth, AirPlay, Continuity, Remote*,
// Aggregate, AutoAggregate and Unknown are out; so is anything Apple adds
// later, until argued in. The System Output POLICY (-1, follow whatever macOS
// points at) is never eligible, but that is the absence of a chosen device,
// not a property of one: the device that happens to be the current default
// is judged by its transport like any other. Read by the switch, the Output
// menu and the report, so the three cannot disagree.
static inline BOOL VibeBitPerfectDeviceEligible(UInt32 transportType) {
    switch (transportType) {
        case kAudioDeviceTransportTypeBuiltIn:
        case kAudioDeviceTransportTypePCI:
        case kAudioDeviceTransportTypeUSB:
        case kAudioDeviceTransportTypeFireWire:
        case kAudioDeviceTransportTypeThunderbolt:
        case kAudioDeviceTransportTypeHDMI:
        case kAudioDeviceTransportTypeDisplayPort:
        case kAudioDeviceTransportTypeAVB:
        case kAudioDeviceTransportTypeVirtual:
            return YES;
        default:
            return NO;
    }
}

// Whether a transport is hogged at all: everything but virtual, which has no
// DAC behind it and is what the loopback verification records from.
static inline BOOL VibeBitPerfectShouldHog(UInt32 transportType) {
    return transportType != kAudioDeviceTransportTypeVirtual;
}

static inline BOOL VibeRangedFormatOffersRate(AudioStreamRangedDescription format, double rate) {
    if (format.mFormat.mSampleRate == rate) {
        return YES;
    }
    return format.mSampleRateRange.mMinimum <= rate && rate <= format.mSampleRateRange.mMaximum
            && format.mSampleRateRange.mMinimum < format.mSampleRateRange.mMaximum;
}

static inline BOOL VibeFormatsOfferRate(const AudioStreamRangedDescription *formats, UInt32 count,
                                        double rate) {
    for (UInt32 i = 0; i < count; i++) {
        if (VibeRangedFormatOffersRate(formats[i], rate)) {
            return YES;
        }
    }
    return NO;
}

// The rate rule: exact, else the smallest integer multiple offered, else 0.
static inline double VibeBitPerfectTargetRate(double sourceRate,
                                              const AudioStreamRangedDescription *formats,
                                              UInt32 count) {
    if (sourceRate <= 0) {
        return 0;
    }
    for (UInt32 multiple = 1; multiple <= 16; multiple *= 2) {
        if (VibeFormatsOfferRate(formats, count, sourceRate * multiple)) {
            return sourceRate * multiple;
        }
    }
    return 0;
}

static inline BOOL VibePhysicalFormatsEquivalent(AudioStreamBasicDescription a,
                                                 AudioStreamBasicDescription b) {
    return a.mSampleRate == b.mSampleRate
            && VibePhysicalFormatIsFloat(a) == VibePhysicalFormatIsFloat(b)
            && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mChannelsPerFrame == b.mChannelsPerFrame;
}

// The depth rule at `rate`, as-is: the integer format whose depth equals the
// source's (a lossy source takes 24), else the smallest integer depth above
// it, else float32. Returns NO when nothing is at `rate`; the caller compares
// the choice against what the device has before writing.
static inline BOOL VibeBitPerfectChooseFormat(AudioStreamBasicDescription source,
                                              double rate,
                                              const AudioStreamRangedDescription *formats,
                                              UInt32 count,
                                              AudioStreamBasicDescription *chosen) {
    UInt32 depth = VibeSourceBitDepth(source) ?: kVibeBitPerfectAssumedLosslessDepth;
    BOOL haveInteger = NO, haveFloat = NO;
    AudioStreamBasicDescription integerPick = {0}, floatPick = {0};
    for (UInt32 i = 0; i < count; i++) {
        if (!VibeRangedFormatOffersRate(formats[i], rate)
                || formats[i].mFormat.mFormatID != kAudioFormatLinearPCM) {
            continue;
        }
        AudioStreamBasicDescription candidate = formats[i].mFormat;
        candidate.mSampleRate = rate;
        if (VibePhysicalFormatIsFloat(candidate)) {
            if (!haveFloat || candidate.mBitsPerChannel > floatPick.mBitsPerChannel) {
                floatPick = candidate;
                haveFloat = YES;
            }
            continue;
        }
        if (candidate.mBitsPerChannel < depth) {
            continue; // never below the source
        }
        // Equal wins outright; otherwise the smallest above.
        if (!haveInteger
                || (candidate.mBitsPerChannel == depth && integerPick.mBitsPerChannel != depth)
                || (integerPick.mBitsPerChannel != depth
                    && candidate.mBitsPerChannel < integerPick.mBitsPerChannel)) {
            integerPick = candidate;
            haveInteger = YES;
        }
    }
    if (!haveInteger && !haveFloat) {
        return NO;
    }
    *chosen = haveInteger ? integerPick : floatPick;
    return YES;
}

// The fold over the report's inputs, in priority order, so two breakers never
// race for the caption: Off > FXGraphPresent > Idle > RateUnsupported >
// SwitchFailed > DepthInsufficient > VolumeScaled > ExclusiveRefused >
// SourceLossy > Active. FXGraphPresent sits second because the mode is inert
// in such a run — nothing below it was even attempted. SourceLossy is last
// before Active because it is the only status that says the chain is perfect
// and the file is not. There is no pitch input: under the mode there is no
// varispeed to have a pitch.
static inline VibeBitPerfectStatus VibeBitPerfectFold(VibeBitPerfectReport r) {
    if (!r.enabled || !r.eligibleDevice) {
        return VibeBitPerfectStatusOff;
    }
    if (r.fxGraph) {
        return VibeBitPerfectStatusFXGraphPresent;
    }
    if (!r.hasTrack) {
        return VibeBitPerfectStatusIdle;
    }
    if (!r.rateExact) {
        return VibeBitPerfectStatusRateUnsupported;
    }
    if (!r.switched) {
        return VibeBitPerfectStatusSwitchFailed;
    }
    if (!r.depthOK) {
        return VibeBitPerfectStatusDepthInsufficient;
    }
    if (r.softwareVolume < 1.0f) {
        return VibeBitPerfectStatusVolumeScaled;
    }
    if (r.hogWanted && !r.exclusive) {
        return VibeBitPerfectStatusExclusiveRefused;
    }
    if (!r.sourceLossless) {
        return VibeBitPerfectStatusSourceLossy;
    }
    return VibeBitPerfectStatusActive;
}
