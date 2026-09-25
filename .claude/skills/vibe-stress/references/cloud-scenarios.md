# The cloud scenario suite's rules, registry, XFAIL contract, and the `block_main` instrument. Read when writing or debugging a scenario, or deciding whether a cloud check belongs here or in `make test`.

The registry is `SCENARIOS` at the bottom of `scripts/cloud-scenarios.py`; each entry is `(id, function, expected_fail)`.

## Five rules, each of which first failed in a plausible-looking way

- **Use trace sequence for ordering.** `dump_cloud_trace` records every transfer's requested / started / completed / cancelled with its role and a sequence number. Elapsed time only bounds waiting, except in the deadline and deferred-fallback scenarios, where the fake trace clock or the runner's monotonic clock plus a tolerance asserts the timing policy itself.
- **Match the role that was actually recorded.** Metadata work is split into `metadata-priority` and `metadata-scan`; a family assertion for `metadata` must match both, while an ordering assertion names the exact lane. An exact-only `metadata` matcher silently made the old sweep checks vacuous.
- **Choose the trace edge that states the claim.** `requested` is emitted before the fake's capacity queue and proves the app admitted work; `started` proves a provider slot ran it. A capacity-one test that looks only at `started` hides an illegally admitted request behind the foreground transfer it is supposed to exclude.
- **One clean launch per scenario.** The launch opens the corpus to establish the sandbox grant, which also starts work, so the runner requires `quiesce.settled`, then clears caches, before arming the fake. `set_fake_cloud` preserves the completed/cancelled tally across a re-arm, the metadata cache persists to disk, and a hold left over from a previous scenario is indistinguishable from one this scenario lost.
- **`capacity=1 uniform` unless a scenario says otherwise.** Unlimited capacity means nothing ever waits on anything, and the 0.5x–2x per-file spread fights every ordering assertion.

## Settings the runner owns

The runner snapshots `pauseAtTrackEnd` once before the loop. Each scenario normalizes it off through the running controller (re-parking the successor) and restores the baseline before quitting; an outer cleanup launches a fresh process and restores it again at exit, even if a scenario killed its process. Successor/prefetch scenarios therefore cannot inherit Settings > Playback = Pause, and the suite does not leave the preference changed.

## Live deadline cases test wiring; XCTest tests the budget

`set_audio_loading timeout-baseline=... timeout-silence=...` applies one immutable diagnostic snapshot to the coordinator, player and metadata loader, verified by `dump_audio_loading.aligned`. Minute-long waits become seconds without restating production's 60-second constants, which stay pinned in XCTest. S8b advances by less than 1% per tick so only the monitor's raw movement feed, not its UI-coalesced delivery, can keep the open alive.

## Keep deterministic machinery in `make test`; reserve this suite for live composition

XCTest runs the real `AudioTrackMetadataLoader` control plane and materialization coordinator behind injected cache-read, file-parse and provider-operation boundaries, plus `DownloadProgressMonitor`, the materializer (its real local `NSFileCoordinator` wrapper, allocated-size polling, injected iCloud query and File Provider publication/KVO lifecycles), loading-policy arithmetic, the transfer registry and `VibeFakeCloud`'s option/trace accounting. `make check-cloud-scenarios` (`tests/test_cloud_scenarios.py`, run by `make test`) pins the runner's role-family matching, request/transfer span assembly, exact ordering, corpus bounds and `--only` validation, so a broken oracle cannot make the live run green.

The live scenarios own what host-less tests cannot honestly reproduce: the shell's deferral and routing, AppDelegate append, playback settlement through the real player and its file handle, row-loading projection, and the real queues composed with the provider seam. Provider-mediated coordination and cancellation, `SF_DATALESS`, OS discovery, cross-process progress publication and named-provider behavior still require a real-provider run; the fake cannot certify them.

## The registry and the XFAIL contract

25 scenarios, S1–S21 with a/b/c variants; clean report `PASS=24 XFAIL=1`. Expected-fail scenarios are **run and reported, never skipped**, so the day one starts passing is visible. Only the scenario's explicit `ExpectedGap` evidence becomes `XFAIL`; setup failures and every other assertion remain `FAIL`.

**S9** is the XFAIL: a provider that withholds `SF_DATALESS` is indistinguishable from a local file at the admission seam, so the local-file exemption can admit its metadata read during foreground playback. Unlimited fake capacity keeps that request visible instead of hiding it in a provider queue; a real-provider run still decides whether a named provider has this shape.

**S20** checks that row loading follows live provider transfers. A gapless-specific wedge under that label is deliberately absent: basename-based live instrumentation cannot distinguish gapless from prefetch, so that purpose is pinned in XCTest.

## `block_main <seconds> [<verb> ...]`

The instrument that makes main-thread ordering testable at all. The channel's own intake is on the main queue, so while main is held nothing can even be *enqueued* — a callback the app dispatched to main from a worker always wins the race against a command sent afterwards. Blocking and then running the next verb *without yielding* is the only way to imitate a click handler: a main-thread turn already underway when the callback arrived. **`open` will not do as the chained verb** — the open funnel is asynchronous, so its play lands in a later turn, behind the callback. `play_index` is synchronous and does.
