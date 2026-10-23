# macOS `--debug-cmd` verbs

Every macOS channel verb with its arguments and reply schema, plus the verbs whose contract needs more than a line. The channel's unknown-command reply is the authoritative list, and `SKILL.md` carries the rules and traps. `$V` is `<app>/Contents/MacOS/Vibe`.

## Inspection

```bash
"$V" --debug-cmd dump_state          # {player, currentTrack, playlist, fx, ui, window, settings}. fx is the FX intent (stages.<name>.intent, delayTapBPM, unitRenders), read without the player queue; the hosting's facts are dump_audio_path's fx stage. playlist includes resolvedRows. ui.displayState (track|loading|empty|launch-grace|error) is the settled UI, player.state the pending intent. ui.headerState is what the header draws. ui.waveformLoading is the waveform's loading indicator. ui.notice is a failed link's status while the header holds it (about 4 s). ui.bufferingShown is YES while Buffering… stands in for the file info line, 0.5 s into a hold. ui.openURLWindow is {shown} when the Open URL window is down, else {shown, text, resolving, key, openEnabled}
"$V" --debug-cmd dump_debug_info     # {bytes, text}: Settings > Advanced > Save Debug Info's report without its save panel. The hardware, player and audio-path sections each get a 2 s deadline and report cached/unavailable on timeout; 30 s client timeout
"$V" --debug-cmd block_player 8      # acknowledges at once, holds only the player queue for 0<seconds<=10; use with dump_debug_info to verify bounded export and stall logging
"$V" --debug-cmd block_render 2      # {ok, heldSeconds}: the next real IO callback spins inside the pipeline for 0<seconds<=5, so the render clock stops. Exercises the beta Stall: lines and renderMaxMicros. Audible as a gap; use --silent
"$V" --debug-cmd block_decoder 0.8   # {ok, heldSeconds}: every decode turn of the current bus waits at its start for 0<seconds<=5, as a stalled read would. A hold longer than the rings buffered underruns (dump_audio_path's bus underrunFrames)
"$V" --debug-cmd dump_now_playing_artwork # {artwork: art|thumbnail|placeholder|other|null, placeholderSide?: dark|light|both, placeholderReference?, windowAppearance}: which image the published artwork came from, by identity
"$V" --debug-cmd dump_view_tree      # {windows: [{class, frame, visible, key, contentView: {…, subviews}}]}: AppKit bottom-left frames
"$V" --debug-cmd dump_menu           # {menu: [{title, id, key, action, enabled, state, imageDigest, items}]}: live enabled and checkmark state from validateMenuItem. imageDigest is present only on an item with an image. It hashes the pixels at 1x, so a script can tell a redrawn swatch from an unchanged one
"$V" --debug-cmd dump_now_playing    # {playbackState, hasInfo, title, artist, duration, elapsed, rate, hasArtwork}: always hasInfo: 0 under --no-audio-hw
"$V" --debug-cmd dump_build          # {version, git, built, pid, path}: the answering instance's identity (both platforms)
"$V" --debug-cmd dump_stats          # {filesOpened, foldersOpened, secondsPlayed}: AppStats lifetime counters
"$V" --debug-cmd dump_equalizer      # producer/renderer snapshot: references/equalizer-counters.md
"$V" --debug-cmd dump_resampler_costs [reset]  # {costs: {cpuSeconds, audioSeconds, corePercent}, conversion}: the resampler's decode-thread CPU since the bus was made or the last reset, file reads excluded. corePercent is the real-time cost. Both platforms
"$V" --debug-cmd dump_audio_path     # {stages: [{stage, present, …}]}: source, decode, bus, varispeed, fx, meter, output, device. Rates, sample formats, channels, the decoder's conversion, varispeed engagement and latency, FX activity and latencySeconds. The output stage reports running, idleStopPending, idle and renderedBy (outputUnit, or pump under --no-audio-hw), presentationLatency, bufferLatency and render counters. The device stage reports channels, physicalChannels and latencySeconds
"$V" --debug-cmd dump_health         # {process: {footprintBytes, residentBytes, residentPeakBytes, mallocLiveBytes, mallocReservedBytes, threads, fileDescriptors, machPorts, uptimeSeconds}, ui: {windows, visibleWindows, views, layers, trackingAreas}, app: {playlistCount, tableRows, currentIndex, playerLoading, gaplessArmed, hostedUnits, outputDropouts, renderRefusals, renderCycles, renderMeanMicros, renderMaxMicros, canUndo, canRedo, …}, materialization: {…}, pending: {…}}. Diff it across a run, never read it alone. mallocLiveBytes, not footprintBytes, is the leak signal (vibe-stress references/health-metrics.md)
"$V" --debug-cmd clear_render_counters  # {ok}: zeroes renderCycles, renderMeanMicros, renderMaxMicros, outputDropouts and renderRefusals, so a phase reads on its own
"$V" --debug-cmd quiesce             # {ok, settled, waitedSeconds, pending, pressureRelief: {releasedBytes, mallocLiveBytes, mallocReservedBytes, reservedFreedBytes}}: closes the file, polls until every pending counter unwinds (15 s deadline), asks every zone to return free pages. settled also needs the player stopped and not loading. Sample dump_health straight after for a reading at rest
"$V" --debug-cmd check_consistency   # {ok, checked, violations: [{id, detail}]}: the app's consistency rules against live state. Re-check after a settle before believing a violation: gapless promotion reaches the player before its playlist callback reaches main
"$V" --debug-cmd dump_metadata_progress # {total, parsed, attempted}: attempted counts rows a parse has landed on, parsed those with real metadata
"$V" --debug-cmd dump_timing         # {loads: [...]}: phase timings of recent waveform decodes, newest first. clear_timing empties it
"$V" --debug-cmd dump_last_playlist  # {exists, rows, currentIndex}: the container mirror (Application Support/<bundle id>/LastPlaylist.m3u). Written only at quit. A relaunch with the setting on restores it parked and publishes no Now Playing until the first real play
"$V" --debug-cmd dump_theme ["id-or-name"] # {ok, activeTheme?, id?, theme}: no arg is the current working record, divergence included; with one, that theme's stored record
"$V" --debug-cmd dump_screenshot -   # PNG on stdout, JSON reply on stderr: references/screenshots-and-logs.md
```

## Transport, FX and window

Action replies are a compact `{ok, state, index, count, position, pitch, lowKill, reverbSend, delaySend, shortDelaySend, playlistShown, pitchPanelShown}`. They are read synchronously and lag async pipeline work, so confirm with `dump_state`.

```bash
"$V" --debug-cmd play_pause          # also: next, previous, skip_forward[_more|_most], skip_back[_more|_most], toggle_size, toggle_pitch_panel
"$V" --debug-cmd play_index 3        # plays row n synchronously (open lands its play a turn later)
"$V" --debug-cmd seek 120            # seconds
"$V" --debug-cmd set_pitch -4.5      # fader (clamps), player and time labels together
"$V" --debug-cmd toggle_low_kill     # also low_kill_boost_on/_off, reverb_send_on/_off, delay_send_on/_off, short_delay_send_on/_off (the held W/E/R/T keys). These bypass audioFXEnabled; use key_down/key_up for the shipping gates
"$V" --debug-cmd set_window_width 900  # {ok, frame, bodyWidth}: body width in points, pitch panel excluded. Optional height and seconds (0..10): `set_window_width 1400 650 2` resizes at 60 Hz and replies on completion. Exercises layout, not AppKit's live-resize lifecycle
"$V" --debug-cmd set_loading 0.42    # {ok, fraction}; `off` → {ok, loading: "off"}; indeterminate → {ok, fraction: -1}. Draws the loading indicator with no play behind it; for a real Loading state use set_fake_cloud
"$V" --debug-cmd set_appearance dark # {ok, windowAppearance}: light|dark|system, applied live
"$V" --debug-cmd raise_window        # {ok, visible, displayAsleep}: orders the window front without activating. visible:false with displayAsleep:true means a sleeping display or locked screen
"$V" --debug-cmd click_menu menu_show_pitch  # {ok, clicked, action}: by identifier (preferred) or exact title; refuses a disabled item
```

## Input injection

Raw input is for explicit gesture tests on an isolated test desktop, never unattended stress. Coordinates and the tracking-loop and right-click traps are in `SKILL.md`. Prefer `stress.py --gesture-test`, which asserts the resulting pitch. The channel command only queues the gesture: `gesture_test pitch-reset|pitch-drag isolated-desktop`.

```bash
"$V" --debug-cmd click 75 122        # {ok, posted, hitView, windowKey}: down+up at a window point; `click x y right`; `click x y left 2` is a double-click
"$V" --debug-cmd drag 728 219 728 299   # the whole left-button gesture in one command (down, 12 dragged steps, up); optional [steps]
"$V" --debug-cmd mouse_move 400 200  # plain move; add left|right for a lone dragged event
"$V" --debug-cmd mouse_down 75 122   # primitives (default left; also right); mouse_up likewise
"$V" --debug-cmd scroll 300 100 -3   # {ok, posted, hitView, windowKey}: one scroll at a window point, sent to the window at once (no activation, no queue). lines by default (a wheel's), `pixels` a trackpad's, `momentum` the coast after the fingers lift. dy is raw: positive is a wheel rolled away under traditional scrolling
"$V" --debug-cmd key p               # keyDown+keyUp into the key window, else the player window; mods: `key p cmd shift`. With Open URL's window key, keys reach it, not the player, so check window.keyWindow first
"$V" --debug-cmd key_down w          # one edge (the held W/E/R/T FX); key_up releases. Keys: a-z, 0-9, period, space, tab, return, esc, delete, forward_delete, up/down/left/right
"$V" --debug-cmd key delete repeat   # `repeat` sets isARepeat, the only way to exercise a repeat guard. `delete` is Backspace, `forward_delete` its twin
"$V" --debug-cmd set_shortcut menu_skip_forward k opt   # {ok, command, shortcut, lost_by}: the Keyboard Shortcuts pane's write path; `none` clears; a reserved combination errors
"$V" --debug-cmd reset_shortcuts     # every command back to its default
```

`set_controls_hover on|off` calls the player's hover enter and exit handlers without moving the pointer. It exercises the button and gradient fade, not tracking-area delivery. Wait 0.3 s for the fade, then read `dump_view_tree`'s `id: "buttonGradient"` node (`hidden` omitted when false, `alpha` omitted when 1).

## Files, playlist and caches

`open` and `file_cache` read the path directly, so the sandbox may deny a file the app was never granted. `open -a "$APP" <file>` grants, so prefer paths opened this session.

```bash
"$V" --debug-cmd open ~/Music/album  # {ok, opening}: expands and plays directly, bypassing the AppDelegate open funnel (no burst coalescing, no supersession); poll dump_state
"$V" --debug-cmd append ~/Music/track.flac  # {ok, appending}: a common verb. On the mac it enters the real deliberate-open funnel; on iOS it is FolderSession.addURLs:. Poll dump_state
"$V" --debug-cmd file_drag_hover 520 275   # {ok, posted, x, y, well}: synthetic external-file drag-over through the real FileDropDelegate, with no native drag session. well = replace|add|none
"$V" --debug-cmd file_drag_drop 520 275 ~/Music/track.wav  # {ok, dropping, x, y, well}: delivers the drop and tears the drag-over UI down. Absolute path; same sandbox caveat as open. An http(s) link drops as a browser's text and opens through Open URL
"$V" --debug-cmd file_drag_end       # {ok, posted}: the drag left without a drop
"$V" --debug-cmd select_rows 0 2     # {ok, selectedRows}: table selection without focus; all/none accepted; rows beyond the list are ignored
"$V" --debug-cmd select_rows current 50  # `current` resolves the playing row at execution time
"$V" --debug-cmd remove_selected     # the shell's removal action over that selection, transport and undo included
"$V" --debug-cmd move_to_trash       # Move to Trash without the key window: that selection, or the loaded track while the playlist is collapsed. Real files go to the Trash, so use working copies. Replies before the moves settle; poll dump_state
"$V" --debug-cmd save_playlist ~/Library/Containers/com.commonwealthrecordings.Vibe/Data/tmp/set.m3u  # {ok, path, tracks}: File > Save Playlist… without its panel. The path must be writable by the sandboxed app
"$V" --debug-cmd file_cache song.flac        # {ok, path, wasCached, bpm, key, camelot, timing}: decode and cache one file's waveform, UI untouched; waits up to 60 s and replies once the entry is on disk
"$V" --debug-cmd file_clear_cache song.flac  # {ok, path, wasPresent}: evict one file's waveform entry. Clear then file_cache is a forced cold decode
"$V" --debug-cmd dump_waveform 1024 song.flac  # {path, wasCached, complete, bins, binFrames, frames, sampleRate, columns, hasBands, bpm, key, min, max, loudest, bandLoudest: {low, mid, high}}: the waveform summary read into that many columns across the window (omitted: 8192), as exact unions. `loudest` is the RMS of the loudest 20 ms window a column covers, which every style draws. `bandLoudest` is the same in each band; zeros without bands. Decodes first when uncached, so it waits up to 60 s. Both platforms. Save it to a file and read it with jq, since the full dump is about 1 MB
"$V" --debug-cmd set_waveform_decode_seconds 8  # {ok, seconds}: every later decode is paced to take about that long; 0 is full speed; a relaunch resets it. Both platforms. How to watch a waveform fill in on a local file (file_clear_cache it first)
"$V" --debug-cmd clear_caches        # {ok, cleared}: blocks until both PINCaches are empty; errors after 15 s under a 20 s client timeout
"$V" --debug-cmd clear_disk_caches   # {ok, cleared}: CLI-process deletion of the PINDiskCache dirs, only with the app NOT running. scripts/clear-caches.sh picks the right one of the two
```

### Row reorder: `reorder_*`

A synthetic playlist row-reorder drag: the real `NSTableViewDataSource` calls with a stand-in `NSDraggingInfo` and no native drag session. The session **survives across channel commands on purpose**. Begin, mutate the playlist with any other verb, then update or drop. That stages mid-drag races no pointer can. AppKit's half (drag threshold, insertion line, autoscroll) is not exercised.

```bash
"$V" --debug-cmd reorder_begin 1 3   # {ok, rows}
"$V" --debug-cmd reorder_update 2    # {ok, slot, operation}: validateDrop at an insertion slot (0..count), "move" or "none"
"$V" --debug-cmd reorder_drop 0      # {ok, slot, dropped}: validate, accept, end the session; dropped:false is a refusal. Poll dump_state for the order
"$V" --debug-cmd reorder_cancel      # {ok, cancelled}: end without a drop
```

## Cloud and loading

`set_fake_cloud`'s behavior and the prefetch trap are in `references/test-audio.md`.

```bash
"$V" --debug-cmd set_fake_cloud 4 100  # set_fake_cloud <seconds> [<percent>] [capacity=N] [uniform] [progress=none|linear|sparse|stall] [sticky] [fail=<basename>]. Capacity defaults to 1 (0 = unlimited); `set_fake_cloud 0` uninstalls. fail=<basename> makes that file's transfers report failure. Reply includes foregroundContentionStarts (metadata starts while a playback or prefetch transfer runs)
"$V" --debug-cmd dump_cloud_trace    # {stats, events}: one entry per transfer event (requested, started with queuedMs, completed, cancelled) with sequence, ms since install, role (playback, prefetch, metadata-priority, metadata-scan, unlabeled) and file. requested is the app/provider boundary, started is slot admission. Assert ordering on this, never on elapsed time; clear_cloud_trace empties it
"$V" --debug-cmd dump_cloud_health   # {cloudParsesPending, cloudLaneHeld, priorityLane, scanLane, materialization}: both platforms. Every live count, pending list and hold is empty once a sweep has settled; stageOneFinished is history, not residue
"$V" --debug-cmd dump_row_loading    # {transfers: [{file, progress}], loadingRows: [{index, file, progress}], playlistCount}: every row in loadingRows must appear in transfers; progress is -1 while indeterminate; both empty once settled
"$V" --debug-cmd dump_audio_loading  # {aligned, materialization, player, metadata}: loading snapshots at each consumer; aligned is true after set_audio_loading
"$V" --debug-cmd set_audio_loading defaults  # {ok, configuration, appliesTo}: resets every loading knob, optionally followed by key=value. Keys: background, local-parses, prefetch-depth; diagnostic-only interactive, interactive-pending, background-pending, interactive-grace, background-grace, probe-pending-grace, retries, timeout-baseline, timeout-silence. Applies to new admissions only
"$V" --debug-cmd hang_open track.wav # {ok, hangingBasename, hungOpens}: <basename>|release. Opens of that basename block just before the AudioFileHandle open, the stage set_fake_cloud cannot stage; release lets them through
"$V" --debug-cmd set_dataless_diag on  # {ok}: record st_flags and lane routing per directory against a real provider; dump_dataless_diag reports it with each directory's mount. Records nothing while the fake is installed
"$V" --debug-cmd set_slow_volume stall  # [off|on|throttle <bytes-per-second>|stall|fail [<errno>]], both platforms. Every file opened from now on reads ahead, as on a network mount; a file already open keeps its road. throttle paces every read-ahead pread together; stall holds every pread until on or off; fail answers every pread with the errno (EIO default). Each set releases held reads. off restores the real rule. No argument only reports
"$V" --debug-cmd open_url https://fake.vibe.test/song.mp3  # {ok: true, file, placeholder} or {ok: false, linkError, code, status, cause}: both platforms. The shell's Open URL road. Replies when the resolve settles; poll dump_state. linkError is the link.error key's last part (invalid, insecure, unreachable, local_network, not_found, denied, not_audio, no_size, live_stream, server, icloud_private, icloud_folder, icloud_unreadable). A failed link leaves the playlist as it is
"$V" --debug-cmd open_url_window https://fake.vibe.test/song.mp3  # {ok, shown, text, resolving, key, openEnabled}: drives the Open URL window (click_menu menu_open_link raises it). Text goes through the field editor. `open`, `cancel` and `close` press those buttons. Replies at once; poll dump_state's ui.openURLWindow
"$V" --debug-cmd dump_links          # {root, budgetBytes, downloadsBytes, links: [{directory, record, file, path, placeholder, stream}]}: both platforms. Every link under <Application Support>/Links, whether its file is still a placeholder, and the stream writing it now
"$V" --debug-cmd set_fake_http <directory>|off [<transfer-seconds>]  # {ok, fake, directory, transferSeconds, hosts}: both platforms. The directory answers as https://fake.vibe.test/<path> and http://fake.local/<path> under the Links client (VibeFakeHTTP.h), no network; other hosts fail as unknown. Ranges answer 206/416, no Range 200, with a strong ETag and Last-Modified. An open range is paced in 64 KB pieces over transfer-seconds; a closed range answers at once. It also answers iCloud Drive share links (VibeFakeHTTP.h). Installing again swaps the directory and clears faults and log
"$V" --debug-cmd fake_http_fault <kind>|off [<value>] [file=<basename>] [after=<bytes>] [once|always]  # {ok, faults}: both platforms; bytes take K and M; after defaults to 512K. Kinds: stall, drop, etag-change, rate <bytes/s>, latency <seconds>, no-range, no-length, icy, status <code>, html, gzip, expiry <seconds>. VibeFakeHTTP.h has each kind's lifetime and effect
"$V" --debug-cmd dump_fake_http      # {fake, directory, transferSeconds, requests, faults, transfers, log: [{seq, t, host, path, range, status, etag, size, delivered, firstByte, finished, faults, outcome}]}: the last 200 requests
"$V" --debug-cmd burst 200 7         # {ok, jumps, playlist}: <jumps> [<seed>] seeded random play_index jumps, one per main-queue turn, capped at 5000. Replies at once, so the next command lands mid-burst
"$V" --debug-cmd block_main 0.5 play_index 3  # {ok, blockedSeconds, then, thenReply}: hold main, then run another shared verb without yielding (vibe-stress references/cloud-scenarios.md). Bounded to 5 s; cannot chain itself
"$V" --debug-cmd block_main_deep 1.2 600 [alternating]  # {ok, blockedSeconds, depth, alternating}: hold main under <depth> real frames to verify beta stall stacks; depth up to 4000, seconds up to 5. The main-thread stall watcher runs only under VIBE_VERBOSE_LOGGING=1
```

## Conversion and undo

`convert_to_flac` runs the menu's funnel on the **current track**, so load the file first. It replies with the settled result, or `row: -1` if the playlist was replaced mid-encode. It converts **beside the source**, so point it at a working copy, never at `Assets/test_audio_files/`. `dump_state`'s `ui.converting` and `ui.convertSweep` move while it runs.

```bash
"$V" --debug-cmd convert_to_flac [keep|delete] [omit-trash-url]  # {ok, output, row, source, sourceDeleted, sourceRemains}: waits up to 120 s
"$V" --debug-cmd undo                # {ok, undid, committed, reason?, canUndo, canRedo}: replies once the file moves settle; {"error": "nothing to undo"}
"$V" --debug-cmd redo                # {ok, redid, committed, reason?, canUndo, canRedo}
```

- `keep|delete` writes Convert > Delete Original before converting and **leaves it written**. Restore it if a later test expects the default (off). `dump_state.settings.deleteOriginalAfterConvert` reports it. `sourceDeleted` is what disposal did. `sourceRemains` stats the original after the Trash move settled. `ls ~/.Trash` from a terminal trips the same TCC denial as reading the container.
- `undo` and `redo` drive the window's NSUndoManager, which also holds Remove from Playlist, Move to Trash and Reorder (`Vibe/Mac/Menu/AGENTS.md`). Move to Trash's file moves settle like a conversion's, so the reply waits for them. TRAP: channel commands post no event, so consecutive edits made through verbs share one undo group. Drive the edits with `key` to get one undo step each. Run them straight after the conversion they reverse. `committed:false` carries one of `restore_failed`, `replacement_location_unknown`, `replacement_unavailable`, `already_at_target`, or Move to Trash's `file_move_failed`. `click_menu menu_edit_undo` exercises the menu path but has no settled signal, so prefer the verbs when a later step depends on the moves.
- `omit-trash-url` is a one-shot fault (requires `delete`, working copy only): the source goes to the Trash but its location is withheld. The refused undo must leave the converted row in place, and its registered inverse must settle as already satisfied:

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

All but `set_analysis` are app-side verbs applied at once. `set_analysis` is a CLI-process prefs write that the running app's next decode reads.

```bash
"$V" --debug-cmd set_theme technical # {ok, activeTheme}: by stable id or display name (case-insensitive); requests the ThemeApply effect
"$V" --debug-cmd import_theme '{"name":"T","window":{"cornerRadius":0}}'  # {ok, imported, name, themeCount}: inline JSON (starts with "{") or a path the app can read (container tmp) to a .json or a theme ZIP. The Settings importer's path without the powerbox. The only scripted route to a font change
"$V" --debug-cmd remove_theme "fuzz-3" # {ok, removed, activeTheme, themeCount}: a user theme (a built-in is refused). A harness that imports themes must remove them, or they persist in the user's real store
"$V" --debug-cmd set_analysis bpm off  # {ok, analyzeBPM, analyzeKey}: <bpm|key> <on|off>; the next waveform decode reads it, no relaunch
"$V" --debug-cmd set_folder_art off  # {ok, folderArt}: writes and re-resolves the loaded playlist's folder art. Needs a running app
"$V" --debug-cmd set_pause_at_track_end off  # {ok, pauseAtTrackEnd}: writes and requests the EndOfTrack live effect
"$V" --debug-cmd set_repeat all      # {ok, repeatMode}: off|all|one. Writes and requests the EndOfTrack live effect. Both platforms
"$V" --debug-cmd set_shuffle on      # {ok, shuffleEnabled}: the same path. Both platforms
"$V" --debug-cmd set_reopen_playlist on  # {ok, reopenLastPlaylist}: off deletes the container mirror at once; the mirror is written only at quit
"$V" --debug-cmd set_declick off     # {ok, declick}: Settings > Audio > Declick, applied live. dump_state.settings.declick is the stored choice, player.declick what the player holds. The loopback verifier turns it off around its captures
```

The View > Theme items carry `view_theme_<identifier>` ids (`view_theme_vibe`, `view_theme_technical`, `view_theme_<uuid>` for user themes; the tail is `menu_edit_themes`). The submenu is built on open, so **run `dump_menu` first in each app run**, or `click_menu` cannot find them. `dump_state.settings.activeTheme` uses the same identifiers, never display text. The waveform style lives in the theme editor (`settings_click Style <identifier>`), not the menu bar.

## Measurement

```bash
"$V" --debug-cmd work_tally begin    # both platforms: a fresh counting window over the debug signposts
"$V" --debug-cmd work_tally end      # {active, label, elapsedMs, work:{name:{count,totalMs,maxMs}}}. Nested intervals overlap, so do not add waveform_update to its waveform_target/raster children. App-side time only
"$V" --debug-cmd measure_resize 600 1080 240  # one out-and-back width sweep at 60 Hz, 30–600 frames; restores the frame and returns CPU seconds, layout mean/p95/max ms and signpost counts. Pause playback and hold style, track and visibility fixed across before/after
```

## Analyzers, lifecycle and scripts

```bash
"$V" --debug-cmd scan_bpm - < file   # {ok, bpm}: decode and analyze in the CLI process, no app needed; prefer scripts/scan-bpm.sh (references/test-audio.md)
"$V" --debug-cmd scan_key - < file   # {ok, key, camelot, index}: same contract; ignores tags
"$V" --debug-cmd quit                # {ok, quitting}: the normal terminate path, the only exit that runs applicationWillTerminate: (AppStats flush, last-playlist mirror). Prefer it to pkill
"$V" --debug-cmd sleep 0.5           # client-side pause (above 0, up to 600 s)
"$V" --debug-cmd script - <<'EOS'    # one verb per line; rules in SKILL.md
seek 30
sleep 0.5
key space
EOS
.claude/skills/vibe-debug/scripts/run-script.sh [--assert '<jq predicate>'] <output-dir> [file]   # saves replies.jsonl and numbered PNGs (SKILL.md)
```

## Output device

`set_output_device <uid|name|system> [<bit-perfect on|off> [<exclusive on|off>]]` selects the output through the Output menu's path. Address it by UID: a HAL device id changes across replugs, and UID keys the per-device modes. A name is accepted as a fallback, and `system` is System Output. An unknown device answers an error listing the known names. UIDs are in `dump_debug_info`'s hardware section. The reply is `{ok, deviceId, uid, name, selectionPending, modesRequested}`. The selection settles asynchronously, so poll `dump_state.player.outputDeviceId` and `outputDeviceUID` and `dump_audio_path`'s device stage. On System Output `requestedOutputDeviceId` is -1. The optional modes are applied once the selection clears. Confirm with `dump_state.player.bitPerfect`.

`set_saved_output_device <uid> <name>` writes only the next-launch preference. Use a missing UID and name plus a relaunch to verify that confirmed absence disables bit-perfect, persists System Output and restores pitch. Restore the original preference afterward.

## Bit-perfect output

**Bit-perfect and exclusive output are remembered per device UID.** `set_bit_perfect on|off` writes the saved device's mode and requests its effects like the Settings switch, without the pane's eligibility gate. It refuses while a device selection is pending, so select the device, wait for it to settle, then toggle. On System Output it is a no-op that answers off. Bluetooth and other excluded transports become eligible only while Advanced's "Allow bit-perfect on any device" is on. A device left with the mode on gets it back whenever it is selected again, so a script that must leave no trace turns it off while that device is selected. The stored map is `AudioPlayer.outputModesByDeviceUID`. Inspect the selected device through the debug channel.

`dump_state.player.bitPerfect` is the report the header's lock and Settings > Audio read: `{enabled, status, sampleRate, bitsPerChannel, isFloat, softwareVolume, balance, playerVolume, eligibleDevice, hasTrack, rateExact, formatConfirmed, channelsMatch, depthOK, muted, hogWanted, exclusive, sourceLossless}`. Beside it are the wanted flags, the bound, requested and pending device fields, and the queue-confined ownership (`hoggedDeviceId`, `restoreOwedToDeviceId`, `preparedDeviceId`, `busRate`, `outputUnitRate`, `outputUnitRunning`, `outputRunning`, `outputDropouts`, …). `status` is one of `off`, `idle`, `active`, `rateUnsupported`, `switchFailed`, `channelConversion`, `depthInsufficient`, `muted`, `volumeScaled`, `exclusiveRefused`, `sourceLossy`. `outputDropouts` counts IO cycles written as silence because the render failed. It is cumulative, and a soak holds it at zero. `player.crossfadeMilliseconds` is the value the player was told. The Output list is read from `dump_settings_ui`, the menu's eligibility from `dump_menu`.

`scripts/hogfollow.swift <deviceID> [engine|hal] [--make-default]` (build it with `swiftc -O`) shows how each kind of output unit follows a hogged default (`vibe-libs/audio/Player/AGENTS.md`). Run it against the device that is the default.

**The acceptance oracle is a loopback through BlackHole**: `test-audio.md`, Bit-perfect acceptance. The exclusive half cannot go through a loopback. Enable **Settings > Audio > Exclusive output** with bit-perfect on and a device that exposes writable hog mode (`settings_click "Exclusive output" on`). Disable it for loopback capture. Read the device's `kAudioDevicePropertyHogMode` (also in the debug info report): Vibe's pid while playing, `-1` from about 6 s after a pause, and `-1` with the format put back after `quit`.

## Beta signal diagnostics

Beta builds (`VIBE_VERBOSE_LOGGING=1`) log `Signal:`, `Phase:`, `AudioOutputUnit:` and `Timeline:` lines on every start. What each line means is in `vibe-libs/audio/Player/AGENTS.md` (Beta diagnostics) and `vibe-libs/audio/Meter/AGENTS.md` (The signal probe). Under the debug pump the probe needs ordinary meter demand, so keep the playlist's equalizer visible.
