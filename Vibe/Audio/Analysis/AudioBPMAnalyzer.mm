//
//  AudioBPMAnalyzer.mm
//  Vibe
//

#import "AudioBPMAnalyzer.h"
#import <Accelerate/Accelerate.h>
#include <vector>
#include <cmath>
#include <algorithm>

// 1024-sample analysis frames with a 256 hop: ~172 envelope samples per
// second at 44.1kHz. Envelope resolution sets raw lag granularity (~1.4 BPM
// near 120); parabolic interpolation of the score peak recovers sub-BPM
// precision from it.
static const int kLog2FrameSize = 10;
static const NSUInteger kFrameSize = 1 << kLog2FrameSize;
static const NSUInteger kHopSize = 256;

static const float kMinBPM = 60.0f;
static const float kMaxBPM = 200.0f;
// Comb harmonics reach 3x the base lag, so autocorrelation is computed out to
// 3x the slowest tempo's lag.
static const int kCombHarmonics = 3;
// Below this much audio the autocorrelation has too few beat periods to be
// meaningful (~15 beats at 120 BPM).
static const double kMinAnalysisSeconds = 8.0;
// Peak-prominence gate: the winning comb score must beat the mean score by
// this factor or the track is reported as having no detectable tempo.
static const float kMinConfidence = 1.3f;

@implementation AudioBPMAnalyzer {
    double _sampleRate;
    FFTSetup _fftSetup;

    // Mono samples not yet consumed by a full analysis frame (< kFrameSize +
    // kHopSize floats at all times).
    std::vector<float> _pending;
    // Scratch, reused across frames.
    std::vector<float> _window;      // Hann coefficients
    std::vector<float> _windowed;    // windowed frame
    std::vector<float> _magnitudes;  // current frame magnitude spectrum
    std::vector<float> _prevMagnitudes;
    std::vector<float> _splitReal;
    std::vector<float> _splitImag;

    // Onset-strength envelope, one value per hop (~690KB/hour — fine).
    std::vector<float> _onsetEnvelope;
}

- (instancetype)initWithSampleRate:(double)sampleRate {
    self = [super init];
    if (self) {
        _sampleRate = sampleRate;
        _fftSetup = vDSP_create_fftsetup(kLog2FrameSize, kFFTRadix2);
        _window.resize(kFrameSize);
        vDSP_hann_window(_window.data(), kFrameSize, vDSP_HANN_NORM);
        _windowed.resize(kFrameSize);
        _magnitudes.assign(kFrameSize / 2, 0.0f);
        _prevMagnitudes.assign(kFrameSize / 2, 0.0f);
        _splitReal.resize(kFrameSize / 2);
        _splitImag.resize(kFrameSize / 2);
    }
    return self;
}

- (void)dealloc {
    if (_fftSetup) {
        vDSP_destroy_fftsetup(_fftSetup);
    }
}

- (void)appendMonoSamples:(const float *)samples frameCount:(NSUInteger)frameCount {
    if (!_fftSetup || frameCount == 0) {
        return;
    }
    // Already mono — the loader downmixes each decode buffer once
    // (AudioWaveformMonoMix) and shares it with the waveform chunker.
    size_t base = _pending.size();
    _pending.resize(base + frameCount);
    memcpy(_pending.data() + base, samples, frameCount * sizeof(float));

    // Consume full frames, advancing by the hop.
    size_t consumed = 0;
    while (_pending.size() - consumed >= kFrameSize) {
        [self processFrame:_pending.data() + consumed];
        consumed += kHopSize;
    }
    if (consumed > 0) {
        _pending.erase(_pending.begin(), _pending.begin() + (long)consumed);
    }
}

- (void)processFrame:(const float *)frame {
    vDSP_vmul(frame, 1, _window.data(), 1, _windowed.data(), 1, kFrameSize);

    DSPSplitComplex split = { _splitReal.data(), _splitImag.data() };
    vDSP_ctoz((const DSPComplex *)_windowed.data(), 2, &split, 1, kFrameSize / 2);
    vDSP_fft_zrip(_fftSetup, &split, 1, kLog2FrameSize, kFFTDirection_Forward);

    // Power spectrum (bin 0 holds DC/Nyquist packed — zero it, neither drives
    // onsets). Squared magnitudes, not linear: energy weighting keeps the
    // envelope driven by the kick/snare hits that mark the beat — with linear
    // magnitudes a broadband transient (hi-hat noise) sums across all bins
    // and drowns out a concentrated low-frequency kick many times its energy.
    split.imagp[0] = 0;
    split.realp[0] = 0;
    vDSP_zvmags(&split, 1, _magnitudes.data(), 1, kFrameSize / 2);

    // Spectral flux: half-wave-rectified magnitude increase since the last
    // frame, summed across bins. Increases in energy mark onsets; decreases
    // (note tails) are ignored.
    float flux = 0;
    const float *mag = _magnitudes.data();
    const float *prev = _prevMagnitudes.data();
    for (NSUInteger k = 1; k < kFrameSize / 2; k++) {
        float d = mag[k] - prev[k];
        if (d > 0) {
            flux += d;
        }
    }
    if (!std::isfinite(flux)) {
        flux = 0; // corrupt decode (NaN/Inf samples) — drop the frame's onset
    }
    _onsetEnvelope.push_back(flux);
    std::swap(_magnitudes, _prevMagnitudes);
}

- (float)finish {
    const double fps = _sampleRate / (double)kHopSize; // envelope samples/sec
    const size_t n = _onsetEnvelope.size();
    if (_sampleRate <= 0 || n < (size_t)(kMinAnalysisSeconds * fps)) {
        return 0;
    }

    // Detrend: subtract a ~0.5s moving average and half-wave rectify, leaving
    // only transient onset spikes. Slow loudness swells otherwise dominate
    // the autocorrelation with a huge low-lag ramp.
    const size_t meanWin = (size_t)(fps * 0.5);
    std::vector<float> detrended(n);
    {
        std::vector<double> cumsum(n + 1, 0.0);
        for (size_t i = 0; i < n; i++) {
            cumsum[i + 1] = cumsum[i] + _onsetEnvelope[i];
        }
        for (size_t i = 0; i < n; i++) {
            size_t lo = i > meanWin / 2 ? i - meanWin / 2 : 0;
            size_t hi = std::min(n, i + meanWin / 2 + 1);
            float localMean = (float)((cumsum[hi] - cumsum[lo]) / (double)(hi - lo));
            float v = _onsetEnvelope[i] - localMean;
            detrended[i] = v > 0 ? v : 0;
        }
    }

    // Autocorrelation over lags covering 60-200 BPM plus the comb's harmonic
    // reach. Normalized by overlap length so long lags aren't penalized.
    const int minLag = std::max(1, (int)std::floor(60.0 * fps / kMaxBPM));
    const int maxLag = (int)std::ceil(60.0 * fps / kMinBPM);
    const int maxCombLag = maxLag * kCombHarmonics;
    if ((size_t)maxCombLag + 1 >= n) {
        return 0;
    }
    std::vector<float> ac(maxCombLag + 1, 0.0f);
    for (int lag = minLag; lag <= maxCombLag; lag++) {
        float sum = 0;
        vDSP_dotpr(detrended.data(), 1, detrended.data() + lag, 1, &sum, n - (size_t)lag);
        ac[lag] = sum / (float)(n - (size_t)lag);
    }

    // Harmonic comb score: rewards the lag whose multiples also align with
    // the envelope. This narrows the field but cannot by itself separate a
    // tempo from its metrical relatives (2:1, 3:2) on dense 8th-note grids —
    // those are settled by the time-domain phase comb below.
    std::vector<float> score(maxLag + 1, 0.0f);
    double totalScore = 0;
    int bestLag = 0;
    for (int lag = minLag; lag <= maxLag; lag++) {
        // maxCombLag = kCombHarmonics(3) * maxLag, so 2*lag and 3*lag always fit in ac[].
        float s = ac[lag] + 0.5f * ac[2 * lag] + 0.33f * ac[3 * lag];
        score[lag] = s;
        totalScore += s;
        if (bestLag == 0 || s > score[bestLag]) {
            bestLag = lag;
        }
    }
    if (bestLag <= minLag || bestLag >= maxLag) {
        return 0; // peak pinned to the range edge — not a real maximum
    }

    // Confidence: a real tempo shows up as a prominent peak; a flat score
    // curve means "no periodicity worth reporting".
    float meanScore = (float)(totalScore / (double)(maxLag - minLag + 1));
    if (meanScore <= 0 || score[bestLag] < kMinConfidence * meanScore) {
        return 0;
    }

    // Candidates: local maxima of the comb score, strongest first. The true
    // tempo's metrical relatives (half, double, 2/3, 3/2) all appear here.
    std::vector<int> candidates;
    for (int lag = minLag + 1; lag < maxLag; lag++) {
        if (score[lag] >= score[lag - 1] && score[lag] >= score[lag + 1] &&
            score[lag] >= 0.4f * score[bestLag]) {
            candidates.push_back(lag);
        }
    }
    std::sort(candidates.begin(), candidates.end(),
              [&](int a, int b) { return score[a] > score[b]; });
    if (candidates.size() > 6) {
        candidates.resize(6);
    }

    // The comb can leave the true tempo out of the local-max list entirely:
    // alternating beat emphasis (kick vs kick+clap on 2 and 4) makes the
    // two-beat lag dominate while the one-beat lag never even peaks. Add each
    // top candidate's metrical relatives so the phase comb below judges the
    // whole family, not just the lags autocorrelation happened to favor.
    {
        const size_t seedCount = std::min(candidates.size(), (size_t)3);
        const double factors[] = {0.5, 2.0, 2.0 / 3.0, 1.5};
        std::vector<int> relatives;
        for (size_t i = 0; i < seedCount; i++) {
            for (double f : factors) {
                int rel = (int)llround((double)candidates[i] * f);
                if (rel < minLag + 1 || rel > maxLag - 1) {
                    continue;
                }
                bool dup = false;
                for (int existing : candidates) {
                    if (std::abs(existing - rel) <= 2) { dup = true; break; }
                }
                for (int existing : relatives) {
                    if (std::abs(existing - rel) <= 2) { dup = true; break; }
                }
                if (!dup) {
                    relatives.push_back(rel);
                }
            }
        }
        candidates.insert(candidates.end(), relatives.begin(), relatives.end());
    }

    // Time-domain phase comb: for each candidate, sum the envelope at the
    // beat positions of its best-aligned grid, normalized by sqrt(grid size)
    // (matched-filter normalization). Unlike autocorrelation this sees which
    // grid actually lands on the strong onsets: a 3:2 error alternates
    // beats and offbeats (weak sum), and a half-tempo grid covers only half
    // the onset energy (sqrt normalization votes it down).
    //
    // Scored over a bounded window: a fixed grid over many minutes magnifies
    // any period error (and real music's tempo wobble) into cumulative drift
    // that walks the grid off the onsets.
    const size_t winLen = std::min(n, (size_t)(40.0 * fps));
    const float *env = detrended.data() + (n - winLen) / 2;

    double bestFinal = -1;
    double bestCandidateLag = 0;
    for (int cLag : candidates) {
        // Parabolic refinement on the comb score seeds the fractional period.
        float y0 = score[cLag - 1], y1 = score[cLag], y2 = score[cLag + 1];
        float denom = y0 - 2 * y1 + y2;
        float offset = denom != 0 ? 0.5f * (y0 - y2) / denom : 0;
        if (offset > 0.5f || offset < -0.5f) {
            offset = 0;
        }
        double seedLag = (double)cLag + offset;

        // Refine the period against the envelope itself: a lag off by even
        // 0.2% drifts a full sample every few beats — enough to walk a
        // 40-second grid off the ~1-sample-wide onset spikes and hand the
        // win to a slower relative that drifts proportionally less. The ±1
        // neighborhood max at each position absorbs the residual jitter.
        double bestSum = 0;
        double bestLagF = seedLag;
        // ±1.0 covers both drift-refinement and the rounding error of the
        // synthesized relative seeds (a half-lag seed can start ~0.75 off).
        for (double L = seedLag - 1.0; L <= seedLag + 1.0001; L += 0.03) {
            if (L < 2) {
                continue;
            }
            double phaseBest = 0;
            int phases = (int)L;
            for (int phase = 0; phase < phases; phase++) {
                double sum = 0;
                for (size_t k = 0;; k++) {
                    size_t idx = (size_t)llround((double)phase + (double)k * L);
                    if (idx + 1 >= winLen) {
                        break;
                    }
                    float v = env[idx];
                    if (idx > 0 && env[idx - 1] > v) v = env[idx - 1];
                    if (env[idx + 1] > v) v = env[idx + 1];
                    sum += v;
                }
                if (sum > phaseBest) {
                    phaseBest = sum;
                }
            }
            if (phaseBest > bestSum) {
                bestSum = phaseBest;
                bestLagF = L;
            }
        }

        size_t gridCount = (size_t)((double)winLen / bestLagF);
        if (gridCount < 4) {
            continue;
        }
        double timeScore = bestSum / std::sqrt((double)gridCount);

        // Mild wide prior toward common tempos — a tiebreaker only; the
        // phase comb has already separated the metrical family.
        double bpm = 60.0 * fps / bestLagF;
        double z = (bpm - 120.0) / 80.0;
        double weighted = timeScore * std::exp(-0.5 * z * z);
        if (weighted > bestFinal) {
            bestFinal = weighted;
            bestCandidateLag = bestLagF;
        }
    }
    if (bestFinal <= 0 || bestCandidateLag <= 0) {
        return 0;
    }
    return (float)(60.0 * fps / bestCandidateLag);
}

@end
