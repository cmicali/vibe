# Audio

The playback engine: `AudioPlayer` and its categories, `AudioTrack`, `AudioError`, `MusicalKey.h`, and the fade, schedule and splice math. Every feature beside it has its own `CLAUDE.md`: `FX/` (the DJ master-bus segment), `Loading/` (materialization, admission, the transfer registry), `Metadata/`, `Waveform/` (data only; rendering is `Vibe/WaveformUI/`), `Analysis/`, `Levels/`, `Mac/Devices/`, `Mac/Convert/` and `iOS/`.

## AudioPlayer

**`AudioPlayer.m` is the single writer of the state it publishes; each category owns one vocabulary and declares its methods in its own header** (`+State`, read-only, is declared in `AudioPlayer.h`). All of them, the platform halves `+Devices` and `+Recovery` included, share `AudioPlayerInternal.h`: the class extension and every ivar a category touches. **That shared header is the cost of every split**: a category that pushes more state into it than it takes out of `AudioPlayer.m` is not worth making.

**State is `{Stopped, Playing, Paused, Loading}`, and Loading keeps its intent live.** Loading covers the in-flight open and reports zero position and duration; play/pause during it toggles whether the opened file starts or parks (on iOS, how an interruption mid-load avoids starting the engine against an inactive session), and a seek replaces its start position. Exactly one of `isPlaying`/`isPaused`/`isStopped` is true; `isLoading` is orthogonal. An action that must order itself after already-submitted transport commands calls `getPlaybackIntent:forTrack:` once. This action-only queue barrier includes pending opens and unfinished seek/pause fades, rejects a different current row when specified, and leaves ordinary UI getters lock-only. A playing seek holds its clamped target until that seek’s ramp settles or its node is replaced; an older seek cannot clear it even when both targets are equal, so a device rebuild or conversion swap preserves the requested position rather than the outgoing audio's position.

**`PlaybackRequestCoordinator` owns the in-flight open**: identity, row, intent, slow-load state and what the delegate must be told (Foundation-only, tested). An identifier is never reused, not even across `invalidate`, so a worker blocked on a dead mount cannot consume a later open of the same path. A re-drop or replay rebinds the row in place instead of starting a second open, re-firing `didBeginLoading:` when the request is already slow. A seek is accepted on either identity, the row or the exact submitted play, because the identifier covers a seek issued before its play reached the queue and the row one issued after.

### Threading

The main mixer uses maximum render quality for sample-rate conversion; `make test-audio` checks passband gain and ultrasonic alias rejection while rendering the production graph (`Tests/CLAUDE.md`). Device negotiation is tested separately.

**Every engine mutation runs on the serial player queue; the UI getters take the `os_unfair_lock` snapshot and compute off it**, never a queue round trip. `publishPlaybackState:` is that snapshot's full-tuple publisher, and the writer model, including the three partial writers it permits, is written at that method. Two generations sort out async work: `_segmentGeneration` discards stale `scheduleSegment` completions, `_rampGeneration` cancels in-flight fades, and stop, seek, skip and device switches bump both first. Every fade is asynchronous, so the queue never sleeps.

**TRAP: `AVAudioPlayerNode` fires completions on stop and reschedule too, not only at a natural end**, so every interruption (skip, seek, device switch, a new play) bumps `_segmentGeneration` first and those completions are dropped.

**TRAP: the node's segment count is `uint32_t` while file positions are `int64_t`.** `AudioScheduleMath.h` keeps the narrowing explicit and tested rather than letting each `scheduleSegment` site cast for itself.

**TRAP: `[AVAudioPlayerNode play]` throws if the engine stopped between the `isRunning` check and the call**, and the engine stops itself on device and format changes. `startEngineAndPlayNode:` starts it if needed and absorbs the race with a retry.

**TRAP: the deferred idle stop must retire a paused node's scheduled segment first.** Pause leaves `_segmentGeneration` current, so stopping the node would fire that segment's completion as a natural end and auto-advance out of a pause. `+Engine` bumps the generation, clears the armed splice, silences and stops, then reschedules in place from the paused frame. The idle stop (Stopped or Paused, deferred ~6s, releasing the output device) is cancelled by generation in `startEngineAndPlayNode:`, which is why the pair share a category.

**TRAP: `+Fades` has two liveness mechanisms, and confusing them is the bug that file exists to keep visible.** Generation-tagged ramps belong to the current node and a newer operation preempts them. Retired fades (`_retiredFades`) belong to a node already out of the live state; membership in the array is the ramp's liveness, and a retired fade is deliberately not preemptable by a generation bump, or a second skip inside the fade window stops the node at mid-fade volume and clicks. Only stop, pause, a parked play and the failure reset silence one early.

### Crossfades and seeks

**`VibeIncomingFadeMilliseconds` (`FadeMath.h`, tested) is the one place that decides a fade's length.** `crossfadeMilliseconds` (default the 10ms declick minimum; Settings > Playback offers 500 and 2000) applies only when a play replaces an audibly playing track; first plays, the pause/seek/stop declicks, `play:atPosition:startPaused:` and an armed gapless splice force the minimum. Fades keep ~10ms per step (`VibeFadeStepsForMilliseconds`). Crossfade-length fades ride an equal-power curve so a 2s crossfade holds level at the midpoint; declick-length fades keep the log curve (`VibeFadeVolumeForFadeLength`).

`AVAudioPlayerNode` smooths volume writes internally. After a fade writes zero, teardown waits another 20 ms for that smoothing to reach silence; the envelope test covers 44.1–192 kHz. The completion still checks its generation or retired membership, so a later transport action wins during that interval.

**A track change crossfades on two independent chains, and a live node is never rerouted**, because reconnecting one reconfigures the graph and clicks. Each ordinary track gets its own `AVAudioUnitVarispeed`, minted at play submission; the outgoing node fades out on its own and is detached, varispeed and all, once silent. Bit-perfect playback creates no varispeed and connects the node directly to the mixer. It reconciles the chain again at settlement because the mode can toggle during the open; disabling it restores the ordinary chain even while Loading. A varispeed at ratio 1.0 is not sample-exact, so ordinary playback keeps it connected but bypasses it at zero pitch. Pitch writes update both rate and bypass; the render suite requires exact PCM on this path.

**A settlement may park before it is consumed.** On macOS `finishPlayOnQueueWithFile:…` parks when bit-perfect output must switch the device format while outgoing audio is still counted. `completeRetiredFadePair:` re-enters it once silent; `consumeRequest:` remains the supersession guard, preserving Loading intent and a newer play’s precedence.

**TRAP: a varispeed reconnected between stereo and mono throws `kAudioUnitErr_FormatNotSupported` and forces an engine stop.** Each varispeed is connected exactly once, for one format. The single re-connect, in device-switch recovery, rewires the same varispeed for the same format with the engine stopped.

**A playing seek declicks without touching the graph**: `seekToPosition:` fades the node down, reschedules it in place inside the fade-out completion, then fades up, so the `[node stop]` and the new segment's start both land at silence. A paused seek just reschedules the silent node.

### Prefetch and gapless

**`prefetchTrack:` on every track start pre-opens the likely next track, and the next `play:` of that path consumes the parked `AVAudioFile`.** The request state is `AudioPrefetchRules.h`: a different-path prefetch requested while an open is in flight is retained and suppressed, resumed by that open's success and dropped by its failure, abandonment, a newer play (same-path rebind included) or a later prefetch; its identity also drops every late callback. There is no acknowledgement handshake with the loading side, because the foreground rule is derived inside the coordinator (`Loading/CLAUDE.md`), so nothing waits on "the successor's claim exists".

**At play submission an unrelated prefetch is cancelled before the foreground open starts**, so its transfer cannot compete with the file the user chose. A same-path prefetch stays alive: its handle run and the playback run ride one path claim, each opens its own handle when the claim is Ready, whichever succeeds first consumes the play request, and the winner retires the loser's park state so the current track cannot become its own prefetched successor. A later consecutive row with the same path is a fresh `prefetchTrack:` and stays valid.

**Gapless arms a private second handle.** With the crossfade at the minimum and the parked file matching the current connection format (`GaplessSpliceMath.h`), `maybeArmGaplessOnQueue` opens a second `AVAudioFile` and schedules it as a second segment on the current node. It must be private: `AVAudioFile` has one stateful read position and the node pre-reads scheduled files, so the armed segment may never share the instance a `play:` would consume. The current segment's completion then means "boundary passed": `promoteGaplessOnQueue` republishes the queued file as current in place (no stop, no fade, no graph mutation, `_segmentGeneration` deliberately not bumped) with a zero-or-negative `_segmentStartFrame`, since `playerTime.sampleTime` is monotonic across queued segments, and fires `didAutoAdvanceFromTrack:toTrack:` so the controller advances the playlist without `play:`. **A track's end fires exactly one of `didFinishPlaying:` or the auto-advance callback, never both.**

On macOS, bit-perfect output adds one gapless gate: the next file must want the current device format (`outputNeedsSwitchOnQueueForFile:unknownNeedsSwitch:`), since a splice cannot switch it. A boundary needing a switch goes through settlement (`Mac/Devices/CLAUDE.md`).

**ALWAYS: every `[node stop]` of the current node drops its queued segment**, so every such site (seek, idle-stop repark, device switch, the retire in `playOnQueue:`, stop, the failure resets) clears the armed flag first (`setGaplessQueuedOnQueue:`), and the sites that reschedule the same file re-arm afterwards. When the playlist's next changes under an armed splice, `prefetchOnQueue:` unqueues by rescheduling the current remainder through the seek path, the only click-free way to drop a queued segment; raising the crossfade setting mid-track unqueues the same way, lowering it re-arms. An unfinished seek already removes the splice. Otherwise the internal seek enters directly on the player queue, so its old position cannot arrive after a newer user seek or output rebuild.

**A main-thread action snapshots its track at dispatch**, because a promote can land between the action and its queue block: `seekToPosition:` and `finishCurrentTrack` drop the request if the boundary advanced it.

CoreAudio honors LAME/iTunes gapless metadata, so tagged MP3/AAC and all lossless files splice seamlessly; an untagged MP3's encoder padding is the one gap this cannot remove. `isGaplessArmed` surfaces the armed state to `dump_state`.

### Settlement identity

**A settlement for a superseded submission is never delivered, and it is matched by submitted-play identity, never by track** (root `CLAUDE.md`: a same-row replay is the same `AudioTrack` and the same URL). `didStartPlaying:` and the play-path errors are dropped on main by `submittedPlayIsCurrent:`, checked inside the delivery block because what matters is whether a newer play existed when the callback ran. The comparison is `PlaybackDeliveryRules.h` (tested): `VibePlaybackDeliveryIsCurrent`, and `VibePlaybackSubmissionStateIsUnchanged` for the media-services reset, where zero is a valid initial snapshot because a reset is not a play, and whose completion may re-park the playlist only if no play arrived in between. The coordinator's own rule ("a superseded open's result is never consumed") cannot cover this: once a result is dispatched to main, nothing can retract it.

**Resume and seek-restart failures use the same identity even though their errors carry no URL.** They belong to the sounding graph, whose `_activeSubmittedPlayIdentifier` survives gapless promotion; a same-row replay could otherwise make the shell accept the old generic error and tear down the newer play's state.

**TRAP: the counter is `_nextSubmittedPlayIdentifier`, which only increments, never `_lastSubmittedPlayIdentifier`**, the pre-Loading handoff cleared to 0 as soon as its play reaches Loading. Comparing against that one reports every settlement as superseded, delivers nothing, and strands whatever the shells release on settlement.

### Opening a file

**Files open off-queue against an abandon deadline, so a cloud placeholder cannot wedge playback**; a slow open surfaces Loading instead. `AudioFileOpenTimeoutMath.h` (`Loading/`) owns the monotonic deadline: a 60s no-progress baseline both platforms share, extended (never shortened) to 60s past each positive raw movement. `AudioLoadingConfiguration.openTimeouts` is snapshotted when the underlying open starts, so a mid-open configuration change cannot move its deadline. A last-valid-position cache preserves the playhead when the engine stops itself before recovery can read it.

**Progress is matched by the underlying open identifier, never by path or submitted-play identity.** A same-row replay changes submission identity but keeps the same `PlaybackRequestCoordinator.identifier`, transfer, monitor baseline and timeout snapshot; a later retry of that URL gets a new identifier, so a callback retained by the previous monitor cannot extend it. `didBeginLoading:` carries the open identifier to both shells, its main-thread delivery guarded separately by submitted-play identity, and the coordinator reissues it for the current submission when a slow request is replayed. The player accepts `noteOpenProgressForOpenRequestIdentifier:` only while both the pending request and the playback-open slot carry the identifier. The claim, admission and transfer-publication machinery underneath is `Loading/CLAUDE.md`'s.

**`stop` (File > Close) unloads outright and fires no transport or track-end callback** (root `CLAUDE.md`): it supersedes any in-flight open so a Loading track never starts and fades a playing node to silence before teardown; the caller owns the UI reset.

### Live output levels

**`levelsEnabled` installs the demand-driven tap in `Levels/`**; `copyBandLevels:count:sequence:` reads the latest coherent snapshot without the player queue or an allocation. `outputAudioActive` is the shell-facing liveness fact: a current playing node or a counted retired fade is active, Loading intent alone is not.

**TRAP: `applyLevelTapOnQueue` is the only tap reconciliation point, `installMasterBusOnQueue` the only rebuild edge, and `dropEngineBoundStateOnQueue` abandons rather than removes a tap bound to a defunct engine.** The ownership, callback, FFT, publication, demand and `--silent` contracts are `Levels/CLAUDE.md`'s.

### Error text

**`VibeAudioError*` descriptions are for logs and are never localized.** The one line a screen shows is `VibeStatusForPlayError` (`AudioErrorRules.h`, tested), mapping `VibeAudioErrorCode` to a `STR_ERROR_*` string; it lives beside the enum because both screens render the same wording.
