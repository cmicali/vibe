# Bug: the dataless probe stats the file system on the coordinator's serial state queue

Found 2026-08-21 by audit (item B3), re-verified in depth. **Fixed 2026-08-23.** The
implementation record is
[Fix: move dataless probes off the materialization state queue](fix-dataless-probe-on-state-queue.md).

Severity: **medium consequence, medium likelihood** for ordinary provider latency;
**high consequence, low likelihood** for a stalled mount or provider.

## Former mechanism

`AudioFileMaterializationCoordinator` injects `_datalessProbe` as
`[NSURLUtil isDatalessFile:]`, a bare `stat(2)`. Before this fix, request entry, admission,
start, foreground preemption, and detach could all call it on the one serial `_stateQueue`.
That queue also owns:

- stage-1 materialization admission and settlement;
- stage-2 handle-run admission;
- synchronous configuration and foreground-state reads;
- cancellation, pending expiry, and lane draining.

A slow `stat` therefore stopped the whole coordinator. No unrelated claim could register or
settle, no pending timer could drain, and every synchronous accessor waited behind the path
whose filesystem was unresponsive.

The everyday local cost is tiny. The failure matters on SMB/NFS and file-provider volumes,
where vnode lookup can block for seconds or until a mount timeout. That defeats the isolation
the transfer and handle bounds are meant to provide: one bad path becomes a process-wide open
stall.

## Main-thread consequence

`ArtworkLoadRegistry` is main-thread-only and synchronously calls `materializeURL:` when a row
has no archived rendition and must extract from its source file. `materializeURL:` enters the
coordinator through `performStateSynchronously:`. A fresh, not-yet-scanned provider folder can
therefore make the app's main thread wait not only on its own `stat`, but on a probe for another
claim reached while the state queue drains or readmits work. The tail is a beachball, not only
an audio-open delay.

## Resolution

Request registration remains synchronous and state-queue-owned. A first waiter installs one
path-keyed `Probing` claim before `materializeURL:` returns; later same-path waiters join it.
One private `AudioWorkScheduler` performs the initial classification off the caller and state
queue with fixed bounds of 8 running, 16 pending, and a 5-second pending grace.

The claim lifecycle is explicit:

- `Probing` — initial classification is outstanding; no transfer lane or operation exists.
- `Pending` — the path is known dataless and waits for its transfer lane.
- `Refreshing` — delayed or readmitted dataless work owns a lane and refreshes its answer in
  that admitted worker; the operation has not entered and no registry begin was published.
- `Running` — state accepted the start answer and the operation may run. `dataless` records
  whether this run published a transfer begin.

A fresh initial answer starts immediately when its lane is available, without a duplicate
coordinator probe. Only a dataless claim delayed in `Pending` or readmitted after a cancelled
run takes the worker-side refresh. Ready marks the claim local before any cancellation/rebind
restart decision.

Initial probe settlement is matched by claim object identity, so a result from an
uncancellable old `stat` cannot classify a replacement claim for the same path. Pending probe
work is cancellable through its scheduler token. Foreground preemption, admission, and detach
use stored classification and perform no filesystem access; unknown `Probing` or `Refreshing`
work has not begun a provider transfer and rechecks the foreground hold when its answer lands.

The resulting queue contract is simple: the materialization state queue coordinates in-memory
claim state and performs no filesystem or provider I/O.

## Regression

The host-less coordinator test gates file A's initial probe while independently registering
file B and reading configuration, foreground activity, and the state snapshot. B and every
state read must complete before A is released. The test dispatches the potentially blocking
pre-fix calls on independent queues and releases the gate from cleanup, so a regression fails
instead of wedging the suite.

Companion coverage pins same-path probe sharing, submission-stable pending order, foreground
preemption, local bypass, cancellation before and during a probe, replacement identity,
scheduler saturation, delayed-start refresh, registry begin/end pairing, and ready-after-cancel
readmission.

The coordinator and scheduler regressions and all repository verification gates passed before
the implementation record moved to `docs/done/`.

## Deferred adjacent probe

`AudioTrackMetadataLoader.judgeWaitingPriorityRecordsWhileHeld:` also re-probes a small bounded
set on its serial callback queue, outside its lock. It cannot wedge coordinator state and is
not part of this coordinator-local repair. Its queue-isolation question is explicitly deferred
to a separate audit/fix rather than hidden inside this change.

## What the original audit understated

- It missed the main-thread artwork path above.
- It counted three shipping synchronous state entry points; there are four:
  `currentConfiguration`, `applyConfiguration:`, `isForegroundTransferActive`, and
  `materializeURL:`.
- `perf` describes the ordinary latency but not the tail's isolation failure.
