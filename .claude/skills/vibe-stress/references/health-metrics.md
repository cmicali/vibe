# The `dump_health` metrics: what each counts, which are trustworthy at rest, and the settled footprint investigation. Read when a `resource` failure fires or before adding a metric or limit.

## The `pending` counters

App-owned work that must unwind at rest; `quiesce` polls until all are zero and names the holdout:

| Counter | Owner |
| --- | --- |
| `metadataHolders`, `metadataWaiters` | `MetadataParseCoordinator`'s claim table; waiter tables are per key |
| `openResultsBuffered` | `OpenRequestCoordinator` results held for in-order delivery |
| `openBurstQueued` | `OpenBurstCoalescer`'s quiet-period queue |
| `retiredFades` | `AudioPlayer`'s voices still fading out after a track change, seek or stop |
| `cloudParsesPending`, `cloudLaneHeld` | the metadata cloud lane |
| `priorityRecordsPending` | priority metadata records |
| `datalessProbesInFlight`, `handleOpensInFlight` | attempt gauges, not containers: probe accounting starts before the scheduler/worker handoff and survives detachment from its claim; handle-open accounting starts before dispatch. A failed quiesce can therefore tell stuck classification from downloading or opening |

**The two cloud counters are not scored for growth, and must not be.** A sweep of a cloud folder legitimately holds dozens of pending parses and the lane is held for the whole of every foreground open, so a headroom over a min-of-three baseline would never fire or fire constantly. They are covered where they mean something: `quiesce` refuses to settle until both are zero, and `check_consistency` tests the *conditions*, not the magnitudes. `dump_cloud_health` reports both on both platforms — the only way to see them on iOS, which has no `dump_health` and no `quiesce`.

`outputDropouts` (macOS) counts the IO cycles the hosted output unit wrote as silence because the render returned an error; it is cumulative, so any growth is a finding and a soak holds it at zero. `renderCycles`, `renderMeanMicros` and `renderMaxMicros` (macOS) are the unit's callback cost over the cycles it rendered, cumulative too: diff the cycles and the mean across a run, and read the max against the device's buffer period, since a max that approaches it is the dropout before it happens. `retiredFades` is reported beside `hostedUnits` because they fail apart: a voice that never reports its end strands a fade entry while the unit count stays flat, and a unit count that moves by more than the varispeed (present in ordinary mode, absent in bit-perfect) means a unit was hosted without its predecessor being disposed. Both come from one `dispatch_sync` onto the player queue.

The counters are nearly impossible to catch nonzero from outside: a local parse is over in microseconds. `MetadataParseCoordinatorTests.testDebugPendingCountsTrackHoldersAndWaiters` pins the holder/waiter accounting deterministically, because a counter that silently always reads zero looks exactly like a clean run.

## `quiesce`

Runs `closeFile:` — stop, drop the prefetch handle, cancel the waveform load and deferred scan, clear the playlist, reset the UI — polls until the pending counters unwind, then calls `malloc_zone_pressure_relief` and reports what it released as `pressureRelief.releasedBytes` (~42 KB on a fresh launch, 0 after a heavy run: it does not deliver what a resting-footprint cap would need). The driver takes its at-rest series this way every `--quiesce-every` batches and scores it against tighter limits.

## What is stable at rest, measured over loading-profile runs

- **Dead stable**: views 47, windows 1, hosted units (the varispeed and, once FX is enabled, the ten FX units; hosted once), every pending counter 0.
- **Breathe with the loader pool**: threads 14–26, fds 45–70.
- **Layers are bistable**, ~101 and ~350–356, moving in *both* directions within one run on the same binary, unmoved by row count (0 to 2208), window width (400 to 3000), `quiesce`, or the pitch panel and playlist toggles (4 and 1 layers). Nothing app-level selects it; it is AppKit's own glass and hosting-view machinery. The limit is sized to clear that step (+320): a +80 limit against a min-of-first-three baseline fires whenever a run starts low, and a real layer leak is unbounded and clears +320 too.
- **Resting footprint does not settle**: 47 to 335 MB, the same seed resting at 298 MB in one run and 51 MB in another. It is a gross-leak backstop (+256 MB), not a signal. `mallocLiveBytes` (+64 MB) is the sensitive metric: 37–52 MB across the same decodes that swung the footprint from 94 to 365 MB.

## Settled: the ~270 MB resting "retention" is not a leak

Symptom: a run resting flat at 55–61 MB steps to ~330 MB and stays there across a `quiesce`, with no op window reproducing it standalone. **It is the allocator's and the VM's high-water mark, not retained objects.** Two-command repro on big files:

| | footprint | live heap |
| --- | --- | --- |
| fresh launch | 94 MB | 38 MB |
| two `file_cache` decodes of ~200 MB MP3s | 203 MB | 52 MB |
| after `quiesce` | **365 MB** | **37 MB** |

`heap` agrees from outside (18.8 MB live across 134k nodes at a 203 MB footprint). `vmmap --summary` puts the dirty pages in `MALLOC_LARGE (empty)` (freed large blocks), `VM_ALLOCATE` and `IOSurface`, the malloc zones 54% fragmented and CoreAudio's `caulk` zones at 100%, where pressure relief cannot reach. It is not the big decodes either: the same swing reproduces on an artwork corpus of few-MB files, the footprint flipping both directions between adjacent 25-op samples with `mallocLiveBytes` flat at 26–42 MB, and a freshly launched, quiesced app with nothing loaded already reads 321 MB against an 11 MB live heap. `vmmap`: 107.9 MB total dirty against a 365 MB `phys_footprint`.

So the footprint oracle counts only when `mallocLiveBytes` agrees; a real gross leak moves both. What remains open is narrower: whether the large transient buffers that fragment the zone are worth pooling, which needs `MallocStackLogging=1` plus `malloc_history` to attribute before anyone refactors.

## The metric audit

Every process metric is checked against an external tool, and they agree: `threads` against `ps -M`, `machPorts` against `lsmp` (±1, the sampling itself), `footprintBytes` against `footprint`, `residentBytes` against `ps rss`, `mallocLiveBytes` against `heap`'s all-zones total, `views` against a node count of `dump_view_tree`, `fileDescriptors` against `lsof`.

`fileDescriptors` is the one that was wrong: `proc_pidinfo(PROC_PIDLISTFDS)` with a null buffer answers the descriptor *table* size, which grows with peak concurrency and never shrinks — 420 reported against 41 actual — so a burst of parallel opens read as a permanent leak while a real fd leak was indistinguishable from a concurrency spike. `VibeOpenFileDescriptorCount` fetches the listing for real, which is what let the limits come down to 64 in flight and 8 at rest. An fd leak is a live hazard here: a failed `AVAudioFile` open against an empty file strands its descriptor.

`heap Vibe` gives per-class live instance counts from outside the process, the attribution `dump_health`'s process-level numbers deliberately leave out.


**Sanitizers need their own live-allocation counter.** A standalone 30,000-open `AVAudioFile` probe reported 139 GB in the ASan zone's `size_in_use` against 0.5 MB from `__sanitizer_get_current_allocated_bytes`: the zone counts freed allocations too. TSan has the opposite problem — its zone reports zero against 2.4 MB actually live. The health oracle uses the sanitizer allocator API for either zone, keeping the ordinary zone counters for CoreAudio's separate allocators. Otherwise ASan reports fictitious leaks and TSan hides real ones.
