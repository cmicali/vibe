---
name: vibe-perf
description: Measure Vibe's performance in-process and compare two versions of the code — VibeBenchComponents, a micro-benchmark tool that drives the production decode, open, seek, resample, waveform, tempo/key, equalizer-meter, metadata-parse and cache-key code (and any area a benchmark file adds) with no app running, counting retired instructions as well as wall and CPU time; perf.py, which builds it at any git ref and runs two refs interleaved; profile.sh, which samples one benchmark to find its hotspots; and --analyze, which prints every file's tempo and key so an analyzer change can be proven exact. Use when asked to update, rerun or regenerate the performance page (docs/performance.md) for a release, a pre-release or a new machine, and before and after any change that could move cost, to find where time goes, to decide between two implementations, or to back a performance claim with numbers. Also runs these component benchmarks at every release back to 1.8 for the performance page's Components charts, pre-releases included (make bench-components-releases, perf.py releases), and documents the whole performance page: the app benchmarks (startup, time to play, playback CPU and energy, library scan; make bench-app) and both together (make bench-releases).
---

# Measuring performance

Two benchmark suites, two questions, one set of names:

| | **Component benchmarks** | **App benchmarks** |
| --- | --- | --- |
| Question | What does *this code* cost? | What does *the app* cost, as a user feels it? |
| What runs | VibeBenchComponents (`Tests/BenchComponents/`): the production code in-process, one benchmark at a time; no app, audio device or window | Each version's own app (`scripts/bench/`), launched and driven over and over |
| Measures | Decode, open, seek, resample, waveform, tempo and key, the meter, metadata, the disk cache, large libraries, UI cells; instructions retired, CPU and wall time | Startup, time to play, seek latency, playback CPU, energy and wakeups, memory, library scan |
| Cost | Seconds to minutes; stable on a busy Mac | About half an hour a version; the Mac must be left alone |
| Compare two refs | `make bench-components [BASE=main]` | — |
| Every release, on `docs/performance.md` | `make bench-components-releases` | `make bench-app` |

`make bench-releases` runs both at every release, and `make bench-report` redraws the page from what is stored. Use the component benchmarks to find and fix; use the app benchmarks to report what a user would feel.

## Common requests

Plain requests map to one command each. Run the matching one with the procedure below; don't improvise a sequence.

| Request | Command |
| --- | --- |
| "Add release 1.16 to the performance page" | `make bench-releases VERSIONS="1.16"`, or each half on its own Mac (below) |
| "Chart this branch as a pre-release" / "add the latest 1.16" | `VERSIONS="HEAD"`, charted as `1.16 pre-release` |
| "Rerun 1.13, 1.14 and the latest 1.15" | `VERSIONS="1.13 1.14 HEAD"` |
| "Replace the pre-release now that 1.16 is tagged" | `VERSIONS="1.16"` (the tag outranks the stored commit) |
| "This is a new Mac: regenerate the whole page" | `make bench-releases`, no `VERSIONS` |
| "Just redraw the page" | `make bench-report` |
| "Is my change faster than main?" | `make bench-components` (compares refs; the page is untouched) |

**The page's two halves can live on different Macs.** Each half of `docs/performance.md` names the machine it was measured on, in its intro line and in `results.json`. Use `make bench-releases` (both halves) only on a Mac that matches both; otherwise run `make bench-app` on the Mac that holds **The app** and `make bench-components-releases` on the one that holds **Components**. The component benchmarks don't launch the app, so they can run on a Mac that's in use.

**The guard.** Before measuring, every release target compares this Mac (chip, cores, memory, macOS, Xcode) and its corpus against the history it is adding to. If they differ and the run would leave versions behind, it refuses and prints what differs: the page charts only versions measured on the newest entry's setup, so a run on the wrong Mac, or after a macOS or Xcode update, would silently take every version it didn't rerun off the page. When it refuses, report the differences and stop. Rerunning every version (no `VERSIONS`) always passes; pass `ARGS="--new-machine"` only when the user says to start that half's history on this Mac.

### Procedure

1. **Get the commands and the tags:** `git fetch origin --tags`, and work on the branch the user names (default `main`; the commands are in this skill's tree). Check that each `v<version>` you will measure exists, unless it is a pre-release.
2. **Prerequisites:** Xcode, `make setup` (xcodegen and the rest) and `brew install ffmpeg`. The corpus is generated on first use.
3. **For the app benchmarks only:** the Mac on power, output on the built-in speakers (put Bluetooth headphones away; the AirPods are often the default), Vibe quit, and nothing else using the Mac: every launch takes focus, and the runner waits for the machine to be 80% idle before each scenario.
4. **Run it in the background under `caffeinate -dimsu`**, with a Monitor on its output, and relay each version's lines (`1.14 rep 2/5 playback: 244s`, `1.14: VibeBenchComponents, 32 benchmarks`) as they land. The app benchmarks take about half an hour a version, longer on slower Macs; the component benchmarks a few minutes. Each version is saved as it finishes, so an interrupted run loses only the version in progress.
5. **Verify:** the run ends with `report: N versions, M charts` and no `leaving out` line; each measured entry in `results.json` has the expected `ref`, `commit` and `prerelease`. Show the user the changed columns of the page's table.
6. **Commit** `docs/performance.md` and `docs/performance/` with a message naming the versions and the machine, and push. No attribution lines.

## Comparing two refs

```bash
make bench-components                              # main vs the working tree, everything
make bench-components BASE=v1.14                   # another base
python3 .claude/skills/vibe-perf/scripts/perf.py compare main --filter '^decode\.'  # one group
python3 .claude/skills/vibe-perf/scripts/perf.py run --filter metadata             # just measure the working tree
python3 .claude/skills/vibe-perf/scripts/perf.py list                              # benchmark names
.claude/skills/vibe-perf/scripts/profile.sh '^key.flac-16-44' 6                    # where one benchmark's time goes
```

`make bench-components` is `perf.py compare BASE`. `compare BASE [HEAD]` builds VibeBenchComponents for each side (a ref once per commit under `build/bench-components/bin/`, the working tree incrementally in `build/BenchComponentsDerivedData`), runs them alternately `--rounds` times (default 3) × `--reps` (default 3), and prints a table of medians — instructions, CPU, wall — and their change. `--md OUT` also writes it as markdown; `build/bench-components/last-compare.json` keeps every sample. A side can be `bin:<path>`, a VibeBenchComponents built some other way (a build-setting experiment: after any `perf.py build`, `xcodebuild -project VibeBenchComponents.xcodeproj -scheme VibeBenchComponents -configuration Release GCC_OPTIMIZATION_LEVEL=3 -derivedDataPath build/bench-components/dd-O3`).

**Any ref back to 1.8 runs today's harness.** `perf.py` grafts the working tree's `Tests/BenchComponents/` onto the ref's checkout and writes `VibeBenchComponentsFeatures.h` from that checkout's sources (`VibeBenchComponents.h` lists the questions: the player's reader, `AVAudioFile` before 1.14; the waveform loader's class; the analysis provider, settings before 1.10; the metadata parse's shape; the meter's). The tool's target is never written down: `tool_spec` derives it, for the working tree as for any ref, from that checkout's own app target (`xcodegen dump`, so 1.8's flat layout builds as it was, and today's cannot drift from the app), into `VibeBenchComponents.xcodeproj` beside the sources (gitignored; the app's `Vibe.xcodeproj` is left alone). An older ref builds without warnings as errors. **A benchmark file the ref cannot compile is left out of that build** and named in the output; the core (`VibeBenchComponents.mm`, `VibeBenchComponents.h`) never is. That is why benchmarks live one subsystem to a file: a version missing one loses only that file. Binaries are cached per commit and harness digest under `build/bench-components/bin/`.

The corpus is the app benchmarks' (`build/bench/corpus`: the play files, a 600-file tagged library) plus a few formats it lacks (`extra/`: 16-bit WAV and AIFF, ALAC, Opus, Vorbis), generated once with ffmpeg by `perf.py corpus`, which every command runs first. A benchmark whose file is missing is skipped, not failed.

## Charting every release on the performance page

`docs/performance.md` has two sets of charts: **The app** (the app benchmarks) and **Components** (the component benchmarks). This skill owns the second: `perf.py releases` measures each version, and `PAGE_CHARTS` in `perf.py` decides what is measured and drawn.

### Generating it

```bash
make bench-components-releases VERSIONS="1.16"         # a new release: tag v1.16, measured, stored, page redrawn
make bench-components-releases VERSIONS="HEAD"         # this checkout before its release: "1.15 pre-release" today
make bench-components-releases VERSIONS="1.16=<ref>"   # any commit, under that version
make bench-components-releases                         # every version already on the page, again
make bench-components-releases VERSIONS="HEAD" ARGS="--reps 1"   # a quick look; the page uses 5
make bench-releases VERSIONS="1.16"                    # the app benchmarks, then these, in one command
make bench-report                                      # redraw the page from results.json, measuring nothing
```

`make bench-components-releases` is `perf.py releases`; `make bench-releases` is `scripts/bench/bench.py all`, which calls the same code after the app benchmarks. A version takes a few minutes; its first build takes longer, and a rerun with the same harness reuses it. No app launches, so the Mac can be in use, though a busy machine adds noise to CPU and wall time (the page charts those; instructions retired, stored beside them, barely move).

**What a version is.** `1.16` is the release tag `v1.16` (or the ref already stored for it), `1.16=<ref>` that version at any commit, and a bare ref such as `HEAD` is labelled with the version its own `project.yml` declares (`MARKETING_VERSION`). **When `v<version>` is not tagged yet, the version is a pre-release**: the run is stored with `prerelease: true` and charted as `1.15 pre-release`. Once the release is tagged, `make bench-releases VERSIONS="1.15"` measures the tag and replaces the pre-release point.

Before running:

1. **The version must resolve to a git commit**, a tag or the ref given.
2. **`ffmpeg` must be installed** (`brew install ffmpeg`): the corpus is generated from it once, into `build/bench/corpus`.
3. **Use one Mac for each half's history.** Each entry records the machine, and the page charts only versions measured on the same setup as the newest; the guard (Common requests, above) refuses a run that would break that. After moving to another Mac, rerun every version (no `VERSIONS`).

Then commit `docs/performance/results.json`, the redrawn `docs/performance/*.svg` and `docs/performance.md`.

### What happens, step by step

For each version, `measure_release` in `perf.py`:

1. **Checks the commit out** as a detached worktree under `build/bench-components/src/<commit>`.
2. **Grafts today's harness onto it** (`build`, `graft`): copies the working tree's `Tests/BenchComponents/` in, writes `VibeBenchComponentsFeatures.h` from what that version's sources have (`features`), and derives the tool's target from that version's own app target with `xcodegen dump` (`tool_spec`), so even 1.8's flat source layout builds as it shipped.
3. **Builds it Release, leaving out what it cannot compile.** A benchmark file that fails against the old code is deleted from that checkout and the build retried; the output names it. The binary is cached under `build/bench-components/bin/<commit>-<harness digest>/`.
4. **Runs only the page's benchmarks** (`page_filter`, every name in `PAGE_CHARTS`), five repetitions, and stores the medians — CPU ms, wall ms, millions of instructions, units — with the commit, `prerelease`, date, corpus hash, machine and harness digest, under the version in `results.json`'s `components` section. A benchmark the version cannot build is absent, not zero, so its line starts at the first version that has the code.
5. **Redraws the page** (`scripts/bench/report.py`): one SVG per `PAGE_CHARTS` entry into `docs/performance/components-*.svg`, and the block between the page's `<!-- performance:begin -->` and `<!-- performance:end -->` markers, the app benchmarks' charts included.

### Changing what the page shows

`PAGE_CHARTS` is the only list. Each entry is `(svg name, title, unit, [(benchmark, measure, legend)], decimals)`, at most four series; the measures (`cpu_per_minute`, `cpu_per_unit`, `wall_per_unit`, `us_per_unit`, `wall`, `wall_s`) are `page_value`'s. Adding a series or a chart means adding it there and running `make bench-components-releases` with no `VERSIONS`, so every version gets the new benchmark; one the old versions cannot build simply starts late. A new benchmark *file* also has to build against old code, which is "Adding a benchmark" below.

### When it goes wrong

- **A version fails to build at all** (not just a benchmark file): the log is `build/bench-components/dd/<commit>.log`. Usually that version's code has a shape the harness assumes; add a flag to `VibeBenchComponents.h`'s list and its detection to `features()`.
- **A chart is missing a version**: that version was measured on another machine or corpus; rerun it here.
- **The guard refuses**: this Mac or its corpus doesn't match the history (it prints what differs). Run on the matching Mac, rerun every version, or, if the user says so, `ARGS="--new-machine"`.
- **A version's numbers jump with no code change**: the harness changed under it (the digest is in its entry). Rerun every version so they share one harness.

## Reading the numbers

**Instructions retired is the number to trust.** It comes from `proc_pid_rusage` for the whole process, so it covers every thread a benchmark starts (the waveform loader's pipeline, ImageIO's workers), and the machine's load and clock barely move it — a stress run or a build beside it changes wall time by tens of percent and instructions by under one. CPU and wall time are what a user feels; read them for the direction and to catch a change that retires fewer instructions but runs slower (it happens: strided vDSP calls fall off the vector path, and small misaligned vDSP calls lose to a memcpy plus one aligned pass — both measured). A difference under ~2% in instructions is noise for anything that calls Apple's decoders (AAC, ALAC, Ogg), which vary run to run.

The `per unit` column is realtime factor (audio seconds per CPU second) for audio work, ms per operation otherwise.

## Proving a change exact

`VibeBenchComponents --analyze <folder>` runs every audio file under it through the production waveform loader with both analyzers and prints `name<TAB>bpm<TAB>key`, the tempo to nine significant digits. Run it at both refs over the GiantSteps sets (`~/projects/giantsteps-tempo-dataset`, `~/projects/giantsteps-key-dataset`; about ten seconds for all 1,257 files) and `cmp` the outputs: an analyzer change that is meant to be exact must leave them identical. A change meant to move the answers is `scripts/validate-tempo.py` / `validate-key.py`'s job (`Audio/Analysis/AGENTS.md`).

## Adding a benchmark

One file per subsystem in `Tests/BenchComponents/`, registered from a static constructor, so adding one touches nothing else, and an older version that lacks the subsystem drops only that file. Code that reads a file goes through `VibeBenchComponentsReader` and loads a waveform through `VibeBenchComponentsWaveformLoader`, so it measures each version's own reader and loader; a shape that changed between versions gets a flag in `VibeBenchComponents.h`'s list and its detection in `perf.py`'s `features()`.

```objc
#import "VibeBenchComponents.h"

static void VibeBenchComponentsRegisterThings(void) {
    auto file = std::make_shared<VibeBenchComponentsFileState>();
    VibeBenchComponentsAdd("things", "flac-16-44", "op",
        [file]() -> double { file->path = VibeBenchComponentsFile(@"flac-16-44"); return file->path ? 10 : -1; },
        [file]() { for (int i = 0; i < 10; i++) { /* the production call */ } });
}
VIBE_BENCH_COMPONENTS_REGISTER(VibeBenchComponentsRegisterThings)
```

`prepare` runs outside every measurement and answers the units of work one repetition does (or a negative number to skip); `body` is one measured repetition, run once to warm up first. State the two share goes in a `shared_ptr`, never a reference to a loop local. `VibeBenchComponentsDecoded(name)` hands a file decoded once to float32 (interleaved, mono, left, right) for benchmarks that start from PCM. The target compiles every source the macOS app does but `main.m`, so views, layers, renderers and cells can be driven offscreen too.

**Commit a new benchmark before the change it measures**, so base and head run the same body.

## Traps

**TRAP: VibeBenchComponents is built Release, as the app ships (`-Os`).** At `-Os` a `std::vector` insert or assign of floats is an element loop, not a memmove — it was a fifth of the key analyzer. Benchmark Release; a Debug build's numbers mean nothing here.

**A whole-app `-O2` or `-O3` is not a win**: measured, it moves nothing, because the hot paths are vDSP and the third-party decoders and resampler, which already build at `-O3`.

**Never launch the app from here.** VibeBenchComponents is its own process with its own defaults domain and touches no app state; the app benchmarks' app runs as `VibeBenchApp` with its own bundle identifier, home and channel directory, so neither collides with a `Vibe` instance another session is stressing (which matches `pgrep -x Vibe`).
