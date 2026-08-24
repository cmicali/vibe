# Metadata-loader test harness hold race

Written and implemented 2026-08-23 after
`testSamePathScanAndPrioritySlotsSpendOneSharedPathBudget` failed once in a full
`make test` run. Line anchors describe the pre-fix tree at `8193413` plus the
in-flight settings-live-effects change; the fake controller in
`Tests/AudioTrackMetadataLoaderTests.m` was untouched by that work.

## Summary

The failure is in the **test harness**, not in the loader. The fake provider
operation can escape its `blocksUntilCancelled` hold and complete as a *success*
when the test expected it to fail, because the operation reads that flag one step
after the point the test synchronizes on. The shared path failure budget itself
was honored exactly — three failures, spent as designed — so no production
behavior is at fault.

Reproduced first with a timing amplifier and then with an exact gate at the bad
interleaving. The behavior fix is one hoisted read; the gate remains as the
deterministic regression.

## What was observed

One failure in 1,022 tests, four assertions inside the one test. It has not
recurred in 19 subsequent runs: 8 single-test runs, 6 class runs and 5 full-suite
runs, the first 18 of them under full CPU saturation (16 spinners on a 16-core
host).

```
Tests/AudioTrackMetadataLoaderTests.m:1460: failed - duplicates on an exhausted path must not parse
Tests/AudioTrackMetadataLoaderTests.m:1487: (startedURLs.count) equal to (3u) failed: ("4") is not equal to ("3")
Tests/AudioTrackMetadataLoaderTests.m:1492: (startedRoles) ... failed: ("(3, 2, 2, 2)") is not equal to ("(3, 2, 2)")
Tests/AudioTrackMetadataLoaderTests.m:1495: (scan.metadata) == nil failed: "<VibeLoaderTestMetadata: 0x758029540>"
```

The app log in the same run names the cause outright:

```
Metadata scan materializing joined-duplicate-attempts.wav (1 pending behind it)
Metadata scan materialized joined-duplicate-attempts.wav in 0.0s          <-- SUCCEEDED
Metadata priority materializing joined-duplicate-attempts.wav
Metadata materialization failed ... (attempt 1 of 3); re-queued last
Metadata priority materializing joined-duplicate-attempts.wav
Metadata materialization failed ... (attempt 2 of 3); re-queued last
Metadata priority materializing joined-duplicate-attempts.wav
Metadata materialization failed ... and is out of attempts
```

**The first start succeeded.** The test intends it to be held and then completed
as a failure. Because it succeeded, the file parsed — which is the `XCTFail` at
:1460 and the non-nil `scan.metadata` at :1495 — and the path's three-failure
budget was then spent in full by the priority slot afterwards, giving four starts
with roles `scan, priority, priority, priority` instead of three.

Read in that order, every one of the four assertion failures is downstream of the
single mis-sequenced first completion. Note in particular that the budget was
**not** exceeded: the three logged attempts are "attempt 1 of 3", "attempt 2 of 3"
and "out of attempts", exactly as the accounting intends.

## The race

`VibeMetadataLoaderOperation.runWithError:`
(`Tests/AudioTrackMetadataLoaderTests.m:169-181`) runs through four relevant
points on a worker thread:

```objc
- (BOOL)runWithError:(NSError *__autoreleasing *)error {
    VibeMetadataLoaderOperationController *controller = _controller;
    [controller recordStartForURL:_url role:_role];        // (1) records; fulfills firstStartExpectation
    if ([controller consumeFailureForURL:_url]) {          // (2) armed-failure check
        ...
        return NO;
    }
    if (!controller.blocksUntilCancelled) {                // (3) hold check
        return YES;                                        //     -> completes as a SUCCESS
    }
    [_condition lock];
    while (!_finished) { [_condition wait]; }               // (4) parked until completeFirst*/cancel
    ...
}
```

Step (1) is what fulfills `firstStartExpectation`, and the test resumes on it:

```objc
[loader load:@[scan, priority]];
[self waitForExpectations:@[controller.firstStartExpectation] timeout:2];   // returns at (1)
[loader prioritizeTrack:priority];
[self waitForCondition: /* priority parked behind the scan claim */ ];
[controller failNextStarts:10 forURL:url];
controller.blocksUntilCancelled = NO;                                       // releases the hold
[controller completeFirstFailed];
```

So the test's synchronization point is "**the start was recorded**", while the
behavior it depends on is "**the operation is parked at (4)**". Between those two
facts the worker still has steps (2) and (3) to run, and the test is free to
mutate both flags those steps read.

Normally the worker gets from (1) to (3) before the test's writes land: it finds
nothing armed at (2), still sees `blocksUntilCancelled == YES` at (3), and parks.
`completeFirstFailed` then fails it. Three starts, roles `3, 2, 2`. Pass.

The failing interleaving is the worker being descheduled **between (2) and (3)**:

1. Worker runs (1) — start recorded, expectation fulfilled.
2. Worker runs (2) — nothing armed yet, so no failure. Then it is descheduled.
3. Test resumes, arms ten failures, sets `blocksUntilCancelled = NO`, and calls
   `completeFirstFailed`, which latches `_finished`/`_ready` under the condition
   even though the worker has not reached its wait loop.
4. Worker resumes at (3), reads `blocksUntilCancelled == NO`, and **returns YES**
   before consulting that latched completion.

The held operation completes as a success, the file parses, and the rest of the
assertions fall over.

The window is the handful of instructions between two flag reads, which is why it
is astronomically rare in practice and why 18 saturated runs never hit it.

**The same latent race exists at all ten `blocksUntilCancelled = YES … = NO`
pairs in the file** — at `:965/1004`, `:1050/1093`, `:1453/1476`,
`:1536/1583`, `:1602/1645`, `:1669/1704`, `:1728/1765`, `:1858/1914`,
`:1936/1968`, `:2054/2110`. This test is simply the one whose assertions are
sharp enough to notice.

## Confirming it

Widening the (2)→(3) window by 20 ms reproduced the failure **exactly**, first
try, with no load:

```objc
    if ([controller consumeFailureForURL:_url]) { ... return NO; }
+   usleep(20000); // probe
    if (!controller.blocksUntilCancelled) { return YES; }
```

```
Metadata scan materialized joined-duplicate-attempts.wav in 0.0s
:1461 failed - duplicates on an exhausted path must not parse
:1488 ("4") is not equal to ("3")
:1493 ("(3, 2, 2, 2)") is not equal to ("(3, 2, 2)")
:1496 (scan.metadata) == nil failed
```

Same four assertions, same roles, same successful first start as the natural
failure. That is useful diagnostic amplification, but a sleep is not a
deterministic test: the main thread must still finish its priority submission,
condition poll and flag writes before the delay expires.

The implemented regression therefore installs a one-shot hook immediately after
the false armed-failure check and blocks that worker on a semaphore. The test
waits for the hook, establishes that the priority record is parked behind the
scan claim, arms the later failures, clears the hold, and latches the first
operation's failed completion before releasing the worker:

```objc
[controller setAfterFailureCheck:^{
    [holdDecisionReached fulfill];
    long waitResult = dispatch_semaphore_wait(holdDecisionGate,
            dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    XCTAssertEqual(waitResult, 0L, @"hold decision gate timed out");
}];

@try {
    [loader load:@[scan, priority]];
    [self waitForExpectations:@[
        controller.firstStartExpectation, holdDecisionReached
    ] timeout:2];
    ...
    [controller failNextStarts:10 forURL:url];
    controller.blocksUntilCancelled = NO;
    [controller completeFirstFailed];
}
@finally {
    [controller setAfterFailureCheck:nil];
    dispatch_semaphore_signal(holdDecisionGate);
}
```

The controller takes and clears the copied hook under its lock, then the worker
invokes it after that lock is released. The `@finally` always opens the gate, so
a failed assertion or exception cannot strand the coordinator during teardown;
the bounded wait makes a broken release path fail instead of leaving an immortal
worker. Against the old dynamic flag read this exact interleaving succeeds
incorrectly every time; against the snapshot it returns the latched failure every
time.

## The fix

Decide whether the operation parks **before** recording the start, so its hold
decision is fixed before the expectation the test waits on fires. The
synchronization point then means what the tests use it to mean, and no later flag
write can retarget an operation that has already begun from held to successful.

```objc
 - (BOOL)runWithError:(NSError *__autoreleasing *)error {
     VibeMetadataLoaderOperationController *controller = _controller;
+    // TRAP: recordStart fulfills the test's synchronization edge. Snapshot
+    // the hold first so a later clear cannot retarget this run to success.
+    BOOL parks = controller.blocksUntilCancelled;
     [controller recordStartForURL:_url role:_role];
     if ([controller consumeFailureForURL:_url]) {
         ...
         return NO;
     }
-    if (!controller.blocksUntilCancelled) {
+    if (!parks) {
         return YES;
     }
     [_condition lock];
```

The remaining ordering between (1) and (2) is then harmless outside the gated
regression. If `failNextStarts:` lands before the check, the held operation fails
there instead of parking; `completeFirstFailed` may still latch its condition
state, but it is outcome-redundant. The retries spend exactly the remaining
budget — three starts, roles `3, 2, 2`, the asserted outcome either way.

One line of behavior fixes all ten hold/clear pairs at once because it fixes the
fake, not their individual timing. The one-shot hook is test instrumentation for
the single deterministic regression and does not choose an operation's result.

### Verified

- The exact gated regression passes with the snapshot and fails with the old
  dynamic read, producing the same successful first start and four downstream
  assertions as the natural failure.
- The whole loader class passes: **29 tests, 0 failures**.
- Full suite: **1,022 XCTest tests plus 25 cloud-runner oracle tests, 0 failures**.

### Why not the alternatives

- **Lengthening the test's `waitForDelay:0.05`** does nothing. That settle exists
  to give an erroneous *fourth* start time to appear; the bug is a *first* start
  taking the wrong branch, which has already happened by then. A longer delay
  would make the test slower and no more correct.
- **Making every vulnerable hold/clear pair observable** — a second expectation
  fulfilled just before `[_condition wait]`, with each affected test waiting on
  that instead — would be defensible. It costs an edit at all ten pairs for the
  same behavior guarantee; the implemented hook exists only to pin this
  regression's exact interleaving.
- **Serializing the fake behind one lock across (1)–(3)** could work if the lock
  were released before step (4). It is more invasive: the controller's flag,
  failure and start access would all need to share that critical section, for no
  stronger guarantee than the snapshot.

## Scope

The code change is in `Tests/AudioTrackMetadataLoaderTests.m` only. No production
source, `project.yml`, or strings changed. The completed plan moved from
`docs/future/` to `docs/done/` with the implementation.
