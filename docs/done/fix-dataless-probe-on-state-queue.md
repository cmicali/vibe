# Fix: move dataless probes off the materialization state queue

Written, implemented, and verified 2026-08-23. This fixes
[the dataless probe running on the coordinator state queue](dataless-probe-on-state-queue.md).
The first proposal made request registration asynchronous. The final design keeps registration
synchronous and moves only filesystem classification.

## Outcome

`materializeURL:role:completionQueue:completion:` still returns a cancellation token
synchronously, with its waiter already registered on the coordinator's serial state queue.
Registration is now in-memory only. A first waiter installs one path-keyed `Probing` claim,
and a private bounded `AudioWorkScheduler` probes that path off the caller and state queue.
Same-path waiters join the installed claim and share its probe.

The behavioral change is coordinator-local:

- No public API or caller changes.
- No atomic request identifiers; identifiers and claim ordinals remain state-queue-owned and
  preserve submission order.
- No changes to `AudioPlayer`, metadata or artwork loading, `CloudFileMaterializer`, or the
  materialization operation protocol.
- No persistent or cross-claim locality cache; a provider can evict or materialize a path at
  any time.

## Claim lifecycle

The four states describe work that has actually happened:

```objc
typedef NS_ENUM(NSUInteger, VibeMaterializationClaimState) {
    VibeMaterializationClaimStateProbing = 0,
    VibeMaterializationClaimStatePending,
    VibeMaterializationClaimStateRefreshing,
    VibeMaterializationClaimStateRunning,
};
```

The claim adds only three fields:

- `BOOL dataless` — the most recent classification accepted by state.
- `AudioWorkToken *probeToken` — cancellation for an initial probe which has not dispatched.
- `BOOL yieldIfDatalessAfterProbe` — remembers that a same-path foreground waiter departed
  while metadata passengers were waiting on an outstanding probe.

There is no `startProbePending`: `Refreshing` is that lifecycle state. There is no
`publishedTransfer`: a `Running` dataless claim has published begin, while `Refreshing` has
not entered its operation and publishes nothing.

The transitions are:

| From | Event | Result |
| --- | --- | --- |
| none | first waiter registers | Install `Probing`, assign ordinal, submit one initial probe. |
| `Probing` | same-path waiter registers | Join, recompute role, keep the one probe. |
| `Probing` | fresh local result | Start immediately, bypassing transfer capacity. |
| `Probing` | fresh dataless result with a free lane | Start immediately from that fresh answer; do not probe again. |
| `Probing` | fresh dataless result without a free lane | Enter `Pending`. |
| `Pending` | lane opens | Reserve it and enter `Refreshing`. |
| classified run | cancelled/inherited-cancel restart while still dataless | Readmit: enter `Pending` if its lane is busy, otherwise reserve it and enter `Refreshing`. |
| `Refreshing` | fresh answer accepted | Publish begin only if dataless, then enter `Running` and call the operation. |
| `Running` | operation settles | Pair any dataless publication, return the lane, then settle or readmit. |

An immediately admitted initial result is already fresh, so neither local nor dataless work
takes a duplicate coordinator refresh. Only delayed or readmitted dataless work refreshes at
start. Local readmission continues through the local bypass.

## Initial probe admission

Each coordinator owns one private `AudioWorkScheduler`:

| Policy | Value |
| --- | ---: |
| QoS | `QOS_CLASS_USER_INITIATED` |
| Maximum running | 8 |
| Maximum pending | 16 |
| Pending grace | 5 seconds |

These are fixed safety bounds, not transfer policy or user settings. A blocked `stat(2)` has
no cancellation point; the scheduler prevents cancelled/resubmitted work from creating an
unbounded dispatch tail. Pending-limit rejection and pending expiry both settle the claim as
the existing `AdmissionExhausted` result.

The eight running slots are process-wide, while playback, prefetch, two metadata slots, and
seven artwork requests can expose roughly eleven distinct claims. Eight wedged probes can
therefore make a later healthy claim expire after five seconds. For metadata,
`AdmissionExhausted` spends one per-path attempt and a sustained stall can drop that path from
the current scan. This bounded-concurrency failure is the cost of capping uncancellable system
calls.

The probe work captures the URL and injected probe block, not a strong coordinator across the
possibly permanent syscall. Its state settlement verifies:

1. `_claims[path]` is the same claim object.
2. The claim is still `Probing`.
3. It still has waiters.

Object identity drops an old result after every waiter cancelled and a replacement claim for
the same path was installed.

A separately owned atomic activity counter follows classification attempts from before their
scheduler/worker handoff through cancellation, rejection, state reconciliation, or drop, while
the coordinator remains weak across the syscall. Its lock-free getter feeds `debugState`, macOS
quiescence's pending counts, and the cloud loading-residue oracle, so detaching the last claim
waiter cannot create a false zero before a dispatched probe starts or hide a stuck call.

## Registration, foreground work, and cancellation

The registration block samples foreground activity before the new waiter joins, preserving
the current ordering. Unknown claims may accept eligible same-path waiters because their probe
settlement rechecks foreground activity. A known dataless metadata-only claim still rejects a
new metadata waiter with `Yielded` under an unrelated foreground hold; a local claim and a
claim already carrying foreground work may accept it.

A probing playback or prefetch waiter counts as foreground immediately. On that rising edge,
known dataless metadata claims are yielded without another syscall. `Probing` and `Refreshing`
claims are skipped: neither has entered a provider operation, and each settlement rechecks the
hold before it may do so.

Cancellation performs no I/O:

- Removing the last waiter from `Probing` calls `cancelIfPending`, removes the claim, and lets
  an already-running syscall finish in its bounded slot; identity drops its answer.
- A foreground departure with metadata passengers and an outstanding initial or refresh probe
  sets `yieldIfDatalessAfterProbe`. A local result continues; a dataless result yields them.
- A classified pending or running claim uses its stored answer for the existing readmit/yield
  decision.
- A new nonmetadata waiter clears the departure flag before the probe settles.

## Delayed and readmitted starts

A `Pending` claim may become local before its lane opens, and a cancelled run may be rebound
after its old classification. Both dataless cases enter `Refreshing` after reserving the lane.
The already-admitted materialization worker runs the refresh, synchronously asks the state queue
to accept its result, then either enters the operation or reports a cancelled run so the lane is
returned exactly once. The state queue never waits for the worker.

The refresh deliberately remains part of that admitted run. If its probe stalls, it holds the
transfer lane — including the one-wide background lane — but not coordinator state; local bypass
and the other lane still flow. Re-admitting after classification would make the answer stale at
the operation boundary again.

State validates claim identity, `runGeneration`, and `Refreshing`. It stores the fresh answer
and refuses operation entry when the run was cancelled, has no waiters, or remains metadata-only
and dataless under a foreground hold or departure flag. Otherwise it publishes begin for a
dataless answer, transitions to `Running`, and releases the worker into `runWithError:`. A local
answer transitions and runs without publication.

`finishClaim:` publishes end only for `Running && dataless`. A ready result sets
`claim.dataless = NO` before cancellation/rebind or inherited-cancellation restart decisions;
reaching the materializer's coordinated-read accessor means the bytes arrived even when cancel
raced afterwards.

`CloudFileMaterializer` keeps its own worker-side probe. That probe owns its prepared-token and
coordinated-read contract; folding it into coordinator publication would widen this fix into
the System layer.

## Queue contract and guarantees

After this change, the materialization state queue performs no filesystem or provider I/O.
The coordinator's `_datalessProbe` call sites are:

1. The bounded initial-claim scheduler worker.
2. The already-admitted `Refreshing` worker for delayed or readmitted dataless work.

This preserves:

- One materialization operation per standardized path.
- Synchronous registration, request identity, and submission-stable pending ordinals.
- Foreground preemption of provider work without guessing that unknown paths are dataless.
- Same-path metadata joining the user's claim and probe.
- Local bypass during a foreground hold.
- Registry begin/end only around a start classified dataless.
- Responsive configuration, state snapshots, cancellation, and settlement while one
  classification is blocked.

Cross-path start order intentionally follows classification availability: a later healthy path
may start while an earlier path remains `Probing`. Equal-role claims which later contend in a
pending lane still use registration ordinal as their tie-breaker.

## Tests

`AudioFileMaterializationCoordinatorTests` uses one thread-safe probe controller which counts
calls per path, returns a configured answer per call, and can gate a chosen call. Cleanup releases
every gate. The direct pre-fix regression dispatches the first request and synchronous state reads
on independent queues, so its timeout reaches cleanup rather than wedging the test process.

The focused coverage is:

- A blocked initial probe does not block state access or another path.
- Same-path waiters share one initial probe and preserve role promotion.
- Foreground registration is visible before its probe settles and preempts known transfers.
- Local and dataless metadata are distinguished under a foreground hold.
- Foreground departure during either probe passes local passengers and yields dataless ones.
- Cancellation before dispatch removes pending probe work; cancellation during a probe and
  same-path replacement drop the stale result.
- `datalessProbesInFlight` reports blocked initial and refresh calls even after a probing
  claim's last waiter detaches, then returns to zero when the call settles.
- Eight running and sixteen pending initial probes enforce the fixed bound and map overflow to
  `AdmissionExhausted`.
- A delayed dataless refresh does not block state; a fresh initial result does not refresh.
- Registration ordinal, not probe completion order, breaks an equal-role pending tie.
- Refresh-time local/dataless answers govern transfer publication, and every begin has one end.
- Ready-after-cancel marks the rebound claim local before readmission.
- Suspended metadata cannot revive a retained dataless run under a foreground hold.

Existing tests which assumed immediate `Pending` or `Running` state wait on the probe event they
actually depend on. There is no universal admission barrier: it would hide the deliberately
blocked state under test.

The coordinator bound test reaches immediate pending-limit rejection. Pending-grace expiry and
its `WaitExpired` reason are covered at the `AudioWorkSchedulerTests` boundary with a short grace;
the coordinator's fixed five-second grace is not duplicated as a wall-clock test. Both reasons
enter the same coordinator failure funnel and settle as `AdmissionExhausted`.

## Scope and deferred adjacent work

No behavior changes belong under `Vibe/Audio/Metadata/`, `Vibe/System/`, either shell, or the
project/loading settings. The metadata loader still calls `NSURLUtil.isDatalessFile:` from its
serial callback queue in `judgeWaitingPriorityRecordsWhileHeld:`. That bounded priority-record
probe is the same general class of risk, but it cannot wedge coordinator state and is explicitly
deferred to a separate audit/fix; this change does not quietly expand into metadata scheduling.

## Verification

The required gates passed: `make test` (1035/1035), `make analyze CONFIG=Release` for both
targets, `make check-layout`, `make check-vocabulary`, `make check-strings`,
`make check-translations`, `make build`, and `make build-ios`.

Four running-app runs were taken on 2026-08-24, against a generated cloud corpus with real
tags and embedded art (`make-cloud-corpus.py`) rather than the 19-file default, which is too
small for the sweep to be doing anything by the time a scenario samples it:

| Run | Result |
| --- | --- |
| `cloud-scenarios.py`, full registry | `PASS=24 XFAIL=1` — the documented clean report; S9 the expected gap, no `FAIL`/`ERROR`/`XPASS` |
| `stress.py --profile cloud` under ThreadSanitizer | 2617 ops, no violations, no unbounded growth, **no TSan report file written** |
| `stress.py --profile loading` | 32,117 ops over 30 min: 46,609 requests ready, 22,065 handle opens, 0 failed, 83 admission-refused |
| `torture.py`, four phases | 9600 ops in 817 s, no violations, no growth, every `pending` counter clear at rest |

The TSan run is the one that covers this change's new cross-thread structure — the scheduler
handoff, the refresh worker's `dispatch_sync` into state, and the activity counter. Verify the
instrumented binary is the one that actually came up (`libclang_rt.tsan_osx_dynamic.dylib` in
the live process) before believing a clean result: `open -a` resolves by bundle ID and will
silently run a different build, which makes "no report" meaningless.

Torture is where `datalessProbesInFlight` is exercised end to end rather than asserted: it
reads 0 at rest beside every other pending counter, so `quiesce` really does gate on it.

The blocked-classification proof remains the injected host-less test, because the fake provider
begins below the coordinator's real locality probe.

**The stress driver could not complete a loading soak before this work.** `click_menu` clicked
submenu parents, and AppKit assigns a submenu item `submenuAction:` the moment it gets a
submenu — so `VibeClickMenuItem`'s nil-action guard did not catch it and the forced send
aborted the app. It reproduces in one command on a freshly launched app and predates this
change (confirmed against `557c191`), and it is `#if DEBUG`, so it never reached a Release
binary. Fixing only the app side was not enough: the clean error then failed the run as a
`command` failure, so `collect_menu_ids` stopped collecting submenu parents as well.

The success criterion is narrow: no coordinator dataless probe executes on the materialization
state queue or calling thread, with no asynchronous admission protocol spread into its callers.
