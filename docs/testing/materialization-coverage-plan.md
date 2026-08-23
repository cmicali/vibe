# Coverage record: the materialization coordinator and the silent-stall class

Split out of `docs/done/background-lane-wedged-open-starvation.md` on 2026-08-21 so the coverage substrate could land **before** that fix. That document diagnoses one bug; this one records the standing coverage work it exposed and the fix-specific tests completed with it.

The original bug in one line: a background-lane `AVAudioFile` open that never returned held its transfer admission forever, permanently starving all cloud background materialization. Read `## Why the original harness did not catch it` (W1–W6) in the bug doc for the diagnosis this coverage answers.

**Anchors** are against `main` at `f814829`. Re-check before acting.

## Status — completed through 2026-08-23

The coverage substrate landed against the unfixed code on 2026-08-21. The fix-specific rows were completed with J8 on 2026-08-23; the table preserves the pre-fix result where that is what proves the regression was real.

| Item | Landed as | Result |
| --- | --- | --- |
| C2 | Cumulative counters on the coordinator: `handleOpensStarted/Completed`, `requestsReady/Failed/Yielded/AdmissionExhausted` | done — named per *outcome per request*, not the plan's vaguer `transfersCompleted`; a claim four waiters joined settles four requests, while a pre-stage-1 handle refusal settles one |
| B1 | Teardown accounting guarantee in both coordinator test files | done — **passed on all 911 pre-existing tests**, proving the original failure needed a never-returning open |
| B2 | `testAWedgedOpenIsNotAForegroundTransfer` | passes |
| B3 | `testAWedgedPlaybackOpenDoesNotStarveForegroundTransfers` | passes — the asymmetry is now a test result, not a comment |
| A1 | `testAWedgedPrefetchOpenDoesNotStarveBackgroundTransfers`, and the gapless twin | **XFAIL before J8; pass after it** — the bug reproduced host-lessly on both paths, then the fix closed it |
| E1 | `handleOpensInFlight` in `dump_health`'s `pending` | done, **verified live**: wedged → `quiesce` returns `settled: false, {handleOpensInFlight: 1}`; released → `settled: true` |
| C1 | `hang_open <basename>\|release` debug verb + a chained opener wrapper | done — the open-side seam the fake provider never had |
| E5-field | `resolvedRows` in `dump_state.playlist` | done |
| D4, E2 | S18 retrofitted to read `foregroundTransferActive` | passes, and its note now says *why* nothing started |
| D1 | **S19** — a wedged prefetch open does not starve the sweep | **XFAIL before J8; pass after it** — seven metadata transfers started behind the wedged open in the full-suite verification |
| D3 | **S21** — the library converges | passes — every row in the selected folder resolved |
| E3 | `cloud.handle_open_stranded` in `check_consistency` | done — a *condition* check beside `cloud.hold_outlives_playback`, not a threshold |
| E4 | Reported, not scored | admission refusals print in the run summary with a warning when they exceed requests served; a scored threshold would fire on ordinary capacity pressure |
| F1 | `exercised:` line in the stress summary | done — prints `[NONE — this run covered no stage 2]` when a run performed no handle opens |
| F2 | `testOutcomeCountersMoveWithRealWork`, `testAdmissionExhaustionIsCounted`, and the seventh-handle-run refusal assertion | done — both admission gates move the shared refusal counter |
| **D2 (S20)** | **not implemented — deliberately** | see below |
| A2–A4 | Fixed handle-run admission and lifecycle tests | done — six live keys admit, the seventh refuses before stage 1, same-key rebind still works, and membership follows the real run lifetime |
| A5 | Proposed handle-open configuration tests | deliberately dropped — J8 uses a private safety ceiling, not another loading knob |

**Why S20 was dropped.** `hang_open` matches by basename, and a successor's prefetch open and its gapless open are opens *of the same file* — so at the scenario level the two are not separable, and a scenario claiming to wedge gapless would in practice be wedging whichever ran first. That is precisely the S18 defect this plan exists to correct, so writing it would have been worse than not writing it. The gapless path is instead pinned deterministically by the unit test, where the purpose is chosen explicitly rather than inferred.

## Execution order and fix dependency

The substrate was executable before the fix. A2–A4 landed with J8; A5 was superseded when the implementation reused exact coordinator state instead of adding configuration.

| Item | What | Pre-fix? |
| --- | --- | --- |
| C2 | Cumulative counters in the coordinator | yes — substrate for E1/E4 |
| B1 | Counters balance at rest, in both test files' teardown | yes — do this first, it retro-covers everything |
| B2, B3 | C1-rule independence, cross-seam admission | yes |
| A1 | The regression test itself | yes — **expected-fail** before J8, must-pass after it |
| E1 | Coordinator counts into `dump_health` → `quiesce` | yes |
| E5-field, C1 | `resolvedRows`, `hang-open` fake-cloud mode | yes — prerequisites for every D item |
| D1, D3, D4, E2 | S19 (expected-fail before J8), S21, S18 retrofit | yes |
| E3, E4, F1, F2 | Saturation, admission rate, coverage reporting | yes |
| **A2–A4** | Handle-run ceiling, lifecycle and gapless path | **no** — these landed with J8 |
| **A5** | Proposed configuration surface | deliberately omitted — the ceiling is private and not tunable |

**Expected-fail was the proof pattern, not a workaround.** The A1 tests and S19 first ran marked so the unfixed behavior was captured rather than skipped. J8 removes those marks; an XPASS would now mean the harness was not updated with the implementation. S20 was deliberately omitted for the basename ambiguity described above.

## The missing oracle category

Everything in the four-oracle table answers *"did something grow, hang, go inconsistent, or die?"* Nothing answers *"is the app still doing the work it has been asked to do?"* A silent capability loss — work that stops being attempted rather than failing loudly — passes every existing oracle by construction: counters stay small, nothing crashes, no guarantee is violated, the app answers the channel promptly. That is the whole reason this survived.

The fifth row of that table is a **progress oracle**: with outstanding demand and no documented gate in force, cumulative completed-work counters must advance. Its three ingredients now exist:

- **Cumulative counters, not gauges.** The coordinator's instantaneous gauges cannot distinguish "nothing is happening" from "a great deal is happening quickly". `handleOpensStarted`, `handleOpensCompleted`, `requestsReady`, `requestsFailed`, `requestsYielded`, and `requestsAdmissionExhausted` can.
- **A demand signal**, so flat progress is only a violation when there is work outstanding: `resolvedRows` and `cloudParsesPending` expose it without guessing from transient gauges.
- **A gate signal**, so a legitimate hold is not read as starvation. `foregroundTransferActive` is already published in `debugState` and is precisely the distinction W2 says S18 cannot make.

With those, the violation is one line: *demand > 0, progress flat across the window, and no gate in force*. Under this bug it fires within a second of the wedge on any cloud corpus.

Two cheaper derivations of the same idea are worth having on their own, because they need no new concepts:

- **In-flight opens must reach zero at rest.** `handleOpensStarted - handleOpensCompleted` is the count of live handle runs; if it is non-zero after a `quiesce`, an open is stranded. That is this bug, stated as a guarantee, and `quiesce` already has the machinery — `VibeIsSettled` (`DebugHealth.m:264`) iterates the whole `pending` dictionary, so a counter added to `VibePendingCounts` is automatically waited on, and a wedged run keeps `settled: false` and names itself in the reported `pending` block at the 15 s deadline. Highest leverage single change in this document.
- **Convergence, stated in user terms.** After a folder is opened and everything settles, *every* row should carry resolved metadata. That assertion knows nothing about lanes, claims or slots, so it survives every refactor of the mechanism and catches the whole class rather than this instance. `resolvedRows` is the landed signal; see item E5.

## Test coverage to add

Items are lettered; the fix steps they pair with are numbered 1–7 in the bug doc's `## The fix`.

### A. Unit tests for the fix

A1 reproduced the bug as expected-fail and is now must-pass. A2–A4 land with J8; A5 was superseded by the private, state-derived ceiling.

Host-less, in `Tests/AudioFileOpenCoordinatorTests.m`, using `initWithConfiguration:operationFactory:datalessProbe:clock:fileOpener:` so a hanging opener and a fake dataless probe compose.

- **A1. The B1 regression itself.** Wedge a gapless or prefetch open on path A, then submit a dataless metadata claim on path B and assert its transfer starts. This is the test whose absence is the bug.
- **A2. Wedged opens are bounded by exact admission.** Six distinct live runs admit; the seventh settles `AdmissionExhausted` before stage 1, increments `requestsAdmissionExhausted`, and leaves transfer counts untouched.
- **A3. Membership follows the run lifecycle.** Stage-1 detach removes it; cancellation after stage 2 keeps it until the uncancellable call returns. The rebound test samples before rebind, after rebind and during the restarted native open to prove that restart retains one membership rather than releasing and reacquiring; the shared B1 teardown pins ordinary completion at zero.
- **A4. Gapless uses the same handle-run ceiling without touching a transfer slot.** A same-key replacement still rebinds when all six memberships are occupied.
- **A5. No configuration surface.** The six-run ceiling is a private safety fuse, with no queue, grace, pending allowance, debug key, or user-facing tuning.

### B. Durable unit guarantees that would catch the next one

These are the ones worth having even if the fix changes shape. Each is generic — it pins the accounting rather than this bug.

- **B1. Counters balance at rest.** A shared assertion in the `tearDown` of both coordinator test files: once all work has settled, `interactiveRunning`, `backgroundRunning`, the existing `handleRunCount`, and in-flight opens are all zero. This is the unit-test analogue of the `quiesce` oracle and retro-covers every existing test in both files.
- **B2. The C1 rule is independent of the counters.** `foregroundTransferActiveLocked` derives from `_claims`, never from the running counts. Pin it: with a wedged open holding capacity, `isForegroundTransferActive` still answers from the claim table alone. This is what makes the split safe to do.
- **B3. Cross-seam composition, as a habit.** At least one test in each file that reaches across the stage-1/stage-2 join, since W6 is that neither file crosses it. A wedged stage-2 run on path A must not change what stage 1 will admit for path B, in either lane.

### C. Harness prerequisites

- **C1. `hang_open` in `VibeFakeCloud` landed** — materialize successfully, then block the matching stage-2 read, releasable on command. It is a separate axis from `VibeFakeCloudProgressMode`: progress mode shapes stage 1; this shapes stage 2.
- **C2. Cumulative counters landed in the coordinator's `debugState`** (`Vibe/Debug/AudioFileMaterializationCoordinator+Debug.m`): `handleOpensStarted`, `handleOpensCompleted`, `requestsReady`, `requestsFailed`, `requestsYielded`, and `requestsAdmissionExhausted`, alongside the live `handleRuns` count. `requestsAdmissionExhausted` includes both a stage-1 capacity settlement and an immediate handle-run refusal. They are cumulative for the life of the process because none of these outcomes is ever transiently wrong; a re-check must not filter one away.

### D. New cloud scenarios

- **D1. S19 — a wedged *prefetch* open does not starve the sweep.** S18's shape, but wedging stage 2 on the successor, asserting a dataless metadata transfer *does* start afterwards. The end-to-end pin for this bug.
- **D2. S20 — deliberately omitted.** `hang_open` selects by basename, while prefetch and gapless can open the same successor file; the scenario could not prove which purpose it wedged. The purpose-specific A1 unit test covers gapless without that ambiguity.
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
- **F2. Treat an all-zero counter as suspicious in its own right.** `MetadataParseCoordinatorTests.m:369` (`testDebugPendingCountsTrackHoldersAndWaiters`) exists because *"a counter that silently always read zero would look exactly like a clean run"*. Every counter added under C2 needs the same deterministic pin, or it becomes another number nobody has checked against ground truth. The stage-1 exhaustion test and seventh-handle-run test now pin both gates feeding `requestsAdmissionExhausted`.

## Verification for this plan

`make test`, `make analyze CONFIG=Release`, `make build`, `make build-ios`, `make check-layout`, `make check-vocabulary`.

Then `cloud-scenarios.py --corpus build/cloud-scenarios-corpus` end to end: every registered scenario, including S18, S19 and S21, must pass. S20 does not exist for the purpose-selection reason above.

Verified 2026-08-23: all 24 registered scenarios passed. S19 observed seven metadata transfers start behind the wedged prefetch handle open; with the current three-folder/42-file corpus, S21 resolved all 14 rows in its selected folder.
