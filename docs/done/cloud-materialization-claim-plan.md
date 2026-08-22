# Plan: atomic path-wide materialization admission

The remaining open defect from `fable-post-implementation-review.md` (item 5), written up rather
than fixed because the remedy is a design change the fable plan considered and rejected, and the
grounds it rejected it on do not survive reading ChatGPT's Phase 6 closely.

## A. The defect, and the evidence for it

**`AudioFileOpenCoordinator.isMaterializingURL:` is a query, not ownership.** The metadata lane's
picker asks it, then dispatches, then the operation re-asks, then calls `materializeURL:`. A claim
registered in any of those gaps is invisible, and both paths download the same bytes.

ChatGPT's plan said so before any of it was built (finding 8): *"a check followed by a separate
materialization is a time-of-check/time-of-use race"*, and Phase 6: *"never use a separate
`isMaterializingURL:` check as proof of ownership."* The header itself documents the query as
advisory (`AudioFileOpenCoordinator.h:82-90`).

**Reproduced**, once in 21,330 ops of `--profile cloud` soak:

```
FAILED after 6758 ops: consistency —
  cloud.metadata_lane_stands_aside: the metadata lane downloaded a file already in transfer 1 time(s)
```

The ops just before it: `set_fake_cloud 0.94 80 capacity=0` — an unbounded provider, so two
transfers of one path genuinely run at once rather than queueing — then `burst 600`, 600 rapid
playlist jumps across three in-flight sweeps. Re-running the identical seed passed 14,572 ops, so
the trigger is timing, not the operation sequence.

**What it costs:** one duplicate whole-file download. Not a correctness fault — both transfers
complete and no data is wrong. It consumes a provider slot, which is the one resource this whole
change set exists to protect. Providers commonly coalesce same-path requests, so the real-world
cost may be smaller than the fake's.

**What the targeted scenario proved instead.** S13 aims 60 plays directly at the lane's current
pick and never reproduces it, because the play's pre-submit hold suspends the lane and cancels its
transfer *before* the playback claim registers — `cancelled metadata` then `started playback`,
every time. So today's safety is real but **emergent**: it comes from hold ordering, not from the
query. The prefetch role is the only one that registers a claim without a hold.

## B. What is not yet known, and how to find out

**Which direction the observed overlap went**, which decides how much has to change:

- *metadata second* — the lane committed to a path the player or prefetch had just claimed. Fixable
  narrowly (C1) without touching the coordinator's claim model.
- *prefetch second* — a prefetch started on top of a transfer the lane was already running. Only
  the full design (C2) covers it, because the prefetch registers with no hold to cancel anything.

The failure directory did not keep the trace when this fired; `stress.py` now writes
`cloud-trace.json` alongside the rest, so the next occurrence names the roles. **Get that evidence
before choosing between C1 and C2** — roughly 25 minutes per soak at about a 50% hit rate.

## C. The two candidate fixes

### C1. Make the lane's decision atomic (narrow)

Replace the picker's query-then-act with one compare-and-set on the coordinator's state queue:

```objc
// Returns NO when another role already holds a live materializer for this
// standardized path; otherwise records the lane as the owner and returns YES.
- (BOOL)beginMetadataMaterializationForURL:(NSURL *)url;
- (void)endMetadataMaterializationForURL:(NSURL *)url;
```

The lane calls it where it currently calls `materializeURL:`, and stands aside on NO exactly as it
stands aside today. Playback and prefetch consult the same set when they register, and *cancel*
the lane's transfer rather than waiting for it — which is what the hold already does, so the
foreground never yields.

- **Covers:** metadata-second only.
- **Cost:** small and local. No change to claim identity, purposes, or the designed race.
- **Leaves:** the 1s `kCloudParseBlockedRecheckSeconds` poll, which the repository's `waiter`
  vocabulary rules out, and the prefetch-second direction if that is what was observed.

### C2. ChatGPT's Phase 6, two layers (full)

One admission point for everything that can download contents, keyed by **standardized path**, with
purpose demoted to scheduling metadata:

- atomically claim **or join** a path across roles;
- playback outranks pending background work;
- no new background transfer admitted while a foreground token is active;
- metadata **waits** on a prefetch of the same path and parses once it is local;
- stable sequence preserved among equal-priority metadata entries;
- known-local work bypasses provider serialization entirely.

**The objection that sank this in fable §B2 does not apply to what Phase 6 actually says.** Fable
rejected it because "re-keying materialization identity by path alone would have to rebuild [the
designed prefetch/open race] as a special case". Phase 6 is explicitly two layers: *"The shared
claim owns only making bytes local. After it settles, playback and prefetch may perform their own
`AVAudioFile` opens."* The designed race is over which `AVAudioFile` open consumes the play
request, and it lives untouched **above** a byte-only claim. The post-implementation review reached
the same two-layer design independently ("their deliberate `AVAudioFile` race can remain above a
lower, standardized-path claim that owns only the work of making bytes local").

- **Covers:** both directions, and it retires the 1s poll — the lane parks on a settlement waiter
  and is woken by it, which is what the vocabulary asks for.
- **Cost:** a refactor of the most contended class in the audio path. `AudioFileOpenCoordinator`
  already owns claim identity, ordered delivery, bounded admission and cancellation semantics; a
  second layer beneath all of that is not a local change, and its failure modes are the kind that
  take thousands of operations to surface.

## D. Verification, which is the hard part

At 1 occurrence in 21,330 ops, "a soak passed" proves almost nothing. Two things are needed:

1. **A deterministic scenario that fails before the fix.** The pattern already exists: `block_main
   <seconds> <verb>` holds the main thread and then runs a verb without yielding it, which is how
   S4b stages an ordering defect that random driving reproduces only occasionally. Here the shape
   is: let the lane commit to a path, hold main, register a same-path prefetch, release. If it
   cannot be staged that way, the fix cannot be claimed — only hoped for.
2. **Long soaks with the standing counter.** `cloud.metadata_lane_stands_aside` is checked by
   `check_consistency` on every stress and torture batch, so any run scores it. Several hours
   across seeds, with `capacity=0` well represented, is the confidence-building half.

Run `make test`, `make analyze CONFIG=Release`, `make build-ios CONFIG=Debug`, `make check-layout`
and `make check-vocabulary`; and the whole cloud scenario suite, since C2 in particular touches the
paths S3, S7 and S11 assert.

## E. Recommendation

Do **B** first — it is 25 minutes and it decides between a small change and a large one. If the
overlap is metadata-second, take **C1** and stop; the residual prefetch-second window is then a
documented known gap with a detector on it, which is a defensible place to stand. If it is
prefetch-second, **C2** is the only thing that covers it, and the case for it is stronger than the
fable plan credited — but it is a design decision about the coordinator and deserves an explicit
owner rather than being folded into a bug fix.

Doing nothing is also defensible on today's evidence, provided it is a decision rather than an
oversight: the cost is bounded, the detector is permanent, and the guarantee — that the metadata
lane never downloads what the player is already downloading — is currently emergent from hold
ordering rather than enforced. The risk of leaving it is that a future change to that ordering
silently removes the protection, with nothing in the code stating the dependency.
