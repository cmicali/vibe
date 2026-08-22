# Tempo and key detection

`AudioBPMAnalyzer` and `AudioKeyAnalyzer` (ObjC++ and Accelerate) both ride the waveform loader's decode pass (`Vibe/Audio/Waveform/`), so neither costs a second file read.

**Analysis is macOS-only.** Both classes compile into both targets — they are portable Accelerate code, and the tests exercise them — but the decode pass constructs them only when its `VibeWaveformAnalysisProvider` says so, and only the mac installs one. So on iOS neither analyzer is ever built, `AudioTrack.detectedBPM` and `.detectedKey` stay unset, and a track's `bpm`/`key` are whatever its tags carry. Both settings are macOS-only for the same reason.

Results travel in `CodableAudioWaveform.bpm`/`.key`, arrive through `audioWaveformCache:didDetectBPM:forURL:` and `didDetectKey:forURL:`, and land in the transient `AudioTrack.detectedBPM`/`.detectedKey`. **Deliveries can race a track change, so receivers must match the URL against the current track.**

**A file's own tag beats analysis for both.** `AudioTrackMetadata.bpm` reads TagLib's PropertyMap "BPM" (ID3 TBPM, MP4 tmpo, Vorbis BPM); `AudioTrackMetadata.key` reads "INITIALKEY" (ID3 TKEY, Vorbis/FLAC INITIALKEY), falling back to the MP4 freeform atom's verbatim "initialkey", parsed through `VibeMusicalKeyFromString` (musical names, Camelot, Open Key). `AudioTrack.bpm` and `.key` are the single homes of that precedence.

## Tempo

`AppSettings.analyzeBPM` (Settings > Playback, default **on**) gates the ride-along. Off, the waveform caches with no BPM, so a file scanned while off is not re-analyzed on re-enable until its cache entry goes; tagged BPM and the explicit `scan_bpm` path are unaffected.

While streaming it builds a power-spectrum spectral-flux onset envelope. At end of file: autocorrelation and a harmonic comb over 60–200 BPM; a time-domain phase comb rescores the top candidates, refining each candidate's fractional period over a window of ≤40 seconds, to resolve 2:1 and 3:2 metrical errors; then an interpolated fine pass polishes the winner's period. Below `kMinConfidence` it returns 0 — noise, speech, rubato.

Two constants settle octave errors and both were swept on GiantSteps:

- **`kGridNormExponent`** (0.5) is the evidence-based half-against-double test. The grid sum is normalized as `sum / count^exponent`; comparing a grid against its half, the faster grid wins exactly when the in-between beats average more than `2^-(1-exponent)` of the strong ones — 41% at 0.5. Lower favors the faster reading on beat evidence alone.
- **`kTempoPriorCenterBPM`** (140, spread 80) breaks genuine ties. Only the center decides which way an octave pair falls: a candidate T beats its half exactly when T < 4/3 of the center, so the center places that crossover at ~187 BPM. It is load-bearing, not decoration — a center of 120 costs 9 points of Accuracy1, widening the spread to 160 costs 6, and dropping the prior entirely costs 11. The cost is that a hip-hop or downtempo track can read 174 instead of 87.

The summation order and double accumulators are **accuracy-bearing** — changing them changes results.

`docs/future/tempo-accuracy.md` has the per-genre failure breakdown and the approaches already tried and ruled out, so they are not tried again.

## Key

`AppSettings.analyzeKey` (Settings > Playback) **defaults off** — exact-match accuracy on real dance music is around half, which is not worth showing unasked. A *tagged* key is unaffected and always displays. Same caching caveat as tempo.

A chromagram over ~0.75s FFT frames — each bin's magnitude folded onto its nearest semitone's pitch class within 55–3520 Hz, then the frame normalized to one vote — correlated at end of file against the 24 rotations of Sha'ath's EDM-tuned major/minor profiles. Below a correlation gate it returns `VibeMusicalKeyNone`.

Three constants carry the accuracy, all swept on GiantSteps:

- **`kHarmonicWeight`** (0.5) — worth 8 MIREX points on its own. It credits each peak to the fundamentals it could be a *harmonic of*: the note a fifth below (its 3rd harmonic) and a major third below (its 5th). Without it every note manufactures its own major third and the chroma drifts major, wrecking mode detection on a mostly minor corpus.
- **`kBassTonicWeight`** (0.15) — a second chroma over the bass band (`kBassMaxHz`, 250 Hz) votes on which note the bassline treats as the root. It *supplements* the full-range chroma and never replaces it; band-limiting the whole thing measured far worse.
- **`kModeThirdWeight`** (0.45) — scores the balance between the minor and major third explicitly, because in a bare 12-bin correlation the one interval that defines the mode is one bin among twelve.

The last two exist because profile correlation identifies a *scale*, not a tonal center — the relative, dominant and subdominant keys share that scale, and those confusions dominated the errors. The scoring is deliberately additive over a correlation in [-1, 1], and **the confidence gate stays on the correlation alone**: it answers "is this tonal at all", which the other two terms, conditioned on a key already being chosen, cannot.

Frames are normalized to one vote and **never log-compressed** — compressing raw magnitudes squashes loud passages harder than quiet ones, the opposite of the intent.

The key representation, Camelot/musical-name formatting and tag parsing live in `Audio/MusicalKey.h`, header-only static inlines.

**TRAP: a `VibeMusicalKey` of 0 is C major.** Freshly inited holders (`CodableAudioWaveform.key`, `AudioTrackMetadata.key`, `AudioTrack.detectedKey`) must be set to `VibeMusicalKeyNone` (-1) explicitly — a zero-filled ivar or a nil-message fabricates C major.

## Cost

Both analyzers together run at roughly 6,000x realtime in Release, about a fifth of the decode they ride along with — and since the loader pipelines that decode against them, they add nothing to the load's wall time, only CPU. `scan_bpm`/`scan_key` report the `streamSeconds`/`finishSeconds` split, though in Debug, where `-O0` inflates whatever is not a vDSP call.

What is left in each is almost entirely its FFT — 172 1024-point ones a second for the tempo, 2.7 32768-point ones for the key — so making them cheaper means fewer or smaller frames, not tighter code around them.

Four rules hold the current floor, each measured:

- **Every per-bin or per-sample reduction goes through vDSP**, never a written-out loop: a per-sample branch does not predict, a single accumulator serializes on float-add latency, and a written-out spectral-flux loop cost several times the FFT ahead of it.
- **Touch only the band that votes.** The key analyzer's chroma band is a sixth of its spectrum; the magnitude and fold passes run over the band alone.
- **A scatter becomes a run.** Within the band each semitone's voting bins are contiguous, so the chroma fold is one reduction per semitone instead of a scatter-add per bin. The same reshaping settles the phase comb, swept **a beat at a time rather than a phase at a time**: a grid's phase offset is an integer, so every phase reads the same beat offsets and one vDSP add per beat scores all of them at once.
- **`vDSP_DFT` is not a drop-in win over `vDSP_fft_zrip`.** It takes a third off the key analyzer's 32768-point frames and *loses* on the tempo analyzer's 1024-point ones, which is why the two differ. Microbenchmarks mislead here — measure a real decode.

**Decimating for the key analyzer is not a way to make it cheaper**, tempting as its 3520 Hz ceiling makes it look: even a short decimating FIR runs on every sample and would cost more than the whole analyzer, which pays for its big FFT only 2.7 times a second.

## Measuring

Quick signal, no app launch, no dataset — the `vibe-debug` skill's `scan-bpm.sh` and `scan-key.sh` against the generated `bpm-*.wav` and `key-*.wav` loops (the `bpm-*.wav` loops double as the atonal negative case for key). Both verbs run inside the CLI client's own process.

Real accuracy is GiantSteps, and **re-run it after any analyzer change**:

```bash
scripts/validate-tempo.py --jobs 6            # ~35s for the full set; --sample N for a quick signal
scripts/validate-key.py   --jobs 6
```

Neither dataset is vendored — point `--dataset` at a local clone with audio downloaded. Tempo scores the MIREX metrics (Accuracy1 within 4%, Accuracy2 forgiving 1/3, 1/2, 2, 3x); key scores the MIREX key weighting (1.0 exact, 0.5 fifth, 0.3 relative, 0.2 parallel).

Last measured: **tempo Accuracy1 85.1%, Accuracy2 92.6%** over 652 files (2026-08-11); **key 61.3% weighted, 54.7% exact** over 602 files.

`Tests/AudioBPMAnalyzerTests.mm` and `Tests/AudioKeyAnalyzerTests.mm` pin the framing guarantee both analyzers rely on — the buffer sizes the decoder happens to hand an analyzer never reach its result. The guarantee lives in one function, `AnalysisFramerMath.h`: it frames a mono stream into fixed windows at a fixed hop, splicing only the frames that straddle a buffer boundary and reading every later one in place, so a decode buffer is never copied whole. C++ only, included from the two `.mm` analyzers and nowhere else.

## Measured worse — do not retry blind

For key: narrowing the chroma band; restricting to spectral peaks (reviving it means first undoing the run-at-a-time fold, which cannot express a per-bin test); log-compressing the chroma at any strength; and the Krumhansl-Kessler, Temperley and flat-diatonic profile pairs.

**Tuning correction is not worth building**: the mean cent offset from equal temperament (`AudioKeyAnalyzer.tuningCents`, also in the `scan_key` reply) is −0.2 cents median over the corpus and never exceeds ±1.8. That measurement cannot see gross detuning — a track more than `kMaxCentsFromSemitone` (35) off has every bin rejected and surfaces as no key.
