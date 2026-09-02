//
//  AudioLevelMath.h
//  Vibe
//
//  The tunable half of the audio-reactive equalizer indicator: where the five
//  bands sit, how a band's energy becomes a 0..1 level, and how much audio one
//  analysis decision covers. AudioLevelTap owns an AVAudioEngine tap and so is
//  unreachable from the host-less suite; its arithmetic lives here where it
//  can be tested.
//
//  A BAND is a frequency range. Its ENERGY is magnitude-squared power,
//  normalized for FFT size and averaged across channels. Relative-activity
//  mode averages that power across a band's bins; the spectrum modes sum it
//  and compensate for the band's octave width. Balanced spectrum admits a
//  bounded amount of relative activity only where shared spectrum also sees
//  signal. The published 0..1 value is a LEVEL. Visual response belongs to
//  EqualizerAnimationMath.h in Controls; audio publishes targets and never
//  knows how a view moves.
//
//  Why each piece exists, since raw magnitudes look wrong rather than merely
//  unpolished: the fixed band edges give bass and low mids three of the five
//  bars. Relative-activity mode gives each band its own reference so all five
//  remain lively; shared-spectrum mode compares energy per octave against one
//  reference; balanced spectrum keeps that comparison as its foundation while
//  allowing supported activity to lift a weak band. Either reference decays
//  rather than being fixed, so quiet tracks can still move the bars.
//

#import <Foundation/Foundation.h>
#import <math.h>
#import <stdint.h>

// One per bar in EqualizerIndicatorView. Five is the indicator's shape, not a
// tunable: the bars are the app icon's waveform.
enum { kLevelBandCount = 5 };

typedef NS_ENUM(NSUInteger, VibeAudioLevelNormalizationMode) {
    // Each band follows its own recent peak. This keeps every part of the
    // spectrum lively, but bar heights are not comparable across bands.
    VibeAudioLevelNormalizationModeRelativeActivity,
    // Energy per octave follows one reference set by the strongest band. Bar
    // heights retain the callback-time spectrum's bass-to-treble balance.
    VibeAudioLevelNormalizationModeSharedSpectrum,
    // Shared spectrum is the foundation. Private per-band activity can only
    // assist upward where that shared result already carries signal.
    VibeAudioLevelNormalizationModeBalancedSpectrum,
};

// Bass-forward musical regions: sub/kick, bass, low mids, mids/presence and
// treble. Below 40 Hz is rumble and DC; output above 20 kHz is inaudible and
// never gets its own bar.
static const double kLevelBandEdgesHz[kLevelBandCount + 1] = {
    40.0, 100.0, 250.0, 800.0, 4000.0, 20000.0,
};

// The shipping mode. Other modes remain available to callers for comparison.
static const VibeAudioLevelNormalizationMode kLevelDefaultNormalizationMode =
        VibeAudioLevelNormalizationModeBalancedSpectrum;

// Roughly how often the analyzer makes a new musical decision. A power-of-two
// FFT nearest this interval is selected for the delivered sample rate.
static const double kLevelAnalysisDecisionsPerSecond = 24.0;

// AVAudioNode's documented tap-buffer range starts at roughly 100 ms. One
// callback may therefore contain several analysis windows. Relative activity
// retains their per-band peaks; shared spectrum averages their energy per
// octave into one callback-time spectrum before normalization.
static const double kLevelTapBufferSeconds = 0.1;

// How far below the running reference reads as silence. Wider raises weaker
// bands and reduces inter-band contrast; narrower lowers them and separates
// the spectrum more strongly, at the cost of hitting the floor between hits.
static const float kLevelDynamicRangeDB = 28.0f;

// Balanced spectrum moves this fraction of the way from the shared level to a
// higher relative-activity level. It never lets activity reduce shared output.
static const float kLevelBalancedLocalAssistance = 0.35f;

// The activity assist fades in as shared spectrum rises from zero and reaches
// full weight here. This keeps a private reference from lighting leakage that
// has no meaningful support on the common spectrum scale.
static const float kLevelBalancedFullSharedSupport = 0.12f;

// Scales the whole balanced result, reserving headroom even below the maximum;
// this is deliberately not only a clip applied to full-scale values.
static const float kLevelBalancedOutputScale = 0.91f;

// A reference can fall this far and no further, so true silence stays flat
// instead of amplifying the noise floor into a light show. The floor is
// especially important to relative-activity mode, where otherwise a
// signal-free band can normalize its own noise to full height.
//
// Energy is normalized by FFT size before it reaches this seam, so this floor
// is in stable, approximately full-scale-squared units rather than being tied
// to one frame size. It keeps quantization noise dark while retaining useful
// motion in quiet recordings.
static const float kLevelReferenceFloor = 1e-7f;

// How long a reference takes to forget a loud passage, in seconds. The slow
// recovery prevents gaps between nearby hits from repeatedly resetting gain.
static const float kLevelReferenceDecaySeconds = 1.5f;

// The power-of-two FFT nearest one analysis interval, bounded to keep scratch
// storage fixed and cover the app's supported 44.1...192 kHz output routes.
static inline NSUInteger VibeLevelFFTSizeForSampleRate(double sampleRate) {
    if (!isfinite(sampleRate) || sampleRate <= 0) {
        return 2048;
    }
    double target = sampleRate / kLevelAnalysisDecisionsPerSecond;
    NSUInteger lower = 256;
    while (lower < 8192 && (double)(lower * 2) <= target) {
        lower *= 2;
    }
    NSUInteger upper = MIN(lower * 2, (NSUInteger)8192);
    return target - (double)lower <= (double)upper - target ? lower : upper;
}

static inline uint32_t VibeLevelTapBufferFrameCount(double sampleRate) {
    if (!isfinite(sampleRate) || sampleRate <= 0) {
        sampleRate = 48000.0;
    }
    double frames = ceil(sampleRate * kLevelTapBufferSeconds);
    return (uint32_t)clampRange(frames, 1.0, (double)UINT32_MAX);
}

static inline double VibeLevelBandEdgeHz(NSUInteger edge, double sampleRate) {
    double nyquist = isfinite(sampleRate) && sampleRate > 0
            ? sampleRate / 2.0 : 24000.0;
    double lowest = kLevelBandEdgesHz[0];
    double nominalTop = kLevelBandEdgesHz[kLevelBandCount];
    double top = MIN(nyquist, nominalTop);
    if (top <= lowest) {
        top = lowest * 2.0;
    }
    if (edge >= kLevelBandCount) {
        return top;
    }
    if (top >= nominalTop) {
        return kLevelBandEdgesHz[edge];
    }

    // Unsupported low-rate formats still need five ordered bands. Preserve
    // each nominal edge's position through the full range in log-frequency
    // space while compressing the ceiling to the available Nyquist frequency.
    double fullRange = log2(nominalTop / lowest);
    double edgePosition = log2(kLevelBandEdgesHz[edge] / lowest) / fullRange;
    return lowest * pow(top / lowest, edgePosition);
}

// Shared-spectrum mode sums each band's bins. Since the explicit ranges do not
// span equal numbers of octaves, comparing those sums directly would favor a
// wider band when the spectrum carries the same energy per octave throughout.
// This precomputable multiplier expresses each sum as energy per octave.
static inline float VibeLevelEnergyPerOctaveScale(NSUInteger band,
                                                   double sampleRate) {
    if (band >= kLevelBandCount) {
        return 0.0f;
    }
    double low = VibeLevelBandEdgeHz(band, sampleRate);
    double high = VibeLevelBandEdgeHz(band + 1, sampleRate);
    double octaveWidth = low > 0.0 && high > low ? log2(high / low) : 0.0;
    if (!isfinite(octaveWidth) || octaveWidth <= 0.0) {
        return 0.0f;
    }
    return (float)(1.0 / octaveWidth);
}

// The first bin whose center is at or above one band edge: `edge` runs
// 0...kLevelBandCount, so edge 0 is 40 Hz and edge kLevelBandCount is the
// lesser of 20 kHz and Nyquist.
//
// One function for both ends of a band, so a band's top IS its neighbour's
// bottom. Rounding each end separately overlaps them by a bin, and that bin's
// energy would then drive two bars at once.
static inline NSUInteger VibeLevelBandEdgeBin(NSUInteger edge, NSUInteger fftSize, double sampleRate) {
    NSUInteger binCount = fftSize / 2;          // usable bins: 0 ..< fftSize/2
    double hz = VibeLevelBandEdgeHz(edge, sampleRate);
    double bin = ceil(hz * (double)fftSize / sampleRate);
    // Bin 0 packs DC and Nyquist in a real FFT, and neither belongs to a band.
    if (!(bin >= 1.0)) {
        return 1;
    }
    return bin > (double)binCount ? binCount : (NSUInteger)bin;
}

// vDSP's real FFT has a factor of two in its output. Scaling spectral energy by
// 4/N^2 makes it independent of FFT size, whether the preceding reduction was
// a mean or sum. A 2048-point 48 kHz window and an 8192-point 192 kHz window can
// therefore share one AGC floor.
static inline float VibeLevelScaleFFTEnergy(float spectralEnergy, NSUInteger fftSize) {
    if (!isfinite(spectralEnergy) || spectralEnergy <= 0 || fftSize == 0) {
        return 0;
    }
    double n = (double)fftSize;
    double scaled = (double)spectralEnergy * 4.0 / (n * n);
    return isfinite(scaled) && scaled > 0 ? (float)scaled : 0;
}

// Channel spectra are combined after magnitude-squaring, never as samples.
// Opposite-polarity stereo therefore carries the same energy as in-phase
// stereo instead of cancelling to false silence.
static inline float VibeLevelMeanChannelEnergy(const float *energies,
                                                NSUInteger channelCount) {
    if (!energies || channelCount == 0) {
        return 0;
    }
    double sum = 0;
    for (NSUInteger channel = 0; channel < channelCount; channel++) {
        float energy = energies[channel];
        if (isfinite(energy) && energy > 0) {
            sum += energy;
        }
    }
    double mean = sum / (double)channelCount;
    return isfinite(mean) && mean > 0 ? (float)mean : 0;
}

// The half-open FFT bin range [*lowBin, *highBin) for `band`, following the
// explicit bass-forward edges and contiguous with its neighbours.
//
// Bound from the sample rate the tap actually delivers, never from a constant:
// the rate changes across route changes and media-services resets, and edges
// computed for another rate put the bands in the wrong places quietly.
//
// Every range is at least one bin wide, so a low sample rate — where the top
// bands crowd together — cannot leave a bar permanently dark.
static inline void VibeLevelBandBinRange(NSUInteger band, NSUInteger fftSize, double sampleRate,
                                         NSUInteger *lowBin, NSUInteger *highBin) {
    NSUInteger binCount = fftSize / 2;
    NSUInteger lo = 1;
    NSUInteger hi = binCount;
    if (binCount > 1 && sampleRate > 0) {
        lo = VibeLevelBandEdgeBin(band, fftSize, sampleRate);
        hi = VibeLevelBandEdgeBin(band + 1, fftSize, sampleRate);
        if (lo > binCount - 1) {
            lo = binCount - 1;
        }
        if (hi <= lo) {
            hi = lo + 1;
        }
        if (hi > binCount) {
            hi = binCount;
        }
    }
    *lowBin = lo;
    *highBin = hi;
}

// One band's energy against the applicable running reference, as 0..1 over
// kLevelDynamicRangeDB.
//
// The energy and reference must use the same aggregation: mean power against a
// band's private reference, or energy per octave against the shared reference.
static inline float VibeLevelNormalize(float energy, float reference) {
    if (!isfinite(energy) || energy <= 0.0f) {
        return 0.0f;
    }
    if (!isfinite(reference) || reference < kLevelReferenceFloor) {
        reference = kLevelReferenceFloor;
    }
    // Energy is magnitude squared, so the decibel factor is 10 rather than 20.
    float db = 10.0f * log10f(energy / reference);
    float level = 1.0f + db / kLevelDynamicRangeDB;
    if (!isfinite(level) || level < 0.0f) {
        return 0.0f;
    }
    return level > 1.0f ? 1.0f : level;
}

// Smoothly opens the balanced mode's activity assist over the bottom of the
// shared scale. Smoothstep keeps both ends free of a visible slope change.
static inline float VibeLevelBalancedSharedSupport(float sharedLevel) {
    if (!isfinite(sharedLevel) || sharedLevel <= 0.0f) {
        return 0.0f;
    }
    float position = sharedLevel / kLevelBalancedFullSharedSupport;
    if (position >= 1.0f) {
        return 1.0f;
    }
    return position * position * (3.0f - 2.0f * position);
}

// Shared spectrum remains the base shape. Relative activity contributes only
// its positive difference, gated by shared support, and the entire result is
// scaled down to leave visual headroom.
static inline float VibeLevelBalancedSpectrumLevel(float sharedLevel,
                                                    float relativeActivityLevel) {
    if (!isfinite(sharedLevel) || sharedLevel <= 0.0f) {
        return 0.0f;
    }
    sharedLevel = MIN(sharedLevel, 1.0f);
    if (!isfinite(relativeActivityLevel) || relativeActivityLevel <= 0.0f) {
        relativeActivityLevel = 0.0f;
    }
    else {
        relativeActivityLevel = MIN(relativeActivityLevel, 1.0f);
    }
    float positiveActivity = MAX(relativeActivityLevel - sharedLevel, 0.0f);
    float combined = sharedLevel
            + kLevelBalancedLocalAssistance
            * VibeLevelBalancedSharedSupport(sharedLevel)
            * positiveActivity;
    if (!isfinite(combined) || combined <= 0.0f) {
        return 0.0f;
    }
    return kLevelBalancedOutputScale * MIN(combined, 1.0f);
}

// An automatic gain reference after observing `observed` over `dt` seconds.
//
// A louder band IS the new reference immediately, so a bar can never clip for
// longer than the frame that overshot; quieter only decays, so the reference
// tracks the passage rather than the last transient.
static inline float VibeLevelUpdateReference(float reference, float observed, float dt) {
    if (!isfinite(reference) || reference < kLevelReferenceFloor) {
        reference = kLevelReferenceFloor;
    }
    if (!isfinite(observed) || observed < 0.0f) {
        observed = 0.0f;
    }
    if (observed > reference) {
        return observed;
    }
    if (!isfinite(dt) || dt <= 0.0f) {
        return reference;
    }
    float decayed = reference * expf(-dt / kLevelReferenceDecaySeconds);
    return decayed > kLevelReferenceFloor ? decayed : kLevelReferenceFloor;
}
