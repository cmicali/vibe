# Future: improving tempo detection accuracy

**Status: Not built.** The baseline: `AudioBPMAnalyzer` scored **Accuracy1 85.1%, Accuracy2 92.6%** over the 652 scorable files of the GiantSteps tempo dataset (annotations v2). The current prior center and grid exponent are 140 BPM and 0.5. Re-measure before acting with `scripts/analysis/validate-tempo.py --jobs 6`. How the analyzer works is `Audio/Analysis/AGENTS.md`.

## Where the error is

97 files fail Accuracy1: 49 octave errors (47 double, 2 half), 36 metrical but not octave (21 of them exactly 3:4 or 4:3), and 12 with no tempo.

| Steady four-to-the-floor | Accuracy1 | Broken beat | Accuracy1 |
| --- | --- | --- | --- |
| psy-trance, deep-house, tech-house | 100% | drum-and-bass | 81.9% |
| trance | 98.6% | dubstep | 77.6% |
| house, electro-house, progressive-house | 95–96% | electronica | 65.4% |
| techno | 93.3% | glitch-hop | 58.8% |

These measurements suggest testing multi-band evidence on syncopated material. Re-run the baseline before comparing a change.

## Already tried, so not tried again

**Parameter tuning is at its frontier.** `kTempoPriorCenterBPM` and `kGridNormExponent` both set the halves-against-doubles trade. A joint sweep (centers 120 to 145, exponents 0.25 to 0.5) peaks at the current 140/0.5. Every other combination trades halves for doubles at a net loss.

**Candidate coverage is not the bottleneck.** Adding 3/4 and 4/3 to the relatives `finish` synthesizes changed nothing (85.1% to 85.0%) and cost 6% more CPU. The true tempo is already scored, and the comb chooses wrong. The problem is the quality of the evidence, not the search.

## Proposal 1: a multi-band onset envelope

`processFrame` sums rectified spectral flux across every bin into one broadband envelope. In four-to-the-floor music the kick alone carries the beat, so that is enough. In drum and bass, dubstep and glitch-hop, the kick, snare and hats carry different periodicities. One envelope cannot tell "kick every beat plus snare on the offbeat" from "kick and snare alternating", which is half that tempo.

- Split the spectrum into 3 or 4 bands: roughly below 100 Hz, 100 to 800 Hz, 800 to 4000 Hz, and above 4000 Hz. Keep one flux envelope per band, a few hundred KB an hour each.
- In `finish`, run the detrend, autocorrelation and comb per band, then combine. Prototype more than one combination: summed scores, summed normalized scores, or a per-band phase comb that votes.
- Keep the fractional-period refinement on the combined winner.

Then re-sweep the constants. A better octave discriminator should let `kTempoPriorCenterBPM` move toward neutral. That would recover the 47 double errors on slow material without losing the drum-and-bass gains. **That recovery is the real prize.** It would remove the deliberate trade where sub-100 BPM tracks read as their double.

Cost: the flux loop scales with band count, and the FFT is shared. Measure with `make bench-components` and the `timing` object of `scan_bpm`. BPM detection runs on iOS too, so measure on a phone, where its cost lands on battery.

Risk: moderate. It can come out worse. One build and a corpus run per experiment makes that safe to find out.

## Proposal 2: a learned model

A learned tempo model is another option if the multi-band experiment does not meet the accuracy goal. Compare candidates on the same files before choosing one.

- **Measure inference.** Prototype a Core ML model and its spectrogram front end on a phone.
- **The model is hard.** Training needs a corpus and a pipeline that do not exist here. Several published tempo models are research-only. `THIRD-PARTY-NOTICES.md` and vibe-libs' rules for `third_party/` apply to weights as much as to source.
- **The payoff is unmeasured.** Compare accuracy, runtime and model size with the multi-band result.

**Do proposal 1 first.** It is cheap and reversible, and it targets the same failures. If it lands near 90%, the case for a model largely goes away.

## Not worth doing

**Do not tune `kMinConfidence` against this dataset.** Every GiantSteps track has a real tempo, so the corpus cannot measure the cost of a looser gate. The gate protects ambient, speech and rubato material, which the dataset lacks. Tuning it needs negative examples.
