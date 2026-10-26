---
name: vibe-perf
description: Measure Vibe's performance and compare two versions of the code. VibeBenchComponents drives the production decode, open, seek, resample, pitch, waveform, tempo/key, meter, metadata and cache code in-process with no app, counting retired instructions as well as wall and CPU time; perf.py builds it at any git ref and runs two refs interleaved (make bench-components); profile.sh finds one benchmark's hotspots; --analyze proves an analyzer change exact. Also owns the performance page (docs/performance.md): component charts per release (make bench-components-releases), app benchmarks (make bench-app), both (make bench-releases), redraw (make bench-report). Use before and after any change that could move cost, to find where time goes, to choose between implementations, to back a performance claim with numbers, or when asked to update, rerun or regenerate the performance page for a release, pre-release or new machine.
---

# Measuring performance

Two benchmark suites, two questions, one set of names:

| | **Component benchmarks** | **App benchmarks** |
| --- | --- | --- |
| Question | What does *this code* cost? | What does *the app* cost, as a user feels it? |
| What runs | VibeBenchComponents (`Tests/BenchComponents/`): the production code in-process, one benchmark at a time; no app or audio output; UI benchmarks can create windows | Each version's own app (`scripts/bench/`), launched and driven over and over |
| Measures | Decode, open, seek, resample, pitch, waveform, tempo and key, the meter, metadata, the disk cache, large libraries, UI cells; instructions retired, CPU and wall time | Startup, time to play, seek latency, playback CPU, energy and wakeups, memory, library scan |
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

**The page's two suites can live on different Macs.** The generated block at the top of `docs/performance.md` names each suite's machine, and so does `results.json`. Use `make bench-releases` (both suites) only on a Mac that matches both. Otherwise run `make bench-app` on the app benchmarks' Mac and `make bench-components-releases` on the component benchmarks' Mac. The component benchmarks don't launch the app, so they can run on a Mac that's in use.

**The guard.** Before measuring, every release target compares this Mac (chip, cores, memory, macOS, Xcode) and its corpus against the history it is adding to. If they differ and the run would leave versions behind, it refuses and prints what differs: the page charts only versions measured on the newest entry's setup, so a run on the wrong Mac, or after a macOS or Xcode update, would silently take every version it didn't rerun off the page. When it refuses, report the differences and stop. Rerunning every version (no `VERSIONS`) always passes; pass `ARGS="--new-machine"` only when the user says to start that half's history on this Mac.

### Procedure

1. **Get the commands and the tags:** `git fetch origin --tags`, and work on the branch the user names (default `main`; the commands are in this skill's tree). Check that each `v<version>` you will measure exists, unless it is a pre-release.
2. **Prerequisites:** Xcode, `make setup` (xcodegen and the rest) and `brew install ffmpeg`. The corpus is generated on first use.
3. **For the app benchmarks only:** the Mac on power, output on the built-in speakers (put Bluetooth headphones away; the AirPods are often the default), Vibe quit, and nothing else using the Mac: every launch takes focus, and the runner waits for the machine to be 80% idle before each scenario.
4. **Run it in the background under `caffeinate -dimsu`**, with a Monitor on its output, and relay each version's lines (`1.14 rep 2/5 playback: 244s`, `1.14: VibeBenchComponents, 32 benchmarks`) as they land. The app benchmarks take about half an hour a version, longer on slower Macs; the component benchmarks a few minutes. Each version is saved as it finishes, so an interrupted run loses only the version in progress.
5. **Verify:** the run ends with `report: N versions, M charts`, with no `leaving out` line and no `does not show` line. Each measured entry in `results.json` has the expected `ref`, `commit` and `prerelease`. Show the user the changed columns of the release table (`docs/performance/summary.svg`). A big move deserves a sentence in its section of the page, saying which change did it.
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

**A bare branch name means origin's branch.** `main` is `origin/main`, fetched first, because the checkout is shared and its own `main` goes stale. A branch origin lacks stays local. `heads/main` names the local branch on purpose. The run prints `main: origin/main` when it does this.

`make bench-components` is `perf.py compare BASE`. Each side is a git ref, read by the rule above. `compare BASE [HEAD]` builds VibeBenchComponents for each side (a ref once per commit under `build/bench-components/bin/`, the working tree incrementally in `build/BenchComponentsDerivedData`), runs them alternately `--rounds` times (default 3) × `--reps` (default 3), and prints a table of medians — instructions, CPU, wall — and their change. `--md OUT` also writes it as markdown; `build/bench-components/last-compare.json` keeps every sample. A side can be `bin:<path>`, a VibeBenchComponents built some other way (a build-setting experiment: after any `perf.py build`, `xcodebuild -project VibeBenchComponents.xcodeproj -scheme VibeBenchComponents -configuration Release GCC_OPTIMIZATION_LEVEL=3 -derivedDataPath build/bench-components/dd-O3`).

**Historical refs use today's harness where compatible.** `perf.py` grafts the working tree's `Tests/BenchComponents/` onto the ref's checkout. It writes `VibeBenchComponentsFeatures.h` from that checkout's sources (`VibeBenchComponents.h` lists the shapes it detects). `tool_spec` derives the tool's target from that checkout's own app target with `xcodegen dump`, into a gitignored `VibeBenchComponents.xcodeproj`, so the app's project is left alone. The tool leaves out the updater's template and builds the App Store channel (`VIBE_DIRECT_DISTRIBUTION=0`), so it links no Sparkle and needs no runpath. An older ref builds without warnings as errors. **A benchmark file the ref cannot compile is left out of that build** and named in the output. `compare` lists its benchmarks under "Not compared" as `base: not built`. A skipped benchmark reads `no result`. A filter matching neither side exits nonzero. Missing samples alone do not fail a comparison. Build and process failures can also end the command. The core (`VibeBenchComponents.mm`, `VibeBenchComponents.h`) is never left out. That is why benchmarks live one subsystem to a file: a version missing one loses only that file. Binaries are cached per commit and harness digest under `build/bench-components/bin/`.

**A renamed class keeps its old name in the harness, and nowhere else.** `perf.py` builds today's benchmarks against every ref back to 1.8. So each benchmark must compile under each ref's names. A benchmark that uses a renamed class imports the new header under `__has_include`. Its `#else` imports the old header and defines the new name to the old one (`#define VibePlaylist Playlist`). These fallbacks are the only old-name aliases in the repository. They are a harness rule, not app compatibility, and only `Tests/BenchComponents/` carries them. A rename adds one. A release that drops support for the refs a fallback serves removes it.

The corpus is the app benchmarks' (`build/bench/corpus`: the play files, a 600-file tagged library) plus formats it lacks (`extra/`: integer, float and 5.1 WAV, AIFF, CAF, Wave64, RF64, ALAC, Opus, Vorbis, ADTS AAC and MP2), generated with ffmpeg by `perf.py corpus`. The `run`, `compare` and `releases` commands ensure it exists first. A missing fixture or unavailable feature skips that benchmark. A checked operation failure stops the run with `FAILED` and a nonzero exit. This includes read errors, failed seeks, missing instruction counters and a main-queue wait over 600 s. No failed sample reaches a median.

### Coverage

`run` and `compare` select every compiled benchmark by default. `releases` selects only `PAGE_CHARTS`. Adding a component benchmark does not silently change the release charts. `docs/performance.md` lists the measured paths and their limits.

Waveform cache reads, writes, fresh writes and snapshots run on three-minute and hour-long files. Separate cases time the first draw after a read or a snapshot. Metadata cache cases archive the real record. Thumbnail cases include the bounded decode queue and main-thread delivery, plus separate memory hits. Playlist cases cover single and bulk edits, indexes, seeded shuffle, CUE parsing and M3U writing and restoration.

The audio cases open each format, load its first 4,096 frames, decode it fully in planar and interleaved blocks, and seek to seeded random positions. Separate skip cases move forward and backward by five seconds and read after every seek. The matrix includes hour-long CBR and VBR MP3, no-Xing MP3, 48 kHz MP3 and FLAC through 352.8 kHz. Window reads decode seconds 60–90. The CUE waveform cases use the same window through the production loader. FLAC encoding starts from ten seconds of prepared PCM. Each version uses its own file reader. These measure local file work. They do not measure shell transport latency or a cloud download.

The drawing cases follow `WaveformRendererRegistry.availableIdentifiers`. Each style gets a fixed 60-frame progress and hover sweep, then the same sweep rasterized into a 2x bitmap. A separate resize-and-draw case changes width from 700 to 936 points and rasterizes every frame. Scroll and pinch cases rasterize an 800-point viewport of a wider track. The `ui-waveform-zoom` cases draw the iOS scrubber's 3x picture, 180 points tall, and scroll and pinch it. The old renderer draws its whole geometry. A renderer with `renderRect` draws the visible window through that API. Track-change cases alternate two fixed waveforms and settle each morph before drawing. Detail reads and drawing exist only in versions with the detail API. They are not a delta against a version without it. Styles with `supportsEnvelopeBake` also bake a 3,200-point envelope at 2x. Unsupported bakes skip. A version that removed the bake API registers no bake cases. These measure CPU work in Vibe and Core Graphics. They do not count GPU work or WindowServer composition.

FX renders use 30 seconds of seeded stereo noise at 48 and 96 kHz. Each repetition resets filters and tails. Control ramps finish before the first slice. These cases measure settled DSP and its reset cost. Separate `fx-host` cases measure fresh unit hosting and disposal. They do not measure the timing of a gesture or tail expiry.

## Charting every release on the performance page

`docs/performance.md` has one section per decision, each with the charts that back it, from either suite. This skill owns the component charts: `perf.py releases` measures each version, and `PAGE_CHARTS` in `perf.py` decides what is measured and drawn.

### Generating it

```bash
make bench-components-releases VERSIONS="1.16"         # a new release: tag v1.16, measured, stored, page redrawn
make bench-components-releases VERSIONS="HEAD"         # this checkout before its release: "<MARKETING_VERSION> pre-release"
make bench-components-releases VERSIONS="1.16=<ref>"   # any commit, under that version
make bench-components-releases                         # every version already on the page, again
make bench-components-releases VERSIONS="HEAD" ARGS="--reps 1"   # a quick look; the page uses 5
make bench-releases VERSIONS="1.16"                    # the app benchmarks, then these, in one command
make bench-report                                      # redraw the page from results.json, measuring nothing
```

`make bench-components-releases` is `perf.py releases`. `make bench-releases` is `scripts/bench/bench.py all`, which calls the same code after the app benchmarks. A version takes a few minutes, and a rerun with the same harness reuses its build. No app launches, so the Mac can be in use. A busy machine adds noise to CPU and wall time, but instructions retired barely move.

**What a version is.** `1.16` is the release tag `v1.16` (or the ref already stored for it). `1.16=<ref>` is that version at any commit. A bare ref such as `HEAD` takes the version its own `project.yml` declares (`MARKETING_VERSION`). **When `v<version>` is not tagged yet, the version is a pre-release.** It is stored with `prerelease: true` and charted as `<version> pre-release`. Once the release is tagged, `make bench-releases VERSIONS="<version>"` measures the tag and replaces the pre-release point.

The procedure and the one-Mac-per-half guard are under Common requests, above. Commit `docs/performance/results.json`, the redrawn `docs/performance/*.svg` and `docs/performance.md`.

### What happens, step by step

For each version, `measure_release` in `perf.py`:

1. **Checks the commit out** as a detached worktree under `build/bench-components/src/<commit>`.
2. **Grafts today's harness onto it** (`graft`, `features`, `tool_spec`), as described under Comparing two refs.
3. **Builds it Release, leaving out what it cannot compile.** A benchmark file that fails against the old code is deleted from that checkout and the build retried. The binary is cached under `build/bench-components/bin/<commit>-<harness digest>/`.
4. **Runs only the page's benchmarks** (`page_filter`, every name in `PAGE_CHARTS`), five repetitions, and stores the medians — CPU ms, wall ms, millions of instructions, units — with the commit, `prerelease`, date, corpus hash, machine and harness digest, under the version in `results.json`'s `components` section. A benchmark the version cannot build is absent, not zero, so its line starts at the first version that has the code.
5. **Redraws the page** (`scripts/bench/report.py`, drawing with `scripts/docs/charts.py`): one SVG per `PAGE_CHARTS` entry with data into `docs/performance/components-*.svg`, the app benchmarks' charts, the release table (`summary.svg`), and the machine line between the page's `<!-- performance:begin -->` and `<!-- performance:end -->` markers. The sections show each chart by file name, and `report.py` names any chart the page doesn't show.

### Changing what the page shows

`PAGE_CHARTS` is the only list. Each entry is `(svg name, title, unit, [(benchmark, measure, legend)], decimals)`, at most four series; the measures (`cpu_per_minute`, `cpu_per_unit`, `wall_per_unit`, `us_per_unit`, `wall`, `wall_s`) are `page_value`'s. Adding a series or a chart means adding it there and running `make bench-components-releases` with no `VERSIONS`, so every version gets the new benchmark; one the old versions cannot build simply starts late. A new chart also needs a line in the section of `docs/performance.md` it belongs to, or under More charts. A series whose legend is a format name (`MP3 320k`, `AAC 256k`, `FLAC 16/44.1`, `FLAC 24/192`, `WAV 24/96`) keeps that format's color on every chart (`report.py`'s `SLOT`). A new benchmark *file* also has to build against old code, which is "Adding a benchmark" below.

### When it goes wrong

- **A version fails to build at all** (not just a benchmark file): the log is `build/bench-components/dd/<commit>.log`. Usually that version's code has a shape the harness assumes; add a flag to `VibeBenchComponents.h`'s list and its detection to `features()`.
- **A chart is missing a version**: check the machine and corpus first. Then check for a benchmark omitted at build time or a missing result.
- **The guard refuses**: this Mac or its corpus doesn't match the history (it prints what differs). Run on the matching Mac, rerun every version, or, if the user says so, `ARGS="--new-machine"`.
- **A version's numbers jump with no code change**: the harness changed under it (the digest is in its entry). Rerun every version so they share one harness.

## Reading the numbers

**Instructions retired is the number to trust.** It comes from `proc_pid_rusage` for the whole process, so it covers every thread a benchmark starts. Instruction counts are usually less sensitive to competing work than wall time. CPU and wall time are what a user feels. Read them for the direction, and to catch a change that retires fewer instructions but runs slower. Strided vDSP calls and small misaligned vDSP calls are two known causes. Measure the run-to-run variation before interpreting small differences.

The `per unit` column is realtime factor (audio seconds per CPU second) for audio work, ms per operation otherwise.

**File cache state.** Component repetitions reuse the corpus after a warm-up. Their file reads and disk-cache hits usually use warm filesystem pages. The app suite's cold-open cases use a fresh APFS clone. `cp -c src clone` creates a separate file with shared storage. It reduces reuse of the source file's cached pages. It does not guarantee a cold storage device. The clone must sit on the source's volume.

## Proving a change exact

`VibeBenchComponents --analyze <folder>` runs every audio file under it through the production waveform loader with both analyzers and prints `name<TAB>bpm<TAB>key`, the tempo to nine significant digits. Run it at both refs over the GiantSteps sets (`~/projects/giantsteps-tempo-dataset`, `~/projects/giantsteps-key-dataset`) and `cmp` the outputs: an analyzer change that is meant to be exact must leave them identical. A change meant to move the answers is `scripts/analysis/validate-tempo.py` / `validate-key.py`'s job (`vibe-libs/audio/Analysis/AGENTS.md`).

`VibeBenchComponents --waveform <file>` draws one file's waveform as the iOS scrubber does. It measures nothing. The `vibe-waveform` skill drives it.

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

**TRAP: VibeBenchComponents is built Release, as the app ships (`-Os`).** The optimizer can change the cost of copies and loops. Measure with the shipping optimization settings.

**Measure compiler-setting changes.** The decoders and resampler have their own optimization flags in vibe-libs' `vibe-libs.yml`. A whole-app flag does not describe every translation unit.

**Never launch the app from here.** VibeBenchComponents is its own process with its own defaults domain and touches no app state. The app benchmarks' app runs as `VibeBenchApp` with its own bundle identifier, home and channel directory. Neither collides with a `Vibe` instance another session is stressing.
