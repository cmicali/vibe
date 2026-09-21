//
//  OutputFormatRules.h
//  Vibe
//
//  The output device layer's decisions, as static inlines so the host-less
//  suite reaches them without a HAL: when a saved device may bind and whether
//  its lookup is still current, then bit-perfect output's — what a source's
//  word length is, which of a device's formats carries it unchanged, whether
//  a device may be driven at all, and how the reasons fold into the one
//  status the header and Settings show. The mechanism they serve is
//  AudioPlayer+Devices.m.
//

#import <Foundation/Foundation.h>
#import <CoreAudio/AudioHardwareBase.h>
#include <math.h>

// A saved-device bind may land whenever nothing is audible, because the one
// thing it must never do is rebind underneath sound — that clicks, or tears
// down a live stream. So: stopped; the first loading open before the engine
// starts; and a pause whose fade has settled. A loading open with a running
// outgoing fade, and playing, are excluded.
//
// Paused used to be excluded outright, including a paused engine that had
// idle-stopped and was plainly silent. That left a device which vanished and
// came back unadoptable until the next stop, because an unplug parks playback
// as Paused. The rebuild already restores a paused track as Paused rather than
// resuming it, so a settled pause is as safe to rebind as a stop.
static inline BOOL VibeCanBindSavedOutputDevice(BOOL stopped, BOOL loading, BOOL paused,
                                                BOOL engineRunning, BOOL audioActive) {
    return stopped || (loading && !engineRunning) || (paused && !audioActive);
}

// Whether a direct HAL read of kAudioDevicePropertyDeviceIsAlive proves the
// device is gone: it answered "dead", or the object itself no longer exists.
// Any other failed read is UNKNOWN, never dead — a false removal falls back to
// System Output and persists it, which is why absence alone is never removal.
static inline BOOL VibeDeviceIsConfirmedDead(OSStatus readStatus, UInt32 isAlive) {
    if (readStatus == kAudioHardwareBadObjectError) {
        return YES;
    }
    return readStatus == noErr && isAlive == 0;
}

// The prepared stream owns the selected output channels. Extra device
// channels are harmless only when the live AU map sends them silence.
static inline BOOL VibeBitPerfectChannelMapPreservesSource(const SInt32 *map, UInt32 count,
        UInt32 sourceChannels, UInt32 firstStreamChannel, UInt32 streamChannels) {
    if (!map || sourceChannels == 0 || firstStreamChannel == 0
            || sourceChannels > streamChannels || firstStreamChannel > count
            || streamChannels > count - (firstStreamChannel - 1)) return NO;
    UInt32 start = firstStreamChannel - 1; // HAL stream channels are one-based
    for (UInt32 destination = 0; destination < count; destination++) {
        SInt32 expected = destination >= start && destination - start < sourceChannels
                ? (SInt32)(destination - start) : -1;
        if (map[destination] != expected) return NO;
    }
    return YES;
}

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
    // The output route, format or gain could not be confirmed.
    VibeBitPerfectStatusSwitchFailed,
    VibeBitPerfectStatusChannelConversion,
    VibeBitPerfectStatusDepthInsufficient,
    VibeBitPerfectStatusMuted,
    // Software volume below 1.0 or balance away from center.
    VibeBitPerfectStatusVolumeScaled,
    // Hog held by another process.
    VibeBitPerfectStatusExclusiveRefused,
    // Everything held, but the file is lossy: the decoded audio is delivered
    // unchanged.
    VibeBitPerfectStatusSourceLossy,
};

// Every input to the fold plus what it produced, so the caption, the glyph
// and dump_state read one snapshot and cannot disagree about why.
typedef struct {
    VibeBitPerfectStatus status;
    double sampleRate;      // the device's, after the switch
    UInt32 bitsPerChannel;  // the physical format's; 32 for float
    BOOL isFloat;
    float softwareVolume;
    float balance;         // 0 = left, 0.5 = center, 1 = right
    // The fold's inputs.
    BOOL enabled;
    BOOL eligibleDevice;
    BOOL hasTrack;
    BOOL rateExact;
    BOOL formatConfirmed;   // the bound device has the requested format; its gain reads succeeded
    BOOL channelsMatch;     // unchanged source channels, verified output routing
    BOOL depthOK;
    BOOL muted;
    BOOL hogWanted;
    BOOL exclusive;
    BOOL sourceLossless;
} VibeBitPerfectReport;

static const UInt32 kVibeBitPerfectAssumedLosslessDepth = 24;

// Every field, so a publication that changed nothing is not announced.
static inline BOOL VibeBitPerfectReportsEqual(VibeBitPerfectReport a, VibeBitPerfectReport b) {
    return a.status == b.status && a.sampleRate == b.sampleRate
            && a.bitsPerChannel == b.bitsPerChannel && a.isFloat == b.isFloat
            && a.softwareVolume == b.softwareVolume && a.balance == b.balance && a.enabled == b.enabled
            && a.eligibleDevice == b.eligibleDevice && a.hasTrack == b.hasTrack
            && a.rateExact == b.rateExact
            && a.formatConfirmed == b.formatConfirmed && a.channelsMatch == b.channelsMatch
            && a.depthOK == b.depthOK && a.muted == b.muted
            && a.hogWanted == b.hogWanted && a.exclusive == b.exclusive
            && a.sourceLossless == b.sourceLossless;
}

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

// A source is asked the PCM question only when it is PCM: the ALAC and FLAC
// depth flags reuse the same low bits.
static inline BOOL VibePhysicalFormatIsFloat(AudioStreamBasicDescription format) {
    return (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
}

static inline BOOL VibeSourceIsFloat(AudioStreamBasicDescription source) {
    return source.mFormatID == kAudioFormatLinearPCM && VibePhysicalFormatIsFloat(source);
}

// Whether one PCM format carries `source`'s samples unchanged: the same
// representation at no less width — a float source needs a float format at
// least as wide, an integer source an integer depth >= its own or a float
// significand that holds it (float32's is 24 bits, float64's 53). A lossy
// source (depth 0) is carried by anything.
static inline BOOL VibePCMFormatCarries(AudioStreamBasicDescription pcm,
                                        AudioStreamBasicDescription source) {
    if (pcm.mFormatID != kAudioFormatLinearPCM) return NO;
    if (VibeSourceIsFloat(source)) {
        return VibePhysicalFormatIsFloat(pcm) && pcm.mBitsPerChannel >= source.mBitsPerChannel;
    }
    UInt32 carried = pcm.mBitsPerChannel;
    if (VibePhysicalFormatIsFloat(pcm)) {
        carried = (pcm.mBitsPerChannel == 32) ? 24 : (pcm.mBitsPerChannel == 64) ? 53 : 0;
    }
    return carried >= VibeSourceBitDepth(source);
}

// YES when the path delivers `source` unchanged: the device at the source's
// rate, and both the decode's processing format (AVAudioFile decodes to
// float32, so a 32-bit integer source is never delivered in full, whatever
// the device offers — measured: 24,641,537 came out 24,641,536) and the
// device's physical format carry it. The report's depth check, not the
// chooser's preference.
static inline BOOL VibePhysicalFormatSatisfies(AudioStreamBasicDescription physical,
                                               AudioStreamBasicDescription source,
                                               AudioStreamBasicDescription processing) {
    return physical.mSampleRate == source.mSampleRate
            && VibePCMFormatCarries(processing, source)
            && VibePCMFormatCarries(physical, source);
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

static inline BOOL VibeRangedFormatOffersRate(AudioStreamRangedDescription format, double rate) {
    if (format.mFormat.mSampleRate == rate) {
        return YES;
    }
    return format.mSampleRateRange.mMinimum <= rate && rate <= format.mSampleRateRange.mMaximum;
}

// The rate rule: exact PCM carrying every source channel, else the smallest
// such integer multiple, else 0. A narrow offer cannot hide a usable rate.
static inline double VibeBitPerfectTargetRate(double sourceRate, UInt32 sourceChannels,
                                              const AudioStreamRangedDescription *formats,
                                              UInt32 count) {
    if (!isfinite(sourceRate) || sourceRate <= 0) {
        return 0;
    }
    double target = 0;
    for (UInt32 i = 0; i < count; i++) {
        if (formats[i].mFormat.mFormatID != kAudioFormatLinearPCM
                || formats[i].mFormat.mChannelsPerFrame < sourceChannels) continue;
        // Discrete rates and continuous ranges both contribute their smallest
        // integral ratio. Scanning the offers also covers 3x, 6x and ratios
        // above 16x without an arbitrary search ceiling.
        double candidates[] = { formats[i].mFormat.mSampleRate,
            sourceRate * MAX(1.0, ceil(formats[i].mSampleRateRange.mMinimum / sourceRate)) };
        for (unsigned j = 0; j < 2; j++) {
            double rate = candidates[j];
            if (isfinite(rate) && rate >= sourceRate && fmod(rate, sourceRate) == 0
                    && VibeRangedFormatOffersRate(formats[i], rate)
                    && (target == 0 || rate < target)) {
                target = rate;
            }
        }
    }
    return target;
}

static inline BOOL VibePhysicalFormatsEquivalent(AudioStreamBasicDescription a,
                                                 AudioStreamBasicDescription b) {
    return a.mSampleRate == b.mSampleRate
            && a.mFormatID == b.mFormatID
            && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket
            && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
            && a.mChannelsPerFrame == b.mChannelsPerFrame;
}

// Shared by the silent settlement and the gapless gate: even an unchanged
// device needs a rebuild when the mixer would resample into it.
static inline BOOL VibeBitPerfectOutputNeedsSwitch(AudioStreamBasicDescription current,
                                                   AudioStreamBasicDescription chosen,
                                                   double mixerRate) {
    return !VibePhysicalFormatsEquivalent(current, chosen) || mixerRate != chosen.mSampleRate;
}

// The depth rule at `rate`, as-is: the integer format whose depth equals the
// source's (a lossy source prefers 16), else the smallest integer depth above
// it, else float32 — and for a float source the float format first, since
// no integer depth delivers one unchanged. Only formats wide enough for all
// source channels qualify. Returns NO when none is usable at `rate`; the
// caller compares the choice against what the device has before writing.
static inline BOOL VibeBitPerfectChooseFormat(AudioStreamBasicDescription source,
                                              double rate,
                                              const AudioStreamRangedDescription *formats,
                                              UInt32 count,
                                              AudioStreamBasicDescription *chosen) {
    UInt32 depth = VibeSourceBitDepth(source) ?: 16;
    BOOL haveInteger = NO, haveFloat = NO;
    AudioStreamBasicDescription integerPick = {0}, floatPick = {0};
    for (UInt32 i = 0; i < count; i++) {
        if (!VibeRangedFormatOffersRate(formats[i], rate)
                || formats[i].mFormat.mFormatID != kAudioFormatLinearPCM
                || formats[i].mFormat.mChannelsPerFrame < source.mChannelsPerFrame) {
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
        // Candidates below the source were excluded, so the smallest wins.
        if (!haveInteger || candidate.mBitsPerChannel < integerPick.mBitsPerChannel) {
            integerPick = candidate;
            haveInteger = YES;
        }
    }
    if (!haveInteger && !haveFloat) {
        return NO;
    }
    BOOL preferFloat = VibeSourceIsFloat(source) ? haveFloat : !haveInteger;
    *chosen = preferFloat ? floatPick : integerPick;
    return YES;
}

// The fold over the report's inputs, in priority order, so two breakers never
// race for the caption: Off > Idle > SwitchFailed >
// RateUnsupported > ChannelConversion > DepthInsufficient > Muted > VolumeScaled > ExclusiveRefused >
// SourceLossy > Active. SourceLossy is last
// before Active because it is the only status that says the chain is perfect
// and the file is not. There is no pitch input: under the mode there is no
// varispeed to have a pitch.
static inline VibeBitPerfectStatus VibeBitPerfectFold(VibeBitPerfectReport r) {
    if (!r.enabled || !r.eligibleDevice) {
        return VibeBitPerfectStatusOff;
    }
    if (!r.hasTrack) {
        return VibeBitPerfectStatusIdle;
    }
    if (!r.formatConfirmed) {
        return VibeBitPerfectStatusSwitchFailed;
    }
    if (!r.rateExact) {
        return VibeBitPerfectStatusRateUnsupported;
    }
    if (!r.channelsMatch) {
        return VibeBitPerfectStatusChannelConversion;
    }
    if (!r.depthOK) {
        return VibeBitPerfectStatusDepthInsufficient;
    }
    if (r.muted) {
        return VibeBitPerfectStatusMuted;
    }
    if (r.softwareVolume < 1.0f || r.balance != 0.5f) {
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
