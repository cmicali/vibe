# Future: improving tempo detection accuracy

Written 2026-08-11, when `AudioBPMAnalyzer` scored **Accuracy1 85.1%, Accuracy2 92.6%** over the 652 scorable files of the GiantSteps tempo dataset (annotations v2). Re-measure before acting on any of this: `scripts/validate-tempo.py --jobs 6` takes about 35 seconds for the full set.

## Where the remaining error actually is

97 files fail Accuracy1: **49 octave errors** (47 double, 2 half), **36 metrical-but-not-octave** (21 of them exactly 3:4 or 4:3), and **12 with no tempo returned**.

Per-genre Accuracy1 splits the corpus almost perfectly in two:

| Steady four-to-the-floor | | Broken beat | |
| --- | --- | --- | --- |
| psy-trance, deep-house, tech-house | 100% | drum-and-bass | 81.9% |
| trance | 98.6% | dubstep | 77.6% |
| house, electro-house, progressive-house | 95–96% | electronica | 65.4% |
| techno | 93.3% | glitch-hop | 58.8% |

**This is the finding that should drive the work.** The analyzer is at its ceiling on four-to-the-floor material and loses 20–40 points on syncopated material. Anyone weighing the effort below should first ask which of those the app's listeners actually play.

## Two things already tried, so they are not tried again

**Parameter tuning is at its frontier.** `kTempoPriorCenterBPM` and `kGridNormExponent` both control the same halves-against-doubles trade-off — the prior by placing the octave crossover at 4/3 of its center, the exponent by setting how much weaker the in-between beats may be before the faster grid loses. Sweeping them jointly (centers 120–145, exponents 0.25–0.5) found a single frontier with its peak at the current 140/0.5; every other combination trades halves for doubles at a net loss.

**Candidate coverage is not the bottleneck.** 21 failures land on exactly 3:4 or 4:3, and the synthesized relatives in `finish` are `{1/2, 2, 2/3, 3/2}` — no 3/4 or 4/3, which looks like the true tempo never reaching the phase comb. Adding both factors changed nothing (85.1% → 85.0%, 2 fixed against 3 regressed, the 3:4 error count unmoved) and cost 6% more CPU. **The true tempo is already being scored and the comb is choosing wrong**, so the problem is the discriminative quality of the evidence, not the search.

## Proposal 1: a multi-band onset envelope

The standard next step, and the one that targets the failing genres directly.

`processFrame` currently sums half-wave-rectified spectral flux across every bin into **one** broadband envelope. In four-to-the-floor music that is enough, because the kick alone carries the beat. In drum and bass, dubstep and glitch-hop the kick, snare and hats carry *different* periodicities, and summing them into one envelope destroys exactly the evidence needed to settle an octave: a broadband envelope cannot tell "kick every beat plus snare on the offbeat" (one tempo) from "kick and snare alternating" (half that tempo).

Sketch:

- Split the spectrum into 3–4 bands — roughly below 100 Hz, 100–800 Hz, 800–4000 Hz, above 4000 Hz — and accumulate one flux envelope per band. Memory is a few hundred KB an hour per band, so keeping all of them is free.
- In `finish`, run the existing detrend, autocorrelation and comb per band, then combine. The combination is the design decision worth prototyping more than one of: summing per-band comb scores is the simplest; summing the *normalized* scores stops a loud band dominating; scoring the phase comb per band and voting is the most robust and the most expensive.
- Keep the phase comb's fractional-period refinement on the combined winner, since that is about precision rather than octave choice and already lands within ±0.01 BPM.

Expect the current constants to need re-sweeping afterwards: a better octave discriminator should let `kTempoPriorCenterBPM` move back toward neutral, which is what would recover the 47 double errors on slow material without giving back the drum-and-bass gains. **That recovery, not the raw accuracy number, is the real prize** — it would remove the current deliberate trade where sub-100 BPM tracks read as their double.

Cost: streaming work scales with band count in the flux loop, but the FFT — the expensive part — is shared, so expect well under 4x on the 0.97 ms per audio-second the analyzer spends today. Measure with `dump_timing` or the `timing` object on `scan_bpm`.

Risk: moderate. It is a real change to a carefully tuned algorithm and it can come out worse. The validation harness makes that safe to discover — one build plus 35 seconds per experiment.

## Proposal 2: a learned model (CNN)

Every method above the mid-80s on this dataset is learned. Schreiber and Müller's CNN reaches roughly 87% Accuracy1 and 97% Accuracy2; the classical DSP family, which is what we are, tops out around where we are now. Accuracy2 is the telling gap: ours is 92.6% against their ~97%, and Accuracy2 failures are estimates that are wrong in a way no octave correction can excuse.

If that gap ever matters, the shape of the work:

- **Inference** is the easy half. Core ML runs a small tempo CNN on the Neural Engine in far less time than the current DSP path, it is public API, and it ships in the App Store without trouble. A mel-spectrogram front end can reuse the existing decode pass, so this still costs no second file read.
- **The model is the hard half.** Training needs a corpus and a pipeline neither of which exist here, and shipping someone else's weights means auditing their license — several published tempo models are research-only. `THIRD-PARTY-NOTICES.md` and the vendored-code rules in `ThirdParty/CLAUDE.md` apply to weights as much as to source.
- **Size and honesty about the payoff.** A tempo CNN is small, a few MB, so bundle size is not the objection. The objection is that it buys perhaps two points of Accuracy1 over a well-executed multi-band DSP analyzer, for a dependency on a trained artifact that cannot be reasoned about or hand-tuned the way the current 400 lines can.

**Do proposal 1 first.** It is cheap, it is reversible, it targets the same failures, and if it lands near 90% the case for a model largely evaporates.

## Not worth doing

**Do not tune `kMinConfidence` against this dataset.** Every GiantSteps track has a real tempo, so the corpus cannot measure the cost of a looser gate — optimizing against it would only teach the analyzer to always answer, and the gate exists to protect ambient, speech and rubato, which the dataset contains none of. Tuning it needs negative examples we do not have.
