---
name: vibe-stress
description: Stress, soak, fuzz, and torture the running Vibe app against a folder of real audio files — seeded random driving with consistency, leak, hang, and crash oracles, a single-playlist skip/seek torture suite for the delivery races that only open when transport outruns the metadata scan, a deterministic cloud-loading scenario suite over a fake file provider (download ordering, the foreground hold, the open deadline), plus the sanitizer (ASan/UBSan/TSan) and malloc-debug build matrix. Use for soak or endurance runs, memory-leak and resource-growth hunting, race hunting, fuzzing the file-loading path, hammering skips and seeks on a large playlist, testing cloud/placeholder loading order, or minimizing a failing run to a repro.
---

# Stress and fuzz testing Vibe

**Read the `vibe-debug` skill first.** This harness is built entirely on that skill's `--debug-cmd` channel: it drives the app with those verbs, launches through that skill's `launch.sh`, and inherits every one of its traps — the sandbox grant rules, the off-hardware flags, the two-instance raciness, the stale-binary check. Nothing here restates them.

There are three drivers here, and they answer different questions. **`stress.py`** drives randomly for hours and notices when something breaks. **`torture.py`** hammers transport on one playlist so track changes outrun everything async. **`cloud-scenarios.py`** drives one named situation at a time and asserts what the fake provider's trace must contain — because the cloud work's guarantees are all about *order*, which no amount of random driving can state.

The division: **`vibe-debug` drives the app; this drives it *randomly, for hours, and notices when something breaks*.** The three oracle verbs themselves — `dump_health`, `check_consistency`, `quiesce` — are ordinary channel commands documented in `vibe-debug`'s command list, and are useful on their own.

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
| `check_consistency` | state that went inconsistent | violations surviving a settle and a second sample. Its `cloud.*` checks are the exception to that filter: they read counters that are cumulative for the life of the fake provider's install, because neither a background download inside a foreground one nor a duplicate download of one file is ever *transiently* true |
| `dump_health` | leaks and unbounded growth | footprint, fds, threads, mach ports, windows, views, layers, engine nodes, and the `pending` counters, each against a post-warmup baseline |
| crash | death | `pgrep`, plus any `Vibe*.ips` in `~/Library/Logs/DiagnosticReports` newer than the run |

### An oracle is only as good as its counter, and one of these was wrong

**`fileDescriptors` used to measure the descriptor TABLE, not the open descriptors.** `proc_pidinfo(PROC_PIDLISTFDS)` with a null buffer answers how big the table is, and that table grows with peak concurrency and never shrinks — so a burst of parallel opens read as a permanent leak that survived a `quiesce`, while `lsof` showed the descriptors had all been closed. Measured: **420 reported against 41 actual**. It failed a 12,000-op run at op 1103 on nothing at all, and worse, it could never have caught a *real* fd leak, since growth and a concurrency spike were indistinguishable. The listing has to be fetched for real (see `VibeOpenFileDescriptorCount`); with true counts the limits came down from 200 to 64 in flight and 32 to 8 at rest, which is what makes an fd leak detectable — and one is a documented hazard here, since a failed `AVAudioFile` open against an empty file strands its descriptor.

**The footprint oracle now only counts when `mallocLiveBytes` agrees**, for the reason the rest of this file already spends paragraphs on: the footprint measures the allocator's and the VM's high-water mark, not retention, and it wanders in *both* directions. A measured resting series read 553, 494, 749, 606, 838 MB while the live heap sat at 2.2 MB byte-identical, fds flat at 6 and every pending counter zero — and a sanitizer build inflates it further, its shadow memory alone clearing the limit on any long run. A real gross leak moves both numbers, so the backstop survives; what goes away is the false failure this file used to tell every reader to expect and dismiss by hand.

**Every other process metric was then audited against an external tool, and they agree**: `threads` against `ps -M`, `machPorts` against `lsmp` (±1, the sampling itself), `footprintBytes` against `footprint`, `residentBytes` against `ps rss`, `mallocLiveBytes` against `heap`'s all-zones total, and `views` against a node count of `dump_view_tree`. Do the same before trusting a new one: a metric nobody has checked against ground truth is a number, not a measurement.

On a failure it writes a `stress-<seed>-failure/` directory with the sample or crash report, `dump_state`, `dump_view_tree`, `dump_health` and a screenshot, and prints the shrink command. Failure kinds are `hang`, `crash`, `exit`, `consistency`, `resource`, `command` and `client`; **`client` is the harness, not the app** — see the traps below.

`--shrink` delta-debugs a failing journal down to a minimal op list, relaunching the app per candidate, and writes it as plain command-script lines you can feed straight to `run-script.sh`. A 5,000-op crash teaches nothing; the six-op version becomes a regression case. Add `--shrink-resting-mb N` to make an at-rest footprint above N MB count as a reproduction, which is what lets a **resource** failure be minimized like a crash — the default predicate only covers crashes, hangs and consistency violations.

## The `pending` counters, and why sampling at rest matters

`dump_health`'s `pending` section counts app-owned work that must unwind at rest: `metadataHolders` and `metadataWaiters` (`MetadataParseCoordinator`'s claim table, whose waiter tables are per key), `openResultsBuffered` (`OpenRequestCoordinator` results held for in-order delivery), `openBurstQueued` (`OpenBurstCoalescer`'s quiet-period queue), `retiredFades` (`AudioPlayer`'s in-flight crossfade pairs), the metadata cloud lane's `cloudParsesPending` and `cloudLaneHeld`, `priorityRecordsPending`, `datalessProbesInFlight`, and `handleOpensInFlight`. The final two are attempt gauges rather than containers. Probe accounting starts before the scheduler/worker handoff and survives detachment from its claim; handle-open accounting likewise starts before dispatch. A failed quiesce can therefore distinguish stuck classification from downloading or opening. All belong at zero once the app settles.

**The two cloud counters are deliberately not scored for *growth*, and a future reader should not add them.** Neither is a growth metric: a sweep of a cloud folder legitimately holds dozens of pending parses, and the lane is legitimately held for the whole of every foreground open, so a headroom over a min-of-three baseline would either never fire or fire constantly. They are covered where they mean something instead — `quiesce` refuses to settle until both reach zero and names the counter that held out, and `check_consistency` tests the *conditions* rather than the magnitudes. `dump_cloud_health` reports the same two on both platforms, which is the only way to see them on iOS at all: there is no `dump_health` and no `quiesce` there. They matter because a stranded parse claim or an undelivered open result is a few hundred bytes — a thousand of them would not move the footprint, yet each is work that will never finish.

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

**It is not the big decodes, either — that attribution was too narrow.** The same 250 MB swing reproduces on an artwork corpus whose largest file is a few MB: 1780 and 2537-op runs both tripped the +256 MB backstop with `mallocLiveBytes` flat at 26–42 MB throughout, the footprint flipping *both* directions between adjacent 25-op samples (op 1300: 340 MB, op 1375: 109, op 1526: 387, op 1603: 135). `vmmap` on the live process settles it: **107.9 MB total dirty against a 365 MB `phys_footprint` reading**, and a freshly launched, quiesced app with nothing loaded already reads 321 MB against an 11 MB live heap. The resting footprint is not measuring anything the app retains, whatever the corpus. Expect this oracle to fire on any long artwork run and check `mallocLiveBytes` before believing it.

So the resting cap stays at +256 MB as a gross backstop, and **sensitivity comes from `mallocLiveBytes`** (+64 MB) beside the pending counters. What remains genuinely open is narrower: whether the large transient buffers that fragment the zone are worth pooling, which needs `MallocStackLogging=1` plus `malloc_history` to attribute before anyone refactors. `--shrink --shrink-resting-mb 150` still works, but shrinking a footprint that is measuring high-water noise will chase ghosts — shrink on live heap instead.

**Two rules keep the health oracle from crying wolf, and both were earned by watching it do so.** The baseline is the element-wise *minimum* of the first three samples rather than the first sample, because the opening decode and its analyzers peak the footprint far above the resting level and a peak baseline is a permissive one that hides the leak it was meant to catch. And a metric must stay over its limit for three **consecutive** samples to count: measured over a loading-profile run, the engine node count swings between 25 and 67 with no trend at all as retired crossfade pairs pile up and drain, and the footprint spikes past 350 MB mid-decode before falling back to ~120 MB. A single over-limit sample is churn, not growth.

## Profiles

`--profile base` mixes everything. `--profile loading` weights the open path and the async deliveries that race it — the documented hazard, where waveform, BPM, key and metadata deliveries land after the track has already changed — including `open_burst`, two to four opens landing on top of each other with no settle. `--profile ui` does no file loading at all: a pure monkey over transport, seeks, pitch, FX, clicks, drags, resizes and menus against whatever is loaded.

`--profile cloud` puts the whole corpus behind a fake file provider, so an open *is* a download and the metadata scan's serial cloud lane, the foreground-download hold, the neighborhood re-ranking and the abandoned play and prefetch opens are all live at once. It arms `set_fake_cloud` before the first op — the premise is that opening already costs a transfer, and a run that spent its first batch on local files would be scoring a different app — and re-arms it mid-run through `cloud_churn`, sometimes tearing the seam out from under in-flight workers, which is the one thing about it that could deadlock rather than merely misreport. `--cloud-percent` (default 60) sets how much of the corpus is cloudy; the rest being local is what proves the cloud machinery has not slowed the local path down.

**Its weights are the inverse of `loading`'s, and copying them was the first version's mistake.** Opens are what this profile must be *sparing* with: the sweep is deferred until playback starts or two seconds pass, and a replacement playlist drops the loader outright, so a stream of opens 80 ms apart means the sweep never runs and the lane the profile exists to test is never populated. Measured on that first attempt: 11 downloads cancelled, 1 completed, `cloudParsesPending` never above zero. So instead — heavy `settle`, so a sweep gets seconds to work; heavy `playlist_jump`, because landing on an arbitrary row is what moves the ranking and raises the hold where nothing has prefetched; and `clear_caches` often, because a cache hit means no parse and therefore no download to race.

**`capacity=1` is what makes the profile score anything.** The fake provider's default is unlimited concurrency, and under it a background download never actually delays a foreground one — every transfer starts the moment it is asked for, so "the user's open outranks the sweep" has nothing to be true about. One or two slots is the shape a real provider has and the shape the hold, the stand-aside and the lane ordering were written for.

Pair it with `make-cloud-corpus.py`, which builds what the profile needs and the default test corpus cannot give it: **big folders** (against 19 files the sweep finishes instantly), **real tags and embedded art** (generated tones carry neither, and the worst bug this machinery has had showed itself in the art path), a **mixture** including artless files, and **globally unique basenames** — the cloud trace records a transfer by last path component alone, so two folders holding a same-named track are one file to any ordering assertion.

```bash
.claude/skills/vibe-stress/scripts/make-cloud-corpus.py --folders 12 --per-folder 40   # needs ffmpeg
make stress CORPUS=build/stress-corpus ARGS="--profile cloud --duration 2400 --iterations 100000"
```

`--profile artwork` aims at the folder-artwork fallback: opens through all three resolve strategies (a folder, a burst of files, a lone file), the playlist visible far more often than elsewhere so cell draws pull thumbnails off the resolver concurrently with the header's display-size load, and the setting flipped underneath both. Pair it with a corpus built for it — one cover per accepted filename, the near-miss names, the unreadable and undecodable and oversize covers, a cover that is a directory and one that is a FIFO.

Four op kinds exist because nothing else would produce them: `open_burst` above, `held_fx` (a `key_down w` whose `key_up` is sometimes lost across a track change, latching a momentary effect), out-of-range `seek` and `set_pitch` values, where the clamp escaping is the finding, and `folder_art`, which flips `set_folder_art` — the one change that drops every answer the resolver holds, landing on resolves and decodes already in flight while the playlist draws cells off the same tables.

**`folder_art` emits `off` and `on` as a pair, and that shape is load-bearing.** See the settings trap below.

**Deliberately excluded from every profile**: `convert_to_flac`, which writes beside the source and can trash the original — the corpus is real music. Right-clicks and lone `mouse_down` are excluded too, for the wedge reasons in `vibe-debug`, and menu items are filtered through a denylist covering anything modal, quitting, hiding or closing, since the channel cannot be served while a modal panel is up.

## The cloud scenario suite: named situations, asserted on the trace

`stress.py` drives randomly and watches for violations. `cloud-scenarios.py` is the third shape, and it exists because the cloud work's guarantees are all about **order** — which download runs next, which is abandoned, which never starts — and order is exactly what a seeded monkey cannot state.

```bash
.claude/skills/vibe-stress/scripts/cloud-scenarios.py --corpus build/cloud-scenarios-corpus
.claude/skills/vibe-stress/scripts/cloud-scenarios.py --corpus <dir> --only S4b,S7 --verbose
```

A small corpus is enough (3 folders × 14 tracks builds in a minute). The first two folders must each contain 6–40 playable files: larger folders belong to the random stress profile and can outlive a named scenario's bounds or rotate its finite trace. The live deadline scenarios install short diagnostic timeout budgets; production's 60-second constants and arithmetic stay pinned in XCTest. Run `make check-cloud-scenarios` first for the runner's trace-helper tests, then budget several minutes for the live suite's fresh app launch per scenario.

The runner snapshots `pauseAtTrackEnd` once before the scenario loop. Each fresh scenario normalizes it off through the running controller (including re-parking the successor) and attempts to restore that original baseline before quitting; an outer cleanup launches a fresh process and restores it again at process exit, even if a scenario killed its process. Successor/prefetch scenarios therefore cannot silently inherit Settings > Playback = Pause, and the suite does not leave the preference changed.

Five rules the file is built on, each of which first failed in a plausible-looking way:

- **Use trace sequence for ordering.** `dump_cloud_trace` records every transfer's requested / started / completed / cancelled with its role and a sequence number. Elapsed time only bounds waiting except in the deadline and deferred-fallback scenarios, where the fake trace clock or the runner's monotonic clock plus a tolerance asserts the timing policy itself.
- **Match the role that was actually recorded.** Metadata work is split into `metadata-priority` and `metadata-scan`; a family assertion for `metadata` must match both, while an ordering assertion names the exact lane. An exact-only `metadata` matcher silently made the old sweep checks vacuous.
- **Choose the trace edge that states the claim.** `requested` is emitted before the fake provider's capacity queue and proves the app admitted work; `started` proves a provider slot ran it. A capacity-one test that looks only at `started` can hide an illegally admitted request behind the foreground transfer it is supposed to exclude.
- **One clean launch per scenario.** The launch opens the corpus to establish the sandbox grant, which also starts work, so the runner requires `quiesce.settled`, then clears caches, before it arms the fake. `set_fake_cloud` deliberately preserves the completed/cancelled tally across a re-arm, the metadata cache persists to disk, and a hold left over from a previous scenario is indistinguishable from one this scenario lost.
- **`capacity=1 uniform` unless a scenario says otherwise**, for the reason above, and because the 0.5x–2x per-file spread would otherwise fight every ordering assertion.

**The live deadline cases test wiring; XCTest tests the production budget.** `set_audio_loading timeout-baseline=... timeout-silence=...` applies one immutable diagnostic snapshot to the coordinator, player and metadata loader, which the runner verifies with `dump_audio_loading.aligned`. This turns minute-long waits into seconds without restating the production constants. S8b deliberately advances by less than 1% per tick so only the monitor's raw movement feed, not its UI-coalesced delivery, can keep the open alive.

**Keep deterministic machinery in `make test`; reserve this suite for live composition.** XCTest runs the real `AudioTrackMetadataLoader` control plane and real materialization coordinator behind injected cache-read, file-parse and provider-operation boundaries, plus `DownloadProgressMonitor`, the materializer, loading-policy arithmetic, the transfer registry and `VibeFakeCloud`'s option/trace accounting. It also exercises the materializer's real local `NSFileCoordinator` wrapper, allocated-size polling, injected iCloud query lifecycle and injected File Provider publication/KVO lifecycle. `make test` runs `make check-cloud-scenarios` too, whose Python tests pin role-family matching, request/transfer span assembly, exact ordering, corpus bounds and `--only` validation. The live scenarios own what host-less tests cannot honestly reproduce: the app shell's deferral and routing, AppDelegate append, playback settlement through AVFoundation, row-loading projection, and the composition of the real queues with the provider seam. Actual provider-mediated coordination/cancellation, `SF_DATALESS`, OS discovery/cross-process progress publication and named-provider behavior still require a real-provider run; the fake-provider suite cannot certify them.

**The current registry has 25 scenarios.** Its clean expected report is `PASS=24 XFAIL=1`, with S9 the XFAIL and no `FAIL` or `ERROR`. An `XPASS` remains a finding to investigate, not proof by itself. Current S20 checks that row loading follows live provider transfers; the older proposal that also used the S20 label for a purpose-specific gapless wedge remains deliberately absent because basename-based live instrumentation cannot distinguish gapless from prefetch. That purpose is pinned directly in XCTest.

**Expected-fail scenarios are run and reported, never skipped**, so the day one starts passing is visible. An expected-fail that passes is reported as `XPASS` and is a finding in its own right — it means either the gap closed or the scenario stopped reaching it, and both are worth knowing. Only the scenario's explicit `ExpectedGap` evidence becomes `XFAIL`; setup failures and every other assertion remain `FAIL`. `XFAIL` does not fail the run; `XPASS`, `FAIL`, and `ERROR` do. S9 is the one current XFAIL: a provider that withholds `SF_DATALESS` is indistinguishable from a genuinely local file at the admission seam, so the local-file exemption can admit its metadata read during foreground playback. Unlimited fake-provider capacity keeps that request visible instead of hiding it in a provider queue; a real-provider run still determines whether a named provider has this shape.

**`block_main <seconds> [<verb> ...]` is the instrument that makes main-thread ordering testable at all**, and it is worth knowing why two commands cannot replace it. The channel's own intake is on the main queue, so while main is held nothing else can even be *enqueued* — a callback the app dispatched to main from a worker always wins the race against a command the test sends afterwards. Blocking and then running the next verb *without yielding* is the only way to imitate what a click handler is: a main-thread turn that was already underway when the callback arrived. `open` will not do as the chained verb, either — the open funnel is asynchronous, so its play lands in a later turn, behind the callback rather than ahead of it. `play_index` is synchronous and does.

## The torture suite: one playlist, transport hammered

`stress.py` keeps *opening* files. `torture.py` is the opposite shape and catches what that cannot: it loads **one large playlist** and then drives transport as fast as the channel allows, so track changes outrun the metadata scan, the waveform load and the analyzers, and seeks land on tracks that have already been replaced.

```bash
.claude/skills/vibe-stress/scripts/run-torture.sh <Vibe.app> <playlist-folder> [--rounds 40] [--burst 40] [--seed N]
make torture APP=build/DerivedData/Build/Products/Debug/Vibe.app PLAYLIST=~/Music/big
```

Ops go through the channel's `script -` verb, so a burst is **one** CLI invocation rather than one per op — that is what makes it a torture test rather than a brisk fuzz. Measured ~15 ops/s of real track changes, each `next` a full open.

Four phases, no settle anywhere: `skip` (next/previous storm), `seek` (including out-of-range and past-the-end values, where escaping the clamp is the finding), `mixed` (skips, seeks, play/pause and the bar-based skip actions), and `boundary` (walking off the end of the playlist repeatedly, which is the end-of-playlist park and `finishCurrentTrack`). Between every burst: alive, `check_consistency`, and fds / engine nodes / live heap / views against baseline; at the end a `quiesce` that requires every `pending` counter to unwind to zero. Seeded and replayable with `--seed`, like `stress.py`.

**Run it through `run-torture.sh`, not by hand**, because three separate things have to be true before a result means anything, and each has burned a run: exactly one mac instance is up, it is the binary you intended, and the caches are cold. The wrapper asserts all three and aborts loudly rather than producing a confident-looking pass.

**Cold caches are the whole point, not hygiene.** The delivery races this suite hunts only open while a scan is still in flight as playback starts. A warm cache closes that window before the first track plays — a suite that passes 6400 ops warm has proven far less than it appears to. `run-torture.sh` runs `clear_caches` for you.

**Where the nil-metadata crash actually lived**, since it is the worked example: `renderState` passed `track.metadata.fileInfoLine` — a message to nil whenever the scan had not landed — into `-[NSAttributedString initWithString:]`, which raises. The trigger is **a large file plus a cold cache**, playback starting before the scan finishes; a 137 MB MP3 did it every time, and unparseable files did *not*, because those take the error branch, which passes a literal. Reproduce with `open <large file>` on a cold cache, not with a corpus of broken ones.

## Traps, each found by the harness misfiring

**A random clicker will quit the app if you let it.** The window draws its own close and minimize buttons as `SymbolButton`s in its top-left corner, and `closeApp:` is `[self close]` — so a uniform random click finds them within a few hundred ops. The driver reads their frames out of `dump_view_tree` at startup and excludes those rects (plus a fixed top-left fallback), and it also distinguishes the two ways the app can vanish: gone **with** a fresh `.ips` is a `crash`, gone **without** one is an `exit`, meaning something in the op stream asked it to quit. Reporting a clean exit as a crash sends you hunting for a stack that was never written.

**Never `sample Vibe` by name.** The CLI client is the app binary, so the name matches every in-flight `--debug-cmd` invocation too, and sampling one yields a stack of the client polling for its own response — `VibeDebugClientRunOne` sitting in `usleep`, which reads exactly like a hang and says nothing whatever about the app. Resolve the GUI instance's pid first by filtering `pgrep -x Vibe` for the process whose argv lacks `--debug-cmd`, and sample that. Sample *before* re-probing, too: a probe that succeeds means the stall already ended and took its stack with it.

**A setting the fuzzer toggles persists across runs, and a disabled feature looks exactly like a clean run.** `AppSettings` lives in `NSUserDefaults`, so a run inherits whatever the *last* one left — including a fuzzer's own random final toggle. Reconstructing `set_folder_art` from the journals of four runs that all reported passes: the feature was on for 49.5%, **36.3%**, 46.8% and 42.3% of their ops, and two of them *ended* off, poisoning every later hand-run probe against the same container. With it off the artwork accessors return before they reach the resolver at all, so those ops exercise none of the code the run was aimed at — and nothing in the summary says so. Two fixes, both needed: the driver forces every entry in `FEATURE_SETTINGS` on at launch and prints it in the header (`settings: folderArt=on`), and the toggle op emits `off` then straight back `on`, which buys both invalidation edges while leaving the feature on essentially throughout and lands the user's setting where it started. **Verify the duty cycle from the journal before believing a coverage claim** — count the `set_folder_art` ops and the gaps between them; the fixed op yields ~98.5% on.

**`open -a <path>` resolves by BUNDLE ID, not path — so it cannot choose between two builds.** Every build of Vibe is `com.commonwealthrecordings.Vibe`, and `open -a` launches whichever copy LaunchServices has registered, silently ignoring the path given. A fix-vs-pre-fix comparison run that way tests one binary twice and "proves" the fix unnecessary; `VIBE_APP` does not save you, because `launch.sh` honors it and then hands the path to `open -a` anyway. Direct-exec the binary and **verify what came up** with `ps -o comm=` before trusting a single op — that is what `run-torture.sh` does. `lsregister -f` is not a fix either: it can leave *both* copies running.

**A second instance answers the channel, and one of them is the iOS Simulator's.** Two mac instances make every result belong to a build and grant set you did not choose; worse, they contest the channel and it stops answering entirely, which presents as "app never answered" against a process whose main thread is idle and perfectly healthy. `pgrep -x Vibe` also matches the **Simulator's** Vibe, so an instance check that does not exclude `*CoreSimulator*` reads a running simulator as a second mac app. And a debug session in **Xcode** is a second instance too: check before running anything that pkills.

**Do not debug the harness while a driver is running.** Several hours went into "the channel is broken" that was really a background run relaunching the app underneath the investigation. Stop the driver first, confirm no Vibe is up, then investigate.

**A concurrent Xcode build silently swaps the binary under a run in progress.** `build/DerivedData` is the same path Xcode writes, so a ⌘B in the middle of a campaign means later ops ran against a different binary than earlier ones, with nothing in the output marking the seam. For any run whose result must be attributable, build to a private `-derivedDataPath` and pass it with `--app`.

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

**Do NOT add a `suppressions=` file, however tempting.** It deadlocks the launch before `main()`: TSan reads it from `__tsan::Initialize` inside dyld's initializers, and that `open()` never returns under the sandbox —

```
libSystem_initializer → __guard_setup → wrap_strlcpy
  → __tsan::Initialize → InitializeSuppressions → ReadFileToBuffer → OpenFile → open()   [blocked forever]
```

The process stays alive, logs nothing, and never registers the debug channel, so from outside it is indistinguishable from the `log_path` trap above. Being inside the container does not help — `log_path` is opened much later in startup, `suppressions` is not. Live with TSan's framework noise and filter the report afterwards.

Three builds catch disjoint bug classes, and **TSan matters most here**: the whole threading contract — every engine mutation on the serial player queue, non-blocking UI-facing getters, delegate callbacks on main — is exactly what it validates, and a race there is invisible to every other oracle in the table above.

- plain Debug: fastest, most iterations, catches logic, assertions and hangs
- `-enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES`: roughly 3x slower; aim it at malformed files, where input reaches TagLib's C++
- `-enableThreadSanitizer YES`: a separate build, incompatible with ASan

Cheap variants on the plain build, same direct-exec launch: `NSZombieEnabled=YES`, `MallocScribble=1`, `MallocGuardEdges=1`, `MallocStackLogging=1` (needed for `leaks Vibe` to give allocation stacks). `heap Vibe` gives per-class live instance counts from outside the process, which is the attribution `dump_health`'s process-level numbers deliberately leave out.
