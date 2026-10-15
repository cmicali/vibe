# The `dump_health` metrics

What each metric counts, which are trustworthy at rest, and why the footprint is not a leak signal. Read when a `resource` or `stalled` failure fires or before adding a metric or limit.

## The `pending` counters

App-owned work that must unwind at rest. `quiesce` polls until all are zero and names the holdout:

| Counter | Owner |
| --- | --- |
| `metadataHolders`, `metadataWaiters` | `MetadataParseCoordinator`'s claim table; waiter tables are per key |
| `openResultsBuffered` | `OpenRequestCoordinator` results held for in-order delivery |
| `openBurstQueued` | `OpenBurstCoalescer`'s quiet-period queue |
| `retiredFades` | `AudioPlayer`'s voices still fading out after a track change, seek or stop |
| `cloudParsesPending`, `cloudLaneHeld` | the metadata cloud lane |
| `priorityRecordsPending` | priority metadata records |
| `datalessProbesInFlight`, `handleOpensInFlight` | attempt gauges, not containers. Probe accounting starts before the worker handoff and survives detachment from its claim. Handle-open accounting starts before dispatch. A failed quiesce can therefore tell stuck classification from downloading or opening |

**The two cloud counters are not scored for growth, and must not be.** A cloud folder's sweep legitimately holds dozens of pending parses, and the lane is held for every foreground open. `quiesce` refuses to settle until both are zero, and `check_consistency` tests the conditions, not the magnitudes. `dump_cloud_health` reports both on both platforms. It is the only way to see them on iOS, which has no `dump_health` and no `quiesce`.

`MetadataParseCoordinatorTests.testDebugPendingCountsTrackHoldersAndWaiters` checks that live holders and waiters produce nonzero counts.

## Render counters (macOS)

- `outputDropouts` counts IO cycles the output unit wrote as silence because the render returned an error. It is cumulative, so any growth is a finding.
- `renderRefusals` counts renders the pipeline turned away because another was still inside: a callback stuck past its bounded stop while the next output unit began. It is cumulative, and `check_consistency` reports any (`graph.no_render_refused`).
- `renderCycles`, `renderMeanMicros` and `renderMaxMicros` are the callback's cost. Diff the cycles and the mean across a run. Read the max against the device's buffer period, since a max near it is the dropout before it happens.
- `clear_render_counters` zeroes all five, for a per-phase reading.
- `retiredFades` (under `pending`) and `hostedUnits` (under `app`) fail apart. A voice that never reports its end strands a fade while the unit count stays flat. The unit count covers hosted FX units. It excludes the output unit and the custom varispeed. Enabling FX can raise it.

## The progress oracle

A capability that stops being attempted grows nothing, hangs nothing and breaks no rule, so only progress can show it. Each batch takes one sample from the `dump_state` and `dump_health` it already reads (`progress_sample`):

- **Demand**: `playlist.resolvedRows` below `count`, or `pending.cloudParsesPending` above 0. A failed parse lands metadata too, so a broken file is not demand.
- **Progress**: one signature of `requestsReady + requestsFailed + handleOpensCompleted`, the resolved rows, the row count and the pending cloud parses. Any change is progress, including a replaced playlist.
- **Gates**: `materialization.foregroundTransferActive`, `pending.cloudLaneHeld`, `app.playerLoading`, and any running transfer (`interactiveRunning` or `backgroundRunning`). A gate legitimately parks the sweep. A running transfer is work still attempted, however slow, such as the fake provider's stuck tail.

**Four samples with demand, no gate and one signature fail as `stalled`.** Four samples span three batches, at least 75 ops. The sweep's deferral is two seconds, so a healthy sweep moves the signature well inside it. The first sample of the window is its baseline, as the health oracle's first samples are. A gate that never lifts is not scored here. `cloud.hold_outlives_playback` catches the hold outliving playback, and `quiesce` catches anything held at rest.

**The equalizer and playback probe** runs after each `quiesce`, in place of the reopen. It plays `equalizer_reference`: the first corpus file by path whose name does not suggest silence (`SILENT_NAMES`). It seeks to 40% of the track, past a quiet intro, and takes `dump_state` and `dump_equalizer` twice, 0.8 s apart. It is scored only when both samples show the reference playing, not buffering, levels enabled and a running display link, since a running poller means the bars are visible and sourced. Then the position must advance, `audio.publications` must rise, and one band must be nonzero. `--silent` zeroes after the meter, so the bars stay live under it. The run prints how many probes were scored. A hidden playlist or an occluded window scores none.

## The resting slope

The absolute resting limits admit a slow leak. 64 MB of live heap over an hour-long run is a leak that never fails. So the resting series is also fitted by least squares against sample index (`resting_slope_findings`):

| Metric | Rate per resting sample | Floor |
| --- | --- | --- |
| `mallocLiveBytes` | 64 MB / 400 ≈ 164 KB | 8 MB |
| `views` | 40 / 400 = 0.1 | 5 |
| `machPorts` | 300 / 400 = 0.75 | 37.5 |

**The rate is the resting limit divided by a long run's resting samples.** A long run is 100,000 ops. At 25 ops per batch and a resting sample every 10 batches, that is 400 samples. A leak at the rate would just reach the absolute limit by the end. **The floor is an eighth of the limit.** The fitted growth across the series must clear it, so allocator noise in a short run is not a slope. **Both halves of the series must rise faster than the rate as well.** One bounded step, such as the pitch panel's views, lands in one half only. Scoring starts at eight resting samples. `--ignore-metric` stands a metric down here too.

## `quiesce`

Runs `closeFile:`: stop, drop the prefetch handle, cancel the waveform load and deferred scan, clear the playlist, reset the UI. It polls until the pending counters unwind, then calls `malloc_zone_pressure_relief` and reports `pressureRelief.releasedBytes`. Pressure relief may release nothing. The driver takes its at-rest series this way every `--quiesce-every` batches.

## What is stable at rest

- **Stable**: windows 1, hosted FX units after initialization, every pending counter 0. Views hold steady until the Settings window has existed. Closing it only hides it, and its views join the resting count for the rest of the run, so a resting-views failure starts with `dump_view_tree`'s window list.
- **Breathe with the loader pool**: threads and fds.
- **Layers are bistable at the chrome** (AppKit's glass and hosting views), moving both ways within one run. The Sonic Cirrus style adds two layers per bar, with the count determined by window width. A wide window can retain thousands of layers. The limit is +2400. Views stay the sensitive UI metric.
- **The resting footprint does not settle.** It is a gross-leak backstop (+256 MB), not a signal. `mallocLiveBytes` (+64 MB) is the sensitive metric.

## Why the footprint is not a leak signal

Footprint includes allocator and VM overhead. It is not a count of retained objects. The driver scores footprint growth only when live heap growth also exceeds its limit. Use `vmmap --summary`, `MallocStackLogging=1` and `malloc_history` to investigate retained pages and allocation sites. This oracle can miss growth outside the measured live heap.

## Cross-checking metrics

Compare the counters with external tools: `threads` with `ps -M`, `machPorts` with `lsmp` (±1), `footprintBytes` with `footprint`, `residentBytes` with `ps rss`, `mallocLiveBytes` with `heap`'s all-zones total, `views` with a node count of `dump_view_tree`, `fileDescriptors` with `lsof`. `heap Vibe` gives per-class live instance counts from outside the process.

`fileDescriptors` must fetch the listing (`VibeOpenFileDescriptorCount`). `proc_pidinfo(PROC_PIDLISTFDS)` with a null buffer answers the descriptor table's size, which grows with peak concurrency and never shrinks, so a burst of parallel opens would read as a permanent leak.

**Sanitizers need their own live-allocation counter.** The ASan zone's `size_in_use` counts freed allocations too, and the TSan zone reports zero. The health oracle uses the sanitizer allocator API (`__sanitizer_get_current_allocated_bytes`) for either zone, and keeps the ordinary zone counters for CoreAudio's separate allocators. Otherwise ASan reports fictitious leaks and TSan hides real ones.
