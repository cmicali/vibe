# Coverage plan: the materialization coordinator and the silent-stall class

Split out of `docs/bugs/background-lane-wedged-open-starvation.md` on 2026-08-21 so it can be executed **before** that fix. That document diagnoses one bug; this one is the standing coverage work it exposed, most of which is worth doing whether or not the fix lands in the shape proposed there.

The bug in one line: a background-lane `AVAudioFile` open that never returns holds its admission slot forever, which permanently starves all cloud background materialization. Read `## Why the harness did not catch it` (W1–W6) in the bug doc before starting — this plan is the answer to it, and several items only make sense against that diagnosis.

**Anchors** are against `main` at `f814829`. Re-check before acting.

## Status — executed 2026-08-21, pre-fix

Everything below landed against the unfixed code except A2–A5, which name the fix's API. `make test` 917 tests green, analyzer clean on both targets, `check-layout` and `check-vocabulary` green, iOS builds.

| Item | Landed as | Result |
| --- | --- | --- |
| C2 | Cumulative counters on the coordinator: `handleOpensStarted/Completed`, `requestsReady/Failed/Yielded/AdmissionExhausted` | done — named per *outcome per request*, not the plan's vaguer `transfersCompleted`; a claim four waiters joined settles four requests, and requests are what callers see |
| B1 | Teardown accounting invariant in both coordinator test files | done — **passed on all 911 pre-existing tests**, so the carried-slot accounting is correct in every non-wedged path; the bug really is only the never-returning open |
| B2 | `testAWedgedOpenIsNotAForegroundTransfer` | passes |
| B3 | `testAWedgedPlaybackOpenDoesNotStarveForegroundTransfers` | passes — the asymmetry is now a test result, not a comment |
| A1 | `testAWedgedPrefetchOpenDoesNotStarveBackgroundTransfers`, and the gapless twin | **XFAIL, deterministically** — the bug reproduced host-lessly on both paths into the lane |
| E1 | `handleOpensInFlight` in `dump_health`'s `pending` | done, **verified live**: wedged → `quiesce` returns `settled: false, {handleOpensInFlight: 1}`; released → `settled: true` |
| C1 | `hang_open <basename>\|release` debug verb + a chained opener wrapper | done — the open-side seam the fake provider never had |
| E5-field | `resolvedRows` in `dump_state.playlist` | done |
| D4, E2 | S18 retrofitted to read `foregroundTransferActive` | passes, and its note now says *why* nothing started |
| D1 | **S19** — a wedged prefetch open does not starve the sweep | **XFAIL end to end**: *"38 rows still want scanning, no foreground transfer holds the lane, and not one metadata transfer started in 8s"* |
| D3 | **S21** — the library converges | passes (all 40 rows resolved) |
| E3 | `cloud.handle_open_stranded` in `check_consistency` | done — a *condition* check beside `cloud.hold_outlives_playback`, not a threshold |
| E4 | Reported, not scored | admission refusals print in the run summary with a warning when they exceed requests served; a scored threshold would fire on ordinary capacity pressure |
| F1 | `exercised:` line in the stress summary | done — prints `[NONE — this run covered no stage 2]` when a run performed no handle opens |
| F2 | `testOutcomeCountersMoveWithRealWork`, `testAdmissionExhaustionIsCounted` | done |
| **D2 (S20)** | **not implemented — deliberately** | see below |
| A2–A5 | — | deferred to the fix, as planned |

**Why S20 was dropped.** `hang_open` matches by basename, and a successor's prefetch open and its gapless open are opens *of the same file* — so at the scenario level the two are not separable, and a scenario claiming to wedge gapless would in practice be wedging whichever ran first. That is precisely the S18 defect this plan exists to correct, so writing it would have been worse than not writing it. The gapless path is instead pinned deterministically by the unit test, where the purpose is chosen explicitly rather than inferred.

## Execution order and fix dependency

Most of this is executable now. Only the items that name the fix's new API have to wait.

| Item | What | Pre-fix? |
| --- | --- | --- |
| C2 | Cumulative counters in the coordinator | yes — substrate for E1/E4 |
| B1 | Counters balance at rest, in both test files' teardown | yes — do this first, it retro-covers everything |
| B2, B3 | C1-rule independence, cross-seam admission | yes |
| A1 | The regression test itself | yes, **expected-fail** until the fix |
| E1 | Coordinator counts into `dump_health` → `quiesce` | yes |
| E5-field, C1 | `resolvedRows`, `hang-open` fake-cloud mode | yes — prerequisites for every D item |
| D1–D4, E2 | S19/S20 (expected-fail), S21, S18 retrofit | yes |
| E3, E4, F1, F2 | Saturation, admission rate, coverage reporting | yes |
| **A2–A5** | Open-admission bound, slot lifecycle, gapless slot, config | **no** — these name `maximumConcurrentHandleOpens` and the new slot lifecycle, so they land with the fix |

**Expected-fail is the pattern here, not a workaround.** `cloud-scenarios.py` already has it, and the skill's rule is the right one: *"Expected-fail scenarios are run and reported, never skipped, so the day one starts passing is visible."* An expected-fail that starts passing is `XPASS` and is a finding in its own right. A1, D1 and D2 land marked, and the fix's commit is what unmarks them — which is also how the fix proves it fixed something.

## The missing oracle category

Everything in the four-oracle table answers *"did something grow, hang, go inconsistent, or die?"* Nothing answers *"is the app still doing the work it has been asked to do?"* A silent capability loss — work that stops being attempted rather than failing loudly — passes every existing oracle by construction: counters stay small, nothing crashes, no invariant is violated, the app answers the channel promptly. That is the whole reason this survived.

The fifth row of that table is a **progress oracle**: with outstanding demand and no documented gate in force, cumulative completed-work counters must advance. Its three ingredients, none of which exists today:

- **Cumulative counters, not gauges.** The coordinator publishes instantaneous gauges (claims, waiters, running, pending). A gauge cannot distinguish "nothing is happening" from "a great deal is happening quickly". Monotone counters can: `transfersCompleted`, `handleOpensStarted`, `handleOpensCompleted`, `admissionsRefused`, `claimsYielded`. `VibeFakeCloud statistics` already keeps exactly this shape of tally across a re-arm; apply it to the coordinator itself.
- **A demand signal**, so flat progress is only a violation when there is work outstanding: unscanned sweep records, rows still on filename-derived titles, `cloudParsesPending`.
- **A gate signal**, so a legitimate hold is not read as starvation. `foregroundTransferActive` is already published in `debugState` and is precisely the distinction W2 says S18 cannot make.

With those, the violation is one line: *demand > 0, progress flat across the window, and no gate in force*. Under this bug it fires within a second of the wedge on any cloud corpus.

Two cheaper derivations of the same idea are worth having on their own, because they need no new concepts:

- **In-flight opens must reach zero at rest.** `handleOpensStarted - handleOpensCompleted` is the count of live handle runs; if it is non-zero after a `quiesce`, an open is stranded. That is this bug, stated as an invariant, and `quiesce` already has the machinery — `VibeIsSettled` (`DebugHealth.m:264`) iterates the whole `pending` dictionary, so a counter added to `VibePendingCounts` is automatically waited on, and a wedged run keeps `settled: false` and names itself in the reported `pending` block at the 15 s deadline. Highest leverage single change in this document.
- **Convergence, stated in user terms.** After a folder is opened and everything settles, *every* row should carry resolved metadata. That assertion knows nothing about lanes, claims or slots, so it survives every refactor of the mechanism and catches the whole class rather than this instance. It needs one new field — see item E5.

## Test coverage to add

Items are lettered; the fix steps they pair with are numbered 1–7 in the bug doc's `## The fix`.

### A. Unit tests for the fix

A1 lands now, marked expected-fail. A2–A5 name the fix's new API and land with it.

Host-less, in `Tests/AudioFileOpenCoordinatorTests.m`, using `initWithConfiguration:operationFactory:datalessProbe:clock:fileOpener:` so a hanging opener and a fake dataless probe compose.

- **A1. The B1 regression itself.** Wedge a gapless or prefetch open on path A, then run a dataless metadata claim on path B through its full retry budget and assert it *starts* rather than exhausting. This is the test whose absence is the bug.
- **A2. Wedged opens bounded by the new admission.** `N+1` wedges on distinct paths; the last settles `AdmissionExhausted`, and the transfer counts are untouched throughout.
- **A3. Slot lifecycle.** Released on completion, released on stage-1 detach, and **not** double-released across the abandoned-then-rebound restart in `finishHandleRun:` (`:1224-1228`) — the path that keeps `_handleRuns` membership and so must neither release nor re-acquire.
- **A4. Gapless takes an open slot, not a transfer slot**, and no longer bypasses its bound the way `:1115-1122` bypasses the lane's today.
- **A5. Config.** Validation limits for `maximumConcurrentHandleOpens` in `AudioLoadingConfigurationTests.m`, and the `handle-opens` key in `AudioLoadingConfigurationDebugTests.m`.

### B. Durable unit invariants that would catch the next one

These are the ones worth having even if the fix changes shape. Each is generic — it pins the accounting rather than this bug.

- **B1. Counters balance at rest.** A shared assertion in the `tearDown` of *both* coordinator test files: once all work has settled, `interactiveRunning`, `backgroundRunning` and the new open count are all zero. This is the unit-test analogue of the `quiesce` oracle, it costs nothing per test, and it would have failed the moment a carried slot leaked. **Add this first** — it retro-covers every existing test in both files.
- **B2. The C1 rule is independent of the counters.** `foregroundTransferActiveLocked` derives from `_claims`, never from the running counts. Pin it: with a wedged open holding capacity, `isForegroundTransferActive` still answers from the claim table alone. This is what makes the split safe to do.
- **B3. Cross-seam composition, as a habit.** At least one test in each file that reaches across the stage-1/stage-2 join, since W6 is that neither file crosses it. A wedged stage-2 run on path A must not change what stage 1 will admit for path B, in either lane.

### C. Harness prerequisites

- **C1. A `hang-open` mode in `VibeFakeCloud`** — materialize successfully, then block the first read, releasable on command. Everything in D depends on it, and it is the one capability the fake provider lacks that this whole class of bug lives behind. It belongs beside `VibeFakeCloudProgressMode` (`VibeFakeCloud.h:42-48`) but is a *separate* axis: progress mode shapes stage 1, this shapes stage 2.
- **C2. Cumulative counters in the coordinator's `debugState`** (`AudioFileMaterializationCoordinator+Debug.m`): `handleOpensStarted`, `handleOpensCompleted`, `transfersCompleted`, `admissionsRefused`, `claimsYielded`, plus the `handleRunCount` it already computes and drops. These are the substrate for D and E both. Cumulative for the life of the process, for the reason `DebugConsistency.m:258-263` gives about the fake provider's tallies: none of these is ever *transiently* wrong, so a re-check must not filter it away.

### D. New cloud scenarios

- **D1. S19 — a wedged *prefetch* open does not starve the sweep.** S18's shape, but wedging stage 2 on the successor, asserting a dataless metadata transfer *does* start afterwards. The end-to-end pin for this bug.
- **D2. S20 — a wedged *gapless* open does not starve the sweep.** A separate scenario, not a parameter of D1: gapless reaches the lane by a different path (`:1115-1122`, no capacity check at all) and would keep working if only the `carrySlot` half were fixed.
- **D3. S21 — convergence.** Open a cloud folder, let it settle, assert *every* row carries resolved metadata. Mechanism-free, so it outlives any refactor of the lanes.
- **D4. Retrofit S18.** Give it the `["materialization"]` read it should always have had, so it distinguishes "gated by C1" from "starved" and its pass means what its name says.

### E. Oracle additions

- **E1. Add the coordinator's counts to `dump_health`'s `pending` section** (`VibePendingCounts`, `DebugHealth.m:165-188`). `VibeIsSettled` iterates that dictionary, so this alone makes `quiesce` refuse to settle on a stuck lane and name it in the reported `pending` block — turning this bug from invisible into a hard failure in every soak that touches cloud files. Include the in-flight open count from C2 (`started - completed`); that is the stranded-run signal.
- **E2. Score `dump_cloud_health["materialization"]` in `cloud-scenarios.py`.** The data has been reaching the harness all along (W3); read it.
- **E3. A saturation check in `check_consistency`.** A lane at capacity with a non-empty pending queue for longer than that lane's own admission grace is either genuine overload or a leak. Computable entirely from the already-published `debugState`, and it belongs beside the four `cloud.*` checks in `DebugConsistency.m:247-292` rather than in one scenario, for the reason that file gives at `:283-286`.
- **E4. An `AdmissionExhausted` rate oracle.** Terminal admission exhaustion is meant to be rare and transient — `MetadataRetryRules.h` says so in as many words. A cumulative count scored against a per-run threshold needs to know nothing about *why*; it just asserts that capacity refusal is not the normal outcome. Under this bug every dataless row burns three.
- **E5. The progress oracle proper**, per *The missing oracle category*: demand > 0 and cumulative progress flat across a window with no gate in force is a violation. Its demand signal needs one new field — `dump_state.playlist` today exposes only `{count, currentIndex, files}` (basenames), so add a per-row resolved flag or a `resolvedRows` count, derived from `AudioTrack.displayTitle`/`displayArtist`, which the root `CLAUDE.md` already makes the single home of that question. That field is also what D3 asserts on.

### F. Coverage self-reporting

The skill already learned this with `set_folder_art`: *"verify the duty cycle from the journal before believing a coverage claim."* The same trap is live here in a different form — a run that never performed a background-lane handle open has not tested any of this, and nothing in the summary says so.

- **F1. Report exercise counts in the run header and summary** — handle opens by purpose, cloud transfers by role, admission refusals. A run reporting zero background handle opens is not a pass, it is a no-op, and it should be as visible as `settings: folderArt=on` already is.
- **F2. Treat an all-zero counter as suspicious in its own right.** `MetadataParseCoordinatorTests.m:369` (`testDebugPendingCountsTrackHoldersAndWaiters`) exists because *"a counter that silently always read zero would look exactly like a clean run"*. Every counter added under C2 needs the same deterministic pin, or it becomes another number nobody has checked against ground truth.

## Verification for this plan

`make test`, `make analyze CONFIG=Release`, `make build`, `make build-ios`, `make check-layout`, `make check-vocabulary`.

Then `cloud-scenarios.py --corpus build/cloud-scenarios-corpus` end to end: S1–S18 stay green, S19 and S20 report **XFAIL** rather than FAIL, S21 passes. A green suite with S19/S20 reporting XPASS means either the bug is fixed or the scenarios stopped reaching it — both worth knowing, neither silent.
