//
//  AudioLevelMath.h
//  Vibe
//
//  The tunable half of the audio-reactive equalizer indicator: where the five
//  bands sit, how a band's energy becomes a 0..1 level, and how that level
//  moves. AudioLevelTap owns an AVAudioEngine tap and so is unreachable from
//  the host-less suite; these are what decide how the bars LOOK, so they live
//  here where they can be tested.
//
//  Three terms, used exactly (root CLAUDE.md): a BAND is a frequency range, its
//  ENERGY is the raw summed magnitude, and the published 0..1 per bar is a
//  LEVEL.
//
//  Why each piece exists, since raw magnitudes look wrong rather than merely
//  unpolished: bands are log-spaced because pitch is; the level is normalized
//  against a per-band reference because music slopes roughly -3 to -6 dB per
//  octave and a shared reference leaves the treble bars dead; the reference
//  decays rather than being fixed because a quiet track would otherwise never
//  move a bar; and the envelope is asymmetric because a transient must arrive
//  instantly and leave slowly, which is what reads as "following the music"
//  instead of as flicker.
//

#import <Foundation/Foundation.h>
#import <math.h>

// One per bar in EqualizerIndicatorView. Five is the indicator's shape, not a
// tunable: the bars are the app icon's waveform.
enum { kLevelBandCount = 5 };

// The bottom of the lowest band. Below this is rumble, DC offset and the room,
// none of which should move a bar.
static const double kLevelLowestBandHz = 40.0;

// How far below the running reference reads as silence. Wider makes the bars
// twitch in quiet passages, narrower slams them to the floor between hits.
static const float kLevelDynamicRangeDB = 28.0f;

// The reference can fall this far and no further, so true silence stays flat
// instead of amplifying the noise floor into a light show.
static const float kLevelReferenceFloor = 1e-7f;

// How long the reference takes to forget a loud passage, in seconds. Slow
// enough that a bar does not re-normalize within a single phrase.
static const float kLevelReferenceDecaySeconds = 1.5f;

// The envelope's two sides. Attack is short enough that a kick lands on the
// frame it arrives in; release is long enough that the bar falls rather than
// drops.
static const float kLevelAttackSeconds = 0.045f;
static const float kLevelReleaseSeconds = 0.22f;

// The bin one band edge falls on: `edge` runs 0...kLevelBandCount, so edge 0 is
// kLevelLowestBandHz and edge kLevelBandCount is Nyquist.
//
// One function for both ends of a band, so a band's top IS its neighbour's
// bottom. Rounding each end separately overlaps them by a bin, and that bin's
// energy would then drive two bars at once.
static inline NSUInteger VibeLevelBandEdgeBin(NSUInteger edge, NSUInteger fftSize, double sampleRate) {
    NSUInteger binCount = fftSize / 2;          // usable bins: 0 ..< fftSize/2
    if (edge >= kLevelBandCount) {
        return binCount;
    }
    double nyquist = sampleRate / 2.0;
    double top = nyquist > kLevelLowestBandHz ? nyquist : kLevelLowestBandHz * 2.0;
    double ratio = top / kLevelLowestBandHz;
    double hz = kLevelLowestBandHz * pow(ratio, (double)edge / (double)kLevelBandCount);
    double bin = floor(hz * (double)fftSize / sampleRate);
    // Bin 0 packs DC and Nyquist in a real FFT, and neither belongs to a band.
    if (!(bin >= 1.0)) {
        return 1;
    }
    return bin > (double)binCount ? binCount : (NSUInteger)bin;
}

// The half-open FFT bin range [*lowBin, *highBin) for `band`, log-spaced from
// kLevelLowestBandHz to Nyquist and contiguous with its neighbours.
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

// A band's mean energy against its running reference, as 0..1 over
// kLevelDynamicRangeDB.
//
// Mean rather than sum: the bands widen geometrically, so the top one spans
// hundreds of bins and the bottom one a handful. Summed, the top band is loud
// by construction and the bars read as a staircase on every track.
static inline float VibeLevelNormalize(float meanEnergy, float reference) {
    if (!isfinite(meanEnergy) || meanEnergy <= 0.0f) {
        return 0.0f;
    }
    if (!isfinite(reference) || reference < kLevelReferenceFloor) {
        reference = kLevelReferenceFloor;
    }
    // Energy is magnitude squared, so the decibel factor is 10 rather than 20.
    float db = 10.0f * log10f(meanEnergy / reference);
    float level = 1.0f + db / kLevelDynamicRangeDB;
    if (!isfinite(level) || level < 0.0f) {
        return 0.0f;
    }
    return level > 1.0f ? 1.0f : level;
}

// The per-band automatic gain reference after observing `observed` over `dt`
// seconds.
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

// One frame of the bar's envelope: an exponential approach to `target` whose
// time constant depends on the direction of travel.
//
// Time-constant based rather than a fixed step per frame, so the motion is the
// same on a 60 Hz display and a 120 Hz one — the view runs this per displayed
// frame, while the tap publishes at the hop rate, and the two are unrelated.
static inline float VibeLevelEnvelope(float current, float target, float dt,
                                      float attack, float release) {
    if (!isfinite(current)) {
        current = 0.0f;
    }
    if (!isfinite(target)) {
        target = 0.0f;
    }
    float tau = target > current ? attack : release;
    if (!isfinite(dt) || dt <= 0.0f || tau <= 0.0f) {
        return target;
    }
    float k = 1.0f - expf(-dt / tau);
    return current + (target - current) * k;
}
