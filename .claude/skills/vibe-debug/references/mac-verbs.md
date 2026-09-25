# macOS `--debug-cmd` verbs

Every macOS channel verb with its arguments and reply schema, plus the verbs whose contract needs more than a line (conversion and undo, cloud staging, row reorder, themes). Read when a verb's arguments or reply keys are needed; the channel's own unknown-command reply is the authoritative list, and `SKILL.md` carries the rules and traps. `$V` is `<app>/Contents/MacOS/Vibe`.

## Inspection

```bash
"$V" --debug-cmd dump_state          # {player, currentTrack, playlist, ui, window, settings} — playlist includes resolvedRows; ui.displayState (track|loading|empty|launch-grace|error) is the settled UI, player.state the pending intent
"$V" --debug-cmd dump_debug_info     # {bytes, text} — Settings > Advanced > Save Debug Info's report without its save panel (settings, devices with formats and latency, bit-perfect report, the audio-path stages, this run's log); the snapshot is read on main, the text and the fresh sections build off it; the fresh hardware, player and audio-path sections each get a 2s deadline in turn (about 6s worst case) and report cached/unavailable on timeout; 30s client timeout
"$V" --debug-cmd block_player 8      # acknowledges immediately, holds only the player queue for 0<seconds<=10; use dump_debug_info to verify bounded export and stall logging
"$V" --debug-cmd dump_view_tree      # {windows: [{class, frame, visible, key, contentView: {…, subviews}}]} — AppKit bottom-left frames
"$V" --debug-cmd dump_menu           # {menu: [{title, id, key, action, enabled, state, items}]} — live enabled/checkmark from the real validateMenuItem pass
"$V" --debug-cmd dump_now_playing    # {playbackState, hasInfo, title, artist, duration, elapsed, rate, hasArtwork} — the system Now Playing publish; always hasInfo: 0 under --no-audio-hw
"$V" --debug-cmd dump_stats          # {filesOpened, foldersOpened, secondsPlayed} — AppStats lifetime counters, live
"$V" --debug-cmd dump_equalizer      # producer/renderer snapshot: references/equalizer-counters.md
"$V" --debug-cmd dump_audio_path     # {stages: [{stage, present, …}]} — the render chain from the source file to the output device, one entry per stage (source, decode, bus, varispeed, fx, meter, output, device): rates, sample formats, channels, whether each is in the render, the decoder's conversion (algorithm, quality, mixed, resampled), the varispeed's engagement and latency, the FX stages' activity and the dry path's `latencySeconds`, the output's `running` and `idleStopPending` (running with nothing to play, the deferred idle stop ahead), its `presentationLatency` (the device's own reckoning) and `bufferLatency` (the IO cycle) under the output unit — under the debug pump the output stage carries `carrier: "pump"` and `automatic` instead — and the device's `channels` (what the unit drives on it; `physicalChannels` is the stream's width) and `latencySeconds`. What Settings > Advanced's Audio group lists, raw
"$V" --debug-cmd dump_health         # {process: {footprintBytes, residentBytes, residentPeakBytes, mallocLiveBytes, mallocReservedBytes, threads, fileDescriptors, machPorts, uptimeSeconds}, ui: {windows, visibleWindows, views, layers, trackingAreas — the counts cover visible windows only}, app: {playlistCount, tableRows, currentIndex, playerLoading, gaplessArmed, drainPolling, hostedUnits, outputDropouts, renderRefusals, renderCycles, renderMeanMicros, renderMaxMicros, canUndo, canRedo, …}, materialization: {…}, pending: {metadataHolders, metadataWaiters, openResultsBuffered, openBurstQueued, retiredFades (voices still fading out), datalessProbesInFlight, handleOpensInFlight, cloudParsesPending, cloudLaneHeld, priorityRecordsPending, …}} — DIFF across a run, never read in isolation. mallocLiveBytes, not footprintBytes, is the leak signal: the footprint carries the allocator's and the VM's high-water mark, the live heap does not
"$V" --debug-cmd quiesce             # {ok, settled, waitedSeconds, pending, pressureRelief: {releasedBytes, mallocLiveBytes, mallocReservedBytes, reservedFreedBytes}} — closes the file, polls until every pending-work counter unwinds (15s deadline), asks every zone to return free pages. Sample dump_health straight after for a reading at rest. settled also needs the player stopped and not loading, so settled:false with every pending counter at zero is the player, not a counter. Check releasedBytes before trusting a resting footprint: after a heavy run it is 0, the pages stay dirty and the footprint keeps its high-water mark (vmmap: MALLOC_LARGE (empty))
"$V" --debug-cmd check_consistency   # {ok, checked, violations: [{id, detail}]} — the app's consistency rules against live state: playlist index, selection range and player-track identity, table rows, finite and clamped position/pitch, fader-vs-player agreement, UI tick rate, a hosted-unit bound (at most 16; growth is dump_health's diff to catch), no render refusals, the equalizer, cloud and Now Playing families, metadata arriving for the playing track, tag-over-analysis precedence, header labels and settled artwork ownership. Re-check after a settle before believing a violation: gapless promotion reaches the player before its playlist callback reaches main, and rendered state lags its input by a runloop turn
"$V" --debug-cmd dump_metadata_progress # {total, parsed, attempted} — attempted counts rows a parse has landed on, parsed those with real metadata, so a failed parse is not mistaken for one still waiting
"$V" --debug-cmd dump_timing         # {loads: [...]} — phase timings of recent waveform decodes, newest first: readSeconds, chunkSeconds, bpmSeconds/keySeconds (Append + Finish), otherSeconds, realtimeFactor. Every load, from play as well as file_cache; clear_timing empties it
"$V" --debug-cmd dump_last_playlist  # {exists, rows, currentIndex} — the container mirror (Application Support/<bundle id>/LastPlaylist.m3u) read back through the app. Written only at quit, so a fresh session reports the LAST quit's. A relaunch with the setting on restores it parked (state "paused", currentTime "0:00") and publishes no Now Playing until the first real play
"$V" --debug-cmd dump_theme ["id-or-name"] # {ok, activeTheme?, id?, theme} — no arg: the current WORKING record, divergence included; with one: that theme's stored record, the exportable form
"$V" --debug-cmd dump_screenshot -   # PNG on stdout, JSON reply on stderr: references/screenshots-and-logs.md
```

## Transport, FX and window

Action replies are a compact `{ok, state, index, count, position, pitch, lowKill, reverbSend, delaySend, shortDelaySend, playlistShown, pitchPanelShown}`, read synchronously, so they lag async pipeline work — confirm with `dump_state`.

```bash
"$V" --debug-cmd play_pause          # also: next, previous, skip_forward[_more|_most], skip_back[_more|_most], toggle_size, toggle_pitch_panel
"$V" --debug-cmd play_index 3        # plays row n synchronously (block_main chains it; `open` lands its play a turn later)
"$V" --debug-cmd seek 120            # seconds
"$V" --debug-cmd set_pitch -4.5      # fader (clamps), player and time labels together
"$V" --debug-cmd toggle_low_kill     # FX; also low_kill_boost_on/_off, reverb_send_on/_off, delay_send_on/_off, short_delay_send_on/_off (the _on/_off pairs mirror the held W/E/R/T keys). These bypass audioFXEnabled by design; use key_down/key_up for the shipping gates
"$V" --debug-cmd set_window_width 900  # {ok, frame, bodyWidth} — body width in points (pitch panel excluded); optional height and seconds (0..10): `set_window_width 1400 650 2` resizes at 60 Hz through public frame changes and replies on completion. Exercises layout, not AppKit's live-resize event lifecycle
"$V" --debug-cmd set_loading 0.42    # {ok, fraction} for a number, {ok, loading: "off"} for off, {ok, fraction: -1} for indeterminate — the waveform loading indicator directly. Draws the control with no play behind it; for a REAL Loading state use set_fake_cloud
"$V" --debug-cmd set_appearance dark # {ok, windowAppearance} — light|dark|system, applied live
"$V" --debug-cmd click_menu menu_show_pitch  # {ok, clicked, action} — by identifier (preferred) or exact title; refuses a disabled item
```

## Input injection

Raw input is for explicit gesture tests on an isolated test desktop, never unattended stress. Coordinates and the tracking-loop and right-click traps are in `../SKILL.md`. Prefer `stress.py --gesture-test`, which asserts the resulting pitch. The underlying channel command only queues the gesture:

```bash
"$V" --debug-cmd gesture_test pitch-reset isolated-desktop  # also pitch-drag
```

```bash
"$V" --debug-cmd click 75 122        # {ok, posted, hitView, windowKey} — down+up at a window point; `click x y right`, `click x y left 2` = double-click
"$V" --debug-cmd drag 728 219 728 299   # whole left-button gesture in ONE command (down, 12 dragged steps, up); optional [steps]
"$V" --debug-cmd mouse_move 400 200  # plain move; add left|right for a lone dragged event
"$V" --debug-cmd mouse_down 75 122   # primitives (default left; also right); mouse_up likewise
"$V" --debug-cmd key p               # keyDown+keyUp through the real dispatch path; mods: `key p cmd shift`
"$V" --debug-cmd key_down w          # one edge — the held W/E/R/T momentary FX; key_up releases. Keys: a-z, 0-9, space, tab, return, esc, delete, forward_delete, up/down/left/right
"$V" --debug-cmd key delete repeat   # `repeat` rides the modifier list but sets isARepeat — the only way to exercise a repeat guard (Remove from Playlist takes ONE row per press; the momentary FX keys ignore repeats). `delete` is Backspace, `forward_delete` its twin: different characters reaching different code
```

`set_controls_hover on|off` calls the player's actual hover enter/exit handlers without moving the system pointer. It exercises the button and gradient fade, not AppKit tracking-area delivery. Wait 0.3 seconds for the fade, then inspect `dump_view_tree`'s `id: "buttonGradient"` node (`hidden` omitted when false, `alpha` when 1). A real cursor crossing or a settings refresh resumes the actual hover state.

## Files, playlist and caches

`open` and `file_cache` read the path directly, so the sandbox may deny a file the app was never granted; `open -a "$APP" <file>` grants, so prefer paths opened this session.

```bash
"$V" --debug-cmd open ~/Music/album  # {ok, opening} — file or dir through the direct expand/filter/replace path, bypassing the AppDelegate funnel; poll dump_state
"$V" --debug-cmd append ~/Music/track.flac  # {ok, appending} — a common verb, defined once for both shells; on the mac it enters the real deliberate-open funnel (`openDroppedURLs:…appending:YES`); on iOS it is the folder session's addURLs:. Poll dump_state
"$V" --debug-cmd file_drag_hover 520 275   # {ok, posted, x, y, well} — synthetic external-file drag-over at a window point, through the real FileDropDelegate. Direct delegate calls, with no mouse events or native drag session. well = replace|add|none
"$V" --debug-cmd file_drag_drop 520 275 ~/Music/track.wav  # {ok, dropping, x, y, well} — completes the drag: delivers the drop at that point (none→replace), tears the drag-over UI down. ABSOLUTE path; same sandbox caveat as open
"$V" --debug-cmd file_drag_end       # {ok, posted} — the drag left without a drop
"$V" --debug-cmd select_rows 0 2      # {ok, selectedRows} — actual table selection without focus; all/none also accepted; ignores rows beyond the current list
"$V" --debug-cmd select_rows current 50  # resolves the playing row at execution time, optionally with numbered rows
"$V" --debug-cmd remove_selected      # shell removal action over that selection, including transport and undo
"$V" --debug-cmd save_playlist ~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/set.m3u  # {ok, path, tracks} — File > Save Playlist… without its panel: extended M3U, entries relative to the file's folder, noted in Open Recent. {"error": "playlist is empty"} on an empty list. The path must be writable by the sandboxed app (the container's tmp is; the host can read it back)
"$V" --debug-cmd file_cache song.flac        # {ok, path, wasCached, bpm, key, camelot, timing} — decode + cache one file's waveform, UI untouched; waits up to 60s. timing is that decode's phase breakdown, absent on a hit. Replies only once the entry is on disk, so a relaunch is guaranteed the hit
"$V" --debug-cmd file_clear_cache song.flac  # {ok, path, wasPresent} — evict one file's waveform entry (keyed by size and mtime). clear then file_cache = a forced cold decode with freshly detected bpm
"$V" --debug-cmd clear_caches        # {ok, cleared} — blocks until both PINCaches are genuinely empty, {"error": "cache clear timed out after 15s"} past that under a 20s client timeout; the waveform clear queues behind an in-flight load, so allow 15s after feeding a long file
"$V" --debug-cmd clear_disk_caches   # {ok, cleared} — CLI-process deletion of the PINDiskCache dirs, ONLY with the app NOT running. scripts/clear-caches.sh picks the right one of the two and keeps shell rm out of the container
```

### Row reorder: `reorder_*`

A synthetic playlist row-reorder drag: the real `NSTableViewDataSource` choreography (writer + token per row, willBegin) with a stand-in `NSDraggingInfo` and no native drag session. The session **survives across channel commands on purpose** — begin, mutate the playlist with any other verb, then update or drop — which stages the mid-drag races (replace-all rejection, a converted-away dragged row dropping out) no pointer can. AppKit's half — the drag threshold, which rows a gesture picks up, the insertion line, autoscroll — is not exercised and stays a manual pointer check.

```bash
"$V" --debug-cmd reorder_begin 1 3   # {ok, rows}
"$V" --debug-cmd reorder_update 2    # {ok, slot, operation} — validateDrop at an insertion slot (0..count): "move" or "none". Sweep every slot to pin the insertion-line decision
"$V" --debug-cmd reorder_drop 0      # {ok, slot, dropped} — validate then accept, then end the session; dropped:false = refused (AppKit slides a refused slot back). Poll dump_state for the order
"$V" --debug-cmd reorder_cancel      # {ok, cancelled} — end without a drop through the same ended call a real cancel takes
```

## Cloud and loading

`set_fake_cloud`'s behavior and the prefetch trap are in `references/test-audio.md`.

```bash
"$V" --debug-cmd set_fake_cloud 4 100  # {installed, percent, baseSeconds, capacity, uniform, progressMode, materialized, completed, cancelled, maxConcurrency, metadataOverlapTransfers, foregroundContentionStarts, …} — grammar: set_fake_cloud <seconds> [<percent>] [capacity=N] [uniform] [progress=none|linear|sparse|stall] [unflagged] [sticky] [fail=<basename>]. Capacity defaults to 1 (0 = unlimited); `set_fake_cloud 0` uninstalls. foregroundContentionStarts counts metadata starts while a playback or prefetch transfer is running. fail=<basename> makes that file's transfers run to term and report failure — the provider-error shape that spends the metadata retry budget
"$V" --debug-cmd dump_cloud_trace    # {stats, events} — the fake provider's admission trace: one entry per transfer event (requested / started with queuedMs / completed / cancelled, plus overlap and contention) with sequence, ms since install, the caller's role (playback, prefetch, metadata-priority, metadata-scan, or unlabeled) and the file. requested is the app/provider boundary, started is slot admission. Ordering assertions read this, never elapsed time; clear_cloud_trace empties it
"$V" --debug-cmd dump_cloud_health   # {cloudParsesPending, cloudLaneHeld, priorityLane:{pending,yieldedUnderHold,inFlight,liveTokens,held}, scanLane:{pending,delayed,inFlight,liveTokens,stageOneFinished}, materialization:{claims,waiters,interactiveRunning,backgroundRunning,interactivePending,backgroundPending,foregroundTransferActive,handleRuns,datalessProbesInFlight,handleOpensInFlight,…}} — both platforms. Every live count, pending list and hold belongs empty once a sweep has settled; stageOneFinished is history, not residue
"$V" --debug-cmd dump_row_loading    # {transfers: [{file, progress}], loadingRows: [{index, file, progress}], playlistCount} — the row loading bar's guarantee, both halves: live provider transfers and every row that would be marked. loadingRows is bounded by lane capacity (~3), every row in it must appear in transfers, progress is -1 while indeterminate, both empty once local or settled
"$V" --debug-cmd dump_audio_loading  # {aligned, materialization, player, metadata} — loading snapshots at each consumer; aligned should be true after set_audio_loading
"$V" --debug-cmd set_audio_loading defaults  # {ok, configuration, appliesTo} — resets every loading knob, optionally followed by key=value in the same command; partial key=value: background, local-parses, prefetch-depth; diagnostic-only interactive, interactive-pending, background-pending, interactive-grace, background-grace, retries, timeout-baseline, timeout-silence. Applies to new admissions, never by cancelling live work
"$V" --debug-cmd hang_open track.wav # {ok, hangingBasename, hungOpens} — <basename>|release: opens of that basename block in the debug opener wrapper just before the AudioFileHandle open (stage 2 of a cloud open, the uncancellable one set_fake_cloud cannot stage); release lets every held open through
"$V" --debug-cmd set_dataless_diag on  # {ok} — record st_flags and lane routing per directory against a REAL provider; dump_dataless_diag reports it. Records nothing while the fake probe is installed
"$V" --debug-cmd burst 200 7         # {ok, jumps, playlist} — <jumps> [<seed>]: seeded random play_index jumps (seed defaults to 1), the first synchronously before the reply and the rest one per main-queue turn, capped at 5000. Replies at once and keeps firing, so the NEXT command lands mid-burst — the in-process race the channel's ~80ms cadence cannot stage
"$V" --debug-cmd block_main 0.5 play_index 3  # {ok, blockedSeconds, then, thenReply} — hold the main thread, then run another shared verb WITHOUT yielding: a worker callback arriving while a user action is underway, which two separate commands cannot stage since intake is on main. Bounded to 5s; cannot chain itself; a chained verb that replies asynchronously (file_cache) is the only reply, so thenReply is absent
"$V" --debug-cmd block_main_deep 1.2 600 [alternating]  # {ok, blockedSeconds, depth, alternating} — hold main under <depth> real frames (alternating call sites defeat frame collapsing) to verify beta stall stacks reach main; depth up to 4000, seconds up to 5. The main-thread stall watcher runs only under VIBE_VERBOSE_LOGGING=1, whatever the audio flags
```

## Conversion and undo

`convert_to_flac` runs the menu's funnel on the **current track** — load the file first — and replies with the settled result: where the FLAC landed and which row points at it, or `row: -1` if the playlist was replaced mid-encode. It converts **in place beside the source**: point it at a working copy, never at `Assets/test_audio_files/`. `dump_state`'s `ui.converting` and `ui.convertSweep` (the encode fraction driving the waveform brush-through) move while it runs. A source opened as a single file exercises the related-item sandbox rung; the log names the rung it fell through to.

```bash
"$V" --debug-cmd convert_to_flac [keep|delete] [omit-trash-url]  # {ok, output, row, source, sourceDeleted, sourceRemains} — waits up to 120s
"$V" --debug-cmd undo                # {ok, undid, committed, reason?, canUndo, canRedo} — replies once the file moves settle; {"error": "nothing to undo"}
"$V" --debug-cmd redo                # {ok, redid, committed, reason?, canUndo, canRedo}
```

- `keep|delete` writes Convert > Delete Original before converting, as the menu item does, and **leaves it written** — restore it if a later test expects the default (off); `dump_state.settings.deleteOriginalAfterConvert` reports it. Assert from the reply: `sourceDeleted` is what disposal did, `sourceRemains` stats the original after the Trash move settled. `ls ~/.Trash` from a terminal trips the same TCC denial as reading the container.
- `undo`/`redo` drive the window's NSUndoManager, whose only registered action is Convert to FLAC: undo restores the trashed original, returns its row, trashes the FLAC; redo reverses that from the Trash without re-encoding. `committed:false` carries one of `restore_failed`, `replacement_location_unknown`, `replacement_unavailable`, `already_at_target`. Read the live stack from `ui.canUndo`/`ui.canRedo`. `click_menu menu_edit_undo`/`menu_edit_redo` exercise the menu path (validation retitles them "Undo Convert to FLAC") but have no settled signal, so prefer the verbs when a later step depends on the moves.
- `omit-trash-url` is a one-shot fault (requires `delete`, working copy only): the source goes to the Trash but its location is withheld from the controller. The refused undo must leave the converted row in place, and the inverse it registers must settle as already satisfied:

```bash
out=$("$V" --debug-cmd script - <<'EOS'
convert_to_flac delete omit-trash-url
undo
redo
dump_state
EOS
)
printf '%s\n' "$out" | jq -s -e '
  length == 4 and
  .[0].sourceDeleted == true and
  .[1].committed == false and .[1].reason == "replacement_location_unknown" and
  .[2].committed == false and .[2].reason == "already_at_target" and
  .[3].currentTrack.url == .[0].output
' >/dev/null
```

## Themes and settings writes

All but `set_analysis` are app-side verbs, applied at once; `set_analysis` is a CLI-process prefs write that the running app's next decode reads.

```bash
"$V" --debug-cmd set_theme technical # {ok, activeTheme} — by stable id or display name (case-insensitive); requests the ThemeApply effect. dump_state.settings.activeTheme/themeCount assert it
"$V" --debug-cmd import_theme '{"name":"T","window":{"cornerRadius":0}}'  # {ok, imported, name, themeCount} — inline JSON (starts with "{") or a path the APP can read (container tmp) to a .json or a theme ZIP (theme.json + custom album-art image); the Settings importer's sanitize-and-store path, powerbox-free. The only scripted route to a font change
"$V" --debug-cmd remove_theme "fuzz-3" # {ok, removed, activeTheme, themeCount} — a USER theme (a built-in is refused); removing the active one falls back to vibe. A harness that imports themes must remove them, or they persist in the user's real store
"$V" --debug-cmd set_key_display musical colors  # {ok, keyNotation, keyColors} — <camelot|musical> <colors|plain>; app-side, since the key display lives on the current THEME object. Persists and repaints immediately
"$V" --debug-cmd set_analysis bpm off  # {ok, analyzeBPM, analyzeKey} — <bpm|key> <on|off>; the next waveform decode reads it, no relaunch — the A/B for analyzer cost
"$V" --debug-cmd set_folder_art off  # {ok, folderArt} — <on|off>, Settings > Files album-art dropdown: writes AND re-resolves the loaded playlist's folder art (header, dock, rows). Needs a RUNNING app
"$V" --debug-cmd set_pause_at_track_end off  # {ok, pauseAtTrackEnd} — writes and requests the EndOfTrack live effect, which re-parks or drops the armed successor at once
"$V" --debug-cmd set_reopen_playlist on  # {ok, reopenLastPlaylist} — writes and requests ReopenLastPlaylist. Off deletes the container mirror at once; the mirror is written only at QUIT (the quit verb, hence launch.sh, runs applicationWillTerminate:)
"$V" --debug-cmd set_declick off  # {ok, declick} — writes Settings > Audio > Declick and requests the Declick live effect, no rebuild: on (the default) every transport edge ramps over the 10 ms declick, off it cuts, leaving every sample untouched; a crossfade longer than the declick fades either way, and under bit-perfect output the crossfade is held at the declick. dump_state.settings.declick is the stored choice, player.declick what the player holds. The loopback verifier turns it off around its captures, which compare from the first frame
```

The View > Theme menu items carry `view_theme_<identifier>` ids (`view_theme_vibe`, `view_theme_technical`, `view_theme_<uuid>` for user themes; the tail is `menu_edit_themes`), so they can be clicked without matching display names. They are built by the submenu's delegate, so **run `dump_menu` first in each app run** — until something populates that submenu, `click_menu` cannot find them. `dump_state.settings.activeTheme` uses those same identifiers, never the menu's display text: the two were split so a display name can never reach the store. The waveform style lives in the theme editor (`settings_click Style <identifier>`), not the menu bar.

## Measurement

```bash
"$V" --debug-cmd work_tally begin    # both platforms: a fresh counting window over the debug signposts
"$V" --debug-cmd work_tally end      # {active, label, elapsedMs, work:{name:{count,totalMs,maxMs}}}. Nested intervals overlap — do not add waveform_update to its waveform_target/path children. App-side time only; presentation hitches are Instruments' job
"$V" --debug-cmd measure_resize 600 1080 240  # one out-and-back width sweep at 60 Hz, 30–600 frames; restores the frame, returns process CPU seconds, synchronous layout mean/p95/max ms, signpost counts, with a 0.6s settle tail. Pause playback and hold style, track and visibility fixed across before/after; programmatic, not an OS border drag
```

## Analyzers, lifecycle and scripts

```bash
"$V" --debug-cmd scan_bpm - < file   # {ok, bpm} — fresh decode+analyze IN THE CLI PROCESS, no app needed; prefer scripts/scan-bpm.sh (references/test-audio.md)
"$V" --debug-cmd scan_key - < file   # {ok, key, camelot, index} — same contract; prefer scan-key.sh. Ignores tags: currentTrack.key/.camelot in dump_state show the tag-over-analysis answer
"$V" --debug-cmd quit                # {ok, quitting} — the normal terminate path, the only exit that runs applicationWillTerminate: (AppStats flush, last-playlist mirror). Prefer to pkill
"$V" --debug-cmd sleep 0.5           # client-side pause (above 0, up to 600s); the app's main thread never sleeps
"$V" --debug-cmd script - <<'EOS'    # one verb per line; rules in SKILL.md
seek 30
sleep 0.5
key space
EOS
.claude/skills/vibe-debug/scripts/run-script.sh [--assert '<jq predicate>'] <output-dir> [file]   # saves replies.jsonl and numbered PNGs; predicate checks the complete reply array after commands succeed (SKILL.md)
```

## Output device

`set_output_device <uid|name|system> [<bit-perfect on|off> [<exclusive on|off>]]` selects the output now, through the same path as the Output menu. Address it by UID: a HAL device id is transient (the same hardware came back as 108, 126, 111 across three replugs), and UID is what the per-device modes are keyed by. A name is accepted as a fallback in the same order the app's own restore uses, so a human can type `"Audient iD4"`; `system` is System Output. An unknown device answers an error listing the known names; UIDs are in `dump_debug_info`'s hardware section. The reply is `{ok, deviceId, uid, name, selectionPending, modesRequested}`, and the selection settles asynchronously — poll `dump_state.player.outputDeviceId` and `outputDeviceUID` (the bound device — on System Output the current default's, with `requestedOutputDeviceId` at -1) and `dump_audio_path`'s device stage. The optional modes are *requested*, applied on main once the selection clears, because their setters write the saved device's mode and would name the device being left; confirm with `dump_state.player.bitPerfect`.

## Bit-perfect output

`set_saved_output_device <uid> <name>` writes only the next-launch preference, without changing the current binding. Use a missing UID/name followed by relaunch to verify that confirmed absence disables bit-perfect, persists System Output and restores pitch; restore the original preference afterward.

**Bit-perfect and exclusive output are remembered per device UID**, and `set_bit_perfect` — like the Settings switch — writes the *saved* device's mode. The verb refuses while an explicit device selection is pending, matching the disabled Settings switches. So select the device, wait for its settlement, and only then toggle; on System Output the verb is a no-op that answers off. A device left with the mode on gets it back whenever it is selected again, including after an unplug, so a script that must leave no trace turns it off *while that device is selected*. `defaults read <bundle id> AudioPlayer.outputModesByDeviceUID` is the whole store: an absent key means no device has a mode on.

`dump_state.player.bitPerfect` is the report the header's lock and Settings > Audio read — `{enabled, status, sampleRate, bitsPerChannel, isFloat, softwareVolume, balance, eligibleDevice, hasTrack, rateExact, formatConfirmed, channelsMatch, depthOK, muted, hogWanted, exclusive, sourceLossless}` — plus the wanted flags (`bitPerfectWanted`, `exclusiveOutputWanted`), the bound, requested and pending device fields (`boundOutputDeviceId`, `requestedOutputDeviceId`, `pendingDeviceUID`, `pendingDeviceModelUID`, `pendingDeviceName`, `savedDeviceLookupInFlight`) and the queue-confined ownership `{hoggedDeviceId (only when the build enables exclusive output, `VIBE_ENABLE_EXCLUSIVE_OUTPUT`), restoreOwedToDeviceId, preparedDeviceId, varispeedPresent, voice, busRate, outputUnitRate, outputUnitRunning, outputRunning, outputDropouts, presentationLatency}`. `scripts/hogfollow.swift <deviceID> [engine|hal] [--make-default]` (`swiftc -O` it) compares the two output carriers: its `engine` mode shows AVAudioEngine's default output unit following a hogged default, its `hal` mode an explicitly hosted HALOutput unit that does not ([Devices/CLAUDE.md](../../../../Vibe/Audio/Mac/Devices/CLAUDE.md)): it binds the chosen carrier to the device, hogs it, and prints the system default, the unit’s device and its liveness every 250 ms through the take, the re-bind, a first and second start (with and without `prepare`) and the release. Run it against the device that IS the default to see it move. `status` is one of `off`, `idle`, `active`, `rateUnsupported`, `switchFailed`, `channelConversion`, `depthInsufficient`, `muted`, `volumeScaled`, `exclusiveRefused`, `sourceLossy`; the two rates say whether the pipeline resamples anywhere (equal by construction: the bus runs at the unit's rate), `outputUnitRunning` whether the unit is pulling, `outputRunning` whether the render's gate is open, and `outputDropouts` the IO cycles it wrote as silence because the render returned an error — cumulative, and a soak holds it at zero. `player.crossfadeMilliseconds` is the value the player was actually told. `set_bit_perfect on|off` writes the setting and requests its effects like the pane's switch, **minus the pane's eligibility gate** — System Output remains ineligible; Bluetooth and other normally excluded transports become eligible only while Advanced’s default-off “Allow bit-perfect on any device” override is on. The override changes transport eligibility, not device capabilities. The Output list is read from `dump_settings_ui`; the menu's eligibility is read from `dump_menu` (`enabled`).

**The acceptance oracle is a loopback through BlackHole.** Follow `test-audio.md` → Bit-perfect acceptance for `make test-bit-perfect`, the standalone capture command, and the ordinary-path, transition, toggle and restoration matrix. The complete source tail must match in every channel; a short matching excerpt cannot pass. Live acceptance is opt-in; the device-free render suite and comparator self-tests run through `make test-audio` in CI.

The exclusive-access half cannot go through a loopback. Enable **Settings > Audio > Exclusive output** (off by default), with bit-perfect output on and a device selected that exposes writable hog mode (physical and virtual devices are eligible; the device that is currently the macOS system output is too, and taking it moves the system default to another device for as long as Vibe holds it). Disable Exclusive output for loopback capture. The channel can drive the switch with `settings_click "Exclusive output" on`. Read the device’s actual `kAudioDevicePropertyHogMode` (also included by `CoreAudioUtil.diagnosticDescriptionOfDeviceID:` in the debug info report): `pid` = Vibe's while playing, `-1` from about 6 s after a pause, and `-1` with the device's format put back after `quit`.

## Beta signal diagnostics

Beta builds (`VIBE_VERBOSE_LOGGING=1`) automatically collect post-mix summaries on starts/seeks/resumes, gapless boundaries and late meter installation, bounded to three seconds. The player queue checks every 100 ms and logs on first signal; meter removal/replacement logs any partial capture immediately, retaining the filename, original play/voice and start reason; empty superseded captures and per-arm chatter are omitted. On hardware, the beta probe holds the meter for its bounded capture independently of visible equalizer demand; the debug pump needs ordinary meter demand. The probe reads no file. `Signal:` includes sample/host timestamps for the first sample above −60 dBFS, observed leading silence in milliseconds, peak, RMS and nonfinite count through the first signal buffer or interruption/expiry; late meter installation can miss the start, and it does not measure audible DAC output. Buffer timestamps exclude audio before the start and before outgoing fades actually settle. `observationStartMS` exposes the unmeasured prefix; `observedLeadingSilenceMS` counts only inspected silent frames, while `firstSignalAfterStartMS` measures elapsed time from the start to the threshold crossing (−1 if none). Without a threshold crossing, the silence figure is a lower bound; discarded overlap is never counted as silence. `--silent` zeroes buffers after the meter, so both silent HAL playback and the default pump launch exercise this signal measurement. Paired `Phase:` logs bracket output preparation, format confirmation, ownership, the device bind and the output start, and `Timeline:` joins queue admission, scheduling, callback delivery and the first advancing UI position. First-render logs separately label the host-clock estimate and poll observation delay.
