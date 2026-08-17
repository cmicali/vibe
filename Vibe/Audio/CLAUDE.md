# Audio

Playback engine, FX, devices, and pointers to the four sub-directories with their own files: **`Metadata/`** (tags, cache, scan, artwork), **`Waveform/`** (waveform data), **`Analysis/`** (BPM and key), **`Mac/Convert/`** (FLAC encoding). Rendering is elsewhere again — `Vibe/WaveformUI/`.

## AudioPlayer

Drives an `AVAudioEngine` with a fresh `AVAudioPlayerNode` per track. State machine `{Stopped, Playing, Paused, Loading}`; `Loading` covers the in-flight file open and reports position and duration of zero. Its pending intent stays live: play/pause toggles whether the opened file starts or parks, seek replaces its start position, and `isPlaying`/`isPaused` report that intent so every transport surface stays honest.

`PlaybackRequestCoordinator` owns that in-flight open — identity, row, intent, slow-load state, and what the delegate must be told. Foundation-only and tested. Three rules:

- **an identifier is never reused**, not even across `invalidate`, so a worker still blocked on a dead mount cannot consume a later open for the same path;
- **a re-drop rebinds the row in place** rather than starting a second open, and re-fires `didBeginLoading:` when the slow-load call had already gone out against a row the playlist has since replaced;
- **a seek is accepted on either identity** — the row it aimed at, or the exact submitted play — because the identifier covers a seek issued before its play reached the queue and the row covers one issued after.

### Where the code lives

`AudioPlayer.m` holds the open/play machine and is the single writer of the state it publishes. Around it, a category per vocabulary:

| Category | Owns |
| --- | --- |
| `+State` | Everything a caller off the player queue may ask: the four predicates, duration, channel count, playhead, armed-splice flag. Read-only, and declared in `AudioPlayer.h` rather than its own header. |
| `+Gapless` | The parked prefetch handle and the splice that renders the next track without a gap. |
| `+Fades` | Every volume ramp, and the two liveness mechanisms below. |
| `+Seek` | Seeking, playing and paused. |
| `+Graph` | Node/varispeed wiring helpers. |
| `+Engine` | When the `AVAudioEngine` runs at all: starting it to play a node, and the deferred idle stop. A pair, because starting playback is what cancels the pending stop. |
| `+Devices` (`Mac/Devices/`) | Device resolution, switching, config-change recovery, parking or falling back when a device vanishes. |
| `+Recovery` (`iOS/`) | The iOS engine restart and media-services-reset rebuild. |

They all share `AudioPlayerInternal.h` — the class extension and every ivar a category touches. **That shared header is the cost of every split**: a category that would push more state into it than it takes out of `AudioPlayer.m` is not worth making.

### Threading

Every engine mutation runs on a serial `dispatch_queue` (`com.vibe.audioplayer`). The UI-facing getters — `position`, `duration`, `isPlaying` — read under an `os_unfair_lock` and never block. Two generation counters sort out async work: `_segmentGeneration` discards stale `scheduleSegment` completions, and `_rampGeneration` cancels in-flight volume fades, which stop, seek, skip and device switches all bump first. Every fade is asynchronous, so the queue never sleeps.

**TRAP: `AVAudioPlayerNode` fires completions on stop and reschedule too, not only at a natural end** — so every interruption (skip, seek, device switch, a new play) bumps `_segmentGeneration` first and those completions are dropped.

**TRAP: `[AVAudioPlayerNode play]` throws if the engine stopped between the `isRunning` check and the call**, and the engine stops itself on device and format changes. `startEngineAndPlayNode:` starts it if needed and absorbs the race with a retry.

**TRAP: the deferred idle stop must retire a paused node's scheduled segment first.** Pause deliberately leaves `_segmentGeneration` current, so stopping the node would fire that segment's completion as a natural track end and auto-advance out of a pause. `+Engine` bumps the generation, clears the armed splice, silences and stops, then reschedules in place from the paused frame.

**TRAP: `+Fades` has two liveness mechanisms and confusing them is the bug that file exists to keep visible.** Generation-tagged ramps belong to the *current* node and a newer operation preempts them. Registered retired fades (`_retiredFades`) belong to a node already pulled out of the live state — membership in the array *is* the ramp's liveness, and a retired fade is deliberately **not** preemptable by an ordinary generation bump, or a second skip inside the fade window stops the node at mid-fade volume and clicks. Only stop, pause and the failure reset silence one early.

### Crossfades and seeks

Track-change crossfade length is `crossfadeMilliseconds` (default the 10ms declick minimum; Settings > Playback offers 500 and 2000). It applies only when a play replaces an *audibly playing* track. Three cases force the minimum, and `VibeIncomingFadeMilliseconds` (`FadeMath.h`, tested) is the single place that decides: first plays and the pause/seek/stop declicks, `play:atPosition:startPaused:` (the convert swap, which replaces a track with its own audio), and an armed gapless splice.

Longer fades keep ~10ms per step (`VibeFadeStepsForMilliseconds`) so the curve stays smooth. Crossfade-length fades ride an equal-power curve — complementary sides sum to ~unity power, so a 2s crossfade holds level instead of dipping at the midpoint — while declick-length fades keep the log curve; `VibeFadeVolumeForFadeLength` picks per length.

A track change crossfades on **two independent chains**: each track gets its own `AVAudioUnitVarispeed`, minted in `playOnQueue:`. The outgoing node's live connection is never rerouted — it fades out on its own varispeed and is detached, varispeed and all, once silent, while the incoming node fades in from silence on the new one. Reconnecting a live node reconfigures the graph and clicks.

**TRAP: a varispeed reconnected between stereo and mono throws `kAudioUnitErr_FormatNotSupported` and forces an engine stop.** Each varispeed is connected exactly once, for one format. The single re-connect, in device-switch recovery, rewires the same varispeed for the same format with the engine stopped.

A seek while playing declicks *without reconnecting the graph at all*: `seekToPosition:` fades the current node down, reschedules it in place at the new frame inside the fade-out completion, then fades back up, so both the `[node stop]` and the new segment's start land at silence. A paused seek simply reschedules the silent node.

### Prefetch, idle and gapless

The controller calls `prefetchTrack:` on every track start to pre-open the likely next track; the next `play:` of that path consumes the parked `AVAudioFile`. The engine stops when playback goes idle (Stopped or Paused), releasing the output device, deferred ~6s and cancelled by generation in `startEngineAndPlayNode:`.

At play submission, an unrelated old prefetch is cancelled before the foreground open starts, so its provider transfer cannot compete with the file the user chose. A same-path prefetch stays alive and races the interactive open; whichever succeeds first consumes the play request, and the winner retires the loser's park state so the now-current track cannot become its own prefetched successor. A later consecutive row with the same path is a fresh `prefetchTrack:` and remains valid.

With the crossfade at the minimum and the prefetched file matching the current connection format (`GaplessSpliceMath.h`), the prefetch also opens a **private second handle** and schedules it as a second segment on the current node (`maybeArmGaplessOnQueue`). The private handle matters: `AVAudioFile` has one stateful read position and the node pre-reads scheduled files, so the armed segment must never share the parked instance a `play:` would consume.

The current segment's completion then means "boundary passed", not "playback stopped": `promoteGaplessOnQueue` republishes the queued file as current *in place* — no node stop, no fade, no graph mutation, `_segmentGeneration` deliberately not bumped — with a zero-or-negative `_segmentStartFrame` (`playerTime.sampleTime` is monotonic across queued segments), and fires `didAutoAdvanceFromTrack:toTrack:` so the controller advances the playlist *without* calling `play:`. **A track's end fires exactly one of `didFinishPlaying:` or the auto-advance callback, never both.**

**ALWAYS: every `[node stop]` of the current node drops its queued segment**, so every such site — seek, idle-stop repark, device switch, the retire in `playOnQueue:`, stop, the failure resets — clears the armed flag first (`setGaplessQueuedOnQueue:`), and the sites that reschedule the same file re-arm afterwards. When the playlist's *next* changes under an armed splice, `prefetchOnQueue:` unqueues by rescheduling the current remainder through the seek path — the only click-free way to drop a queued segment. Raising the crossfade setting mid-track unqueues the same way; lowering it re-arms.

Because a promote can land between a main-thread action and its queue block, intent is snapshotted: `seekToPosition:` and `finishCurrentTrack` capture the current track at dispatch and drop the request if the boundary advanced it.

CoreAudio honors LAME/iTunes gapless metadata, so tagged MP3/AAC and all lossless files splice seamlessly; an untagged MP3's baked-in encoder padding is the one gap this cannot remove. `isGaplessArmed` (lock-free) surfaces the armed state to `dump_state`.

### Robustness

A last-valid-position cache preserves the playhead when the engine stops itself before recovery can read it. A `playPause` during Loading toggles whether the in-flight open lands playing or parked (`_pendingStartPaused`) rather than being dropped — on iOS that is how an interruption mid-load avoids starting the engine against an inactive session. Files open off-queue with a timeout, so an undownloaded cloud placeholder cannot wedge playback; a slow open surfaces Loading instead.

Playback opens use a fixed-slot user-initiated scheduler; prefetch and the private gapless handle use a separate utility scheduler, and waveform work has two of its own. Pending blocks stay in explicitly bounded app memory and are not dispatched until a slot is free, and every admission failure is delivered on the caller's nominated failure queue — never inline, so a rejection decided while the caller sits on a serial queue cannot re-enter it. Within each purpose, the coordinator keeps one standardized-path claim registered until an uncancellable `AVAudioFile` call really returns. A timeout or superseding request cancels its delivery and any still-abortable materialization without forgetting the underlying claim, so repeated retries cannot multiply stranded workers.

**Cancelling is the only way to stop waiting, and it is deliberately not separable from marking the run abandoned.** `finishClaim:` tells "this run produced nothing because nobody was waiting" from "this file would not open" by that mark alone: a waiter cleared without it would let the first be delivered to a later same-path waiter as a nil file with no error, which every caller reads as the file failing. A completion therefore always carries a file or a reason there is none.

Admission has its own failure: the interactive lane parks one request for up to five seconds, and the background lane parks two for up to ten. If every worker remains blocked, `VibeAudioFileOpenErrorAdmissionExhausted` says the later file never began opening; it is not reported as that file's ordinary timeout. A true never-returning OS call cannot be killed in-process and keeps its fixed slot until process restart, but the scheduler prevents that unavoidable loss from becoming unbounded worker or queue growth.

`stop` (File > Close) unloads outright: it supersedes any in-flight open so a Loading track never starts, fades a playing node to silence before teardown, and **fires no delegate callback** — the caller owns the UI reset, and nothing may drive auto-advance from it.

### Error text

`VibeAudioError*` descriptions are for logs and are never localized. The one line a screen shows is `VibeStatusForPlayError` (`AudioErrorRules.h`, header-only and tested), which maps `VibeAudioErrorCode` to a `STR_ERROR_*` string. It lives here, beside the enum, because both screens render the same wording.

## AudioFX

`AudioPlayer` owns `AudioFX` (readonly `fx`): the low-kill high-pass with its Q key and W double-cutoff boost, and the send-returns — E a long reverb wash, R and T BPM-synced ping-pong delays on 1/8- and 1/16-note taps, fed by the controller through `delayTapBPM`.

**The whole segment is optional.** `initWithDeviceUID:name:enableFX:delegate:`'s `enableFX` decides for the player's lifetime whether `AudioFX` exists at all. Without it `fx` is nil, no FX node is ever created or attached, and `installMasterBusOnQueue` wires the mixer straight to the output — the same helper the iOS media-services-reset rebuild calls, so both configurations rebuild identically. macOS passes `AppSettings.audioFXEnabled` (read once at launch, so it applies on relaunch; with it off the FX menu is omitted and `TransportKeyMonitor` passes Q/W/E/R/T through). iOS passes a hard `NO`.

`AudioFX` stores plain on-off state per effect; telling a tap from a hold is `TransportKeyMonitor`'s job. **One coupling is enforced here so every path gets it: clearing `lowKillEnabled` also clears `lowKillBoostActive`** — the boost modifies that filter, so a latched W must not outlive the low kill and hold the cutoff up while the low kill reads off.

The numbers those toggles resolve to — the three-way low-kill cutoff, the ping-pong tap and lane times with their no-tempo fallback, the lane feedback and the swell target — are `AudioFXMath.h`, header-only and tested, since the class owns an `AVAudioEngine` graph and cannot be reached from the host-less suite.

The class owns the whole master-bus graph segment between `mainMixerNode` and `outputNode`. `installInEngine:` wires it once on the player queue during the async init; the `AudioFX` object is created synchronously, so intent set before the engine exists is applied at install. Every toggle is click-free — cutoff sweeps and gate fades on the player queue with generation-counter preemption. Its `.m` records the hard-won AVFAudio traps (MatrixReverb's stale header ranges, dropped pre-attach mixer writes, EQ bypass clicks).

## The platform halves

`Mac/Devices/` is the CoreAudio HAL output-device layer — `AudioDeviceManager` and `AudioPlayer+Devices` — and has its own `CLAUDE.md`. `iOS/` is the `AVAudioSession` lifecycle and the engine-recovery category that answers its verdicts, likewise. Both are reached from the player through `AudioPlayerInternal.h`'s shared private surface, and neither target compiles the other's.
