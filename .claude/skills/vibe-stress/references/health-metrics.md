# The `dump_health` metrics

What each metric counts, which are trustworthy at rest, and why the footprint is not a leak signal. Read when a `resource` failure fires or before adding a metric or limit.

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
