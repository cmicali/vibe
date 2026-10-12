# Tempo and key detection

`AudioBPMAnalyzer` and `AudioKeyAnalyzer` (ObjC++ and Accelerate) both ride the waveform loader's decode pass (`Audio/Waveform/AGENTS.md`), so neither costs a second file read.

**Tempo runs on both platforms; key is macOS-only.** Both classes compile into both targets, and the tests exercise them. The decode pass builds one only when its `VibeWaveformAnalysisProvider` asks. The mac's provider reads the two settings. The iOS card's answers `{analyzeBPM, NO}`, so on iOS `AudioTrack.detectedKey` stays unset and a track's `key` is its tag's. `analyzeBPM` is shared in `AppSettings`, and `analyzeKey` is macOS-only.

Results travel in `CodableAudioWaveform.bpm`/`.key`, arrive through `audioWaveformCache:didDetectBPM:forTrack:` and `didDetectKey:forTrack:`, and land in the transient `AudioTrack.detectedBPM`/`.detectedKey`. A cue row is analyzed over its own window, so a mix gets a tempo and key per track. A receiver stamps every row whose `sourceKey` is the delivered track's (`Playlist.stampTracksSounding:usingBlock:`), never just the current one (root `AGENTS.md`, async deliveries).

**A whole file's tag beats analysis; a cue row's never does** (root `AGENTS.md`). `AudioTrack.rowTagMetadata` is nil for a windowed row. `AudioTrackMetadata.bpm` reads TagLib's PropertyMap "BPM" (ID3 TBPM, MP4 tmpo, Vorbis BPM). `AudioTrackMetadata.key` reads "INITIALKEY" (ID3 TKEY, Vorbis/FLAC INITIALKEY), falling back to the MP4 freeform atom "initialkey". It is parsed through `VibeMusicalKeyFromString` (musical names, Camelot, Open Key).

## Tempo

`AppSettings.analyzeBPM` (Settings > Playback on both platforms, default **on**) gates the ride-along. On iOS the detected tempo also drives the FX pad's delay taps (`iOS/Player/AGENTS.md`). Off, the waveform caches with no BPM. A file scanned while off is analyzed again only when a request that runs the analyzer misses its entry (`Audio/Waveform/AGENTS.md`). Tagged BPM and `scan_bpm` are unaffected.

While streaming it builds a power-spectrum spectral-flux onset envelope. At end of file it runs autocorrelation and a harmonic comb over 60–200 BPM. A time-domain phase comb rescores the top candidates over a window of ≤40 seconds, to resolve 2:1 and 3:2 metrical errors. An interpolated fine pass then polishes the winner's period. Below `kMinConfidence` it returns 0: noise, speech, rubato.

Two constants settle octave errors. Both were swept on GiantSteps:

- **`kGridNormExponent`** (0.5) is the half-against-double test. The grid sum is normalized as `sum / count^exponent`. The faster grid wins exactly when the in-between beats average more than `2^-(1-exponent)` of the strong ones, 41% at 0.5.
- **`kTempoPriorCenterBPM`** (140, spread 80) breaks genuine ties. A candidate T beats its half exactly when T < 4/3 of the center, so the crossover sits at ~187 BPM. It is load-bearing: a center of 120 costs 9 points of Accuracy1, a spread of 160 costs 6, and no prior costs 11. The cost is that a hip-hop or downtempo track can read 174 instead of 87.

The summation order and double accumulators are **accuracy-bearing**. Changing them changes results.

`docs/future/tempo-accuracy.md` has the per-genre failure breakdown and the approaches already ruled out.

## Key

`AppSettings.analyzeKey` (Settings > Playback) **defaults off**. Exact-match accuracy on real dance music is around half, which is not worth showing unasked. A *tagged* key always displays.

A chromagram over ~0.75 s FFT frames folds each bin's magnitude onto its nearest semitone's pitch class within 55–3520 Hz. Each frame is normalized to one vote. At end of file it is correlated against the 24 rotations of Sha'ath's EDM-tuned major/minor profiles. Below a correlation gate it returns `VibeMusicalKeyNone`.

Three constants carry the accuracy, all swept on GiantSteps:

- **`kHarmonicWeight`** (0.5), worth 8 MIREX points on its own. It credits each peak to the fundamentals it could be a *harmonic of*: the note a fifth below (its 3rd harmonic) and a major third below (its 5th). Without it every note makes its own major third and the chroma drifts major.
- **`kBassTonicWeight`** (0.15). A second chroma over the bass band (`kBassMaxHz`, 250 Hz) votes on which note the bassline treats as the root. It *supplements* the full-range chroma. Band-limiting the whole chroma measured far worse.
- **`kModeThirdWeight`** (0.45) scores the minor third against the major third. In a bare 12-bin correlation the interval that defines the mode is one bin among twelve.

The last two exist because profile correlation finds a *scale*, not a tonal center. The relative, dominant and subdominant keys share that scale, and those confusions dominated the errors. The scoring is additive over a correlation in [-1, 1]. **The confidence gate stays on the correlation alone**: it answers "is this tonal at all", which the other two terms cannot.

Frames are normalized to one vote and **never log-compressed**. Compressing raw magnitudes squashes loud passages harder than quiet ones.

The key type, Camelot and musical-name formatting and tag parsing live in `Audio/MusicalKey.h`. **TRAP: a `VibeMusicalKey` of 0 is C major** (root `AGENTS.md`). `CodableAudioWaveform.key`, `AudioTrackMetadata.key` and `AudioTrack.detectedKey` are each set to `VibeMusicalKeyNone` explicitly.

## Cost

Both analyzers together run at roughly 6,000x realtime in Release, about a fifth of the decode they ride. The loader pipelines the decode against them, so they add CPU but no wall time. `scan_bpm`/`scan_key` report the `streamSeconds`/`finishSeconds` split, in Debug, where `-O0` inflates everything but vDSP.

What is left in each is almost all FFT: 172 1024-point ones a second for tempo, 2.7 32768-point ones for key. Cheaper means fewer or smaller frames. **The tempo analyzer decimates a file at 88.2 kHz or more by a power of two first** (a windowed-sinc FIR through `vDSP_desamp`, its history carried across appends), since its frame and hop are in samples. At 96 kHz that halves its cost with Accuracy1 unchanged. 44.1 and 48 kHz files take no filter and no copy.

Four measured rules hold the current floor:

- **Every per-bin or per-sample reduction goes through vDSP**, never a written-out loop. A per-sample branch does not predict, and a single accumulator serializes on float-add latency.
- **Touch only the band that votes.** The key's chroma band is a sixth of its spectrum, and the magnitude and fold passes run over it alone.
- **A scatter becomes a run.** Within the band each semitone's bins are contiguous, so the chroma fold is one reduction per semitone. The phase comb is swept **a beat at a time rather than a phase at a time**: one vDSP add per beat scores every phase at once.
- **`vDSP_DFT` is not a drop-in win over `vDSP_fft_zrip`.** It takes a third off the key's 32768-point frames and *loses* on tempo's 1024-point ones. Microbenchmarks mislead here. Measure a real decode.

**Decimating for the key analyzer would not make it cheaper**, despite its 3520 Hz ceiling. Even a short FIR runs on every sample and would cost more than the whole analyzer, which pays for its big FFT only 2.7 times a second.

## Measuring

For a quick signal with no app and no dataset, use the `vibe-debug` skill's `scan-bpm.sh` and `scan-key.sh` on the generated `bpm-*.wav` and `key-*.wav` loops. The `bpm-*.wav` loops double as the atonal case for key. Both verbs run in the CLI client's own process.

Real accuracy is GiantSteps. **Re-run it after any analyzer change**:

```bash
scripts/validate-tempo.py --jobs 6            # ~35s for the full set; --sample N for a quick signal
scripts/validate-key.py   --jobs 6
```

Neither dataset is vendored. Point `--dataset` at a local clone with audio downloaded. Tempo scores the MIREX metrics (Accuracy1 within 4%, Accuracy2 forgiving 1/3, 1/2, 2, 3x). Key scores the MIREX weighting (1.0 exact, 0.5 fifth, 0.3 relative, 0.2 parallel). The baseline: **tempo Accuracy1 85.1%, Accuracy2 92.6%** over 652 files; **key 61.3% weighted, 54.7% exact** over 602 files.

Both analyzers rely on one framing guarantee: the buffer sizes the decoder hands an analyzer never reach its result. `Tests/Audio/Analysis/AudioBPMAnalyzerTests.mm` and `Tests/Audio/Analysis/AudioKeyAnalyzerTests.mm` pin it end to end with synthetic signals in arbitrary chunk sizes. It lives in `AnalysisFramerMath.h`, which frames a mono stream into fixed windows at a fixed hop. It splices only the frames that straddle a buffer boundary and reads every later one in place. It is C++, included only by the two analyzers. `Tests/Audio/Analysis/AnalysisFramerMathTests.mm` pins the arithmetic directly.

**TRAP: `0 < hopSize <= frameSize` is a precondition of that arithmetic.** Past it, a short buffer wraps `frameCount - base` into a huge resize and an overread, and a zero hop never advances. Both analyzers satisfy it, and the guard gives a future caller nothing rather than undefined behavior.

## Measured worse — do not retry blind

For key: narrowing the chroma band; restricting to spectral peaks (the run-at-a-time fold cannot express a per-bin test); log-compressing the chroma at any strength; and the Krumhansl-Kessler, Temperley and flat-diatonic profile pairs.

**Tuning correction is not worth building.** The mean offset from equal temperament (`AudioKeyAnalyzer.tuningCents`, also in the `scan_key` reply) is −0.2 cents median over the corpus and never exceeds ±1.8. It cannot see gross detuning: a track more than `kMaxCentsFromSemitone` (35) off has every bin rejected and shows no key.
