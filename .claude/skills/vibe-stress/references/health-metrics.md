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

The counters are nearly impossible to catch nonzero from outside, since a local parse is over in microseconds. `MetadataParseCoordinatorTests.testDebugPendingCountsTrackHoldersAndWaiters` pins the holder and waiter accounting, because a counter that always reads zero looks exactly like a clean run.

## Render counters (macOS)

- `outputDropouts` counts IO cycles the output unit wrote as silence because the render returned an error. It is cumulative, so any growth is a finding.
- `renderRefusals` counts renders the pipeline turned away because another was still inside: a callback stuck past its bounded stop while the next output unit began. It is cumulative, and `check_consistency` reports any (`graph.no_render_refused`).
- `renderCycles`, `renderMeanMicros` and `renderMaxMicros` are the callback's cost. Diff the cycles and the mean across a run. Read the max against the device's buffer period, since a max near it is the dropout before it happens.
- `clear_render_counters` zeroes all five, for a per-phase reading.
- `retiredFades` (under `pending`) and `hostedUnits` (under `app`) fail apart. A voice that never reports its end strands a fade while the unit count stays flat. A unit count that moves means a unit was hosted without its predecessor being disposed.

## `quiesce`

Runs `closeFile:`: stop, drop the prefetch handle, cancel the waveform load and deferred scan, clear the playlist, reset the UI. It polls until the pending counters unwind, then calls `malloc_zone_pressure_relief` and reports `pressureRelief.releasedBytes`. That is mostly 0 after a heavy run, so it cannot bring a resting footprint down. The driver takes its at-rest series this way every `--quiesce-every` batches.

## What is stable at rest

- **Stable**: windows 1, hosted units (the varispeed and, once FX is enabled, the FX units, hosted once), every pending counter 0. Views hold steady until the Settings window has existed. Closing it only hides it, and its views join the resting count for the rest of the run, so a resting-views failure starts with `dump_view_tree`'s window list.
- **Breathe with the loader pool**: threads and fds.
- **Layers are bistable at the chrome** (AppKit's glass and hosting views), moving both ways within one run. The Sonic Cirrus style adds two layers per bar, up to 1,024 bars, so about 2,048 layers is a legitimate resting state for a wide window. The limit is +2400. Views stay the sensitive UI metric.
- **The resting footprint does not settle.** It is a gross-leak backstop (+256 MB), not a signal. `mallocLiveBytes` (+64 MB) is the sensitive metric.

## Why the footprint is not a leak signal

A run can step from about 60 MB to over 300 MB of footprint and stay there across a `quiesce`, with the live heap flat. **It is the allocator's and the VM's high-water mark, not retained objects.** Two `file_cache` decodes of large MP3s followed by `quiesce` reproduce it: the footprint climbs while `mallocLiveBytes` returns to its starting value. `vmmap --summary` puts the dirty pages in `MALLOC_LARGE (empty)`, `VM_ALLOCATE`, `IOSurface` and CoreAudio's zones, where pressure relief cannot reach. So the footprint oracle counts only when `mallocLiveBytes` agrees. A real gross leak moves both. Whether the large transient buffers are worth pooling is open; attribute them with `MallocStackLogging=1` and `malloc_history` first.

## The metric audit

Every process metric agrees with an external tool: `threads` with `ps -M`, `machPorts` with `lsmp` (±1), `footprintBytes` with `footprint`, `residentBytes` with `ps rss`, `mallocLiveBytes` with `heap`'s all-zones total, `views` with a node count of `dump_view_tree`, `fileDescriptors` with `lsof`. `heap Vibe` gives per-class live instance counts from outside the process.

`fileDescriptors` must fetch the listing (`VibeOpenFileDescriptorCount`). `proc_pidinfo(PROC_PIDLISTFDS)` with a null buffer answers the descriptor table's size, which grows with peak concurrency and never shrinks, so a burst of parallel opens would read as a permanent leak.

**Sanitizers need their own live-allocation counter.** The ASan zone's `size_in_use` counts freed allocations too, and the TSan zone reports zero. The health oracle uses the sanitizer allocator API (`__sanitizer_get_current_allocated_bytes`) for either zone, and keeps the ordinary zone counters for CoreAudio's separate allocators. Otherwise ASan reports fictitious leaks and TSan hides real ones.
