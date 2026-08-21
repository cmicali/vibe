# Bug: two DownloadProgressMonitors watch the same file on every cloud playback open

Found 2026-08-21 by audit (item B2), re-evaluated but **not fixed**. The file:line anchors below are against `main` at `07d7777` with a clean working tree; every one was re-verified after the re-evaluation. Re-check them before acting.

Severity: **medium**. Bounded resource waste plus a violated guarantee — no wrong pixels, no crash, no leak. The audit's magnitude claim needs two corrections and misses two aggravations; see *What the audit got wrong* and *What the audit missed*.

## The guarantee it breaks

Root `CLAUDE.md:106`:

> The playing row's fraction comes from the shell's own open-request-identified monitor via `noteProgress:forURL:`, **so no file is watched by two monitors.**

Restated at `Vibe/Audio/CLAUDE.md:102` ("one `DownloadProgressMonitor` per transferring path unless the shell's own monitor already feeds that path"). The code does not keep either sentence. As with the display-art stash, the docs state the intent correctly, so the fix restores a rule already written rather than inventing one.

## The mechanism

`AudioFileMaterializationCoordinator.m:733-740` publishes a begin the moment a dataless claim starts running — t≈0 for a playback open. `CloudTransferRegistry.m:107` mints a monitor unconditionally on that begin.

The shell mints its own at `kSlowOpenIndicatorDelaySeconds = 0.5` (`AudioPlayer.m:72`, armed at `:656` → `MainPlayerController+PlayerEvents.m:61`, `PlaybackController+PlayerEvents.m:56`).

Suppression is **reactive**: only `noteProgress:forURL:` (`CloudTransferRegistry.m:150-157`) cancels the registry's monitor, and it runs only when a fraction actually arrives. So the overlap is:

| Provider | Overlap |
| --- | --- |
| macOS, provider publishes `NSProgress` | ~0.5 s → first publication (measured ~1 Hz), so up to ~1 s |
| macOS, iCloud-indexed only | 0.5 s → `NSMetadataQuery` gathering completes |
| **Provider that never publishes a fraction** | **the entire transfer** |

That last row is not a corner case. `DownloadProgressMonitor.h:37-41` records the measurement: *"MEASURED on an iPhone against Dropbox: dataless=1 with allocated=0 for the whole 9s of a 66MB file, then complete in one step."* A replicated File Provider extension fetches into its own temp file and has the system swap it in, so the poll sees nothing to report and `noteProgress:` is never called.

## What the audit got wrong

The finding costs the overlap as *"two NSMetadataQuery instances plus two File Provider subscriptions per file"*. Neither is the dominant cost, and one does not exist in the case it calls worst:

1. **The File Provider subscription is macOS-only** — `DownloadFileProviderProgressSource` is inside `#if TARGET_OS_OSX` (`DownloadProgressSourceAdapters.m:219`). It is not doubled on iOS, which is exactly the platform where the overlap lasts longest.
2. **The `NSMetadataQuery` is real but short-lived off iCloud.** It starts for any item answering `NSURLIsUbiquitousItemKey`, which per `System/CLAUDE.md` includes Dropbox — but `queryUpdated:` cancels it at `DidFinishGathering` when the item is not iCloud-indexed (`DownloadProgressSourceAdapters.m:196-200`). So two queries, both self-limiting.

## What the audit missed

Both are worse than the window it describes.

### 1. The suppression is not sticky across a claim restart

`externallyFed` is a property of `VibeCloudTransferEntry` (`CloudTransferRegistry.m:23`), and `endedTransferForPath:` **removes the entry** (`:120`). Any coordinator path that ends and re-begins the same path therefore resets it while the shell's monitor is still alive and its open request identifier unchanged — the re-begin mints a **third** monitor, and its samples are applied to the entry until the shell's next fraction re-sets the flag.

Two reachable routes:

- `inheritedCancelRestarts` (`AudioFileMaterializationCoordinator.m:823-834`) — its own comment describes the trigger: *"a play landing milliseconds after a rising edge cancelled the sweep's transfer inherits it."* Bounded at 2 restarts.
- `yieldClaim:` on a running claim (`:882`), whose readmission re-begins the same way.

`Tests/CloudTransferRegistryTests.m:137` (`testAReadmittedRunEndsAndRebegins`) already pins the mint-on-rebegin behaviour. Nothing tests it against a live shell declaration, because there is nothing to declare.

### 2. The doubled `stat` poll is the real cost, and the only one on iOS

`DownloadAllocatedSizeSource` runs a 0.25 s timer (`DownloadProgressSourceAdapters.m:11`). Two monitors = **8 `stat`s/sec against a dataless provider file for the whole transfer**. In the measured Dropbox-on-iPhone case that is 9 s at 8 Hz for a source that publishes nothing until completion — pure waste, and the only doubled source there.

### 3. The existing scenario suite structurally cannot catch this

Under `VibeFakeCloud`, `startFakeProgress` arms with `DISPATCH_TIME_NOW` (`DownloadProgressMonitor.m:164`) and `reportFraction:` lets a first `0` through — init sets `_lastReported = -1` (`:58`), so the `fraction < _lastReported + 0.01f` gate at `:204` is false. The shell's very first fake tick calls `noteProgress:0` and the overlap closes in one runloop turn.

The fake is precisely the case where the bug is invisible. Real providers pay. **Any fix must be gated by a unit test, not by `cloud-scenarios.py`.**

## What is *not* wrong

Checked and cleared, so they are not re-investigated:

- **The fraction never goes wrong.** `displayFraction:over:` (`CloudTransferRegistry.m:128`) never downgrades a positive value to zero, and once `externallyFed` is set the registry monitor's samples are dropped (`:136`). Even the three-monitor case yields a plausible fraction for the right file.
- **Local files are exempt.** `claim.publishedTransfer = _datalessProbe(claim.url)` (`AudioFileMaterializationCoordinator.m:733`) means a local claim publishes nothing and no monitor is minted at all.
- **Prefetch and playback do not double-publish.** The coordinator holds one claim per path (`_claims[claim.path]`), so a prefetch joining a playback open is one begin, not two.
- **No leak.** Both monitors are cancelled on their own paths; this is concurrent waste, not unbounded growth.

## The fix

The root cause is that ownership is **inferred from a fraction** instead of **declared**. Make it declared.

### 1. An explicit single-slot external-feed declaration

`Vibe/Audio/CloudTransferRegistry.h` — beside `noteProgress:forURL:`:

```objc
- (void)beginExternalProgressForURL:(NSURL *)url;
- (void)endExternalProgressForURL:(NSURL *)url;
```

Backed by one `NSString *_externallyFedPath` ivar — **not a set**. Each shell holds exactly one `DownloadProgressMonitor` (a single `_downloadMonitor` ivar: `MainPlayerControllerInternal.h:52`, `PlaybackControllerInternal.h:65`) and there is one shell per process, so a single slot models the truth exactly and makes replacement atomic. Document it with the escape hatch the class already uses for `observer` (`CloudTransferRegistry.h:33-36`): *a second means upgrading this to counted registration, not silently replacing whoever declared first.*

- `beginExternalProgressForURL:` — release any prior slot, take the new path, cancel the entry's monitor if one exists.
- `endExternalProgressForURL:` — release **only if the path matches**, so a mismatched release is a no-op rather than a steal.
- **Release resumes.** If the entry still exists and has no monitor, mint one.

Release-resumes is not a nicety. The shell's teardown at `didStartPlaying:` can race a *new* begin on the same path (a metadata claim landing on the file the playback claim just finished); without resume that transfer runs unwatched for its whole life and its row freezes at the last fraction.

`beganTransferForPath:` then mints only when the path is not the declared one. **That single check is what fixes aggravation 1**, because the declaration lives outside the entry and outlives entry churn.

### 2. Delete `externallyFed`; replace it with a monitor generation

The flag becomes derivable (`[path isEqualToString:_externallyFedPath]`), so it goes — one source of truth. But the job it was doing at `:136` — dropping a sample already dispatched to main from a just-cancelled monitor — is better done exactly: stamp `entry.monitorGeneration`, capture it in the factory handler, drop on mismatch. That also closes the same class of late sample across the **resume** path, which a derived flag would not.

Spelled `monitorGeneration`, never bare `_generation`, per the vocabulary rule — `make check-vocabulary` enforces it.

`noteProgress:` then records only when the caller has declared. Fail-quiet-and-single beats fail-silent-and-doubled; the shell's handler is already `currentURL`-gated (`DownloadProgressMonitor.m:78-82`), so the declared path always matches the reported URL.

### 3. Shell wiring, both platforms

- **Declare before minting**, inside the same `if` block that constructs the monitor (`MainPlayerController+PlayerEvents.m:58-74`, `PlaybackController+PlayerEvents.m:53-73`), so no instant exists with both alive. The same-open-identifier preserve branch correctly re-declares nothing.
- Add `_downloadMonitorURL` beside `_downloadMonitor` and `_downloadMonitorOpenRequestIdentifier`. The release must name the path that was **monitored**; after a track change that is not the current track's URL, so it cannot be derived at teardown.
- macOS releases in the existing `teardownDownloadMonitor` (`MainPlayerController.m:637`), whose comment already exists so the pair cannot drift — the URL joins that pair. Guard the call on a non-nil URL rather than widening the registry API to nullable. Needs a `CloudTransferRegistry.h` import in `MainPlayerController.m`.
- **iOS has no teardown helper** — the same three lines are duplicated at `PlaybackController+PlayerEvents.m:104-106` and `:241-243`. Add `teardownDownloadMonitor` to `PlaybackControllerInternal.h` and fold both sites into it, so each shell has exactly one release point. This is what makes the fix structurally safe instead of three copies to keep in sync.

### 4. Tests — `Tests/CloudTransferRegistryTests.m`

New cases (the injected-factory seam already supports all of them):

1. declaration before begin → nothing minted;
2. declaration after begin → the registry's monitor cancelled;
3. **readmitted run under a live declaration → nothing minted** (aggravation 1);
4. release while still transferring → a fresh monitor minted;
5. release after the transfer ended → nothing minted;
6. declaring a second path → the first is released and resumes;
7. a late sample from a cancelled monitor is dropped by generation.

Update `testAZeroSampleNeverLeavesOrReentersIndeterminate` (`:98`) and `testNoteProgressSuppressesTheRegistrysMonitor` (`:112`) to declare first. The contract changed; that is the point.

### 5. Docs

Both guarantee statements read as though the first fraction is what enforces the rule. Rewrite to say ownership is declared and outlives entry churn:

- root `CLAUDE.md:106`
- `Vibe/Audio/CLAUDE.md:102`
- one clause in `Vibe/System/CLAUDE.md`'s `monitorReplacing:` paragraph (`:23`), which currently ends at "preserving it when a same-row replay still owns the same underlying open identifier"

### 6. Optional — make the guarantee observable

Add the declared-owner flag per transfer to `dump_row_loading` (`DebugCommonVerbs.m:430`), whose own comment says its job is *"so a mismatch is visible"*. Given §3 above, the debug channel against a real provider is the only place "one monitor per transfer" was ever checkable.

## Rejected alternatives

- **Skip minting for playback-role claims.** Role is the wrong signal: the shell only mints at 0.5 s *and* only if the track is still current, so a fast cloud open or a superseded one would leave the row permanently indeterminate. Prefetch claims are interactive-lane and unwatched by any shell.
- **Delay the registry's mint by 0.5 s.** Racy, and duplicates a player constant in a UI publication surface.
- **Invert — the registry owns the only monitor and the shell reads from it.** The shell's monitor carries `movement` (the open's abandon deadline) and `currentURL` playlist gating. `CloudTransferRegistry.m:50-52` explicitly refuses to own deadline policy and is right to.
- **A refcounted shared monitor pool keyed by path.** Over-built for two call sites with genuinely different needs (one needs `movement`, one does not), and it trades explicit ownership for lifetime questions.

## Open calls for the implementer

1. **Naming.** `beginExternalProgressForURL:` / `endExternalProgressForURL:` follows the "externally fed" language already in `CloudTransferRegistry.m:17`. The vocabulary table's `claim` arguably fits — this *is* single-flight ownership of shared work — but `claim` is load-bearing for the coordinator's materialization claims and reusing it in the registry invites confusion. Decide before writing the header.
2. **Scope.** Whether the iOS `teardownDownloadMonitor` refactor (§3) rides along or lands as a separate commit.

## Verification

`make test`, `make analyze CONFIG=Release`, `make check-layout`, `make check-vocabulary`, `make build`, `make build-ios`.

`vibe-stress`'s cloud-scenario suite as a non-regression check only — per §3 of *What the audit missed*, it cannot prove the fix.

Real confirmation needs a `vibe-debug` run against an actual iCloud Drive or Dropbox file with the log stream up. Before: `Download progress (poll)` / `(provider)` lines interleave from two monitors on one filename. After: one.
