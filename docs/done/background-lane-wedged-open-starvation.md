# Bug: one wedged background handle open permanently starves all cloud background materialization

**Done.** Found 2026-08-21 by audit (item B1), re-verified in depth, and fixed 2026-08-23. File:line anchors in the diagnosis are against `main` at `f814829`; they describe the pre-fix implementation.

Severity: **high consequence, low likelihood**. The audit filed it medium and got the blast radius wrong in both directions — see *What the audit got wrong*.

The coverage work landed independently, before the fix, in `67983e0`. The W1–W6 section is retained as the historical explanation for why the original harness missed the defect; it is not a list of current harness gaps.

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

A handle open is **uncancellable, its scarcity is worker threads, and a never-returning call is permanent until process exit**. Making it consume a transfer's budget is what breaks. Two lesser defects fall out of the same conflation and are fixed by the same change:

1. Even with no wedge, every prefetch and every gapless open occupies the sole background slot for its whole duration, so a cloud metadata sweep is blocked during each one, routinely.
2. A prefetch run cancelled and rebound can restart stage 1 while its own carried slot still holds the lane. The usual post-transfer probe reports the file local and takes the capacity-exempt fast path, so this is not the routine rebound outcome. It self-starves only when the provider still reports the file dataless or re-evicts it before the restart.

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

**Too mild in consequence, but too fast in timing.** The audit says claims "park and expire". That is the ordinary sweep behavior: the sweep owns only one scan materialization at a time, so with no other background requests it parks that claim for the 10 s grace, retries sequentially, and exhausts the path after three attempts plus retry delays. It cannot fill six pending coordinator slots in milliseconds by itself. Immediate refusal can still happen when artwork, prefetch, or other requests have already filled the background pending list. Either way, the loss is permanent for dataless background work until relaunch and affected rows eventually spend their session retry budget; it is not a library-wide failure within a couple of seconds. Playback survives on the 3-wide interactive lane.

`MetadataRetryRules.h`'s own comment — "Admission exhaustion is capacity pressure, not a file verdict. Give a live claim time to settle" — is exactly inverted here: the budget is spent on a capacity condition that will never clear.

## The fix

Split the two lifetimes, using state the coordinator already owns. The net implementation is carried-slot deletion plus one private admission guard:

1. **A transfer slot ends at stage-1 settlement.** Delete `_carriedSlotLanes`, `pathHasLiveHandleRuns:`, `releaseCarriedSlotIfNoLiveRunsForPath:`, the carry branch in `finishClaim:`, and gapless's artificial background count. `finishClaim:` always releases the lane slot held by that stage-1 run; gapless continues to skip stage 1.
2. **`_handleRuns` is the handle-run bound.** At most six distinct `(purpose, standardized path)` runs may be live per coordinator; production's shared coordinator makes that process-wide in the app. Dictionary membership already has the exact lifecycle needed: it begins before stage 1, survives an uncancellable stage-2 call and any rebound restart, and ends only when that run really leaves `_handleRuns`. There is no second running counter to keep in sync.
3. **Rebind before admission.** An existing same-key run always accepts the replacement waiter, even when six runs are live. Only creation of a seventh distinct run is refused.
4. **Refuse immediately.** The seventh distinct run settles asynchronously with the existing `VibeAudioFileOpenErrorAdmissionExhausted` before materialization begins. Handle-run admission has no queue, pending allowance, grace period, configuration value, new error, or caller behavior.
5. **Deliberately no watchdog.** Reclaiming a wedged run on a deadline would let stranded workers grow without bound. A never-returning OS call remains one of the six live runs until process restart, but it consumes no transfer capacity.
6. **Leave transfer policy alone.** Foreground transfer concurrency remains three and background remains one. The old "three, not two because a handle may wedge" rationale is retired; changing transfer concurrency is a separate policy decision.

This is file-loading spec **J8**, which supersedes J7's spanning-slot resolution. The existing `handleRunCount` snapshot and cumulative open counters, added by the coverage work, remain diagnostics; a handle-run refusal contributes to the existing `requestsAdmissionExhausted` outcome counter, so the fix adds no new counter or configuration surface.

`foregroundTransferActiveLocked` derives from `_claims`, never from the running counts, so **the C1 foreground rule is untouched by all of this**. `CloudTransferRegistry` publication is likewise gated on the claim's accepted dataless classification, independent of the carried slot — the change repairs the root `CLAUDE.md` claim that "lane capacity bounds the indicators as well as the transfers", which carried slots had skewed.

### Alternative, rejected

Raise `maximumBackgroundMaterializations` to 2. One line, validation already allows up to 4. Rejected: it doubles concurrent background provider transfers against the C1 foreground-priority rule that the whole spec is built on, buys tolerance for exactly one wedge, and leaves the category error in place. Legitimate only as a stopgap.

## Why the original harness did not catch it

Four independent gaps lined up. Coverage commit `67983e0` closed them before this fix; these are the historical gaps and their present answers.

**W1. S18 wedged the wrong stage.** `s18_a_wedged_open_still_starts_the_sweep` stalled the stage-1 download, so it never reached the Ready-only carry branch. It was also a playback open on the three-wide interactive lane. The debug channel now has `hang_open`, which lets materialization succeed and blocks the stage-2 opener instead.

**W2. S18's assertion could not distinguish a gate from starvation.** Its positive signal was only that scan records had been filed, and its negative signal was that no metadata transfer started. S18 now reads `foregroundTransferActive`, so its pass is tied to the documented C1 gate rather than to the same under-capacity symptom this bug produced.

**W3. Coordinator state reached the debug channel but no oracle consumed it.** The coverage work added `handleRuns` and cumulative outcome counters to the materialization state, `handleOpensInFlight` to `dump_health`, and live checks that prove the counters move. A wedged open therefore prevents `quiesce` from claiming the app settled and names the outstanding work.

**W4. Every oracle asked whether something grew, became inconsistent, or died; none asked whether requested work still advanced.** S19 now asserts the missing capability directly: a wedged prefetch open must not prevent a metadata transfer. S21 asserts user-visible convergence: every row eventually resolves. `cloud.handle_open_stranded` and the admission summary make the mechanism visible as well.

**W5. Local soak corpora cannot reproduce a provider-only fault, and ordinary operation fuzzing cannot synthesize a never-returning `AVAudioFile` initializer.** That structural limit remains; the deterministic opener seam and cloud scenarios cover the environmental fault explicitly instead of pretending a local soak exercises it.

**W6. Unit tests stopped at the stage boundary.** `AudioFileOpenCoordinatorTests` now composes a gated file opener, materialization harness, and dataless probe. Its prefetch and gapless regressions reproduced this defect deterministically as expected failures, while the playback-lane control stayed green.

## The coverage work this exposed

`docs/testing/materialization-coverage-plan.md` records the pre-fix execution in `67983e0`: the cross-seam regressions, durable accounting checks, `hang_open`, S19 and S21, health integration, and coverage self-reporting. S20 was deliberately omitted because its basename-level injection could not distinguish a gapless open from the same file's prefetch open; the purpose-specific unit test covers that path deterministically.

The fix unmarks the two A1 expected failures and adds only the focused tests the minimal guard needs: six distinct live runs admit and the seventh refuses before materialization while incrementing the existing admission-exhaustion counter; an existing same-key run rebinds at the ceiling; cancellation before stage 2 frees membership; cancellation after stage 2 remains counted until the OS call returns; the abandoned-then-rebound restart retains one membership before rebind, after rebind and while the replacement open runs; and gapless shares the same bound. The shared teardown accounting, extended to `handleRunCount`, verifies that ordinary completion frees membership. The earlier plan's proposed configuration and second counter are superseded by `_handleRuns.count` and `requestsAdmissionExhausted`.

## Verification

`make analyze CONFIG=Release`, `make build`, `make build-ios`, `make check-layout`, `make check-vocabulary`, `make test`.

Then the cloud scenario suite end to end (`cloud-scenarios.py --corpus build/cloud-scenarios-corpus`), with S19 unmarked and passing alongside S18 and S21.

Verified 2026-08-23: all 960 host-less tests passed, both Release builds and the analyzer were clean, and all 24 cloud scenarios passed. S19 started seven metadata transfers behind the wedged prefetch handle open; S21 resolved every row.

## Companion records

- `docs/file-loading-spec.md` records the independent transfer policies, the private six-run ceiling, and J8 superseding J7.
- `Vibe/Audio/CLAUDE.md` records the two lifetimes and why a never-returning call remains counted without consuming transfer capacity.
- `Vibe/Audio/AudioFileMaterializationCoordinator.h` records the caller-visible immediate refusal and same-key rebind behavior.
