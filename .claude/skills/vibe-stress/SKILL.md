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
| liveness | main-thread stalls | the channel is delivered on the **main queue**, so a timeout *is* a stall. It samples the app, then re-probes: a stall it recovers from is counted (`--max-stalls`, default 3) rather than failing the run, but is sampled either way |
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

**`quiesce` is what makes the health numbers worth trusting.** It runs `closeFile:` — stop, drop the prefetch handle, cancel the waveform load and deferred metadata scan, clear the playlist, reset the UI — then polls until the pending counters unwind, then calls `malloc_zone_pressure_relief` so `phys_footprint` reports live data rather than the allocator's high-water mark. The driver takes a separate at-rest health series this way every `--quiesce-every` batches (default 10) and scores it against much tighter limits.

Measured over loading-profile runs, that at-rest state is *dead stable* in exactly the metrics that matter: views 47, layers 100–104, windows 1, engine nodes 23, every pending counter 0. Threads (14–26) and fds (45–70) breathe with the loader pool. **Resting footprint does not settle** — 47 to 335 MB, with the same seed resting at 298 MB in one run and 51 MB in another, and one run dropping from 313 MB to 88 MB two samples later. Concurrent decode and analyzer buffers dominate it and their lifetimes are timing-dependent, so it is a gross-leak backstop (+256 MB) rather than a sensitive signal. Sensitivity comes from the counters, not the megabytes.

### Open finding: an unexplained ~270 MB retention

A loading-profile run rests flat at 55–61 MB and then steps to ~330 MB and stays there, across a `quiesce` and `malloc_zone_pressure_relief`. Replaying the journal reproduces the step consistently (55 MB at op 449, 319 MB at op 453), but the four ops in that window do **not** reproduce it standalone, so it depends on accumulated state. Ruled out by direct experiment: opens (400 rapid opens go 41→44 MB), window resizes (6000 points and back, flat), waveform-style switching (48 switches, 53→54 MB), and both caches (`clear_caches` changes nothing). Bare launch is 31 MB; a folder open is 45 MB. The resting cap is deliberately left at +256 MB so this still fires rather than being tuned away. `--shrink --shrink-resting-mb 150` is the tool for chasing it.

**Two rules keep the health oracle from crying wolf, and both were earned by watching it do so.** The baseline is the element-wise *minimum* of the first three samples rather than the first sample, because the opening decode and its analyzers peak the footprint far above the resting level and a peak baseline is a permissive one that hides the leak it was meant to catch. And a metric must stay over its limit for three **consecutive** samples to count: measured over a loading-profile run, the engine node count swings between 25 and 67 with no trend at all as retired crossfade pairs pile up and drain, and the footprint spikes past 350 MB mid-decode before falling back to ~120 MB. A single over-limit sample is churn, not growth.

## Profiles

`--profile base` mixes everything. `--profile loading` weights the open path and the async deliveries that race it — the documented hazard, where waveform, BPM, key and metadata deliveries land after the track has already changed — including `open_burst`, two to four opens landing on top of each other with no settle. `--profile ui` does no file loading at all: a pure monkey over transport, seeks, pitch, FX, clicks, drags, resizes and menus against whatever is loaded.

Three op kinds exist because nothing else would produce them: `open_burst` above, `held_fx` (a `key_down w` whose `key_up` is sometimes lost across a track change, latching a momentary effect), and out-of-range `seek` and `set_pitch` values, where the clamp escaping is the finding.

**Deliberately excluded from every profile**: `convert_to_flac`, which writes beside the source and can trash the original — the corpus is real music. Right-clicks and lone `mouse_down` are excluded too, for the wedge reasons in `vibe-debug`, and menu items are filtered through a denylist covering anything modal, quitting, hiding or closing, since the channel cannot be served while a modal panel is up.

## Three traps, each found by the harness misfiring

**A random clicker will quit the app if you let it.** The window draws its own close and minimize buttons as `SymbolButton`s in its top-left corner, and `closeApp:` is `[self close]` — so a uniform random click finds them within a few hundred ops. The driver reads their frames out of `dump_view_tree` at startup and excludes those rects (plus a fixed top-left fallback), and it also distinguishes the two ways the app can vanish: gone **with** a fresh `.ips` is a `crash`, gone **without** one is an `exit`, meaning something in the op stream asked it to quit. Reporting a clean exit as a crash sends you hunting for a stack that was never written.

**Never `sample Vibe` by name.** The CLI client is the app binary, so the name matches every in-flight `--debug-cmd` invocation too, and sampling one yields a stack of the client polling for its own response — `VibeDebugClientRunOne` sitting in `usleep`, which reads exactly like a hang and says nothing whatever about the app. Resolve the GUI instance's pid first by filtering `pgrep -x Vibe` for the process whose argv lacks `--debug-cmd`, and sample that. Sample *before* re-probing, too: a probe that succeeds means the stall already ended and took its stack with it.

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

Three builds catch disjoint bug classes, and **TSan matters most here**: the whole threading contract — every engine mutation on the serial player queue, non-blocking UI-facing getters, delegate callbacks on main — is exactly what it validates, and a race there is invisible to every other oracle in the table above.

- plain Debug: fastest, most iterations, catches logic, assertions and hangs
- `-enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES`: roughly 3x slower; aim it at malformed files, where input reaches TagLib's C++
- `-enableThreadSanitizer YES`: a separate build, incompatible with ASan

Cheap variants on the plain build, same direct-exec launch: `NSZombieEnabled=YES`, `MallocScribble=1`, `MallocGuardEdges=1`, `MallocStackLogging=1` (needed for `leaks Vibe` to give allocation stacks). `heap Vibe` gives per-class live instance counts from outside the process, which is the attribution `dump_health`'s process-level numbers deliberately leave out.
