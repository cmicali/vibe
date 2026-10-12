# Cloud scenarios

The cloud scenario suite's rules, registry and XFAIL contract, and the `block_main` instrument. Read when writing or debugging a scenario, or deciding whether a cloud check belongs here or in `make test`.

The registry is `SCENARIOS` at the bottom of `scripts/cloud-scenarios.py`. Each entry is `(id, function, expected_fail)`.

## Five rules

- **Use trace sequence for ordering.** `dump_cloud_trace` records every transfer's requested, started, completed and cancelled events with its role and a sequence number. Elapsed time only bounds waiting. The exceptions are the deadline and deferred-fallback scenarios, where a clock plus a tolerance asserts the timing policy itself.
- **Match the role that was actually recorded.** Metadata work is split into `metadata-priority` and `metadata-scan`. A family assertion for `metadata` must match both, and an ordering assertion names the exact lane. An exact-only `metadata` matcher makes the sweep checks vacuous.
- **Choose the trace edge that states the claim.** `requested` is emitted before the fake's capacity queue and proves the app admitted work. `started` proves a provider slot ran it. A capacity-one test that looks only at `started` hides an illegally admitted request behind the foreground transfer it should exclude.
- **One clean launch per scenario.** The launch opens the corpus to establish the sandbox grant, which also starts work. So the runner requires `quiesce.settled`, then clears caches, before arming the fake. `set_fake_cloud` keeps its tally across a re-arm, the metadata cache persists to disk, and a leftover hold is indistinguishable from one this scenario lost.
- **`capacity=1 uniform` unless a scenario says otherwise.** At unlimited capacity nothing waits on anything, and the per-file duration spread fights every ordering assertion.

## Settings the runner owns

The runner snapshots `pauseAtTrackEnd` before the loop. Each scenario turns it off through the running controller and restores the baseline before quitting. An outer cleanup restores it again at exit, even if a scenario killed its process.

## Live deadline cases test wiring; XCTest tests the budget

`set_audio_loading timeout-baseline=... timeout-silence=...` applies one diagnostic snapshot to the coordinator, player and metadata loader, verified by `dump_audio_loading.aligned`. Minute-long waits become seconds without restating production's 60-second constants, which stay pinned in XCTest. S8b advances by less than 1% per tick, so only the monitor's raw movement feed, not its UI-coalesced delivery, can keep the open alive.

## Keep deterministic machinery in `make test`

XCTest runs the real `AudioTrackMetadataLoader` control plane and materialization coordinator behind injected cache-read, file-parse and provider boundaries. It also covers `DownloadProgressMonitor`, the materializer, loading-policy arithmetic, the transfer registry and `VibeFakeCloud`'s accounting. `make check-cloud-scenarios` (`tests/test_cloud_scenarios.py`, run by `make test`) pins the runner's role matching, span assembly, ordering, corpus bounds and `--only` validation, so a broken oracle cannot make the live run green.

The live scenarios own what host-less tests cannot reproduce: the shell's deferral and routing, AppDelegate append, playback settlement through the real player and its file handle, row-loading projection, and the real queues composed with the provider seam. Provider-mediated coordination and cancellation, `SF_DATALESS`, OS discovery, cross-process progress and named-provider behavior still need a real-provider run.

## The registry and the XFAIL contract

24 scenarios, S1–S21 with a/b/c variants and no S9. A clean report is `PASS=24`. Expected-fail scenarios are **run and reported, never skipped**, so the day one starts passing is visible. Only the scenario's explicit `ExpectedGap` evidence becomes `XFAIL`. Setup failures and every other assertion stay `FAIL`.

**S9 stays unused.** It staged a provider that withholds `SF_DATALESS`, which no measured provider does. Run `set_dataless_diag` against a new provider before bringing it back.

**S20** checks that row loading follows live provider transfers. Gapless-specific wedging is pinned in XCTest instead, since basename-based live instrumentation cannot tell gapless from prefetch.

## `block_main <seconds> [<verb> ...]`

The instrument that makes main-thread ordering testable. The channel's intake is on the main queue, so while main is held nothing can be enqueued. A callback the app dispatched to main from a worker always wins against a command sent afterwards. Blocking and then running the next verb without yielding imitates a click handler: a main-thread turn already underway when the callback arrived. **`open` will not do as the chained verb**, since the open funnel is asynchronous and its play lands in a later turn. `play_index` is synchronous and does.
