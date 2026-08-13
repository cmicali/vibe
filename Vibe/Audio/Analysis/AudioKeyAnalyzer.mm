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

// One semitone's run of voting bins. Within the band the bins that vote for a
// semitone are contiguous — they are the ones inside kMaxCentsFromSemitone of
// its center — and the bins between semitones weigh 0 and separate one run
// from the next. So the whole spectrum-to-chroma fold is one vDSP reduction
// per semitone rather than a scatter-add per bin, which is also why nothing
// finer-grained than a run, such as peak picking, can ride along here.
struct VibeChromaRun {
    uint32_t start;
    uint32_t count;
    uint32_t bassCount;  // leading bins of the run inside the bass band
    int pitchClass;
};

@implementation AudioKeyAnalyzer {
    double _sampleRate;
    vDSP_DFT_Setup _dftSetup;
    NSUInteger _frameSize;
    NSUInteger _hopSize;

    // Mono samples not yet consumed by a full analysis frame. Only the frames
    // straddling a buffer boundary are read out of it, so it holds fewer than
    // _frameSize floats between calls and twice that within one.
    std::vector<float> _pending;
    // Scratch, reused across frames.
    std::vector<float> _window;      // Hann coefficients
    std::vector<float> _windowed;
    std::vector<float> _magnitudes;  // written over the chroma band only
    std::vector<float> _weighted;    // magnitudes scaled by their bin weights
    std::vector<float> _splitReal;
    std::vector<float> _splitImag;

    // The chroma fold, precomputed once. The runs cover the band in bin order;
    // _bandFirst and _bandCount span all of them, for the whole-band sums.
    std::vector<VibeChromaRun> _chromaRuns;
    NSUInteger _bandFirst;
    NSUInteger _bandCount;
    std::vector<float> _binWeight;  // 0 outside the band and between semitones
    std::vector<float> _binCents;   // signed distance from the semitone center

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
        int log2FrameSize = (int)std::lround(std::log2(bins));
        log2FrameSize = std::max(13, std::min(17, log2FrameSize));
        _frameSize = (NSUInteger)1 << log2FrameSize;
        _hopSize = _frameSize / 2;
        _dftSetup = vDSP_DFT_zrop_CreateSetup(NULL, _frameSize, vDSP_DFT_FORWARD);
        if (!_dftSetup) {
            return self; // finish() reports none; appends are ignored
        }
        _pending.reserve(_frameSize * 2);
        _window.resize(_frameSize);
        vDSP_hann_window(_window.data(), _frameSize, vDSP_HANN_NORM);
        _windowed.resize(_frameSize);
        _magnitudes.resize(_frameSize / 2);
        _weighted.resize(_frameSize / 2);
        _splitReal.resize(_frameSize / 2);
        _splitImag.resize(_frameSize / 2);

        const double binHz = sampleRate / (double)_frameSize;
        std::vector<int> binPitchClass(_frameSize / 2, 0);
        std::vector<uint8_t> binIsBass(_frameSize / 2, 0);
        _binWeight.assign(_frameSize / 2, 0.0f);
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
            binPitchClass[k] = (int)(((long)nearest % 12) + 12) % 12;
            _binWeight[k] = (float)(1.0 - cents / 50.0);
            binIsBass[k] = f <= kBassMaxHz;
            _binCents[k] = (float)signedCents;
        }
        for (NSUInteger k = 1; k < _frameSize / 2;) {
            if (_binWeight[k] <= 0) {
                k++;
                continue;
            }
            NSUInteger start = k, bassCount = 0;
            while (k < _frameSize / 2 && _binWeight[k] > 0 &&
                   binPitchClass[k] == binPitchClass[start]) {
                if (binIsBass[k] && bassCount == k - start) {
                    bassCount++;
                }
                k++;
            }
            _chromaRuns.push_back({(uint32_t)start, (uint32_t)(k - start),
                                   (uint32_t)bassCount, binPitchClass[start]});
        }
        if (!_chromaRuns.empty()) {
            _bandFirst = _chromaRuns.front().start;
            _bandCount = _chromaRuns.back().start + _chromaRuns.back().count - _bandFirst;
        }
        memset(_chroma, 0, sizeof(_chroma));
        memset(_bassChroma, 0, sizeof(_bassChroma));
    }
    return self;
}

- (void)dealloc {
    if (_dftSetup) {
        vDSP_DFT_DestroySetup(_dftSetup);
    }
}

- (double)tuningCents {
    return _tuningWeight > 0 ? _tuningWeightedCents / _tuningWeight : 0;
}

- (void)appendMonoSamples:(const float *)samples frameCount:(NSUInteger)frameCount {
    if (!_dftSetup || _chromaRuns.empty() || frameCount == 0) {
        return;
    }
    // Only the frames straddling the buffer boundary are spliced into
    // _pending; every later frame is read in place out of the caller's buffer,
    // so a decode buffer is never copied whole.
    const size_t carried = _pending.size();
    size_t offset = 0;
    if (carried > 0) {
        _pending.insert(_pending.end(), samples,
                        samples + std::min((size_t)frameCount, (size_t)_frameSize));
        while (offset < carried && offset + _frameSize <= _pending.size()) {
            [self processFrame:_pending.data() + offset];
            offset += _hopSize;
        }
        if (offset < carried) { // not even the first straddling frame is whole yet
            _pending.erase(_pending.begin(), _pending.begin() + (long)offset);
            return;
        }
    }
    size_t base = offset - carried;
    while (base + _frameSize <= frameCount) {
        [self processFrame:samples + base];
        base += _hopSize;
    }
    _pending.assign(samples + base, samples + frameCount);
}

- (void)processFrame:(const float *)frame {
    vDSP_vmul(frame, 1, _window.data(), 1, _windowed.data(), 1, _frameSize);

    DSPSplitComplex split = { _splitReal.data(), _splitImag.data() };
    vDSP_ctoz((const DSPComplex *)_windowed.data(), 2, &split, 1, _frameSize / 2);
    // vDSP_DFT beats vDSP_fft_zrip by about a third at this frame size, where
    // for the BPM analyzer's 1024-point frames it loses; the crossover is why
    // the two analyzers do not use the same call.
    vDSP_DFT_Execute(_dftSetup, split.realp, split.imagp, split.realp, split.imagp);

    // Only the chroma band's magnitudes are ever read, and it is a sixth of the
    // spectrum, so the square root runs over that slice alone. Bin 0, where DC
    // and Nyquist arrive packed together, is below the band and never voted.
    DSPSplitComplex band = { split.realp + _bandFirst, split.imagp + _bandFirst };
    vDSP_zvabs(&band, 1, _magnitudes.data() + _bandFirst, 1, _bandCount);

    // Fold the spectrum onto the frame's chroma. The per-frame normalization
    // at the accumulate below is what keeps one loud passage from
    // steamrolling the whole track's profile.
    //
    // Each semitone's bins are one contiguous run, so the fold is a reduction
    // per run rather than a scatter-add per bin. A non-finite magnitude
    // poisons the frame's total, which the guard below drops.
    double frameChroma[12] = {0};
    double frameBass[12] = {0};
    double rawChroma[12] = {0};
    vDSP_vmul(_magnitudes.data() + _bandFirst, 1, _binWeight.data() + _bandFirst, 1,
              _weighted.data() + _bandFirst, 1, _bandCount);
    for (const VibeChromaRun &run : _chromaRuns) {
        float sum = 0;
        vDSP_sve(_weighted.data() + run.start, 1, &sum, run.count);
        rawChroma[run.pitchClass] += sum;
        if (run.bassCount > 0) {
            // No harmonic weighting on the bass chroma: the bass band holds
            // fundamentals, and crediting notes below them is exactly the
            // wrong direction.
            float bass = 0;
            vDSP_sve(_weighted.data() + run.start, 1, &bass, run.bassCount);
            frameBass[run.pitchClass] += bass;
        }
    }
    for (int pc = 0; pc < 12; pc++) {
        frameChroma[pc] += rawChroma[pc];
        if (kHarmonicWeight > 0) {
            // A fifth below is pc - 7, a major third below pc - 4, both mod 12.
            // Spreading a pitch class's whole energy at once is the same sum as
            // spreading each bin's, twelve operations instead of two per bin.
            frameChroma[(pc + 5) % 12] += rawChroma[pc] * kHarmonicWeight;
            frameChroma[(pc + 8) % 12] += rawChroma[pc] * kHarmonicWeight * kHarmonicWeight;
        }
    }
    float weightSum = 0, centsSum = 0;
    vDSP_sve(_weighted.data() + _bandFirst, 1, &weightSum, _bandCount);
    vDSP_dotpr(_weighted.data() + _bandFirst, 1, _binCents.data() + _bandFirst, 1,
               &centsSum, _bandCount);
    _tuningWeightedCents += centsSum;
    _tuningWeight += weightSum;

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
    // compressing the raw magnitudes makes the compression depend on level,
    // the opposite of the intent.
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
