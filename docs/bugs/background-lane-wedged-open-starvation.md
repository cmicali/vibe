# Bug: one wedged background handle open permanently starves all cloud background materialization

Found 2026-08-21 by audit (item B1), re-verified in depth, **not fixed**. File:line anchors are against `main` at `f814829`; the working tree was dirty at that commit but none of the anchored files (`Vibe/Audio/**`, `Vibe/Debug/**`, `Tests/**`, `docs/file-loading-spec.md`, `.claude/skills/vibe-stress/**`) were among the modifications, so the anchors are clean. The one exception is the root `CLAUDE.md`, which *is* modified — re-check that reference before acting.

Severity: **high consequence, low likelihood**. The audit filed it medium and got the blast radius wrong in both directions — see *What the audit got wrong*.

The harness gaps (W1–W6) and the coverage items (A–F) are actionable **independently of the fix**, and several of them are worth doing whether or not the fix lands in this shape.

## The mechanism

`VibeLaneForRole` (`AudioFileMaterializationCoordinator.m:492`) sends **only** `RolePlayback` to the interactive lane. Prefetch, metadata-priority and metadata-scan all land in the background lane, sized **1** (`AudioLoadingConfiguration.m:23`).

A handle open can take a background slot two ways:

- **Gapless** (`AudioFileMaterializationCoordinator.m:1115-1122`) does `_backgroundRunningCount++` with **no capacity check at all**, and stamps `_carriedSlotLanes[path]`.
- **Prefetch** reaches the same place indirectly: role `Prefetch` → background lane → `startClaim:` increments → `finishClaim:`'s `carrySlot` branch (`:794-802`) hands the slot to the handle run instead of releasing it.

The only releases are `releaseCarriedSlotIfNoLiveRunsForPath:`, called from `finishHandleRun:` and from `detachOpenToken:`'s stage-1 branch. Once stage 2 has dispatched, that second branch is unreachable — the code says so at `:1107`:

> Stage 2 already dispatched: the `AVAudioFile` call is uncancellable and keeps the run (and its carried slot) until it returns.

So a never-returning `AVAudioFile` open holds the slot until process exit. `drainPendingClaims`'s `while (_backgroundRunningCount < max)` is then permanently false, and `admitClaim:` falls straight through to parking. Nothing else decrements it, and `applyConfiguration:` is the only escape — debug-only, so in Release the loss is for the life of the process.

The player's 60 s open deadline does not help: it detaches the token, which sets `run.runWasCancelled` and clears the waiter, but the run and its carried slot survive by design.

## The category error underneath it

A lane slot bounds **concurrent provider transfers** — cancellable, scarcity is the wire. That is why background is 1, and why `background` sits in the debug config's `safe` tier (max 4) while `interactive` sits in `diagnostic` (max 64) — `AudioLoadingConfiguration.m:13-16`, `AudioLoadingConfiguration+Debug.m:41-52`.

A handle open is **uncancellable, its scarcity is worker threads, and it is permanent on failure**. Making the second consume the first's budget is what breaks. Two lesser defects fall out of the same conflation and are fixed by the same change:

1. Even with no wedge, every prefetch and every gapless open occupies the sole background slot for its whole duration, so a cloud metadata sweep is blocked during each one, routinely.
2. A prefetch run cancelled and rebound restarts stage 1 while its own carried slot still holds the lane; the new claim cannot be admitted and self-clears only via the 10 s grace into an error.

## Where it came from

`docs/file-loading-spec.md:285` — J7's resolution reads:

> one bound per claim spanning transfer + handle open, with the foreground lane resized 2 → 3 so one wedged open cannot halve foreground capacity.

J7 changed **what a lane slot means** for both lanes, then re-derived the consequence for one. The spec's own H table (`:220-221`) still carries the annotation on one row only:

```
| Foreground transfers (running / pending / grace) | 3 / 1 / 5 s — the slot spans transfer + handle open (J7) |
| Background transfers (running / pending / grace) | 1 / 6 / 10 s |
```

`Vibe/Audio/CLAUDE.md:94` and `AudioLoadingConfiguration.m:25-28` repeat the same one-sided reasoning. At 1 wide, "cannot halve" becomes "eliminates".

## What the audit got wrong

**Too broad.** It says "every later metadata-scan and prefetch claim then parks and expires". `admitClaim:`'s local fast path (`:686-690`) starts any non-dataless claim regardless of lane occupancy — pinned by `AudioFileMaterializationCoordinatorTests.testLocalFileStartsPastBackgroundCapacity`. A **local library is completely unaffected**. This only bites dataless claims, i.e. iCloud / file-provider libraries.

**Too mild, for those libraries.** The audit says claims "park and expire". Most never park: with `maximumBackgroundPendingMaterializations = 6`, a sweep fills the pending list in milliseconds and later claims take the `return NO` path for an *immediate* `AdmissionExhausted`. `MetadataRetryRules.h` then treats `AdmissionExhausted` as consuming the attempt budget — 3 attempts at 0.25 s / 0.5 s, then `RetryNone`. So one wedged background open does not slow the cloud metadata scan; it **kills it permanently within a couple of seconds**, file by file, along with all dataless prefetch. Playback survives on the 3-wide interactive lane.

`MetadataRetryRules.h`'s own comment — "Admission exhaustion is capacity pressure, not a file verdict. Give a live claim time to settle" — is exactly inverted here: the budget is spent on a capacity condition that will never clear.

## The fix

Split the two bounds. Net effect is a deletion plus one counter.

1. **Add `_handleOpenRunningCount`.** A handle run holds exactly one open slot for its lifetime in `_handleRuns` — acquired in `openURL:` at new-run creation, released at the two sites a run leaves `_handleRuns` (`finishHandleRun:` `:1230-1231`, `detachOpenToken:` `:1103-1105`). Tying the slot to dictionary membership makes the restart path in `finishHandleRun:` (`:1224-1228`) correct for free: it keeps membership, so it neither releases nor re-acquires. A rebind (`run.waiter = token`, `:1064-1069`) takes no new slot — one run, one slot.
2. **Delete the carried-slot machinery.** `_carriedSlotLanes` (`:345`), `pathHasLiveHandleRuns:` (`:1017`), `releaseCarriedSlotIfNoLiveRunsForPath:` (`:1027`), the `carrySlot` block in `finishClaim:` (`:794-802`), and the gapless special case (`:1115-1122`) all go. `finishClaim:` releases its lane slot unconditionally; the lane returns to meaning exactly "concurrent provider transfers", which is what its numbers were reasoned about. Gapless becomes an ordinary run that skips stage 1.
3. **New config value `maximumConcurrentHandleOpens = 6`**, validated 1…32 against a new `kMaximumDiagnosticConcurrentHandleOpens`, in the `diagnostic` tier of `AudioLoadingConfiguration+Debug.m` with key `handle-opens`. Sizing: at most 3 purposes are ever wanted at once, so 6 is steady state plus three wedges of headroom — and exhausting it now costs only opens, never transfers. Today's effective bound is ~4, so this is strictly more headroom.
4. **Refusal path.** `openURL:` with no open slot settles the token with the existing `VibeAudioFileOpenErrorAdmissionExhausted` on its completion queue, through `takeCompletionForDelivery` so single-shot delivery holds. No new error code, no caller changes. Add one `LogWarn` naming the stranded run keys, so a wedge is diagnosable instead of mysterious.
5. **Deliberately no watchdog.** Reclaiming a wedged slot on a deadline would let stranded workers grow without bound — the thing the bound exists to prevent. Correct behavior is bounded, permanent loss of *open* capacity and zero effect on transfers.
6. **Do not touch `maximumInteractiveMaterializations`.** With opens off the lane, the "three, not two" rationale evaporates and 3 becomes plain foreground transfer concurrency. Reverting to 2 is a separate behavior change; leave the value and rewrite the comment. **Open decision for the owner.**
7. **Snapshot and debug surface.** `VibeAudioFileMaterializationCoordinatorSnapshot` (`AudioFileMaterializationCoordinatorInternal.h:39-48`) gains `handleOpenRunningCount`; `AudioFileMaterializationCoordinator+Debug.m`'s `debugState` gains `openRunning` and `handleRuns` — it computes `handleRunCount` today and drops it on the floor.

`foregroundTransferActiveLocked` derives from `_claims`, never from the running counts, so **the C1 foreground rule is untouched by all of this**. `CloudTransferRegistry` publication is likewise gated on `publishedTransfer` at `startClaim:`/`finishClaim:`, independent of the carried slot — the change in fact *repairs* the root `CLAUDE.md` claim that "lane capacity bounds the indicators as well as the transfers", which carried slots currently skew.

### Alternative, rejected

Raise `maximumBackgroundMaterializations` to 2. One line, validation already allows up to 4. Rejected: it doubles concurrent background provider transfers against the C1 foreground-priority rule that the whole spec is built on, buys tolerance for exactly one wedge, and leaves the category error in place. Legitimate only as a stopgap.

## Why the harness did not catch it

Four independent gaps had to line up. Read this before writing the new tests — the first one is the uncomfortable one.

**W1. There is already a scenario named for this, and it passes.** `s18_a_wedged_open_still_starts_the_sweep` (`cloud-scenarios.py:915`) arms `progress="stall"`, which wedges the **stage-1 download**. The claim never reaches Ready, so `finishClaim:`'s `carrySlot` branch — which requires `ready` — never fires and no slot is ever carried. The bug needs a transfer that *succeeds* and then an open that hangs, and `VibeFakeCloudProgressMode` (`VibeFakeCloud.h:42-48`) has no such mode: Hashed, None, Linear, Sparse and Stall are all download-progress shapes. There is no "materialize successfully, then block the read." S18 is also a *playback* open, so even a genuine stage-2 wedge would carry an **interactive** slot, which the 3-wide lane absorbs. Nothing in the suite wedges a prefetch or gapless open — the only two that touch the background lane.

**W2. S18's assertions point the wrong way.** Its only positive signal is `cloudParsesPending > 0` (`:928`) — records *filed* by stage 1, which is exactly the half that keeps working under the bug. Its negative assertion is `if events_of(ctx.trace(), event="started", role="metadata"): raise Failed(...)` (`:937`) — that no metadata transfer starts. Correct for its own setup, where C1 genuinely gates it, but it means the scenario reads the bug's symptom as the pass condition and cannot distinguish "gated by the foreground rule" from "starved by lane capacity".

**W3. The instrument exists, is plumbed to the harness, and no oracle reads it.** `dump_cloud_health` returns `materialization: [coordinator debugState]` (`DebugCommonVerbs.m:427`), which contains `backgroundRunning` — the number that goes to 1 and never comes back. `cloud-scenarios.py` calls that verb in eight places and reads only `cloudLaneHeld`, `cloudParsesPending` and `priorityLane`; **no scenario ever reads `["materialization"]`**. `stress.py` does not call the verb at all. And `dump_health`'s `pending` section (`DebugHealth.m:165-188`) — the set `stress.py` and `torture.py` score, and the set `VibeIsSettled` (`:264`) iterates for `quiesce` — does not carry the coordinator's counts either.

The comment already at `DebugHealth.m:183-185` describes this exact failure mode from the last time it happened: *"the 37-entry one the stress soak missed was invisible precisely because no health counter carried it."* Same lesson, learned once, and these counters did not get added.

**W4. Category mismatch: every oracle asks "did something grow or die?", none asks "is the app still doing its job?"** The four are liveness, consistency, health and crash — all resource-growth or death oracles. A pegged lane is one integer stuck at 1: no footprint, no fds, one stranded thread far under any limit, no inconsistent state. This bug is a **capability loss**, and the suite has no oracle for that category at all. See *The missing oracle category* below.

The codebase has already seen the shape of it. `DebugConsistency.m:235-238`, on `cloud.hold_outlives_playback`:

> That is the only symptom a lost release produces **until the sweep visibly never runs**, and it is invisible to every other check here.

"The sweep visibly never runs" is named there as the thing that matters — and the check written for it tests one specific *cause* (a lost hold), not the symptom. A second cause arrived and nothing was watching. Note also that `cloud.concurrency_within_capacity` (`:269`) is an **over**-count check (`maxConcurrency > capacity`); this bug drives concurrency *under*, so it cannot fire.

**W5. Two structural blind spots.** `torture.py` runs a local corpus, so every claim takes `admitClaim:`'s non-dataless fast path and behaves identically whether the lane is pegged or not — blind by construction. And `stress.py` cannot synthesize the trigger: it needs an uncancellable OS hang inside `AVAudioFile initForReading:`, which on a real local corpus returns in microseconds. That is an environmental fault, not an op ordering, and fuzzing op order cannot produce it.

**W6. The unit suite splits along the same seam.** `AudioFileMaterializationCoordinatorTests.m` tests lane capacity thoroughly — `testLocalFileStartsPastBackgroundCapacity` and the readmission and grace tests — but never composes a lane test with a stage-2 open. `AudioFileOpenCoordinatorTests.m` has every seam needed (gated `fileOpener`, injectable materialization harness, injectable dataless probe) and all 17 of its tests assert on *delivery* — who gets the file, who stays silent, who gets a fresh run — none on *admission state while a run is wedged*. The closest, `testCentralAdmissionFailureRejectsClaimAndSkipsAudioFileOpen` (`:728`), is stage 1 refusing, not stage 2 blocking stage 1. The bug is at the join, and the join is where the suite's boundary runs.

## The coverage work this exposed

Split out to **`docs/testing/materialization-coverage-plan.md`** so it can be executed before this fix, which is the agreed order. It carries the missing-oracle analysis (W4's category gap, stated as a design) and items A–F: unit tests for the fix, durable accounting invariants, the fake provider's missing `hang-open` mode, scenarios S19–S21, five oracle additions, and coverage self-reporting.

Everything there except A2–A5 is executable against the unfixed code. A1, D1 and D2 land **expected-fail**; unmarking them is how this fix proves it fixed something.

## Verification

`make analyze CONFIG=Release`, `make build`, `make build-ios`, `make check-layout`, `make check-vocabulary`, `make test`.

Then the cloud scenario suite end to end (`cloud-scenarios.py --corpus build/cloud-scenarios-corpus`), which must stay green including S18, plus the new S19–S21.

## Docs to update in the same commit

- `docs/file-loading-spec.md` — H table rows for both lanes, a new row for the handle-open bound, and a **J8** entry in the DECIDED format recording this defect and its resolution.
- `Vibe/Audio/CLAUDE.md:94` and `:98` — the "carried" paragraph and the never-returning-OS-call paragraph.
- `Vibe/Audio/AudioLoadingConfiguration.m:25-28` — the "three, not two" comment.
- `Vibe/Audio/AudioFileMaterializationCoordinator.h` — the `openURL:purpose:` doc comment's carried-slot paragraph (`:80-90`).
- `Vibe/Audio/AudioFileMaterializationCoordinator.m:340-345` — the `_handleRuns` / `_carriedSlotLanes` ivar comment.
