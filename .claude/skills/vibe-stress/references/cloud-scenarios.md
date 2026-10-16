# Cloud scenarios

The cloud scenario suite's rules, registry and XFAIL contract, the `block_main` instrument, and the real-provider mode. Read when writing or debugging a scenario, or deciding whether a cloud check belongs here or in `make test`.

The registry is `SCENARIOS` near the bottom of `scripts/cloud-scenarios.py`. Each entry is `(id, function, expected_fail, real)`. `real` is the scenario's real-provider function, or `None`. `FAKE_ONLY` holds each fake-only scenario's reason.

## Five rules

- **Use trace sequence for ordering.** `dump_cloud_trace` records every transfer's requested, started, completed and cancelled events with its role and a sequence number. Elapsed time only bounds waiting. The exceptions are the deadline and deferred-fallback scenarios, where a clock plus a tolerance asserts the timing policy itself.
- **Match the role that was actually recorded.** Metadata work is split into `metadata-priority` and `metadata-scan`. A family assertion for `metadata` must match both, and an ordering assertion names the exact lane. An exact-only `metadata` matcher makes the sweep checks vacuous.
- **Choose the trace edge that states the claim.** `requested` is emitted before the fake's capacity queue and proves the app admitted work. `started` proves a provider slot ran it. A capacity-one test that looks only at `started` hides an illegally admitted request behind the foreground transfer it should exclude.
- **One clean launch per scenario.** The launch opens the corpus to establish the sandbox grant, which also starts work. So the runner requires `quiesce.settled`, then clears caches, before arming the fake. `set_fake_cloud` keeps its tally across a re-arm, the metadata cache persists to disk, and a leftover hold is indistinguishable from one this scenario lost.
- **`capacity=1 uniform` unless a scenario says otherwise.** At unlimited capacity nothing waits on anything, and the per-file duration spread fights every ordering assertion.

## Settings the runner owns

The runner snapshots `pauseAtTrackEnd` before the loop. Each scenario turns it off through the running controller and restores the baseline before quitting. An outer cleanup restores it again at exit, even if a scenario killed its process.

## Live deadline cases test wiring; XCTest tests the budget

`set_audio_loading timeout-baseline=... timeout-silence=...` applies one diagnostic snapshot to the coordinator, player and metadata loader, verified by `dump_audio_loading.aligned`. Minute-long waits become seconds without restating production's 60-second constants, which stay pinned in XCTest. S8b advances by less than 1% per tick, so only the monitor's raw movement feed, not its UI-coalesced delivery, can keep the open alive.

## Keep deterministic machinery in `make test`

XCTest runs the real `AudioTrackMetadataLoader` control plane and materialization coordinator behind injected cache-read, file-parse and provider boundaries. It also covers `DownloadProgressMonitor`, the materializer, loading-policy arithmetic, the transfer registry and `VibeFakeCloud`'s accounting. `make check-cloud-scenarios` (`tests/test_cloud_scenarios.py`, run by `make test`) pins the runner's role matching, span assembly, ordering, corpus bounds and `--only` validation, so a broken oracle cannot make the live run green.

The live scenarios own what host-less tests cannot reproduce: the shell's deferral and routing, AppDelegate append, playback settlement through the real player and its file handle, row-loading projection, and the real queues composed with the provider seam. Provider-mediated coordination and cancellation, `SF_DATALESS`, OS discovery, cross-process progress and named-provider behavior need the real-provider mode (Real provider, below).

## The registry and the XFAIL contract

24 scenarios, S1–S21 with a/b/c variants and no S9. A clean report is `PASS=24`. Expected-fail scenarios are **run and reported, never skipped**, so the day one starts passing is visible. Only the scenario's explicit `ExpectedGap` evidence becomes `XFAIL`. Setup failures and every other assertion stay `FAIL`.

**S9 stays unused.** It staged a provider that withholds `SF_DATALESS`, which no measured provider does. Run `set_dataless_diag` against a new provider before bringing it back.

**S20** checks that row loading follows live provider transfers. Gapless-specific wedging is pinned in XCTest instead, since basename-based live instrumentation cannot tell gapless from prefetch.

## `block_main <seconds> [<verb> ...]`

The instrument that makes main-thread ordering testable. The channel's intake is on the main queue, so while main is held nothing can be enqueued. A callback the app dispatched to main from a worker always wins against a command sent afterwards. Blocking and then running the next verb without yielding imitates a click handler: a main-thread turn already underway when the callback arrived. **`open` will not do as the chained verb**, since the open funnel is asynchronous and its play lands in a later turn. `play_index` is synchronous and does.

## Real provider

`--provider real --folder <path>` runs the suite against a real iCloud Drive folder, with no fake. It covers what the fake replaces: the real `SF_DATALESS` verdict, the provider's own coordination and cancellation, and the real progress sources. **No real run has been recorded yet.** The first one is a finding either way.

### Preparing the folder

- Sign in to iCloud Drive, on macOS 14 or later. A placeholder there keeps its name. The runner refuses a folder holding legacy `.icloud` stubs.
- `brctl` must be on the path. It ships with macOS.
- Build a small corpus and copy it into iCloud Drive. Leave out the 20 MB `.wav` copies, since the runner refuses any file over 4 MB.

  ```bash
  .claude/skills/vibe-stress/scripts/make-cloud-corpus.py --out build/cloud-real-corpus --folders 2 --per-folder 12
  rsync -a --exclude '*.wav' build/cloud-real-corpus/ ~/Library/Mobile\ Documents/com~apple~CloudDocs/VibeCloudScenarios/
  ```

- The first two subfolders each need 6 to 40 playable files, as in the fake mode. Files between 100 KB and 4 MB suit. A file that downloads inside one poll cannot be seen, and its scenario reports `ERROR`.
- Wait until every file has uploaded. `brctl evict` refuses a file that has not.
- Open the folder once in the Debug app, to grant it. The runner's own launch then reaches it.

### Running

```bash
.claude/skills/vibe-stress/scripts/cloud-scenarios.py --provider real \
    --folder ~/Library/Mobile\ Documents/com~apple~CloudDocs/VibeCloudScenarios
.claude/skills/vibe-stress/scripts/cloud-scenarios.py --provider real --folder <path> --only S20 --wait-scale 3
```

A clean real run reads **`PASS=14  SKIP=10`** with no `FAIL` or `ERROR`. `SKIP` does not fail the run. The `PASS=24` contract is the fake mode's.

Each wait is bounded by a named constant. One file's transfer gets 60 s (`REAL_TRANSFER`). An eviction gets 30 s to land (`REAL_EVICT`). A claim leaving the registry, or the player landing, gets 10 s (`REAL_SETTLE`). `--wait-scale N` multiplies all of them. Reach for it on a slow network, before reading a timeout as a finding.

### What the runner does around each scenario

1. A fresh launch, `quiesce` and `clear_caches`, as in the fake mode. `dump_cloud_trace`'s stats must show the fake not installed.
2. `brctl evict` on every audio file in the first two subfolders. The runner then reads each file's `st_flags` until all carry `SF_DATALESS`. A file that will not evict, or is still local after the wait, makes the scenario `ERROR`.
3. `set_dataless_diag on`, then the scenario.
4. `quiesce`, then three closing checks. The coordinator's cumulative counters must not have gone backwards. `check_consistency` must report no `cloud.*` violation that survives a second sample. `dump_dataless_diag` must show the app's own stat answering dataless in a scenario folder. Otherwise the scenario met only local files, and it is `ERROR`.

The diagnostic counts per directory, not per file. That is why the runner verifies each file's eviction itself. It uses the app's record only to rule out a vacuous pass. Both diagnostic verbs join the command gate in `cloud-scenarios.py`, not in `stress.py`, so random stress never sends them.

### The oracle without a trace

A real transfer leaves no `dump_cloud_trace`. The runner samples `dump_row_loading` and the coordinator's `foregroundTransferActive` instead. `sample_events` turns the samples into trace events. A file appearing between two samples is `started`, and one leaving is `completed`. The sample index is `seq`, and `role` is `None`. The trace helpers then serve both modes. The file's own `SF_DATALESS` says whether its bytes arrived. A failing scenario prints these events as its trace.

How the five rules carry over:

- **Trace sequence** becomes the sample index. The counters give the rest of the order, and they only rise. A sample can miss a transfer shorter than one poll. So every real assertion is about what was observed. A step that needed to see a transfer and did not is `ERROR`, never a pass.
- **Role matching** cannot hold. The registry names files, not roles. A scenario tells the foreground's file from the others by what it played.
- **Choosing the edge** comes down to `started`. Contention is a `held` start of a file other than the foreground's. `held` means both samples around it read the hold. A hold that fell and rose between two samples hides an arrival. So this oracle can miss contention, but it cannot invent it.
- **One clean launch per scenario** holds. Eviction follows the quiesce.
- **`capacity=1 uniform`** cannot hold. The provider's capacity and durations are its own. The app's one-wide background lane still serializes the scan. S5 and S6 rely on that.

### What each scenario asserts

| Id | Real-mode assertion |
| --- | --- |
| S1 | After folder B's open, every A transfer leaves the registry. No A file arrives again, and no background file arrives under the hold. |
| S2 | While the picked row 5 downloads, the hold is up and no other file arrives under it. Two other files then land, and the sweep attempted rows. |
| S3 | The successor lands, and the playlist resolves. The successor went on the wire at most once. |
| S4a | Eight rapid nexts land on the expected row. The superseded opens leave the registry. No file outside the storm and its successor arrives under the hold. |
| S5 | The observed scan arrivals have no duplicate, and they follow rank, then index. Fewer than two observed is `ERROR`. |
| S6 | The first scan arrival after the park is the played row's next, next-but-one or previous. |
| S7 | A play aimed at a live scan transfer joins it. The file goes on the wire once, and no claim yields. The rows resolve, with no contention seen. |
| S11 | Three appends during the first file's transfer keep the exact rows. Replaying a file already local puts nothing on the wire. |
| S14 | Two play storms across a replacement, then Close, leave no loading residue. |
| S16 | Close during the picked file's transfer leaves the registry empty for 3 s, with no residue. |
| S17 | Play/pause during the transfer lands paused on the picked file. Its one transfer runs to term, and the file is local. |
| S19 | While `hang_open` wedges the successor's handle open, two scan files arrive and resolved rows rise. |
| S20 | The playback transfer, then a scan transfer, each project as the sole loading row at its playlist index. Both clear at settlement. |
| S21 | Every row resolves, and at least one transfer was seen. Every row's file is then local. |

### Fake-only scenarios

Each is reported `SKIP` with its reason from `FAKE_ONLY`.

| Id | Why only the fake can state it |
| --- | --- |
| S4b | Every replay must pay a fresh transfer of a known length (`sticky`). |
| S8a, S12a | They need a transfer that reports no progress (`progress=none`). |
| S8b | It needs a 600 s transfer that moves under 1% a second (`progress=linear`). |
| S8c, S12b | They need a transfer that stalls at 40% (`progress=stall`). |
| S10, S15 | They need a scripted provider failure (`fail=`). |
| S13 | Its ground truth is the fake's overlap count. S7 owns the observable join. |
| S18 | It needs a transfer that never ends. |

### Known limits

- **Eviction is asynchronous.** `brctl evict` returns before the file is dataless. The runner waits for the flag. A provider that rematerializes a file by itself after the check is outside the runner's control.
- **The provider's throttling is not the runner's to control.** iCloud can queue, slow or batch downloads. That moves timing, never what the app must do. Widen the waits with `--wait-scale` before reading a timeout as a finding.
- **Cancelling stops the app waiting, not the provider** (`Vibe/Loading/AGENTS.md`). A cancelled file can still finish downloading. A file that turned local therefore never proves alone that the app asked for it. S2 and S21 pair it with the app's own metadata counts.
- **The launch costs downloads.** Each launch opens the whole folder for its grant. That starts a play and a scan before the quiesce.
- **Only iCloud Drive evicts.** The runner evicts with `brctl`. Another File Provider folder runs only if every file is already dataless.
