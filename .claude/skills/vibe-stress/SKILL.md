---
name: vibe-stress
description: Stress, soak, and fuzz the running Vibe app against a folder of real audio files — seeded random driving with invariant, leak, hang, and crash oracles, plus the sanitizer (ASan/UBSan/TSan) and malloc-debug build matrix. Use for soak or endurance runs, memory-leak and resource-growth hunting, race hunting, fuzzing the file-loading path, or minimizing a failing run to a repro.
---

# Stress and fuzz testing Vibe

**Read the `vibe-debug` skill first.** This harness is built entirely on that skill's `--debug-cmd` channel: it drives the app with those verbs, launches through that skill's `launch.sh`, and inherits every one of its traps — the sandbox grant rules, the off-hardware flags, the two-instance raciness, the stale-binary check. Nothing here restates them.

The division: **`vibe-debug` drives the app; this drives it *randomly, for hours, and notices when something breaks*.** The three oracle verbs themselves — `dump_health`, `check_invariants`, `quiesce` — are ordinary channel commands documented in `vibe-debug`'s command list, and are useful on their own.

```bash
make stress CORPUS=~/Music/big
make stress CORPUS=~/Music/big ARGS="--profile loading --duration 3600"

.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --iterations 2000
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --seed 48213     # replay a run exactly
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --shrink stress-48213.ndjson
```

Needs a **Debug** build; the whole debug channel compiles out of Release.

**Every run is reproducible.** The seed is printed first and `--seed N` regenerates the identical op sequence; without that a fuzz failure is nearly worthless. Every op is journaled as NDJSON beside the run, and `--replay` re-runs a journal verbatim.

It throttles at roughly 12 ops/second, and that floor is the CLI client's 50 ms response poll rather than process spawn — batching through `script -` was measured at 57 ms/op against 81 ms/op, not enough to be worth losing per-op exit codes over, which is why each op is its own invocation.

## The four oracles

Between batches (`--batch`, default 25 ops) it checks:

| Oracle | What it catches | How |
| --- | --- | --- |
| liveness | main-thread stalls | the channel is delivered on the **main queue**, so a timeout whose recovery probe is *also* slow is a stall. It samples the app first, then re-probes: a stall it recovers from is counted (`--max-stalls`, default 3) rather than failing the run, but is sampled either way. A timeout that probes clean at the usual ~110 ms was a slow verb, not a stall — journaled as `slow`, uncounted. `VERB_TIMEOUTS` keeps each verb's client deadline above its own in-app wait, because a client timeout underneath the app's deadline reports work still in progress as an unresponsive app |
| `check_invariants` | state that went inconsistent | violations surviving a settle and a second sample |
| `dump_health` | leaks and unbounded growth | footprint, fds, threads, mach ports, windows, views, layers, engine nodes, and the `pending` counters, each against a post-warmup baseline |
| crash | death | `pgrep`, plus any `Vibe*.ips` in `~/Library/Logs/DiagnosticReports` newer than the run |

On a failure it writes a `stress-<seed>-failure/` directory with the sample or crash report, `dump_state`, `dump_view_tree`, `dump_health` and a screenshot, and prints the shrink command. Failure kinds are `hang`, `crash`, `exit`, `invariant`, `resource`, `command` and `client`; **`client` is the harness, not the app** — see the traps below.

`--shrink` delta-debugs a failing journal down to a minimal op list, relaunching the app per candidate, and writes it as plain command-script lines you can feed straight to `run-script.sh`. A 5,000-op crash teaches nothing; the six-op version becomes a regression case. Add `--shrink-resting-mb N` to make an at-rest footprint above N MB count as a reproduction, which is what lets a **resource** failure be minimized like a crash — the default predicate only covers crashes, hangs and invariant violations.

## The `pending` counters, and why sampling at rest matters

`dump_health`'s `pending` section counts every unbounded container in the app that holds work in flight: `metadataHolders` and `metadataWaiters` (`MetadataParseCoordinator`'s claim table, whose waiter tables are per key), `openResultsBuffered` (`OpenRequestCoordinator` results held for in-order delivery), `openBurstQueued` (`OpenBurstCoalescer`'s quiet-period queue), and `retiredFades` (`AudioPlayer`'s in-flight crossfade pairs). All belong at zero once the app settles. They matter because a stranded parse claim or an undelivered open result is a few hundred bytes — a thousand of them would not move the footprint, yet each is work that will never finish.

`retiredFades` is reported alongside `engineNodes` rather than folded into it because the two fail apart: a fade entry dropped with its nodes still attached and a fade entry stranded after its nodes were detached are different bugs that either number alone cannot distinguish. Both come from one `dispatch_sync` onto the player queue.

**Two of these are unreachable from this driver as it stands.** `--debug-cmd open` calls `NSURLUtil expandAndFilterList:` and then `play:` directly — it does *not* go through the burst coalescer or the open-request coordinator — so `openBurstQueued` only moves under a real Launch Services open or the open panel, and `openResultsBuffered` only under `drag_drop`, which routes through `MainWindow`'s drop path. Do not read a run of zeroes there as evidence those paths are clean.

The counters are also nearly impossible to observe live from outside the process: a parse of a local file is over in microseconds, so a poll almost never lands inside one. `MetadataParseCoordinatorTests.testDebugPendingCountsTrackHoldersAndWaiters` pins the holder/waiter accounting deterministically instead — a counter that silently always read zero would look exactly like a clean run.

**`quiesce` is what makes the health numbers worth trusting.** It runs `closeFile:` — stop, drop the prefetch handle, cancel the waveform load and deferred metadata scan, clear the playlist, reset the UI — then polls until the pending counters unwind, then calls `malloc_zone_pressure_relief` — which mostly releases nothing, so `phys_footprint` keeps the allocator's high-water mark and `mallocLiveBytes` is the number to read at rest. See below. The driver takes a separate at-rest health series this way every `--quiesce-every` batches (default 10) and scores it against much tighter limits.

Measured over loading-profile runs, that at-rest state is *dead stable* in exactly the metrics that matter: views 47, windows 1, engine nodes 23, every pending counter 0. Threads (14–26) and fds (45–70) breathe with the loader pool. **Layers are not one of the stable ones, and an earlier "100–104" here was one plateau rather than the range**: the resting layer count is bistable at ~101 and ~350–356 and moves in *both* directions within a single run — one soak read 355, 352, 351 and then settled at 101, and the very next read 101 and settled at 352, on the same binary. Nothing app-level selects it. Holding views pinned at 47, it is unmoved by row count (0, 3, 60, 2208 rows), window width (400 to 3000), `quiesce`, and the pitch panel and playlist toggles, which are worth 4 layers and 1 layer respectively; it is AppKit's own glass and hosting-view machinery. Its limit is sized to clear that step (+320), because a +80 limit against a min-of-first-three baseline fires whenever a run happens to start low. A real layer leak is unbounded and clears +320 too.

**Resting footprint does not settle** — 47 to 335 MB, with the same seed resting at 298 MB in one run and 51 MB in another, and one run dropping from 313 MB to 88 MB two samples later. It is the allocator's high-water mark rather than live data — see below — so it is a gross-leak backstop (+256 MB), not a sensitive signal. `mallocLiveBytes` is the megabyte metric that *is* sensitive: it sat at 37–52 MB across the same decodes that swung the footprint from 94 to 365 MB.

### Settled: the ~270 MB resting "retention" is not a leak

The symptom was a loading-profile run resting flat at 55–61 MB and then stepping to ~330 MB and staying there across a `quiesce`, with no op window reproducing it standalone. **It is the allocator's and the VM's high-water mark, not retained objects**, and `dump_health`'s `mallocLiveBytes` now says so directly. A two-command repro on a corpus of big files:

| | footprint | live heap |
| --- | --- | --- |
| fresh launch | 94 MB | 38 MB |
| two `file_cache` decodes of ~200 MB MP3s | 203 MB | 52 MB |
| after `quiesce` | **365 MB** | **37 MB** |

The resting footprint *rises* while the live heap falls below where it started. `heap` agrees from outside: 18.8 MB live across 134k nodes at a 203 MB footprint. `vmmap --summary` puts the dirty pages in `MALLOC_LARGE (empty)` (67.5 MB — freed large blocks, no live allocations), `VM_ALLOCATE` (47.5 MB) and `IOSurface` (33.6 MB), with the malloc zones 54% fragmented; only the first is even reachable by pressure relief, and CoreAudio's `caulk` zones sit at 100% fragmentation where it cannot reach at all.

**`malloc_zone_pressure_relief` does not deliver what `quiesce` assumes.** It returns ~42 KB on a fresh launch and 0 after a heavy run, which is why the resting footprint could never be tightened. `quiesce` now reports `pressureRelief.releasedBytes` — read it before believing any resting footprint number.

So the resting cap stays at +256 MB as a gross backstop, and **sensitivity comes from `mallocLiveBytes`** (+64 MB) beside the pending counters. What remains genuinely open is narrower: whether the large transient buffers that fragment the zone are worth pooling, which needs `MallocStackLogging=1` plus `malloc_history` to attribute before anyone refactors. `--shrink --shrink-resting-mb 150` still works, but shrinking a footprint that is measuring high-water noise will chase ghosts — shrink on live heap instead.

**Two rules keep the health oracle from crying wolf, and both were earned by watching it do so.** The baseline is the element-wise *minimum* of the first three samples rather than the first sample, because the opening decode and its analyzers peak the footprint far above the resting level and a peak baseline is a permissive one that hides the leak it was meant to catch. And a metric must stay over its limit for three **consecutive** samples to count: measured over a loading-profile run, the engine node count swings between 25 and 67 with no trend at all as retired crossfade pairs pile up and drain, and the footprint spikes past 350 MB mid-decode before falling back to ~120 MB. A single over-limit sample is churn, not growth.

## Profiles

`--profile base` mixes everything. `--profile loading` weights the open path and the async deliveries that race it — the documented hazard, where waveform, BPM, key and metadata deliveries land after the track has already changed — including `open_burst`, two to four opens landing on top of each other with no settle. `--profile ui` does no file loading at all: a pure monkey over transport, seeks, pitch, FX, clicks, drags, resizes and menus against whatever is loaded.

`--profile artwork` aims at the folder-artwork fallback: opens through all three resolve strategies (a folder, a burst of files, a lone file), the playlist visible far more often than elsewhere so cell draws pull thumbnails off the resolver concurrently with the header's display-size load, and the setting flipped underneath both. Pair it with a corpus built for it — one cover per accepted filename, the near-miss names, the unreadable and undecodable and oversize covers, a cover that is a directory and one that is a FIFO.

Four op kinds exist because nothing else would produce them: `open_burst` above, `held_fx` (a `key_down w` whose `key_up` is sometimes lost across a track change, latching a momentary effect), out-of-range `seek` and `set_pitch` values, where the clamp escaping is the finding, and `folder_art`, which flips `set_folder_art` — the one change that drops every answer the resolver holds, landing on resolves and decodes already in flight while the playlist draws cells off the same tables.

**`folder_art` emits `off` and `on` as a pair, and that shape is load-bearing.** See the settings trap below.

**Deliberately excluded from every profile**: `convert_to_flac`, which writes beside the source and can trash the original — the corpus is real music. Right-clicks and lone `mouse_down` are excluded too, for the wedge reasons in `vibe-debug`, and menu items are filtered through a denylist covering anything modal, quitting, hiding or closing, since the channel cannot be served while a modal panel is up.

## Traps, each found by the harness misfiring

**A random clicker will quit the app if you let it.** The window draws its own close and minimize buttons as `SymbolButton`s in its top-left corner, and `closeApp:` is `[self close]` — so a uniform random click finds them within a few hundred ops. The driver reads their frames out of `dump_view_tree` at startup and excludes those rects (plus a fixed top-left fallback), and it also distinguishes the two ways the app can vanish: gone **with** a fresh `.ips` is a `crash`, gone **without** one is an `exit`, meaning something in the op stream asked it to quit. Reporting a clean exit as a crash sends you hunting for a stack that was never written.

**Never `sample Vibe` by name.** The CLI client is the app binary, so the name matches every in-flight `--debug-cmd` invocation too, and sampling one yields a stack of the client polling for its own response — `VibeDebugClientRunOne` sitting in `usleep`, which reads exactly like a hang and says nothing whatever about the app. Resolve the GUI instance's pid first by filtering `pgrep -x Vibe` for the process whose argv lacks `--debug-cmd`, and sample that. Sample *before* re-probing, too: a probe that succeeds means the stall already ended and took its stack with it.

**A setting the fuzzer toggles persists across runs, and a disabled feature looks exactly like a clean run.** `AppSettings` lives in `NSUserDefaults`, so a run inherits whatever the *last* one left — including a fuzzer's own random final toggle. Reconstructing `set_folder_art` from the journals of four runs that all reported passes: the feature was on for 49.5%, **36.3%**, 46.8% and 42.3% of their ops, and two of them *ended* off, poisoning every later hand-run probe against the same container. With it off the artwork accessors return before they reach the resolver at all, so those ops exercise none of the code the run was aimed at — and nothing in the summary says so. Two fixes, both needed: the driver forces every entry in `FEATURE_SETTINGS` on at launch and prints it in the header (`settings: folderArt=on`), and the toggle op emits `off` then straight back `on`, which buys both invalidation edges while leaving the feature on essentially throughout and lands the user's setting where it started. **Verify the duty cycle from the journal before believing a coverage claim** — count the `set_folder_art` ops and the gaps between them; the fixed op yields ~98.5% on.

**`--iterations` silently caps `--duration`.** It defaults to 2000, and whichever limit is reached first ends the run, so `--duration 3600` alone stops after ~2000 ops — for a "one hour" soak, raise both.

**The sandbox will kill your clients under launch pressure.** The CLI client being the app binary also means every op launches a short-lived instance of a sandboxed executable. Launch a few hundred in quick succession and libsecinit's container setup starts failing outright, SIGTRAPping inside dyld's initializers before `main()` ever runs — a real `.ips` crash report for "Vibe" that has nothing to do with Vibe's code. The giveaway is `parentProc: Python`, a sub-millisecond process lifetime, and a stack topped by `_libsecinit_appsandbox`. The driver retries a signal-killed client that produced no output, and only calls it a `client` failure once the retries are exhausted; do the same in any hand-rolled loop over `--debug-cmd`.

## The corpus grant, and why it unlocks the sanitizer builds

The driver launches through `vibe-debug`'s `launch.sh` passing the **corpus directory**, and that is load-bearing rather than incidental: `open -a` is what grants sandbox access, `FolderAccessManager` bookmarks folders arriving through the open funnel, and the grant then persists across relaunches. Every later `--debug-cmd open` on a file inside that folder is readable because of it.

That matters beyond convenience. Sanitizer and malloc-debug options are **environment variables**, `open -a` cannot pass environment variables, and a direct-exec `"$V" <file>` cannot read argv paths under the sandbox. Once the corpus folder is granted, though, a direct-exec launch can reach every file in it through the channel:

```bash
xcodebuild -project Vibe.xcodeproj -scheme Vibe -configuration Debug \
    -derivedDataPath build/DerivedData -enableThreadSanitizer YES build
TSAN_OPTIONS=halt_on_error=0 "$V" --no-audio-hw --silent &
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big --profile ui   # app already up
```

### Getting a sanitizer report out of a sandboxed app

**Default options make TSan kill the app instead of reporting it**, and the crash looks nothing like a race: an `EXC_CRASH`/`SIGABRT` whose faulting stack is `__sanitizer::Die` under `ReportFile::ReopenIfNecessary` and `StartSymbolizerSubprocess`. That is the sanitizer failing to *report*, not the app failing. Two independent causes, both the sandbox:

- **`log_path` must be inside the app's container**, `~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/`. Anywhere else — including a scratch dir under `/tmp` — and the first report aborts the process on the write. With no `log_path` at all the report goes to stderr, which is nowhere for a GUI app launched by `open -a`.
- **`external_symbolizer_path=` must be empty.** Symbolizing spawns `atos`, which the sandbox denies; TSan then tries to report *that* failure and hits the first problem. Empty falls back to the in-process `dladdr` symbolizer — function names but no file or line, which is enough to place a race.

Build to a **separate** derived-data path so the plain Debug build stays usable, and hand it to the driver with `--app`, which sets `VIBE_APP` for `launch.sh`:

```bash
C=~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp
xcodebuild -project Vibe.xcodeproj -scheme Vibe -configuration Debug \
    -derivedDataPath build/DerivedData-tsan -enableThreadSanitizer YES build
launchctl setenv TSAN_OPTIONS \
    "log_path=$C/tsan:halt_on_error=0:external_symbolizer_path=:symbolize=1:history_size=7"
.claude/skills/vibe-stress/scripts/stress.py --corpus ~/Music/big \
    --app "$PWD/build/DerivedData-tsan/Build/Products/Debug/Vibe.app" \
    --profile artwork --max-stalls 20
launchctl unsetenv TSAN_OPTIONS        # it is a session-wide variable
```

`launchctl setenv` is what gets the variable to an `open -a` launch at all, and it applies session-wide until unset, so unset it when the run ends. Reports land as `$C/tsan.<pid>`; **no file means no race**, since TSan creates it only on the first report. Raise `--max-stalls`, because instrumentation makes ordinary verbs slow enough to trip the liveness oracle.

TSan's own noise is worth suppressing so it cannot bury a finding in app code — put a suppressions file in the container too and add `suppressions=$C/tsan-suppressions.txt`.

Three builds catch disjoint bug classes, and **TSan matters most here**: the whole threading contract — every engine mutation on the serial player queue, non-blocking UI-facing getters, delegate callbacks on main — is exactly what it validates, and a race there is invisible to every other oracle in the table above.

- plain Debug: fastest, most iterations, catches logic, assertions and hangs
- `-enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES`: roughly 3x slower; aim it at malformed files, where input reaches TagLib's C++
- `-enableThreadSanitizer YES`: a separate build, incompatible with ASan

Cheap variants on the plain build, same direct-exec launch: `NSZombieEnabled=YES`, `MallocScribble=1`, `MallocGuardEdges=1`, `MallocStackLogging=1` (needed for `leaks Vibe` to give allocation stacks). `heap Vibe` gives per-class live instance counts from outside the process, which is the attribution `dump_health`'s process-level numbers deliberately leave out.
