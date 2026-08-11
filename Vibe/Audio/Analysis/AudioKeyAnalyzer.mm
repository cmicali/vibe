//
//  AudioKeyAnalyzer.mm
//  Vibe
//

#import "AudioKeyAnalyzer.h"
#import <Accelerate/Accelerate.h>
#include <vector>
#include <cmath>

// The chroma band. Below A1 the FFT bins pack too many semitones each and
// kick drums dominate; above A7 there is little tonal energy left and cymbal
// noise smears every pitch class evenly.
static const double kMinChromaHz = 55.0;    // A1
static const double kMaxChromaHz = 3520.0;  // A7

// A bin only votes when it sits within this many cents of a semitone center.
// The complement is FFT leakage and inharmonic content, which would smear the
// chroma floor upward and dilute the profile correlation.
static const double kMaxCentsFromSemitone = 35.0;

// Below this much accumulated audio the chroma is a handful of frames and one
// sustained chord can pass for a key.
static const double kMinAnalysisSeconds = 3.0;

// The confidence gate: the winning profile correlation. Tonal music
// correlates far above this; drum loops, noise and speech sit below it.
static const double kMinCorrelation = 0.55;

// Only spectral peaks vote, and only those at least this fraction of the
// frame's loudest peak; 0 admits every bin. Measured at 0 — restricting to
// peaks was worse at every threshold tried, because a 32768-point frame
// already resolves partials and the discarded energy between them carries
// real harmonic content.
static const double kPeakThreshold = 0.0;

// How much of a peak's energy is credited to the fundamentals it could be a
// harmonic of, rather than to its own pitch class alone. A peak may be the
// 3rd harmonic of the note a fifth below it, or the 5th harmonic of the note
// a major third below; the latter is why unweighted chroma drifts major,
// since every note manufactures its own major third. The 3rd-harmonic share
// is this weight, the 5th-harmonic share its square. 0 disables it.
static const double kHarmonicWeight = 0.5;

// The bass band, accumulated into a second chroma. Correlation against a
// profile identifies the scale but not which of its notes is the tonic, which
// is why the relative, dominant and subdominant keys — all sharing that scale
// — dominate the remaining errors. In dance music the bassline states the
// root, so the bass chroma is the evidence the full-range one cannot supply.
// It supplements rather than replaces: band-limiting the whole chroma this far
// measured much worse, because it throws away the scale.
static const double kBassMaxHz = 250.0;

// How much the bass chroma's support for a pitch class adds to that key's
// score, against a profile correlation in [-1, 1]. 0 disables it.
static const double kBassTonicWeight = 0.15;

// How much the balance between the minor and major third — the interval that
// actually defines the mode — adds to the score, in favor of the matching
// mode. In a bare 12-bin correlation the third is one bin among twelve, and
// mode came out wrong about a third of the time in both directions; this makes
// the deciding evidence decisive. 0 disables it.
static const double kModeThirdWeight = 0.45;

// Key profiles, indexed by interval above the tonic. Sha'ath's EDM-tuned
// revision of the Krumhansl-Schmuckler probe-tone profiles ("Estimation of
// key in digital music recordings", 2011) — numeric constants from the
// published thesis, chosen because dance music's sparse harmony flattens the
// classical profiles' minor-mode assumptions.
static const double kMajorProfile[12] =
        {6.6, 2.0, 3.5, 2.3, 4.6, 4.0, 2.5, 5.2, 2.4, 3.7, 2.3, 3.4};
static const double kMinorProfile[12] =
        {6.5, 2.7, 3.5, 5.4, 2.6, 3.5, 2.5, 5.2, 4.0, 2.7, 4.3, 3.2};

// Pearson correlation of a 12-bin chroma against a profile rotated so that
// `tonic` lines up with profile index 0.
static double VibeChromaCorrelation(const double *chroma, const double *profile, int tonic) {
    double meanC = 0, meanP = 0;
    for (int i = 0; i < 12; i++) {
        meanC += chroma[i];
        meanP += profile[i];
    }
    meanC /= 12.0;
    meanP /= 12.0;
    double num = 0, denC = 0, denP = 0;
    for (int i = 0; i < 12; i++) {
        double c = chroma[(tonic + i) % 12] - meanC;
        double p = profile[i] - meanP;
        num += c * p;
        denC += c * c;
        denP += p * p;
    }
    double den = std::sqrt(denC * denP);
    return den > 0 ? num / den : 0;
}

@implementation AudioKeyAnalyzer {
    double _sampleRate;
    FFTSetup _fftSetup;
    int _log2FrameSize;
    NSUInteger _frameSize;
    NSUInteger _hopSize;

    // Mono samples not yet consumed by a full analysis frame.
    std::vector<float> _pending;
    // Scratch, reused across frames.
    std::vector<float> _window;      // Hann coefficients
    std::vector<float> _windowed;
    std::vector<float> _magnitudes;
    std::vector<float> _splitReal;
    std::vector<float> _splitImag;

    // Per-bin chroma routing, precomputed once: which pitch class each FFT
    // bin votes for and with what weight, or weight 0 outside the band and
    // between semitones.
    std::vector<int> _binPitchClass;
    std::vector<float> _binWeight;
    // Which bins fall in the bass band, and each bin's signed distance from
    // its semitone, for the tuning estimate.
    std::vector<uint8_t> _binIsBass;
    std::vector<float> _binCents;

    double _chroma[12];
    double _bassChroma[12];
    // Magnitude-weighted accumulators for the mean signed cent deviation.
    double _tuningWeightedCents;
    double _tuningWeight;
    NSUInteger _framesAccumulated;
}

- (instancetype)initWithSampleRate:(double)sampleRate {
    self = [super init];
    if (self) {
        _sampleRate = sampleRate;
        if (sampleRate <= 0) {
            return self; // finish() reports none; appends are ignored
        }
        // A ~0.75-second frame regardless of sample rate, so the bin spacing
        // in Hz — what separates neighboring semitones down at A1 — does not
        // degrade for 88.2/96k files.
        double bins = 0.74 * sampleRate;
        _log2FrameSize = (int)std::lround(std::log2(bins));
        _log2FrameSize = std::max(13, std::min(17, _log2FrameSize));
        _frameSize = (NSUInteger)1 << _log2FrameSize;
        _hopSize = _frameSize / 2;
        _fftSetup = vDSP_create_fftsetup(_log2FrameSize, kFFTRadix2);
        _window.resize(_frameSize);
        vDSP_hann_window(_window.data(), _frameSize, vDSP_HANN_NORM);
        _windowed.resize(_frameSize);
        _magnitudes.resize(_frameSize / 2);
        _splitReal.resize(_frameSize / 2);
        _splitImag.resize(_frameSize / 2);

        const double binHz = sampleRate / (double)_frameSize;
        _binPitchClass.assign(_frameSize / 2, 0);
        _binWeight.assign(_frameSize / 2, 0.0f);
        _binIsBass.assign(_frameSize / 2, 0);
        _binCents.assign(_frameSize / 2, 0.0f);
        for (NSUInteger k = 1; k < _frameSize / 2; k++) {
            double f = k * binHz;
            if (f < kMinChromaHz || f > kMaxChromaHz) {
                continue;
            }
            double midi = 69.0 + 12.0 * std::log2(f / 440.0);
            double nearest = std::round(midi);
            double signedCents = (midi - nearest) * 100.0;
            double cents = std::fabs(signedCents);
            if (cents > kMaxCentsFromSemitone) {
                continue;
            }
            _binPitchClass[k] = (int)(((long)nearest % 12) + 12) % 12;
            _binWeight[k] = (float)(1.0 - cents / 50.0);
            _binIsBass[k] = f <= kBassMaxHz;
            _binCents[k] = (float)signedCents;
        }
        memset(_chroma, 0, sizeof(_chroma));
        memset(_bassChroma, 0, sizeof(_bassChroma));
    }
    return self;
}

- (void)dealloc {
    if (_fftSetup) {
        vDSP_destroy_fftsetup(_fftSetup);
    }
}

- (double)tuningCents {
    return _tuningWeight > 0 ? _tuningWeightedCents / _tuningWeight : 0;
}

- (void)appendMonoSamples:(const float *)samples frameCount:(NSUInteger)frameCount {
    if (!_fftSetup || frameCount == 0) {
        return;
    }
    size_t base = _pending.size();
    _pending.resize(base + frameCount);
    memcpy(_pending.data() + base, samples, frameCount * sizeof(float));

    size_t consumed = 0;
    while (_pending.size() - consumed >= _frameSize) {
        [self processFrame:_pending.data() + consumed];
        consumed += _hopSize;
    }
    if (consumed > 0) {
        _pending.erase(_pending.begin(), _pending.begin() + (long)consumed);
    }
}

- (void)processFrame:(const float *)frame {
    vDSP_vmul(frame, 1, _window.data(), 1, _windowed.data(), 1, _frameSize);

    DSPSplitComplex split = { _splitReal.data(), _splitImag.data() };
    vDSP_ctoz((const DSPComplex *)_windowed.data(), 2, &split, 1, _frameSize / 2);
    vDSP_fft_zrip(_fftSetup, &split, 1, _log2FrameSize, kFFTDirection_Forward);
    split.realp[0] = 0; // DC and Nyquist, packed together — neither is a pitch
    split.imagp[0] = 0;
    vDSP_zvabs(&split, 1, _magnitudes.data(), 1, _frameSize / 2);

    // Fold the spectrum onto the frame's chroma, then log-compress it before
    // accumulating. The compression is what keeps one loud chord from
    // steamrolling the whole track's profile, and it flattens the harmonic
    // series enough that a note's fifth partial does not outvote another
    // note's fundamental.
    double frameChroma[12] = {0};
    double frameBass[12] = {0};
    const float *mag = _magnitudes.data();
    float peakFloor = 0;
    if (kPeakThreshold > 0) {
        float loudest = 0;
        vDSP_maxv(mag + 1, 1, &loudest, _frameSize / 2 - 1);
        peakFloor = (float)(loudest * kPeakThreshold);
    }
    const NSUInteger lastBin = _frameSize / 2 - 1;
    for (NSUInteger k = 1; k < _frameSize / 2; k++) {
        float w = _binWeight[k];
        if (w <= 0 || !std::isfinite(mag[k])) {
            continue;
        }
        if (kPeakThreshold > 0) {
            // A pitch shows up as a local maximum; anything else in the band
            // is noise sitting under it.
            if (mag[k] < peakFloor) {
                continue;
            }
            if (mag[k] < mag[k - 1] || (k < lastBin && mag[k] < mag[k + 1])) {
                continue;
            }
        }
        int pc = _binPitchClass[k];
        double energy = w * mag[k];
        frameChroma[pc] += energy;
        if (kHarmonicWeight > 0) {
            // A fifth below is pc - 7, a major third below pc - 4, both mod 12.
            frameChroma[(pc + 5) % 12] += energy * kHarmonicWeight;
            frameChroma[(pc + 8) % 12] += energy * kHarmonicWeight * kHarmonicWeight;
        }
        if (_binIsBass[k]) {
            // No harmonic weighting here: the bass band holds fundamentals,
            // and crediting notes below them is exactly the wrong direction.
            frameBass[pc] += energy;
        }
        _tuningWeightedCents += energy * _binCents[k];
        _tuningWeight += energy;
    }
    double total = 0;
    for (int i = 0; i < 12; i++) {
        total += frameChroma[i];
    }
    if (total <= 0 || !std::isfinite(total)) {
        return; // silence, or a corrupt decode — no vote
    }
    // Each frame casts one equally weighted vote, normalized so a loud passage
    // counts no more than a quiet one. Deliberately linear: log-compressing
    // here was measurably worse across the whole compression range, and
    // compressing the raw magnitudes — as this did originally — made the
    // compression depend on level, the opposite of the intent.
    for (int i = 0; i < 12; i++) {
        _chroma[i] += frameChroma[i] / total;
    }
    // The bass band votes on its own schedule: a frame can carry a bassline
    // while the full-range chroma is dominated by something else, and a frame
    // with no bass at all simply does not vote here.
    double bassTotal = 0;
    for (int i = 0; i < 12; i++) {
        bassTotal += frameBass[i];
    }
    if (bassTotal > 0 && std::isfinite(bassTotal)) {
        for (int i = 0; i < 12; i++) {
            _bassChroma[i] += frameBass[i] / bassTotal;
        }
    }
    _framesAccumulated++;
}

- (VibeMusicalKey)finish {
    if (_sampleRate <= 0 || _framesAccumulated == 0) {
        return VibeMusicalKeyNone;
    }
    double seconds = (double)_framesAccumulated * (double)_hopSize / _sampleRate;
    if (seconds < kMinAnalysisSeconds) {
        return VibeMusicalKeyNone;
    }

    // Scaled against the loudest pitch class rather than the total, so the
    // term is "how strongly does the bass insist on this note" — independent
    // of how many notes the bassline visits.
    double bassPeak = 0;
    for (int i = 0; i < 12; i++) {
        bassPeak = std::max(bassPeak, _bassChroma[i]);
    }

    VibeMusicalKey best = VibeMusicalKeyNone;
    double bestScore = -1e9;
    double bestCorrelation = -2;
    for (int tonic = 0; tonic < 12; tonic++) {
        double bassSupport = bassPeak > 0 ? _bassChroma[tonic] / bassPeak : 0;
        // +1 when only the minor third is present, -1 for only the major.
        double minorThird = _chroma[(tonic + 3) % 12];
        double majorThird = _chroma[(tonic + 4) % 12];
        double thirds = minorThird + majorThird;
        double thirdBalance = thirds > 0 ? (minorThird - majorThird) / thirds : 0;
        for (int minor = 0; minor <= 1; minor++) {
            double correlation = VibeChromaCorrelation(
                    _chroma, minor ? kMinorProfile : kMajorProfile, tonic);
            double score = correlation
                    + kBassTonicWeight * bassSupport
                    + kModeThirdWeight * (minor ? thirdBalance : -thirdBalance);
            if (score > bestScore) {
                bestScore = score;
                bestCorrelation = correlation;
                best = VibeMusicalKeyMake(tonic, minor);
            }
        }
    }
    // The gate stays on the profile correlation, not the combined score: it
    // answers "is this tonal at all", which the bass and third terms — both
    // conditioned on a key already being chosen — say nothing about.
    return bestCorrelation >= kMinCorrelation ? best : VibeMusicalKeyNone;
}

@end
