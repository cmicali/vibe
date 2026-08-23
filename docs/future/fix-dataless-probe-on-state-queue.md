# Fix: move dataless probes off the materialization state queue

Written 2026-08-23. **Proposed, not implemented.** This plan corrects
[Bug: the dataless probe stats the file system on the coordinator's serial state queue](../bugs/dataless-probe-on-state-queue.md).
The finding is real, but this plan supersedes that document's proposed fully asynchronous
request-admission rewrite with a smaller coordinator-local change.

The symbols below were checked against `main` at `bd2b0dc` and the current uncommitted
stage-2 admission work. The plan deliberately uses symbol names rather than line numbers;
re-check the shared loading changes before implementation.

## Outcome

`materializeURL:role:completionQueue:completion:` keeps its current public behavior: it
returns a cancellation token synchronously and registers the waiter on the coordinator's
serial state queue before returning. The change is that this registration performs only
in-memory work. A new path-keyed claim enters a `Probing` state, and one bounded worker
probes the path before the existing admission logic decides whether the claim is local,
pending, running, yielded, or refused.

This is intentionally contained:

- No public API or caller changes.
- No atomic request identifiers and no change to claim-ordinal assignment or pending rank.
- No changes to `AudioPlayer`, the stage-2 audio-file open, metadata loading, artwork
  loading, `CloudFileMaterializer`, or `AudioFileMaterializationOperation`.
- No raw concurrent probe queue, semaphore wrapper, or test-only global barrier.
- No cross-claim or persistent cache of a file's dataless state; materialization and
  provider eviction can change it.

The only production behavior added outside the existing claim flow is a private,
fixed-bound `AudioWorkScheduler` used for the initial file-system probe.

## Why this is the smallest correct boundary

The serial state queue is useful. It is the reason same-path requests join atomically,
request identifiers and claim ordinals have one owner, foreground registration has an
exact order, and cancellation can be matched to the installed waiter. The defect is not
that `materializeURL:` enters that queue synchronously; the defect is that the queue calls
`NSURLUtil.isDatalessFile:`, which can block in `stat(2)` on a dead mount or file provider.

The metadata loader has one adjacent instance to consider with this work:
`judgeWaitingPriorityRecordsWhileHeld:` re-probes yielded priority records on its serial
callback queue. That set is bounded to the priority records normally present (roughly one
or two), so it is not the coordinator-wide choke point addressed here, but it is the same
class of filesystem call on a state-owning queue and should be evaluated alongside the
coordinator probes.

Making the whole request asynchronous before registration would solve the blocking call,
but would also create work the feature does not need: request identifiers would become
atomic, claim order would become probe-completion order, same-path waiters could each run
their own probe, cancellation would need a pre-registration path, and tests would need a
new admission barrier. Registering a `Probing` claim first preserves all of today's useful
serialization while moving only the syscall.

A raw concurrent dispatch queue is not enough. A running `stat` has no cancellation point;
repeated cancel-and-resubmit cycles could leave an unbounded tail of blocked work even if
the number of current callers is normally small. `AudioWorkScheduler` already implements
the repository's fixed-running, fixed-pending, expiring-admission contract for exactly this
kind of OS call, including removal of work cancelled before dispatch. Reusing it is both
less code and a stronger bound than the queue proposed in the bug write-up.

## Guarantees preserved

| Requirement | How the fix preserves it |
| --- | --- |
| One materialization operation per standardized path (A2) | The state queue installs one `Probing` claim before the request returns. Every eligible later waiter joins it and shares its initial probe and eventual operation; metadata rejected by the foreground hold never becomes a waiter. |
| Foreground work outranks provider downloads (C1/C6) | A probing playback or prefetch waiter counts as foreground immediately. Known dataless metadata claims are preempted without I/O; unknown claims cannot transfer until their probe settles and the foreground state is checked again. |
| Local tags and artwork keep flowing (C2) | A probe which answers local enters the existing local-bypass path, even while a foreground claim or transfer lane is active. |
| A same-path metadata request may ride the user's transfer (C3) | Role promotion happens on the installed claim while it is `Probing`; it does not launch another probe or operation. |
| Pending rank remains submission-stable | Request identifiers and `claim.ordinal` are still assigned on the state queue at registration time, not when a probe completes. Once claims contend in a pending lane, the ordinal remains their tie-breaker. |
| Loading indicators describe started transfers | A claim classified dataless is refreshed in its already-admitted lane worker and reported to state before the materializer runs; begin/end publication remains paired from that fresh answer. A newly classified local claim starts immediately and preserves the existing narrow local-to-evicted race. |
| A bad path cannot wedge unrelated state | The initial probe and any dataless start refresh run off the state queue. `currentConfiguration`, `isForegroundTransferActive`, snapshots, cancellations, settlements, and unrelated admissions remain responsive. |

## Claim state and fields

Add one state before the existing two:

```objc
typedef NS_ENUM(NSUInteger, VibeMaterializationClaimState) {
    VibeMaterializationClaimStateProbing = 0,
    VibeMaterializationClaimStatePending,
    VibeMaterializationClaimStateRunning,
};
```

Add four private claim fields:

- `BOOL dataless` — the last classification reported to the state queue.
- `AudioWorkToken *probeToken` — the cancellable-if-pending initial probe.
- `BOOL startProbePending` — a known-dataless lane has been admitted, but its fresh
  worker-side classification has not yet returned to state.
- `BOOL yieldIfDatalessAfterProbe` — narrowly preserves the existing rule for a
  foreground waiter which departs while metadata waiters remain on the same path. If the
  outstanding probe says dataless, those passengers yield; if it says local, they continue.

`dataless` is never read as authoritative while the relevant probe-pending flag is true.
That prevents preemption or detach from acting on an older classification while a fresh
one is already in flight.

The high-level transitions are:

| From | Event | Result |
| --- | --- | --- |
| none | first waiter registers | Install one `Probing` claim, assign its ordinal, submit one initial probe. |
| `Probing` | same-path waiter registers | Join the claim, recompute its effective role, and keep the one probe. |
| `Probing` | probe says local | Store `dataless = NO` and enter ordinary admission; local bypass starts immediately without a second coordinator probe. |
| `Probing` | probe says dataless | Yield if the claim is metadata-only and foreground is active or the departure flag is set; otherwise enter ordinary lane admission. |
| `Probing` | every waiter cancels | Cancel the scheduler item if it is still pending, remove the claim, and ignore a result from an already-running probe. |
| `Probing` | scheduler refuses or expires the probe | Settle every waiter once with `AdmissionExhausted` and remove the claim. |
| `Pending` | lane becomes available | Enter `Running`, reserve the lane, and refresh the known-dataless classification before the operation. |
| `Running` | dataless start refresh settles | Re-check claim/run identity, cancellation, foreground state, and the departure flag; then either yield/finish or publish and run the operation. |
| `Running` | operation settles ready | Record `dataless = NO` before any cancellation/rebind restart decision. |

## Probe scheduler

Add one private `AudioWorkScheduler *_datalessProbeScheduler` to
`AudioFileMaterializationCoordinator`, initialized once with:

| Policy | Value |
| --- | ---: |
| QoS | `QOS_CLASS_USER_INITIATED` |
| Maximum running probes | 8 |
| Maximum pending probes | 16 |
| Pending grace | 5 seconds |

These are private safety limits, not transfer policy and not settings. They do not belong
in `AudioLoadingConfiguration`: changing the number of provider transfers must not also
change how many file-system classifications can be isolated from one another. Eight
running probes lets one or several dead paths lose their own slots without recreating a
single serial choke point; the pending bound and grace make total captured work finite and
give playback a prompt failure instead of an invisible queue if the file system is broadly
unresponsive.

Both scheduler rejection modes map to the coordinator's existing
`VibeAudioFileMaterializationResultAdmissionExhausted` and error domain. There is no new
caller-visible result and no retry policy change; metadata already retries that result,
while an interactive open already treats it as an admission failure distinct from its
ordinary file-open timeout.

## Detailed implementation

### 1. Register first, then probe

Keep `materializeURL:role:completionQueue:completion:` inside
`performStateSynchronously:`. Within that state block:

1. Allocate the request identifier and token exactly where they are allocated today.
2. Expire old pending claims and sample foreground activity before this waiter joins, as
   today.
3. Build the waiter and look up `_claims[path]`.
4. If a claim exists, first preserve the current suspended-metadata gate. An incoming
   metadata waiter finding an unrelated foreground hold and a metadata-only claim already
   known dataless (`state != Probing`, `startProbePending == NO`, and `dataless == YES`)
   settles `Yielded` without joining. Otherwise join immediately: an unknown `Probing` or
   start-refreshing claim may accept the waiter because its completion re-checks the hold;
   a known-local claim may accept it; and any request may join a claim which already has a
   foreground waiter. Recompute the effective role and never submit another initial probe.
5. If no claim exists, create it in `Probing`, assign `claim.ordinal` immediately, install
   it in `_claims`, and submit one scheduler item.
6. If this waiter creates the foreground rising edge, preempt other known dataless
   metadata claims before returning, still excluding the joined path.

Submitting to `AudioWorkScheduler` is in-memory admission and dispatch bookkeeping; the
probe body itself runs on its worker queue. The method then returns the installed token.
The main-thread artwork path can wait briefly for the serial state block, but it can no
longer inherit a file-system call from that block.

For an already-classified claim, the current entry decisions remain immediate: dataless
metadata submitted while an unrelated foreground claim is active yields without joining,
local metadata joins or starts, and metadata joining a claim which already has a foreground
waiter rides that path-wide work. The first case matters for a cancelled `Running` claim
retained for settlement: attaching metadata to it could otherwise make `finishClaim:`
readmit background work while the foreground hold is still active.

### 2. Settle the initial probe by claim identity

The scheduler work captures the URL and weak references to the coordinator and claim,
calls `_datalessProbe(url)`, then dispatches the boolean to `_stateQueue`. Its settlement
helper must verify all three conditions before doing anything:

- `_claims[path]` is the same claim object.
- `claim.state == VibeMaterializationClaimStateProbing`.
- The claim still has waiters.

Object identity is the staleness check. If every waiter cancelled and a new claim for the
same path was installed while the old `stat` remained blocked, the old answer cannot
classify the new claim.

On a current result, clear `probeToken`, store `dataless`, and make one decision:

- A metadata-only dataless claim yields if foreground is currently active or
  `yieldIfDatalessAfterProbe` is set.
- Otherwise call the existing `admitClaim:preserveExistingAdmission:` path.
- If ordinary lane admission has no pending capacity, settle `AdmissionExhausted` exactly
  once and remove the claim.

If the scheduler rejects at submission or expires a pending probe, its failure block runs
on `_stateQueue`, applies the same identity/state checks, and settles `AdmissionExhausted`.

### 3. Make admission purely in-memory

`admitClaim:preserveExistingAdmission:` reads `claim.dataless` for the local bypass. It
must never be called for the initial `Probing` state, and it never calls `_datalessProbe`.
Pending-list rank remains role first, then the ordinal assigned when the request was
registered. Probe latency can—and must be allowed to—let a later healthy path classify and
start while an earlier path is still stuck in `Probing`; if both later contend in a pending
lane, their registration ordinals remain the tie-breaker.

`preemptMetadataClaimsForForegroundRiseExcludingPath:` also performs no probe:

- `Pending` or fully classified `Running` claims use stored `claim.dataless`.
- An initial `Probing` claim is skipped because it has started no provider transfer. Its
  completion re-checks foreground activity before admission.
- A `Running` claim whose `startProbePending` is true is also skipped because its operation
  has not begun. The start-probe settlement performs the same foreground check before it
  can start a transfer.

This preserves the purpose of C6—cancel work already using the provider—without cancelling
a local claim merely because its classification is not back yet.

### 4. Refresh known-dataless starts in the admitted worker

The probe currently in `startClaim:` decides whether to publish a transfer. A known-dataless
claim can wait through its admission grace and become local before its lane opens, so it
needs a fresh answer at the start. Move that refresh into the worker block already admitted
for the claim. A claim whose initial probe answered local starts immediately without this
refresh: its answer is fresh, it bypassed transfer capacity by design, and the existing
local-to-evicted race remains the documented one-transfer-wide exception.

1. On `_stateQueue`, `startClaim:` sets `Running`, reserves the existing lane count,
   increments `runGeneration`, prepares the operation, and dispatches the worker. It
   performs no filesystem access.
2. If stored `claim.dataless` is false, set `publishedTransfer = NO` and enter
   `runWithError:` directly. Do not add a second coordinator probe for the common local
   path.
3. If stored `claim.dataless` is true, set `startProbePending = YES`; the worker refreshes
   `_datalessProbe(claim.url)` before `runWithError:`.
4. The worker synchronously reports that boolean to `_stateQueue`. This direction is safe:
   the state queue never waits for the worker.
5. State validates claim identity, `runGeneration`, and `Running`, inspects
   `runWasCancelled`, clears `startProbePending`, and stores the fresh answer.
6. If the run was cancelled, has no waiters, or is metadata-only and dataless while
   foreground is active or the departure flag is set, it must not enter `runWithError:`.
   The metadata branch calls `yieldClaim:` first so `runWasCancelled` is set and the waiters
   settle `Yielded`; otherwise a bare cancellation error could enter the inherited-cancel
   restart branch under the same foreground hold. The already-cancelled/no-waiter branch
   preserves or sets the cancellation mark. In every branch the worker still reports a
   cancelled result through `finishClaim:runGeneration:ready:error:`; it must not return
   early and strand the lane.
7. Otherwise, a dataless answer sets `publishedTransfer` and queues the registry begin on
   main; a local answer publishes nothing. Only then does the worker call `runWithError:`.
8. The existing asynchronous `finishClaim:runGeneration:ready:error:` delivery follows.

The refresh uses the already-dispatched materialization worker rather than creating a
second scheduler or queue. It runs only for a claim classified dataless, so that claim won
a real transfer-lane admission rather than the local bypass. A blocked refresh consumes
that lane slot, but it cannot block coordinator state or the caller, and it cannot create an
additional worker beyond the run which was already admitted. Begin is queued before the
operation and end is queued from `finishClaim:`, so main-queue FIFO ordering keeps the
registry pair balanced even for an immediate no-op or failure.

`CloudFileMaterializer` keeps its own probe. That probe protects its prepared-token
contract, so removing it would widen this fix into the System layer and every operation
test double. The duplicate cheap check is deliberate: the coordinator's worker-side answer
owns admission/publication, while the materializer's answer owns whether it coordinates a
read. If diagnostics later show the duplication is material, reporting classification
through the operation protocol can be considered as a separate change; it is not part of
this fix.

### 5. Make cancellation probe-aware

Extend `detachRequestToken:` without doing I/O:

- If a `Probing` claim loses its last waiter, call `[claim.probeToken cancelIfPending]`,
  clear the token, and remove the claim. A running `stat` cannot be killed; its result is
  dropped by claim identity and remains at most one of the scheduler's eight running slots.
- If other waiters remain, recompute `effectiveRole` as today.
- If the departing waiter was foreground and only metadata passengers remain while either
  probe is outstanding, set `yieldIfDatalessAfterProbe`. Do not guess. The probe result
  yields a dataless remainder and passes a local remainder.
- For a known classification, use `claim.dataless` in today's detach decision. Pending
  role changes still go through `readmitPendingClaim:`; a running dataless remainder still
  cancels through `yieldClaim:`.
- Extend `yieldClaim:` so a `Probing` claim is removed and settled like a pending claim;
  only `Running` has an operation to cancel.

If a new foreground waiter joins before an outstanding probe settles, the completion check
first observes that the claim is no longer metadata-only. A stale departure flag can never
yield the foreground waiter; clear it once the probe reports local or the claim again has a
nonmetadata waiter.

### 6. Record successful materialization before restart decisions

In `finishClaim:runGeneration:ready:error:`, set `claim.dataless = NO` whenever `ready` is
true, before branching on `runWasCancelled` or an inherited-cancellation restart.

This must not be limited to `ready && !runWasCancelled`. `CloudFileMaterializer` defines
reaching the coordinated-read accessor as “the bytes are here”; cancellation can race after
that accessor. If a new waiter has already rebound to the claim, its readmission must know
the file is local rather than re-queueing or publishing another transfer from the older
classification.

### 7. Remove every state-queue probe

After the refactor, `_datalessProbe` has exactly two coordinator call sites, both off
`_stateQueue` and off the caller:

1. The bounded initial-claim probe worker.
2. The already-admitted run worker for a claim whose stored answer is dataless, immediately
   before `runWithError:`.

The current calls in request entry, foreground preemption, `admitClaim:`, `startClaim:`,
and detach are deleted or replaced with the state described above. Add a terse queue
contract beside `_stateQueue`: its blocks may coordinate in-memory claim state but may not
perform filesystem or provider I/O.

## Race and failure audit

The implementation is not complete until each of these cases has one explicit code path:

- **Same path, probe outstanding:** every role eligible under the foreground hold joins one
  claim and one initial probe; effective-role promotion is applied before admission.
- **Foreground registers while a metadata probe is outstanding:** no transfer has begun,
  so there is nothing to cancel. The probe may finish, but a dataless result cannot enter
  the provider while foreground remains active.
- **Foreground registers while a start probe is outstanding:** the lane is reserved but the
  operation has not begun. The start settlement blocks dataless metadata before
  `runWithError:`.
- **Foreground departs from a probing same-path claim:** metadata passengers yield only if
  the answer is dataless; local work continues.
- **All waiters cancel before a probe starts:** `cancelIfPending` releases the captured work
  and no completion is delivered.
- **All waiters cancel during a probe:** the claim leaves the table immediately; the
  uncancellable syscall owns one bounded scheduler slot until it returns, and its result is
  ignored.
- **Old probe returns after same-path replacement:** object identity rejects it.
- **Probe admission is saturated:** the request settles `AdmissionExhausted`; the state
  queue remains responsive and no unbounded dispatch tail forms.
- **Cancellation races a ready operation:** ready marks the path local before a rebound
  run is admitted.
- **Begin/end publication races a quick operation:** begin is decided before entering the
  operation and end uses the stored `publishedTransfer`; both are queued to main in order.

## Tests

Read `Tests/CLAUDE.md`, then add a small thread-safe probe controller to
`AudioFileMaterializationCoordinatorTests.m`. It should count calls per path, provide a
result per call, and optionally gate a chosen call with a semaphore or condition. Tests
must release every gate in cleanup so a failing assertion cannot strand the test process.

Add or adapt these cases:

1. **Blocked initial probe does not block state or another path.** Gate file A's first
   probe. File B must probe and start; `currentConfiguration`,
   `isForegroundTransferActive`, and `stateSnapshotForTesting` must return while A remains
   gated. This is the direct regression for the bug and its main-thread consequence.
2. **Foreground is registered before its probe returns.** A gated playback probe makes
   `foregroundTransferActive` true immediately and preempts an already-running, known
   dataless metadata claim.
3. **Metadata under foreground is classified, not guessed.** With foreground active, a
   local result starts and a dataless result yields without creating an operation.
4. **Same-path promotion shares work.** Metadata followed by playback while the initial
   probe is gated produces one claim, two waiters, one initial probe, one dataless start
   refresh, and one operation at the promoted role.
5. **Foreground departure during initial probing.** With metadata passengers left on the
   path, a dataless result yields them and a local result admits them.
6. **Cancel before probe dispatch.** Saturate the running probe slots, queue another claim,
   cancel it, free a slot, and prove its probe and operation never run.
7. **Cancel during a running probe.** Remove the only waiter, release the probe, and prove
   the stale result creates no operation or delivery. Reuse the same path before release to
   prove claim identity protects the replacement.
8. **Probe bounds are real.** Gate eight running probes, park sixteen, and verify the next
   distinct claim settles `AdmissionExhausted` without starting another worker. Release all
   gates and verify accounting drains.
9. **Blocked dataless start refresh does not block state.** Let a dataless initial probe
   return, gate the second call, then prove unrelated state access and an interactive or
   known-local path continue. A same-lane dataless claim may correctly park behind the
   occupied transfer slot. Cancel and release it to verify the lane is returned once.
10. **Foreground rises during a start refresh.** A dataless metadata run must not enter its
    operation; a local one may.
11. **Ready after cancellation/rebind is local.** Reproduce the accessor-won cancellation
    race and prove the rebound run bypasses dataless admission/publication.
12. **Transfer publication uses the start answer.** Dataless-at-admission/local-at-start
    publishes nothing; dataless-at-admission/dataless-at-start publishes one balanced
    begin/end pair; a local claim has no coordinator refresh and publishes nothing.
13. **Suspended metadata does not join a retained dataless claim.** Keep a cancelled
    metadata run registered until its worker returns, register foreground elsewhere, and
    prove a new metadata waiter for the retained path yields rather than being readmitted
    by `finishClaim:`.

Most current tests already wait for an operation to start before inspecting lane state.
The few assertions which assume a request is immediately `Pending` or `Running` must wait
on the injected probe event they actually depend on. Do not add a broad
`waitForAdmissionSettledForTesting`: registration is still synchronous, and a universal
barrier would either wait on deliberately blocked probes or hide the state being tested.
Teardown should wait for `claimCount == 0` as well as lane and handle-open accounting after
releasing its probe gates. It must also wait for the probe controller's own gated/in-flight
count to reach zero, because a cancelled running probe has already removed its claim and is
therefore invisible to `claimCount`.

## Files to change when implementing

- `Vibe/Audio/AudioFileMaterializationCoordinator.m` — `Probing`, scheduler ownership,
  request registration, probe settlements, stored classification, worker-side start
  refresh, and cancellation.
- `Vibe/Audio/AudioFileMaterializationCoordinatorInternal.h` — import the scheduler only
  if the private type cannot stay in the implementation; update the injected-probe comment
  and, only if tests need it, add a probing count to the internal snapshot.
- `Tests/AudioFileMaterializationCoordinatorTests.m` — the gated probe controller and the
  race/bound tests above. Update `AudioFileOpenCoordinatorTests.m` and artwork tests only
  where their injected probe timing creates a real assertion dependency.
- `Vibe/Audio/CLAUDE.md` — state that the materialization state queue performs no I/O,
  describe `Probing`, and document that registry publication uses the start-worker answer.
- `docs/file-loading-spec.md` — keep the spec mechanism-free: add the observable rule that
  a stalled classification cannot block the caller, coordinator state, or unrelated paths;
  add the fixed probe policy numbers to section H.
- `docs/bugs/dataless-probe-on-state-queue.md` — when the implementation lands, mark it
  fixed, link back to this plan, replace the superseded remedy summary, and refresh anchors.

There should be no source change under `Vibe/Audio/Metadata/`, `Vibe/Audio/Metadata/Mac/`,
`Vibe/System/`, `Vibe/Playlist/`, or either app shell. There should be no project-file or
loading-settings change.

## Implementation order

1. Add the gated probe test helper and the direct A-blocks/B-continues regression, with
   cleanup that cannot strand a gate.
2. Add `Probing`, the fixed scheduler, synchronous claim registration, and identity-checked
   initial settlement.
3. Replace admission, preemption, and detach probes with stored state; land the same-path,
   foreground, cancellation, and saturation tests.
4. Move the publication probe into the admitted worker; land the start-refresh and
   begin/end tests.
5. Set local state on every ready settlement and add the ready-after-cancel regression.
6. Update the directory contract, behavioral spec, and bug status only after the tests
   demonstrate the complete flow.

Keep these as reviewable commits if practical. In particular, do not combine the fix with
the current stage-2 handle-run admission work: the probe lifecycle is stage 1 and can be
reviewed independently.

## Verification

Mechanical and host-less gates:

```bash
make test
make analyze CONFIG=Release
make check-layout
make check-vocabulary
make build
make build-ios
```

Then use the `vibe-debug` and `vibe-stress` skills for running-app verification:

- Hold one fake-cloud transfer while opening a different local and cloud file; transport,
  settings, and the second path must remain responsive. The blocked-classification proof is
  the injected host-less regression, not a fake-provider command.
- Exercise foreground playback arriving during a metadata sweep, same-path joining, rapid
  Next/cancel, and an abandoned open with metadata passengers.
- Confirm loading pills appear only after a dataless start classification and disappear on
  every settlement, with no pill for a local no-op.
- Run the fake-provider cloud scenarios and inspect the foreground hold, provider-slot
  count, quiescence accounting, and open deadline.
- Assert exact per-stage probe counts with the injected test controller. In a controlled
  real-provider, single-file run, use dataless diagnostics only to confirm aggregate probe
  counts remain bounded; the diagnostics cannot distinguish coordinator admission, start
  refresh, materializer, and metadata-loader probes.

## Accepted trade-offs and non-goals

- A new claim has one initial admission probe. A run initially classified dataless has one
  fresh start probe; a local run does not. The real materializer keeps its own defensive
  probe. This keeps classification, publication, and the System-layer token contract
  separate, and none runs on main or coordinator state.
- A provider can change a dataless file between the start refresh and the materializer's own
  probe, or evict a local file between its initial answer and the materializer. Those narrow
  time-of-check/time-of-use races exist today, including the documented one-transfer-wide
  local-bypass race. Closing them requires a new operation/materializer reporting contract
  and is explicitly outside this fix.
- Eight permanently stuck probes can exhaust the private scheduler. The correct behavior at
  that point is bounded `AdmissionExhausted`, not more threads. The coordinator and UI still
  remain responsive.
- Cross-path start order is no longer strictly submission order: a later healthy path may
  classify and start while an earlier path is blocked in `Probing`. That is the isolation
  this fix exists to provide. Registration ordinals still govern equal-role pending rank.
- This plan does not remove the metadata loader's own off-lock probes, alter transfer-lane
  policy, change stage-2 handle admission, or add a new user setting or debug command.

The success criterion is deliberately narrow: no coordinator dataless probe executes on
the materialization state queue or the calling thread, and achieving that does not spread
a new asynchronous protocol through audio-file, metadata, artwork, or System code.
