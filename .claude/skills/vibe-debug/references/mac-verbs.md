# macOS `--debug-cmd` verbs

Every macOS channel verb with its arguments and reply schema, plus the verbs whose contract needs more than a line (conversion and undo, cloud staging, row reorder, themes). Read when a verb's arguments or reply keys are needed; the channel's own unknown-command reply is the authoritative list, and `SKILL.md` carries the rules and traps. `$V` is `<app>/Contents/MacOS/Vibe`.

## Inspection

```bash
"$V" --debug-cmd dump_state          # {player, currentTrack, playlist, ui, window, settings} — playlist includes resolvedRows; ui.displayState (track|loading|empty|launch-grace|error) is the settled UI, player.state the pending intent
"$V" --debug-cmd dump_view_tree      # {windows: [{class, frame, visible, key, contentView: {…, subviews}}]} — AppKit bottom-left frames
"$V" --debug-cmd dump_menu           # {menu: [{title, id, key, action, enabled, state, items}]} — live enabled/checkmark from the real validateMenuItem pass
"$V" --debug-cmd dump_now_playing    # {playbackState, hasInfo, title, artist, duration, elapsed, rate, hasArtwork} — the system Now Playing publish; always hasInfo: 0 under --no-audio-hw
"$V" --debug-cmd dump_stats          # {filesOpened, foldersOpened, secondsPlayed} — AppStats lifetime counters, live
"$V" --debug-cmd dump_equalizer      # producer/renderer snapshot: references/equalizer-counters.md
"$V" --debug-cmd dump_health         # {process: {footprintBytes, residentBytes, mallocLiveBytes, mallocReservedBytes, threads, fileDescriptors, machPorts, uptimeSeconds}, ui: {windows, views, layers, trackingAreas}, app: {playlistCount, tableRows, engineNodes, …}, pending: {metadataHolders, metadataWaiters, openResultsBuffered, openBurstQueued, retiredFades, datalessProbesInFlight, …}} — DIFF across a run, never read in isolation. mallocLiveBytes, not footprintBytes, is the leak signal: the footprint carries the allocator's and the VM's high-water mark, the live heap does not
"$V" --debug-cmd quiesce             # {ok, settled, waitedSeconds, pending, pressureRelief: {releasedBytes, mallocLiveBytes, mallocReservedBytes, reservedFreedBytes}} — closes the file, polls until every pending-work counter unwinds (15s deadline), asks every zone to return free pages. Sample dump_health straight after for a reading at rest; settled:false names the counter that held out. Check releasedBytes before trusting a resting footprint: after a heavy run it is 0, the pages stay dirty and the footprint keeps its high-water mark (vmmap: MALLOC_LARGE (empty))
"$V" --debug-cmd check_consistency   # {ok, checked, state, violations: [{id, detail}]} — the app's consistency rules against live state: playlist index and player-track identity, table rows, position/pitch clamps, fader-vs-player agreement, UI tick rate, an engine node bound, tag-over-analysis precedence, header labels and settled artwork ownership. Re-check after a settle before believing a violation: gapless promotion reaches the player before its playlist callback reaches main, and rendered state lags its input by a runloop turn
"$V" --debug-cmd dump_metadata_progress # {total, parsed, attempted} — attempted counts rows a parse has landed on, parsed those with real metadata, so a failed parse is not mistaken for one still waiting
"$V" --debug-cmd dump_timing         # {loads: [...]} — phase timings of recent waveform decodes, newest first: readSeconds, chunkSeconds, bpmSeconds/keySeconds (Append + Finish), otherSeconds, realtimeFactor. Every load, from play as well as file_cache; clear_timing empties it
"$V" --debug-cmd dump_last_playlist  # {exists, rows, currentIndex} — the container mirror (Application Support/<bundle id>/LastPlaylist.m3u) read back through the app. Written only at quit, so a fresh session reports the LAST quit's. A relaunch with the setting on restores it parked (state "paused", currentTime "0:00") and publishes no Now Playing until the first real play
"$V" --debug-cmd dump_theme ["id-or-name"] # {ok, activeTheme?, id?, theme} — no arg: the current WORKING record, divergence included; with one: that theme's stored record, the exportable form
"$V" --debug-cmd dump_screenshot -   # PNG on stdout, JSON reply on stderr: references/screenshots-and-logs.md
```

## Transport, FX and window

Action replies are a compact `{ok, state, index, count, position, pitch, lowKill, reverbSend, delaySend, shortDelaySend, playlistShown, pitchPanelShown}`, read synchronously, so they lag async engine work — confirm with `dump_state`.

```bash
"$V" --debug-cmd play_pause          # also: next, previous, skip_forward[_more|_most], skip_back[_more|_most], toggle_size, toggle_pitch_panel
"$V" --debug-cmd play_index 3        # plays row n synchronously (block_main chains it; `open` lands its play a turn later)
"$V" --debug-cmd seek 120            # seconds
"$V" --debug-cmd set_pitch -4.5      # fader (clamps), player and time labels together
"$V" --debug-cmd toggle_low_kill     # FX; also low_kill_boost_on/_off, reverb_send_on/_off, delay_send_on/_off, short_delay_send_on/_off (the _on/_off pairs mirror the held W/E/R/T keys). These bypass audioFXEnabled by design; use key_down/key_up for the shipping gates
"$V" --debug-cmd set_window_width 900  # {ok, frame, bodyWidth} — body width in points (pitch panel excluded); optional height and seconds (0..10): `set_window_width 1400 650 2` resizes at 60 Hz through public frame changes and replies on completion. Exercises layout, not AppKit's live-resize event lifecycle
"$V" --debug-cmd set_loading 0.42    # {ok, fraction} — the waveform loading indicator directly: off, indeterminate, or a 0..1 fraction. Draws the control with no play behind it; for a REAL Loading state use set_fake_cloud
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

## Files, playlist and caches

`open` and `file_cache` read the path directly, so the sandbox may deny a file the app was never granted; `open -a "$APP" <file>` grants, so prefer paths opened this session.

```bash
"$V" --debug-cmd open ~/Music/album  # {ok, opening} — file or dir through the direct expand/filter/replace path, bypassing the AppDelegate funnel; poll dump_state
"$V" --debug-cmd append ~/Music/track.flac  # {ok, appending} — the real deliberate-open funnel with appending:YES, then addURLs:; poll dump_state
"$V" --debug-cmd file_drag_hover 520 275   # {ok, well} — synthetic external-file drag-over at a window point, through the real FileDropDelegate. Direct delegate calls, with no mouse events or native drag session. well = replace|add|none
"$V" --debug-cmd file_drag_drop 520 275 ~/Music/track.wav  # {ok, dropping, well} — completes the drag: delivers the drop at that point (none→replace), tears the drag-over UI down. ABSOLUTE path; same sandbox caveat as open
"$V" --debug-cmd file_drag_end       # {ok} — the drag left without a drop
"$V" --debug-cmd select_rows 0 2      # actual table selection without focus; all/none also accepted; ignores rows beyond the current list
"$V" --debug-cmd select_rows current 50  # resolves the playing row at execution time, optionally with numbered rows
"$V" --debug-cmd remove_selected      # shell removal action over that selection, including transport and undo
"$V" --debug-cmd save_playlist ~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/set.m3u  # {ok, path, tracks} — File > Save Playlist… without its panel: extended M3U, entries relative to the file's folder, noted in Open Recent. {"error": "playlist is empty"} on an empty list. The path must be writable by the sandboxed app (the container's tmp is; the host can read it back)
"$V" --debug-cmd file_cache song.flac        # {ok, wasCached, bpm, key, camelot, timing} — decode + cache one file's waveform, UI untouched; waits up to 60s. timing is that decode's phase breakdown, absent on a hit. Replies only once the entry is on disk, so a relaunch is guaranteed the hit
"$V" --debug-cmd file_clear_cache song.flac  # {ok, wasPresent} — evict one file's waveform entry (keyed by size and mtime). clear then file_cache = a forced cold decode with freshly detected bpm
"$V" --debug-cmd clear_caches        # {ok, cleared} — blocks until both PINCaches are genuinely empty; the waveform clear queues behind an in-flight load, so allow 15s after feeding a long file
"$V" --debug-cmd clear_disk_caches   # {ok, cleared} — CLI-process deletion of the PINDiskCache dirs, ONLY with the app NOT running. scripts/clear-caches.sh picks the right one of the two and keeps shell rm out of the container
```

### Row reorder: `reorder_*`

A synthetic playlist row-reorder drag: the real `NSTableViewDataSource` choreography (writer + token per row, willBegin) with a stand-in `NSDraggingInfo` and no native drag session. The session **survives across channel commands on purpose** — begin, mutate the playlist with any other verb, then update or drop — which stages the mid-drag races (replace-all rejection, a converted-away dragged row dropping out) no pointer can. AppKit's half — the drag threshold, which rows a gesture picks up, the insertion line, autoscroll — is not exercised and stays a manual pointer check.

```bash
"$V" --debug-cmd reorder_begin 1 3   # {ok, rows}
"$V" --debug-cmd reorder_update 2    # {ok, slot, operation} — validateDrop at an insertion slot (0..count): "move" or "none". Sweep every slot to pin the insertion-line decision
"$V" --debug-cmd reorder_drop 0      # {ok, slot, dropped} — validate then accept, then end the session; dropped:false = refused (AppKit slides a refused slot back). Poll dump_state for the order
"$V" --debug-cmd reorder_cancel      # {ok} — end without a drop through the same ended call a real cancel takes
```

## Cloud and loading

`set_fake_cloud`'s behavior and the prefetch trap are in `references/test-audio.md`.

```bash
"$V" --debug-cmd set_fake_cloud 4 100  # {installed, percent, baseSeconds, capacity, uniform, progressMode, materialized, completed, cancelled, maxConcurrency, metadataOverlapTransfers, foregroundContentionStarts, …} — grammar: set_fake_cloud <seconds> [<percent>] [capacity=N] [uniform] [progress=none|linear|sparse|stall] [unflagged] [sticky] [fail=<basename>]. Capacity defaults to 1 (0 = unlimited); `set_fake_cloud 0` uninstalls. foregroundContentionStarts counts metadata starts while a playback or prefetch transfer is running. fail=<basename> makes that file's transfers run to term and report failure — the provider-error shape that spends the metadata retry budget
"$V" --debug-cmd dump_cloud_trace    # {stats, events} — the fake provider's admission trace: one entry per transfer event (requested / started with queuedMs / completed / cancelled) with sequence, ms since install, the caller's role (playback, prefetch, metadata-priority, metadata-scan) and the file. requested is the app/provider boundary, started is slot admission. Ordering assertions read this, never elapsed time; clear_cloud_trace empties it
"$V" --debug-cmd dump_cloud_health   # {cloudParsesPending, cloudLaneHeld, priorityLane:{pending,yieldedUnderHold,inFlight,liveTokens,held}, scanLane:{pending,delayed,inFlight,liveTokens,stageOneFinished}, materialization:{claims,waiters,interactiveRunning,backgroundRunning,interactivePending,backgroundPending,metadataHolds,handleRuns,datalessProbesInFlight,handleOpensInFlight,…}} — both platforms. Every live count, pending list and hold belongs empty once a sweep has settled; stageOneFinished is history, not residue
"$V" --debug-cmd dump_row_loading    # {transfers: [{file, progress}], loadingRows: [{index, file, progress}], playlistCount} — the row loading bar's guarantee, both halves: live provider transfers and every row that would be marked. loadingRows is bounded by lane capacity (~3), every row in it must appear in transfers, progress is -1 while indeterminate, both empty once local or settled
"$V" --debug-cmd dump_audio_loading  # {aligned, materialization, player, metadata} — loading snapshots at each consumer; aligned should be true after set_audio_loading
"$V" --debug-cmd set_audio_loading defaults  # resets every loading knob; partial key=value: background, local-parses, prefetch-depth; diagnostic-only interactive, interactive-pending, background-pending, interactive-grace, background-grace, retries, timeout-baseline, timeout-silence. Applies to new admissions, never by cancelling live work
"$V" --debug-cmd hang_open track.wav # {ok, hangingBasename, hungOpens} — <basename>|release: opens of that basename block inside the uncancellable AVAudioFile call (stage 2 of a cloud open, the one failure set_fake_cloud cannot stage); release lets every held open through
"$V" --debug-cmd set_dataless_diag on  # {ok} — record st_flags and lane routing per directory against a REAL provider; dump_dataless_diag reports it. Records nothing while the fake probe is installed
"$V" --debug-cmd burst 200 7         # {ok, jumps, playlist} — <jumps> [<seed>]: seeded random play_index jumps, one per main-queue turn, capped at 5000. Replies at once and keeps firing, so the NEXT command lands mid-burst — the in-process race the channel's ~80ms cadence cannot stage
"$V" --debug-cmd block_main 0.5 play_index 3  # {ok, blockedSeconds, then, thenReply} — hold the main thread, then run another shared verb WITHOUT yielding: a worker callback arriving while a user action is underway, which two separate commands cannot stage since intake is on main. Bounded to 5s
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

Most are CLI-process prefs writes a running app sees at once; `set_key_display` and `set_folder_art` are app-side because their state lives in memory.

```bash
"$V" --debug-cmd set_theme technical # {ok, activeTheme} — by stable id or display name (case-insensitive); requests the ThemeApply effect. dump_state.settings.activeTheme/themeCount assert it
"$V" --debug-cmd import_theme '{"name":"T","window":{"cornerRadius":0}}'  # {ok, imported, name, themeCount} — inline JSON (starts with "{") or a path the APP can read (container tmp) to a .json or a theme ZIP (theme.json + custom album-art image); the Settings importer's sanitize-and-store path, powerbox-free. The only scripted route to a font change
"$V" --debug-cmd remove_theme "fuzz-3" # {ok, removed, activeTheme, themeCount} — a USER theme (a built-in is refused); removing the active one falls back to vibe. A harness that imports themes must remove them, or they persist in the user's real store
"$V" --debug-cmd set_key_display musical colors  # {ok, keyNotation, keyColors} — <camelot|musical> <colors|plain>; app-side, since the key display lives on the current THEME object. Persists and repaints immediately
"$V" --debug-cmd set_analysis bpm off  # {ok, analyzeBPM, analyzeKey} — <bpm|key> <on|off>; the next waveform decode reads it, no relaunch — the A/B for analyzer cost
"$V" --debug-cmd set_folder_art off  # {ok, folderArt} — <on|off>, Settings > Files album-art dropdown: writes AND re-resolves the loaded playlist's folder art (header, dock, rows). Needs a RUNNING app
"$V" --debug-cmd set_pause_at_track_end off  # {ok, pauseAtTrackEnd} — writes and requests the EndOfTrack live effect, which re-parks or drops the armed successor at once
"$V" --debug-cmd set_reopen_playlist on  # {ok, reopenLastPlaylist} — writes and requests ReopenLastPlaylist. Off deletes the container mirror at once; the mirror is written only at QUIT (the quit verb, hence launch.sh, runs applicationWillTerminate:)
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
"$V" --debug-cmd sleep 0.5           # client-side pause (0–600s); the app's main thread never sleeps
"$V" --debug-cmd script - <<'EOS'    # one verb per line; rules in SKILL.md
seek 30
sleep 0.5
key space
EOS
.claude/skills/vibe-debug/scripts/run-script.sh <shots-dir> [file]   # decodes in-script screenshots to numbered PNGs
```

## Bit-perfect output

`dump_state.player.bitPerfect` is the whole report the header's lock and Settings > General read — `{enabled, status, sampleRate, bitsPerChannel, isFloat, softwareVolume, balance, eligibleDevice, hasTrack, fxGraph, rateExact, formatConfirmed, channelsMatch, depthOK, muted, hogWanted, exclusive, sourceLossless, systemDefault}` plus the queue-confined ownership `{hoggedDeviceId, restoreOwedToDeviceId, preparedDeviceId, varispeedPresent, mixerOutputRate, outputNodeInputRate, outputNodeOutputRate}`. `scripts/hogfollow.swift <deviceID>` (`swiftc -O` it) is the standalone experiment behind the "never hog the system default" trap (`Audio/Mac/Devices/CLAUDE.md`; the findings are in the system-output experiment in `docs/future/bit-perfect-output.md`): it binds an engine to the device, hogs it, and prints the system default, the unit's device and the engine's liveness every 250 ms through the take, the re-bind, a first and second start (with and without `prepare`) and the release. Run it against the device that IS the default to see it move. `status` is one of `off`, `idle`, `active`, `rateUnsupported`, `switchFailed`, `channelConversion`, `depthInsufficient`, `muted`, `volumeScaled`, `exclusiveRefused`, `sourceLossy`, `fxGraphPresent`; the three rates say whether the graph resamples anywhere (all three equal is the bit-perfect shape). `player.crossfadeMilliseconds` is the value the player was actually told. `set_bit_perfect on|off` writes the setting and requests its effects like the pane's switch, **minus the pane's eligibility gate** — forced on over System Output or Bluetooth it stays `off` in the report, which is what a test of that gate wants to see. The Output popup's and menu's graying is read from `dump_settings_ui` / `dump_menu` (`enabled`).

**The oracle is a loopback through BlackHole.** `scripts/verify-bit-perfect.swift <file> <seconds> [device] [--force-volume] [--set-rate]` records the device with a raw HAL IOProc and compares the capture against the file's own decoded samples, printing one JSON line — `exact` requires equal source/capture channel counts as well as matching samples; `fileChannels`/`captureChannels` and `mismatches`/`comparedFrames` are the evidence, `approxAlignedAtFrame`/`approxMaxError` the diagnosis when it is not exact (1e-3-class errors are resampling, 1e-5-class are a float stage such as the varispeed). Rules learned the hard way: launch Vibe **`VIBE_AUDIBLE=1`** (the mixer must be at unity; a virtual device is silent to a human), choose BlackHole explicitly and turn the mode on first; start the verifier, then `open` the file — it waits for the device to reach the file's rate before binding, because Vibe's switch tears down anything bound earlier; `--force-volume` holds BlackHole's software volume *and* its driver volume scalars at 1.0 for the run and puts them back, since either scales the samples; `--set-rate` sets the device to the file's rate itself for measuring the everyday chain with the mode off. A loopback needs a virtual transport, which the mode never hogs. Compile it once (`swiftc -O`) rather than running it through `swift` per file.

The exclusive-access half cannot go through a loopback. Enable **Settings > General > Audio > Exclusive output** (off by default), with bit-perfect output on and a physical device selected that is **not** the macOS system output. The channel can drive the switch with `settings_click "Exclusive output" on`. Check it against that device with Appendix A of `docs/future/bit-perfect-output.md` (a read-only HAL probe printing the hog owner's pid): `pid` = Vibe's while playing, `-1` from about 6 s after a pause, and `-1` with the device's format put back after `quit`.
