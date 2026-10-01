---
name: vibe-perf
description: Measure Vibe's performance in-process and compare two versions of the code — VibePerf, a micro-benchmark tool that drives the production decode, open, seek, resample, waveform, tempo/key, equalizer-meter, metadata-parse and cache-key code (and any area a benchmark file adds) with no app running, counting retired instructions as well as wall and CPU time; perf.py, which builds it at any git ref and runs two refs interleaved; profile.sh, which samples one benchmark to find its hotspots; and --analyze, which prints every file's tempo and key so an analyzer change can be proven exact. Use before and after any change that could move cost, to find where time goes, to decide between two implementations, or to back a performance claim with numbers. The app-level suite (startup, time to play, playback CPU, library scan over released versions) is `make bench`, docs/performance.md.
---

# Measuring performance

Two suites, two questions:

- **VibePerf** (`Tests/Perf/`, this skill): what does *this code* cost? Production code in-process, one benchmark at a time, no app, no audio device, no window. Seconds to run, stable on a loaded machine, any two refs comparable.
- **`make bench`** (`scripts/bench/`, `docs/performance.md`): what does *the app* cost? Launches each version's own app over and over against one corpus; startup, time to play, seek latency, playback CPU, wakeups, memory, library scan. Half an hour a version, wants the Mac quiet.

Use VibePerf to find and fix; use `make bench` to report what a user would feel.

## Running it

```bash
python3 .claude/skills/vibe-perf/scripts/perf.py compare main                    # main vs the working tree, everything
python3 .claude/skills/vibe-perf/scripts/perf.py compare main --filter '^decode\.' # one group
python3 .claude/skills/vibe-perf/scripts/perf.py run --filter metadata           # just measure the working tree
python3 .claude/skills/vibe-perf/scripts/perf.py list                            # benchmark names
.claude/skills/vibe-perf/scripts/profile.sh '^key.flac-16-44' 6                  # where one benchmark's time goes
```

`compare BASE [HEAD]` builds VibePerf for each side (a ref once per commit under `build/perf/bin/`, the working tree incrementally in `build/PerfDerivedData`), runs them alternately `--rounds` times (default 3) × `--reps` (default 3), and prints a table of medians — instructions, CPU, wall — and their change. `--md OUT` also writes it as markdown; `build/perf/last-compare.json` keeps every sample. A side can be `bin:<path>`, a VibePerf built some other way (a build-setting experiment: `xcodebuild ... -scheme VibePerf GCC_OPTIMIZATION_LEVEL=3 -derivedDataPath build/perf/dd-O3`).

**Any ref back to 1.8 runs today's harness.** `perf.py` grafts the working tree's `Tests/Perf/` onto the ref's checkout and writes `VibePerfFeatures.h` from that checkout's sources (`VibePerf.h` lists the questions: the player's reader, `AVAudioFile` before 1.14; the waveform loader's class; the analysis provider, settings before 1.10; the metadata parse's shape; the meter's). When the ref's spec has no `VibePerf` target, it derives one from the ref's own app target (`xcodegen dump`, so 1.8's flat layout builds as it was), and builds without warnings as errors. **A benchmark file the ref cannot compile is left out of that build** and named in the output; the core (`VibePerf.mm`, `VibePerf.h`) never is. That is why benchmarks live one subsystem to a file: a version missing one loses only that file. Binaries are cached per commit and harness digest under `build/perf/bin/`.

**The performance page charts it.** `make bench` and `make bench-rerun` run the suite against each version after the app suite, and `make bench-perf` runs it alone (no app launches, so the Mac can be in use), into `results.json`'s `perf` section; `scripts/bench/report.py`'s `PERF_CHARTS` draws the "Inside the app" charts on `docs/performance.md` from it. `bench.py`'s `PERF_FILTER` is the set it runs; a new benchmark joins the page only by being in both.

The corpus is `make bench`'s (`build/bench/corpus`: the play files, a 600-file tagged library) plus a few formats it lacks (`extra/`: 16-bit WAV and AIFF, ALAC, Opus, Vorbis), generated once with ffmpeg by `perf.py corpus`, which every command runs first. A benchmark whose file is missing is skipped, not failed.

## Reading the numbers

**Instructions retired is the number to trust.** It comes from `proc_pid_rusage` for the whole process, so it covers every thread a benchmark starts (the waveform loader's pipeline, ImageIO's workers), and the machine's load and clock barely move it — a stress run or a build beside it changes wall time by tens of percent and instructions by under one. CPU and wall time are what a user feels; read them for the direction and to catch a change that retires fewer instructions but runs slower (it happens: strided vDSP calls fall off the vector path, and small misaligned vDSP calls lose to a memcpy plus one aligned pass — both measured). A difference under ~2% in instructions is noise for anything that calls Apple's decoders (AAC, ALAC, Ogg), which vary run to run.

The `per unit` column is realtime factor (audio seconds per CPU second) for audio work, ms per operation otherwise.

## Proving a change exact

`VibePerf --analyze <folder>` runs every audio file under it through the production waveform loader with both analyzers and prints `name<TAB>bpm<TAB>key`, the tempo to nine significant digits. Run it at both refs over the GiantSteps sets (`~/projects/giantsteps-tempo-dataset`, `~/projects/giantsteps-key-dataset`; about ten seconds for all 1,257 files) and `cmp` the outputs: an analyzer change that is meant to be exact must leave them identical. A change meant to move the answers is `scripts/validate-tempo.py` / `validate-key.py`'s job (`Audio/Analysis/AGENTS.md`).

## Adding a benchmark

One file per subsystem in `Tests/Perf/`, registered from a static constructor, so adding one touches nothing else, and an older version that lacks the subsystem drops only that file. Code that reads a file goes through `VibePerfReader` and loads a waveform through `VibePerfWaveformLoader`, so it measures each version's own reader and loader; a shape that changed between versions gets a flag in `VibePerf.h`'s list and its detection in `perf.py`'s `features()`.

```objc
#import "VibePerf.h"

static void VibePerfRegisterThings(void) {
    auto file = std::make_shared<VibePerfFileState>();
    VibePerfAdd("things", "flac-16-44", "op",
        [file]() -> double { file->path = VibePerfFile(@"flac-16-44"); return file->path ? 10 : -1; },
        [file]() { for (int i = 0; i < 10; i++) { /* the production call */ } });
}
VIBE_PERF_REGISTER(VibePerfRegisterThings)
```

`prepare` runs outside every measurement and answers the units of work one repetition does (or a negative number to skip); `body` is one measured repetition, run once to warm up first. State the two share goes in a `shared_ptr`, never a reference to a loop local. `VibePerfDecoded(name)` hands a file decoded once to float32 (interleaved, mono, left, right) for benchmarks that start from PCM. The target compiles every source the macOS app does but `main.m`, so views, layers, renderers and cells can be driven offscreen too.

**Commit a new benchmark before the change it measures**, so base and head run the same body.

## Traps

**TRAP: VibePerf is built Release, as the app ships (`-Os`).** At `-Os` a `std::vector` insert or assign of floats is an element loop, not a memmove — it was a fifth of the key analyzer. Benchmark Release; a Debug build's numbers mean nothing here.

**A whole-app `-O2` or `-O3` is not a win**: measured, it moves nothing, because the hot paths are vDSP and the third-party decoders and resampler, which already build at `-O3`.

**Never launch the app from here.** VibePerf is its own process with its own defaults domain and touches no app state; `make bench`'s app runs as `VibeBench` with its own bundle identifier, home and channel directory, so neither collides with a `Vibe` instance another session is stressing (which matches `pgrep -x Vibe`).
