# Bug: the dataless probe stats the file system on the coordinator's serial state queue

Found 2026-08-21 by audit (item B3), re-verified in depth, **not fixed**. File:line anchors are against `main` at `07d7777`; the working tree is dirty but no anchored file (`Vibe/Audio/**`, `Vibe/System/CloudFileMaterializer.m`, `Vibe/Util/NSURLUtil.m`, `Tests/AudioFileMaterializationCoordinatorTests.m`) is among the modifications, so the anchors are clean. The root `CLAUDE.md` *is* modified — re-check that reference before acting.

Severity: **medium consequence, medium likelihood** for the everyday case; **high consequence, low likelihood** for the tail. The audit filed it `medium · perf` and understated the blast radius in one specific way — it missed a main-thread path. See *What the audit got wrong*.

## The mechanism

`_datalessProbe` is `[NSURLUtil isDatalessFile:]` in production (`AudioFileMaterializationCoordinator.m:375`, `:388`), which is a bare `stat(2)` (`NSURLUtil.m:141-142`). It is called from five places, **all of them on `_stateQueue`**:

| Site | Caller | Probes |
| --- | --- | --- |
| `:561` | `preemptMetadataClaimsForForegroundRiseExcludingPath:` | every *other* live claim's URL, in a loop |
| `:612` | `materializeURL:` admission body | the incoming request's URL |
| `:684` | `admitClaim:preserveExistingAdmission:` | the claim's URL |
| `:733` | `startClaim:` | the claim's URL |
| `:962` | `detachRequestToken:` | the claim's URL |

`_stateQueue` is a single serial queue (`:430`) and it is the coordinator's only critical section. Everything funnels through it:

- **Stage-1 admission** — `materializeURL:` (`:596`, via `performStateSynchronously`).
- **Stage-2 opens** — `openURL:purpose:…` (`:1058`), which is the single admission point for the interactive playback open, and which reaches `materializeURL:` re-entrantly (`:1131`) so the whole chain `openURL:` → `startHandleRunStages:` → `materializeURL:` → `admitClaim:` → `startClaim:` runs inline in one state-queue block and does the `:612`/`:684`/`:733` stats inside it.
- **Four shipping sync entry points** — `currentConfiguration` (`:471`), `applyConfiguration:` (`:479`), `isForegroundTransferActive` (`:541`), `materializeURL:` (`:596`) — plus two `*ForTesting` (`:1257`, `:1274`).
- Every settlement, detach, drain and the pending timer.

So a `stat` that blocks stalls the coordinator entirely: no claim is admitted, no run is started, no settlement is processed, and the pending timer's handler cannot fire.

## Why this is not merely "a syscall in a lock"

`stat` is fast on a healthy local file — **measured 2.3 µs**, recorded in `NSURLUtil.m:118`. That is the everyday case and it is negligible. The defect is what happens on the file systems this coordinator exists for:

- **A hung or slow network mount (SMB/NFS).** `stat` blocks for the mount's timeout — seconds to a minute on a hard mount.
- **An unresponsive file-provider extension.** A cold vnode lookup upcalls to the provider; a wedged third-party provider (Dropbox, Google Drive, OneDrive) blocks the caller.

And that is precisely the failure the module's whole design exists to contain. Lane capacity plus the admission grace is a bound on *how much of the app one bad file can take down*: a wedged transfer or a wedged `AVAudioFile` open holds **one slot**, and other files keep flowing. Putting the probe on the shared serial queue defeats that containment — one wedged path takes the whole coordinator, playback included.

The codebase already knows this rule and states it twice, in the two other places the same syscall appears:

- `AudioTrack.m:70-73` — "The file-attribute stat can block indefinitely on a hung network mount or a dataless cloud file, and holding the monitor through it would wedge every other caller" — and deliberately computes it **outside** the `@synchronized`, accepting a duplicated computation to do so.
- `AudioTrackMetadataLoader.m:704-706` — "Probed before the lock — the stat is cheap but is still I/O".

`VibeStandardizedAudioOpenPath` (`AudioFileOpenRules.h:36-38`) makes the same commitment for path standardization: "Standardization is deliberately lexical: resolving symlinks would stat the target, which is one of the operations this key exists to keep inside a bounded worker."

The coordinator is the one component that states the rule in its own comments and then breaks it.

## The main-thread path the audit missed

`ArtworkLoadRegistry` is main-thread-only by contract — `ArtworkLoadRegistry.h:31`, asserted at `ArtworkLoadRegistry.m:125` and again at `AudioTrackArtwork.m:791`. It calls `materializeURL:` synchronously at `ArtworkLoadRegistry.m:174`, and `materializeURL:` is `performStateSynchronously` → `dispatch_sync(_stateQueue, …)` (`:460-467`).

So the main thread can block on `_stateQueue`, and inside that block it runs `stat` — not only for its own URL (`:612`, `:684`, `:733`) but, via `drainPendingClaims` → `startClaim:` and `readmitPendingClaim:` → `admitClaim:`, for **arbitrary other claims' URLs**. On a wedged mount that is a beachball, not a latency blip.

Preconditions, stated honestly: the registry only reaches the coordinator when `request.sourceURL` is non-nil, i.e. when the artwork has no archived rendition (`AudioTrackArtwork.m:779-781`). A scanned library with renditions never gets here. The exposed case is a **freshly opened, not-yet-scanned cloud folder** — which is exactly the situation in which a provider is most likely to be slow.

## Everyday cost, honestly bounded

The concurrent in-flight request count is small by construction, so this is not a throughput problem:

- The metadata sweep holds one scan slot plus one priority slot (`_scanMaterializationInFlight` / `_priorityMaterializationInFlight`, `AudioTrackMetadataLoader.m`).
- `ArtworkLoadRegistry` is capped at 2 running / 5 pending (`ArtworkLoadRegistry.h:25-27`).
- Playback and prefetch are one each.

On a real provider with a cold vnode cache a `stat` can cost a few ms, so the realistic everyday effect is single-digit-to-tens of milliseconds of serial-queue occupancy in front of a playback open. Real, but small. **The tail is the reason to fix it.**

## A related redundancy

`CloudFileMaterializer.m:241` already probes the same file on the worker queue, at the top of `materializeURL:token:error:` ("Keep the placeholder probe inside the prepared call"). So a running claim stats its file twice — once on the state queue at `startClaim:` and once on the worker microseconds later. Moving the state-queue probe off is therefore not adding a syscall; it is relocating one that already has a correct home.

## The fix

Take every syscall off `_stateQueue` **and** off the caller's thread by inserting one asynchronous probe stage ahead of admission. The state queue then does only in-memory work, which is what makes `isForegroundTransferActive`'s `dispatch_sync` safe.

### 1. A dedicated probe queue

Add `_probeQueue`, a **concurrent** queue at `QOS_CLASS_USER_INITIATED`, used for nothing but `_datalessProbe`. Concurrent, not serial: a serial one would just relocate the head-of-line blocking. Not one of the existing worker queues: a `dispatch_barrier_sync` on those would wait for in-flight transfers, which the tests deliberately keep parked.

Thread-explosion risk is bounded by the caller counts above; if a hard bound is wanted later, a `dispatch_semaphore` of ~8 around the probe is the knob, with the same trade-off any bound has.

### 2. `materializeURL:` becomes non-blocking

```objc
- (AudioFileMaterializationRequestToken *)materializeURL:(NSURL *)url
                                                    role:(VibeAudioFileMaterializationRole)role
                                         completionQueue:(dispatch_queue_t)completionQueue
                                              completion:(VibeAudioFileMaterializationCompletion)completion {
    NSString *path = VibeStandardizedAudioOpenPath(url);        // lexical, no I/O
    uint64_t identifier = [self nextRequestIdentifier];          // now atomic, see 3
    AudioFileMaterializationRequestToken *token = [[AudioFileMaterializationRequestToken alloc]
            initWithCoordinator:self path:path identifier:identifier
                completionQueue:completionQueue completion:completion];
    __weak AudioFileMaterializationCoordinator *weakSelf = self;
    dispatch_async(_probeQueue, ^{
        AudioFileMaterializationCoordinator *strongSelf = weakSelf;
        if (!strongSelf) return;
        BOOL dataless = strongSelf->_datalessProbe(url);        // the only stat, on neither queue
        dispatch_async(strongSelf->_stateQueue, ^{
            if ([token isDetached]) return;                      // cancelled before admission
            [strongSelf admitRequestWithToken:token url:url path:path
                                         role:role dataless:dataless];
        });
    });
    return token;
}
```

`admitRequestWithToken:…dataless:` is today's `performStateSynchronously` body verbatim, with `self->_datalessProbe(url)` at `:612` replaced by the passed-in flag and `claim.dataless = dataless` stored on claim creation.

The token is still returned synchronously, so `run.materializationToken = [self materializeURL:…]` at `:1131` is unchanged. The `[token isDetached]` guard is the same shape as `openURL:`'s existing `[token deliveryStillWaiting]` check at `:1060`; the token's `isDetached` (`:214`) and single-shot settle (`:220`) already make this safe, and `detachRequestToken:` (`:932`) already no-ops when no claim is installed.

### 3. Atomic request identifiers

`nextRequestIdentifier` (`:496-503`) is currently state-queue-protected. It must now run before the hop. Make `_nextRequestIdentifier` an `atomic_uint_fast64_t` with `atomic_fetch_add`, keeping the existing "skip 0" guard.

### 4. A stored `claim.dataless`, and where it is refreshed

Add `@property (nonatomic) BOOL dataless;` to `VibeAudioFileMaterializationClaim`. The four remaining probe sites read it instead of stat'ing:

- `:684` `admitClaim:` — the local-bypass fast path, pinned by `testLocalFileStartsPastBackgroundCapacity`.
- `:733` `startClaim:` — the `publishedTransfer` decision.
- `:561` `preemptMetadataClaimsForForegroundRiseExcludingPath:` — reads each claim's own stored flag; the loop stops doing I/O per claim entirely, which is the single largest win here.
- `:962` `detachRequestToken:` — reads the claim's stored flag.

Refresh points, none of which is a syscall:

- **Claim creation** — from the admitting request's probe.
- **Every subsequent request joining the path** — each carries its own fresh probe, and this is the case the C1 comments care about: "the playback open downloading this very file is the common way local flips to YES" (`AudioTrackMetadataLoader.m:610`).
- **`finishClaim:` with `ready && !runWasCancelled`** — the bytes are now local, so set `claim.dataless = NO` before the readmit and inherited-cancel restart paths run.

### 5. What this trades away

Stated rather than hidden, because each is a real change:

- **Ordinal ordering.** `claim.ordinal` (`:645`) is assigned at claim creation, which is now probe-completion order rather than submission order. Two same-lane pending claims can swap rank by the difference between two `stat` latencies. The sweep submits one at a time and artwork is capped at 2, so this is close to unobservable — but it is a change to `bestPendingIndexInArray`'s input.
- **`startClaim:`'s publish freshness.** A claim readmitted from pending uses a value up to one admission grace old (5 s interactive, 10 s background) instead of one probed at start. Worst case is a loading pill that appears and vanishes for a run that turned out to be a no-op; `CloudTransferRegistry`'s begin/end stay paired and FIFO-ordered to main, so nothing desynchronises. Step 6 removes even this.
- **`foregroundWasActive` is sampled one probe later.** It is still computed inside the same state-queue block "before this request joins the table" (`:604-608`), so the comment stays true. If anything the rule tightens: a foreground open submitted just before is now more likely to be visible.

### 6. Optional, and strictly more accurate than today

Have the operation report the probe it already performs. Add an out-parameter or a `datalessAtRun` property to `AudioFileMaterializationOperation`, set by `CloudFileMaterializer.m:241`'s existing probe, and post it back to the state queue alongside the run result. `publishedTransfer` then reflects the file's state at the instant the transfer began rather than just before dispatch — better than the current code — and the duplicate stat noted above collapses to one.

Cost: it touches the operation protocol and the test double (`VibeTestMaterializationOperation`). Worth doing as a second commit, not folded into the first.

### 7. Tests

`materializeURL:` no longer settles the claim table before it returns, so a snapshot taken immediately after a request can race. Most existing assertions are already fenced by `waitForStartedCount:` or an expectation; three are not:

- `Tests/AudioFileMaterializationCoordinatorTests.m:312` — `testSamePathRequestsAtomicallyJoinOneOperation`, snapshot straight after the second request.
- `:346` — `testCancelledRunRebindsOnePathClaimAndRestartsAtThePromotedRole`, snapshot straight after the rebinding request.
- `:618` — `backgroundPendingCount == 1` asserts on a prefetch submitted after the request that was waited on.

Add one barrier to the `*ForTesting` surface:

```objc
- (void)waitForAdmissionSettledForTesting {
    dispatch_barrier_sync(_probeQueue, ^{});     // every in-flight probe has hopped
    [self performStateSynchronously:^{}];        // …and its admission has run
}
```

Then add the regression test this bug is about, which the injectable `datalessProbe` already makes expressible: a probe that blocks on a semaphore for file A must not delay admission or start of file B. That test fails on today's code and passes after the fix, and it is the only durable guard against the probe drifting back onto the state queue.

### 8. Documentation to update

- `Vibe/Audio/CLAUDE.md:102` — "gated on the dataless probe computed once at start" becomes "computed once at admission".
- The `publishedTransfer` doc comment, `AudioFileMaterializationCoordinator.m:105-108` — same wording.
- Root `CLAUDE.md`, the "A row shows the loading bar only while a provider transfer is actually running" guarantee — the guarantee itself is unchanged; only the *when* of the probe moves.
- `docs/file-loading-spec.md` — add the rule this fix establishes, in the same voice as the existing ones: **the coordinator's state queue performs no I/O; every syscall belongs to a bounded worker.** That is the sentence that makes the next call site checkable, which is the whole point of writing it down once.

## Verification

- `make test` — the coordinator suite plus the new blocking-probe regression test.
- `make analyze CONFIG=Release` — both targets, must stay clean.
- The `vibe-stress` skill's cloud scenario suite over the fake file provider — download ordering, the foreground hold and the open deadline are the three guarantees most exposed to the reordering in step 5.
- The debug channel's dataless diagnostics (`NSURLUtil.setDatalessDiagnosticsEnabled:`, `NSURLUtil.m:160`) to confirm the per-file probe count did not multiply, and `debugPriorityLaneState` to confirm lane behaviour is unchanged.

## What the audit got wrong

**It missed the main thread.** The finding described the hazard as one confined to the coordinator's own serial queue — "a stalled SMB mount or provider wedges every audio open including playback". True, but `ArtworkLoadRegistry` is main-thread-only and enters through `materializeURL:`'s `dispatch_sync`, so the same wedge is a UI hang, not only an open stall. That is the difference between a latency defect and a beachball.

**It said three sync entry points.** There are four shipping ones — `currentConfiguration`, `applyConfiguration:`, `isForegroundTransferActive`, `materializeURL:` — plus two testing-only.

**Its severity label is defensible but incomplete.** `perf` describes the everyday case correctly (small, bounded by the caller counts above). It does not describe the tail, which is an isolation failure in the one component built to provide isolation.
