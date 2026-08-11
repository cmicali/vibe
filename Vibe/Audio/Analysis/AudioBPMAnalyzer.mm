//
//  AudioBPMAnalyzer.mm
//  Vibe
//

#import "AudioBPMAnalyzer.h"
#import <Accelerate/Accelerate.h>
#include <vector>
#include <cmath>
#include <algorithm>

// 1024-sample analysis frames with a 256 hop give about 172 envelope samples
// per second at 44.1kHz. The envelope's resolution sets the raw lag
// granularity, roughly 1.4 BPM near 120, and parabolic interpolation of the
// score peak recovers sub-BPM precision from it.
static const int kLog2FrameSize = 10;
static const NSUInteger kFrameSize = 1 << kLog2FrameSize;
static const NSUInteger kHopSize = 256;

static const float kMinBPM = 60.0f;
static const float kMaxBPM = 200.0f;
// Comb harmonics reach 3x the base lag, so autocorrelation is computed out to
// 3x the slowest tempo's lag.
static const int kCombHarmonics = 3;
// Below this much audio the autocorrelation has too few beat periods to mean
// anything: about 15 beats at 120 BPM.
static const double kMinAnalysisSeconds = 8.0;
// The peak-prominence gate. The winning comb score must beat the mean score by
// this factor, or the track is reported as having no detectable tempo.
static const float kMinConfidence = 1.3f;

// The tie-breaking tempo prior applied to the phase comb's candidates, as a
// Gaussian over BPM. Only the center decides which way an octave pair falls:
// a candidate T beats its half exactly when T < 4/3 of the center, so the
// center places that crossover — here at 187 BPM, which keeps drum and bass at
// 174 rather than halving it to 87 — and the spread only sets how hard the
// prior can override the comb. Both were swept against GiantSteps; see
// Audio/CLAUDE.md. The center is the sensitive one: 120 costs 9 points of
// Accuracy1, and widening the spread to 160, or dropping the prior entirely,
// costs 6 and 11 — the prior is load-bearing, not decoration.
static const double kTempoPriorCenterBPM = 140.0;
static const double kTempoPriorSpreadBPM = 80.0;

// How the phase comb's grid sum is normalized for grid size: score = sum /
// count^exponent. This, not the prior, is the evidence-based half-against-
// double test, and the exponent sets its threshold. Comparing a grid against
// its half — which hits only the strong beats, skipping the ones between —
// the faster grid wins exactly when the in-between beats average more than
// 2^-(1-exponent) of the strong ones: 41% at 0.5, 62% at 0.3. Lower therefore
// favors the faster reading on beat evidence alone, which is the right place
// to settle an octave, leaving the prior to break genuine ties.
static const double kGridNormExponent = 0.5;

// The phase comb's inner sweep: the best-aligned grid of period L, scored over
// `winLen` envelope samples. Both passes in finish share one reformulation. A
// phase offset is an integer, so a grid index round(p + k*L) is exactly
// p + round(k*L): every phase reads the same beat offsets, shifted. Scoring
// them a beat at a time rather than a phase at a time therefore makes each beat
// one vDSP add of an envelope slice onto the running phase scores, and scores
// every phase at once. A phase's own terms are still summed in k order, as in
// the scalar loop this replaces, and still in double.
//
// Later phases run off the end of the window first, so each beat's slice is a
// prefix of the phase range — which is also the original's per-phase break.
//
// `acc` is caller-owned scratch, so a sweep allocates nothing.
static double VibeCombPhaseBest(const double *env, size_t winLen, double L,
                                std::vector<double> &acc) {
    const size_t phases = (size_t)L;
    acc.assign(phases, 0.0);
    for (size_t k = 0;; k++) {
        const long offset = (long)llround((double)k * L);
        long len = (long)winLen - 1 - offset;
        if (len <= 0) {
            break;
        }
        len = std::min(len, (long)phases);
        vDSP_vaddD(acc.data(), 1, env + offset, 1, acc.data(), 1, (vDSP_Length)len);
    }
    double best = 0;
    vDSP_maxvD(acc.data(), 1, &best, phases);
    return best;
}

// The same sweep with linearly interpolated envelope samples and no tolerance
// window. The interpolation weights depend on the fractional part of k*L alone,
// which the integer phase offset leaves untouched, so each beat is two scaled
// adds of a slice.
static double VibeCombPhaseBestInterpolated(const double *env, size_t winLen, double L,
                                            std::vector<double> &acc) {
    const size_t phases = (size_t)L;
    acc.assign(phases, 0.0);
    for (size_t k = 0;; k++) {
        const double pos = (double)k * L;
        const long offset = (long)pos;
        long len = (long)winLen - 1 - offset;
        if (len <= 0) {
            break;
        }
        len = std::min(len, (long)phases);
        double upper = pos - (double)offset, lower = 1.0 - upper;
        vDSP_vsmaD(env + offset, 1, &lower, acc.data(), 1, acc.data(), 1, (vDSP_Length)len);
        vDSP_vsmaD(env + offset + 1, 1, &upper, acc.data(), 1, acc.data(), 1, (vDSP_Length)len);
    }
    double best = 0;
    vDSP_maxvD(acc.data(), 1, &best, phases);
    return best;
}

@implementation AudioBPMAnalyzer {
    double _sampleRate;
    FFTSetup _fftSetup;

    // The tail of earlier buffers, from the next frame's first sample on. Only
    // the frames straddling a buffer boundary are read out of it, so it holds
    // fewer than kFrameSize floats between calls and twice that within one.
    std::vector<float> _pending;
    // Scratch, reused across frames.
    std::vector<float> _window;      // Hann coefficients
    std::vector<float> _windowed;    // windowed frame
    std::vector<float> _magnitudes;  // current frame magnitude spectrum
    std::vector<float> _prevMagnitudes;
    std::vector<float> _binDelta;    // per-bin magnitude change since the last frame
    std::vector<float> _splitReal;
    std::vector<float> _splitImag;

    // The onset-strength envelope, one value per hop. That is about 690KB an
    // hour, which is fine.
    std::vector<float> _onsetEnvelope;
}

- (instancetype)initWithSampleRate:(double)sampleRate {
    self = [super init];
    if (self) {
        _sampleRate = sampleRate;
        _fftSetup = vDSP_create_fftsetup(kLog2FrameSize, kFFTRadix2);
        _pending.reserve(kFrameSize * 2);
        _window.resize(kFrameSize);
        vDSP_hann_window(_window.data(), kFrameSize, vDSP_HANN_NORM);
        _windowed.resize(kFrameSize);
        _magnitudes.assign(kFrameSize / 2, 0.0f);
        _prevMagnitudes.assign(kFrameSize / 2, 0.0f);
        _binDelta.resize(kFrameSize / 2);
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
    // Already mono: the loader downmixes each decode buffer once, through
    // AudioWaveformMonoMix, and shares it with the waveform chunker.
    //
    // Only the frames straddling the buffer boundary are spliced into
    // _pending; every later frame is read in place out of the caller's buffer,
    // so a decode buffer is never copied whole.
    const size_t carried = _pending.size();
    size_t offset = 0;
    if (carried > 0) {
        _pending.insert(_pending.end(), samples,
                        samples + std::min((size_t)frameCount, (size_t)kFrameSize));
        while (offset < carried && offset + kFrameSize <= _pending.size()) {
            [self processFrame:_pending.data() + offset];
            offset += kHopSize;
        }
        if (offset < carried) { // not even the first straddling frame is whole yet
            _pending.erase(_pending.begin(), _pending.begin() + (long)offset);
            return;
        }
    }
    size_t base = offset - carried;
    while (base + kFrameSize <= frameCount) {
        [self processFrame:samples + base];
        base += kHopSize;
    }
    _pending.assign(samples + base, samples + frameCount);
}

- (void)processFrame:(const float *)frame {
    vDSP_vmul(frame, 1, _window.data(), 1, _windowed.data(), 1, kFrameSize);

    DSPSplitComplex split = { _splitReal.data(), _splitImag.data() };
    vDSP_ctoz((const DSPComplex *)_windowed.data(), 2, &split, 1, kFrameSize / 2);
    vDSP_fft_zrip(_fftSetup, &split, 1, kLog2FrameSize, kFFTDirection_Forward);

    // The power spectrum. Bin 0 holds DC and Nyquist packed together, so zero
    // it: neither drives onsets. The magnitudes are squared rather than
    // linear, because energy weighting keeps the envelope driven by the kick
    // and snare hits that mark the beat. With linear magnitudes a broadband
    // transient such as hi-hat noise sums across every bin and drowns out a
    // concentrated low-frequency kick many times its energy.
    split.imagp[0] = 0;
    split.realp[0] = 0;
    vDSP_zvmags(&split, 1, _magnitudes.data(), 1, kFrameSize / 2);

    // Spectral flux: the half-wave-rectified magnitude increase since the last
    // frame, summed across bins. Increases in energy mark onsets, and
    // decreases, which are note tails, are ignored. Summing the changes and
    // their magnitudes gives twice that rectified sum, which keeps the whole
    // reduction inside vDSP. The per-bin loop this replaces cost several times
    // the FFT ahead of it: its branch is unpredictable and its single
    // accumulator serializes on float-add latency, so it neither vectorized nor
    // pipelined.
    vDSP_vsub(_prevMagnitudes.data(), 1, _magnitudes.data(), 1, _binDelta.data(), 1, kFrameSize / 2);
    float signedSum = 0, absSum = 0;
    vDSP_sve(_binDelta.data() + 1, 1, &signedSum, kFrameSize / 2 - 1);
    vDSP_svemg(_binDelta.data() + 1, 1, &absSum, kFrameSize / 2 - 1);
    float flux = 0.5f * (signedSum + absSum);
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

    // Detrend by subtracting a moving average of about 0.5 seconds and
    // half-wave rectifying, which leaves only transient onset spikes. Slow
    // loudness swells otherwise dominate the autocorrelation with a huge
    // low-lag ramp.
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
    // reach, normalized by overlap length so that long lags are not penalized.
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

    // The harmonic comb score rewards the lag whose multiples also align with
    // the envelope. It narrows the field but cannot by itself separate a tempo
    // from its metrical relatives, 2:1 and 3:2, on a dense 8th-note grid. The
    // time-domain phase comb below settles those.
    std::vector<float> score(maxLag + 1, 0.0f);
    double totalScore = 0;
    int bestLag = 0;
    for (int lag = minLag; lag <= maxLag; lag++) {
        // maxCombLag is kCombHarmonics, 3, times maxLag, so 2*lag and 3*lag
        // always fit in ac[].
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

    // Confidence. A real tempo shows up as a prominent peak, whereas a flat
    // score curve means there is no periodicity worth reporting.
    float meanScore = (float)(totalScore / (double)(maxLag - minLag + 1));
    if (meanScore <= 0 || score[bestLag] < kMinConfidence * meanScore) {
        return 0;
    }

    // The candidates are the local maxima of the comb score, strongest first.
    // The true tempo's metrical relatives — half, double, 2/3 and 3/2 — all
    // appear here.
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

    // The comb can leave the true tempo out of the local-maximum list
    // entirely. Alternating beat emphasis — a kick against a kick and clap on
    // 2 and 4 — makes the two-beat lag dominate while the one-beat lag never
    // even peaks. Add each top candidate's metrical relatives, so that the
    // phase comb below judges the whole family rather than only the lags
    // autocorrelation happened to favor.
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

    // The time-domain phase comb. For each candidate, sum the envelope at the
    // beat positions of its best-aligned grid, normalized by the square root
    // of the grid size — matched-filter normalization. Unlike autocorrelation,
    // this sees which grid actually lands on the strong onsets: a 3:2 error
    // alternates beats and offbeats, giving a weak sum, and a half-tempo grid
    // covers only half the onset energy, which the square-root normalization
    // votes down.
    //
    // It is scored over a bounded window, because a fixed grid over many
    // minutes magnifies any period error, and real music's tempo wobble, into
    // cumulative drift that walks the grid off the onsets.
    const size_t winLen = std::min(n, (size_t)(40.0 * fps));
    const float *env = detrended.data() + (n - winLen) / 2;

    // The two envelopes the sweeps read, in double because their sums are. The
    // coarse one carries the ±1-sample neighborhood maximum that absorbs onset
    // jitter, taken once here rather than per candidate per lag and per phase.
    // Its last element is never addressed: a beat is only scored when the
    // sample after it is in the window too.
    std::vector<double> envWide(winLen, 0.0), envExact(winLen);
    {
        std::vector<float> pairMax(winLen), wide(winLen);
        vDSP_vmax(env, 1, env + 1, 1, pairMax.data(), 1, winLen - 1);
        wide[0] = pairMax[0];
        vDSP_vmax(pairMax.data() + 1, 1, env, 1, wide.data() + 1, 1, winLen - 2);
        vDSP_vspdp(wide.data(), 1, envWide.data(), 1, winLen - 1);
        vDSP_vspdp(env, 1, envExact.data(), 1, winLen);
    }
    std::vector<double> phaseScores;

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

        // Refine the period against the envelope itself. A lag off by even
        // 0.2% drifts a full sample every few beats, enough to walk a
        // 40-second grid off the roughly one-sample-wide onset spikes and hand
        // the win to a slower relative that drifts proportionally less. The
        // neighborhood maximum of ±1 at each position absorbs the residual
        // jitter.
        double bestSum = 0;
        double bestLagF = seedLag;
        // A band of ±1.0 covers both the drift refinement and the rounding
        // error of the synthesized relative seeds, since a half-lag seed can
        // start about 0.75 off.
        for (double L = seedLag - 1.0; L <= seedLag + 1.0001; L += 0.03) {
            if (L < 2) {
                continue;
            }
            double phaseBest = VibeCombPhaseBest(envWide.data(), winLen, L, phaseScores);
            if (phaseBest > bestSum) {
                bestSum = phaseBest;
                bestLagF = L;
            }
        }

        size_t gridCount = (size_t)((double)winLen / bestLagF);
        if (gridCount < 4) {
            continue;
        }
        double timeScore = bestSum / std::pow((double)gridCount, kGridNormExponent);

        // A mild, wide prior toward common tempos. It is a tiebreaker only,
        // since the phase comb has already separated the metrical family.
        double bpm = 60.0 * fps / bestLagF;
        double z = (bpm - kTempoPriorCenterBPM) / kTempoPriorSpreadBPM;
        double weighted = timeScore * std::exp(-0.5 * z * z);
        if (weighted > bestFinal) {
            bestFinal = weighted;
            bestCandidateLag = bestLagF;
        }
    }
    if (bestFinal <= 0 || bestCandidateLag <= 0) {
        return 0;
    }

    // The fine pass on the winner. The coarse sweep's ±1-frame neighborhood
    // maximum is what makes the phase comb robust to onset jitter, but it also
    // flattens the score into a plateau about ±0.05 frames wide around the
    // true period, and the coarse winner lands anywhere on it, roughly ±0.1
    // BPM at 120. So re-score a narrow band around the winner with linearly
    // interpolated envelope samples and no tolerance window: exact sampling
    // turns any period error into real accumulated drift off the onset blobs,
    // and the score then peaks at the true period rather than plateauing. The
    // blobs themselves are about two frames wide, because spectral flux
    // spreads each transient across overlapping frames, and that supplies all
    // the jitter tolerance this final ±0.09-frame band still needs. Only the
    // period is refined: an integer phase offset shifts every sampled beat
    // equally and cannot bias the slope.
    {
        double bestSum = -1;
        double refined = bestCandidateLag;
        for (double L = bestCandidateLag - 0.09; L <= bestCandidateLag + 0.0901; L += 0.005) {
            if (L < 2) {
                continue;
            }
            double phaseBest = VibeCombPhaseBestInterpolated(envExact.data(), winLen, L, phaseScores);
            if (phaseBest > bestSum) {
                bestSum = phaseBest;
                refined = L;
            }
        }
        bestCandidateLag = refined;
    }
    return (float)(60.0 * fps / bestCandidateLag);
}

@end
