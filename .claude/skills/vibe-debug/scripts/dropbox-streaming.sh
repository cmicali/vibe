#!/bin/bash
# The Dropbox streaming scenarios, end to end in this session's simulator over
# the fake Dropbox (VibeFakeDropbox.h): no account, no network. Each scenario
# opens a fresh fixture folder, so every file starts as a placeholder, drives
# the debug channel, polls dump_state, dump_row_loading, dump_dropbox,
# dump_fake_dropbox, dump_art and dump_cloud_health, and asserts on the JSON.
#
# Usage: dropbox-streaming.sh [-o <out-dir>] [scenario ...]   (default: all)
# Scenarios: stream-wav stream-flac stream-m4a stream-m4a-moovlast stream-mp3
#   stream-adts small-mp3 seek seek-ahead-mp3 seek-ahead-flac
#   seek-ahead-m4a skip quick-skip pause-replay gapless buffering
#   pause-buffering scrub-buffering stall drop throttle expired-token
#   rev-change tail-fail slow-tail sign-out reupload
# Not in the default run: stream-mp3-noxing, an MP3 with no Xing/Info frame,
#   which opens only once the whole download is in until the parser stops
#   walking every frame to count packets: red until that is fixed.
# Needs: a Debug build up through launch-ios.sh; ffmpeg, lame, afconvert, jq;
#   Assets/test_audio_files/tone-long.wav (generate-test-audio.sh), from which
#   the six-minute fixtures are transcoded once into build/streaming-fixtures.
# Out: <out-dir>/<scenario>.jsonl, every poll; summary.json, each scenario's
#   measured numbers and failed checks. Exit 0 only when every check passed.
# TRAP: it reinstalls the fake and opens folders, replacing the playlist, and
#   leaves set_audio_loading at its defaults.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../../.." && pwd)"
S="$DIR/debug-ios.sh"
FIX="${VIBE_STREAMING_FIXTURES:-$ROOT/build/streaming-fixtures}"
OUT="$ROOT/build/streaming-scenarios/$(date +%Y%m%d-%H%M%S)"
if [ "${1:-}" = "-o" ]; then OUT="$2"; shift 2; fi
ALL="stream-wav stream-flac stream-m4a stream-m4a-moovlast stream-mp3 stream-adts small-mp3 seek seek-ahead-mp3 seek-ahead-flac seek-ahead-m4a skip quick-skip pause-replay gapless buffering pause-buffering scrub-buffering stall drop throttle expired-token rev-change tail-fail slow-tail sign-out reupload"
SCENARIOS="${*:-$ALL}"
mkdir -p "$OUT"
VIBE_SIM_UDID="$("$DIR/sim-udid.sh")" || { echo "no simulator: run launch-ios.sh first" >&2; exit 1; }
export VIBE_SIM_UDID

dbg() { "$S" "$@"; }
now() { python3 -c 'import time; print(time.time())'; }

# ---- Fixtures, once: six minutes of tone-long.wav in every streaming shape.
SOURCE="$ROOT/Assets/test_audio_files/tone-long.wav"
[ -f "$SOURCE" ] || { echo "missing $SOURCE: run generate-test-audio.sh" >&2; exit 1; }
mkdir -p "$FIX/source"
make_fixture() {   # <name> <command...>: skipped when present
    local name="$1"; shift
    [ -s "$FIX/source/$name" ] || "$@" || { echo "could not make $name" >&2; exit 1; }
}
make_fixture long.wav ffmpeg -loglevel error -y -stream_loop 2 -i "$SOURCE" -c copy "$FIX/source/long.wav"
make_fixture long.flac ffmpeg -loglevel error -y -i "$FIX/source/long.wav" -c:a flac "$FIX/source/long.flac"
make_fixture long.m4a afconvert -f m4af -d aac -b 256000 "$FIX/source/long.wav" "$FIX/source/long.m4a"
make_fixture moovlast.m4a ffmpeg -loglevel error -y -i "$FIX/source/long.wav" -c:a aac -b:a 256k "$FIX/source/moovlast.m4a"
make_fixture long.mp3 lame --quiet -b 320 "$FIX/source/long.wav" "$FIX/source/long.mp3"
make_fixture short.wav ffmpeg -loglevel error -y -i "$SOURCE" -t 20 "$FIX/source/short.wav"
# No Xing/Info frame: CoreAudio walks every frame to count packets.
make_fixture noxing.mp3 lame --quiet -b 320 -t "$FIX/source/long.wav" "$FIX/source/noxing.mp3"
make_fixture adts.aac ffmpeg -loglevel error -y -i "$FIX/source/long.wav" -c:a aac -b:a 256k -f adts "$FIX/source/adts.aac"
# Under the tail window's 4 MB floor: no window, so the open's ID3v1 check waits.
make_fixture small.mp3 sh -c "ffmpeg -loglevel error -y -i '$SOURCE' -t 75 -f wav - | lame --quiet -b 320 - '$FIX/source/small.mp3'"
# A pair that sorts short first, for the gapless successor.
make_fixture g1.wav cp -c "$FIX/source/short.wav" "$FIX/source/g1.wav"
make_fixture g2.mp3 cp -c "$FIX/source/long.mp3" "$FIX/source/g2.mp3"
# Earlier runs' folders, here and in the mirror, so the fake's index stays small.
rm -rf "$FIX"/run-*

ACCOUNT=""
F0=""
FIXTURES=0
SCENARIO=""
FAILED=()
RESULTS="{}"

# A fresh folder of APFS clones, the fake reinstalled over it (no session
# rebuild, VibeFakeDropbox.h), its mirror directory made so `open` lists it.
# Sets FOLDER and ACCOUNT, so never call it in a subshell.
fixture() {   # <transfer-seconds> <file...>
    local seconds="$1"; shift
    FIXTURES=$((FIXTURES + 1))
    local name="run-$SCENARIO-$$-$FIXTURES"
    mkdir -p "$FIX/$name"
    # Named for the scenario, so a fault scoped to F0 never lands on a
    # previous scenario's transfer of the same source still running.
    F0=""
    for f in "$@"; do
        local clone="${f%.*}-$SCENARIO-$FIXTURES.${f##*.}"
        cp -c "$FIX/source/$f" "$FIX/$name/$clone"
        F0="${F0:-$clone}"
    done
    dbg set_fake_dropbox "$FIX" "$seconds" >/dev/null || { echo "set_fake_dropbox failed" >&2; exit 1; }
    ACCOUNT="$(dbg dump_dropbox | jq -r .accountPath)"
    # Earlier runs' mirror folders, once: never one a transfer may still write.
    [ "$FIXTURES" = 1 ] && rm -rf "$ACCOUNT"/run-*
    mkdir -p "$ACCOUNT/$name"
    FOLDER="$name"
}

T0=0
open_folder() { T0="$(now)"; dbg open "$ACCOUNT/$1" >/dev/null; }

# One poll, every dump the assertions read, as one compact line, appended to
# the scenario's log. t is seconds since the folder was opened.
SNAP=""
snap() {
    local st rl db fd ar ch
    st="$(dbg dump_state)"; rl="$(dbg dump_row_loading)"; db="$(dbg dump_dropbox)"
    fd="$(dbg dump_fake_dropbox)"; ar="$(dbg dump_art)"; ch="$(dbg dump_cloud_health)"
    SNAP="$(jq -cn --argjson t "$(now)" --argjson t0 "$T0" --argjson st "${st:-null}" --argjson rl "${rl:-null}" \
        --argjson db "${db:-null}" --argjson fd "${fd:-null}" --argjson ar "${ar:-null}" --argjson ch "${ch:-null}" '{
        t: ($t - $t0), state: $st.player.state, pos: $st.player.position, buf: $st.player.buffering,
        gapless: $st.player.gaplessArmed, br: $st.player.bufferingRecord, idx: $st.playlist.currentIndex, err: $st.ui.error,
        url: ($st.currentTrack.url // ""), rows: [$rl.loadingRows[]? | {i: .index, p: .progress}],
        tracks: [$db.playlistTracks[]? | {ph: .placeholder, s: .stream}],
        dl: $fd.downloads, requests: $fd.requests, log: $fd.log, faults: $fd.faults,
        wf: {target: $ar.waveformTarget, pages: [$ar.pages[]? | {f: .waveformFilled, c: .waveformComplete}]},
        readable: $ch.materialization.readableClaims}')"
    printf '%s\n' "$SNAP" >> "$OUT/$SCENARIO.jsonl"
}

# Polls until the jq predicate holds of a poll, or the timeout; 0 when it held.
# Only polls of the opened folder's track count, so the previous scenario's
# track still sounding at the open is never mistaken for this one.
wait_for() {   # <timeout-seconds> <predicate>
    local deadline; deadline=$(( $(date +%s) + $1 ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        snap
        printf '%s' "$SNAP" | jq -e --arg f "$FOLDER" "(.url | contains(\$f)) and ($2)" >/dev/null && return 0
    done
    return 1
}

# The scenario's polls so far, as one array, for whole-run checks.
polls() { jq -s --arg f "$FOLDER" 'map(select(.url | contains($f)))' "$OUT/$SCENARIO.jsonl"; }

check() {   # <name> <jq predicate over the input> <json>
    if printf '%s' "$3" | jq -e "$2" >/dev/null 2>&1; then
        echo "    ok    $1"
    else
        echo "    FAIL  $1"
        FAILED+=("$SCENARIO: $1")
    fi
}

record() {   # <jq object of measured numbers>
    RESULTS="$(printf '%s' "$RESULTS" | jq -c --arg s "$SCENARIO" --argjson m "$1" '.[$s] = $m')"
    echo "    $1"
}

# ---- Scenarios

# Opens a long file over a transfer of `seconds`, then waits for the download
# to finish, checking the streaming guarantees on every poll.
stream() {   # <file> <seconds> <expect-tail 0|1>
    local file="$1" seconds="$2" tail="$3"
    fixture "$seconds" "$file" short.wav
    open_folder "$FOLDER"
    wait_for 30 '.state == "playing" and .pos > 0.5' || true
    local played="$SNAP"
    wait_for $(( seconds + 20 )) '.tracks[0].ph == false' || true
    wait_for 5 '.rows == []' || true
    local all; all="$(polls)"
    local m; m="$(printf '%s' "$all" | jq -c --argjson played "$played" --argjson seconds "$seconds" '
        ([.[] | .rows[] | select(.i == 0) | .p]) as $bar |
        {startedAt: ($played.t - $played.pos), transferSeconds: $seconds,
         completeAt: ([.[] | select(.tracks[0].ph == false) | .t] | first),
         barSamples: ($bar | length), barMonotonic: ($bar | . == sort), barLast: ($bar | last),
         barSamplesAfterPlay: ([.[] | select(.t > $played.t) | .rows[] | select(.i == 0)] | length),
         placeholderWhileStreaming: ([.[] | select(.tracks[0].s != null) | .tracks[0].ph] | all),
         windowHeld: ([.[] | .tracks[0].s.windowBytes // 0] | max),
         tailReads: (last.dl.tail // 0), wholeDownloads: (last.dl.whole // 0),
         filledAtHalf: ([.[] | select(.tracks[0].s != null and .tracks[0].s.writtenBytes * 2 >= .tracks[0].s.size)
                         | .wf.pages[0].f] | first),
         complete: (last.wf.pages[0].c), neighbourWaveform: ([.[] | .wf.pages[1].f | select(. != null)] | length),
         errors: ([.[] | .err | select(. != "")] | unique)}')"
    record "$m"
    check "plays before a quarter of the transfer" '.startedAt < .transferSeconds / 4' "$m"
    check "download completes" '.completeAt != null' "$m"
    check "loading bar moves after play and never back" '.barMonotonic and .barSamplesAfterPlay >= 3' "$m"
    check "placeholder until complete" '.placeholderWhileStreaming' "$m"
    check "waveform fills with the download" '.filledAtHalf != null and .filledAtHalf > 0.3 and .complete' "$m"
    check "no waveform for the neighbouring page" '.neighbourWaveform == 0' "$m"
    check "no error" '.errors == []' "$m"
    if [ "$tail" = 1 ]; then
        check "one tail read, its window held" '.tailReads == 1 and .windowHeld == 2097152' "$m"
    fi
}

scenario_stream-wav() { stream long.wav 30 1; }
scenario_stream-flac() { stream long.flac 30 0; }
scenario_stream-m4a() { stream long.m4a 30 1; }
scenario_stream-m4a-moovlast() { stream moovlast.m4a 30 1; }
scenario_stream-mp3() { stream long.mp3 30 1; }

scenario_stream-mp3-noxing() { stream noxing.mp3 30 1; }

# Opens over a transfer of `seconds` and reports when it started against when
# the download completed: the formats whose open needs the whole file.
starts() {   # <file> <seconds>
    fixture "$2" "$1"
    open_folder "$FOLDER"
    wait_for $(( $2 + 25 )) '.state == "playing" and .pos > 0.3' || true
    local played="$SNAP"
    local m; m="$(polls | jq -c --argjson p "$played" --argjson seconds "$2" '
        {startedAt: ($p.t - $p.pos), transferSeconds: $seconds,
         completeAt: ([.[] | select(.tracks[0].ph == false) | .t] | first),
         tailReads: (last.dl.tail // 0), errors: ([.[] | .err | select(. != "")] | unique)}')"
    record "$m"
    check "plays, no error" '.errors == [] and .startedAt != null' "$m"
}
# Under the window's floor the download reaches the tail as soon as a tail
# read would have: an MP3's open waits for its last 128 bytes, so the whole file.
scenario_small-mp3() {
    starts small.mp3 30
    check "no tail read; the open waits for the whole download" '.tailReads == 0 and .startedAt >= 25' "$(printf '%s' "$RESULTS" | jq -c '.["small-mp3"]')"
}
# ADTS reads the whole file in order at its open (the spike): no streaming.
scenario_stream-adts() {
    starts adts.aac 30
    check "the open waits for the whole download" '.startedAt >= 25' "$(printf '%s' "$RESULTS" | jq -c '.["stream-adts"]')"
}

# A seek past the download's edge, per format: lands once the bytes arrive.
seek_ahead() {   # <file> <fraction>
    fixture 60 "$1" short.wav
    open_folder "$FOLDER"
    wait_for 30 '.state == "playing" and .pos > 2' || true
    local duration; duration="$(dbg dump_state | jq .player.duration)"
    local target; target="$(python3 -c "print(int($duration * $2))")"
    local asked; asked="$(now)"
    dbg seek "$target" >/dev/null
    wait_for 5 ".pos >= $target" || true
    local held="$SNAP"
    # The position reads the target at once while the voice holds for the
    # bytes; it moves on only once the download has reached them.
    wait_for 90 ".pos > $target + 1" || true
    local moving="$SNAP" movingAt; movingAt="$(now)"
    local m; m="$(jq -cn --argjson h "$held" --argjson l "$moving" --argjson target "$target" \
        --argjson s "$(python3 -c "print($movingAt - $asked)")" '
        {target: $target, heldAt: $h.pos, heldBuffering: $h.buf, movingFrom: $l.pos, secondsToMove: $s,
         writtenWhenMoving: (if $l.tracks[0].s then $l.tracks[0].s.writtenBytes / $l.tracks[0].s.size else 1 end),
         errors: [$l.err | select(. != "")]}')"
    record "$m"
    check "holds at the target while the download catches up" '.heldAt >= .target and .heldBuffering' "$m"
    check "plays on from the target once the bytes arrive, no error" '.movingFrom > .target and .writtenWhenMoving > 0.5 and .errors == []' "$m"
}
scenario_seek-ahead-mp3() { seek_ahead long.mp3 0.6; }
scenario_seek-ahead-flac() { seek_ahead long.flac 0.6; }
scenario_seek-ahead-m4a() { seek_ahead long.m4a 0.6; }

scenario_seek() {
    fixture 60 long.wav short.wav
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 4' || true
    local before="$SNAP"
    dbg seek 1 >/dev/null
    local asked; asked="$(now)"
    wait_for 5 '.pos < 3 and .state == "playing"' || true
    local back="$SNAP" backAt; backAt="$(now)"
    dbg seek 300 >/dev/null
    local ahead; ahead="$(now)"
    wait_for 80 '.pos >= 300' || true
    local landed="$SNAP" landedAt; landedAt="$(now)"
    wait_for 5 '.pos > 302' || true
    local m; m="$(jq -cn --argjson b "$before" --argjson k "$back" --argjson l "$landed" --argjson after "$SNAP" \
        --argjson backS "$(python3 -c "print($backAt - $asked)")" --argjson aheadS "$(python3 -c "print($landedAt - $ahead)")" '
        {backFrom: $b.pos, backTo: $k.pos, backSeconds: $backS, aheadTo: $l.pos, aheadSeconds: $aheadS,
         writtenAtLanding: (($l.tracks[0].s.writtenBytes // $l.tracks[0].s.size // 0) / ($l.tracks[0].s.size // 1)),
         placeholderAtLanding: $l.tracks[0].ph, playsOn: ($after.pos > $l.pos), errors: [$after.err | select(. != "")]}')"
    record "$m"
    check "seek back lands at once" '.backTo < 3 and .backSeconds < 3' "$m"
    check "seek ahead lands" '.aheadTo >= 300 and .playsOn' "$m"
    check "seek ahead waited for the download to reach it" '.placeholderAtLanding == false or .writtenAtLanding > 0.8' "$m"
    check "no error" '.errors == []' "$m"
}

scenario_skip() {
    fixture 60 long.wav short.wav
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 2' || true
    local before="$SNAP"
    dbg next >/dev/null
    wait_for 10 '.idx == 1 and ([.rows[] | select(.i == 0)] == [])' || true
    sleep 1
    snap
    local m; m="$(jq -cn --arg f0 "$F0" --argjson b "$before" --argjson a "$SNAP" '
        {skippedAt: $b.pos, index: $a.idx,
         oldRowLoading: ([$a.rows[] | select(.i == 0)] | length),
         oldTransfer: ([$a.log[] | select(.file == $f0 and .kind == "whole")] | last | .outcome),
         oldPlaceholder: $a.tracks[0].ph, oldStream: $a.tracks[0].s, readable: $a.readable}')"
    record "$m"
    check "the next track is current" '.index == 1' "$m"
    check "the old transfer was cancelled" '.oldTransfer == "cancelled" and .oldRowLoading == 0 and .oldStream == null' "$m"
    check "the old file stays a placeholder" '.oldPlaceholder' "$m"
}

# A skip a moment after the open: the first stream's transfer is cancelled
# however early, and its row's bar goes.
scenario_quick-skip() {
    fixture 60 long.wav short.wav
    open_folder "$FOLDER"
    sleep 0.3
    dbg next >/dev/null
    wait_for 10 '.idx == 1 and ([.rows[] | select(.i == 0)] == [])' || true
    sleep 2
    snap
    local m; m="$(jq -cn --arg f0 "$F0" --argjson a "$SNAP" '
        {index: $a.idx, state: $a.state, oldRowLoading: ([$a.rows[] | select(.i == 0)] | length),
         oldTransfers: [$a.log[] | select(.file == $f0 and (.kind == "whole" or .kind == "resume")) | .outcome],
         oldStream: $a.tracks[0].s, oldPlaceholder: $a.tracks[0].ph, readable: $a.readable,
         errors: [$a.err | select(. != "")]}')"
    record "$m"
    check "the old transfer was cancelled" '(.oldTransfers | all(. == "cancelled")) and .oldRowLoading == 0 and .oldStream == null and .oldPlaceholder' "$m"
    check "the next track plays" '.index == 1 and .state == "playing" and .errors == []' "$m"
}

# A short track streaming into a long one: the successor's stream is the
# gapless park, and the boundary promotes it without a reopen.
scenario_gapless() {
    fixture 15 g1.wav g2.mp3
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 0.3' || true
    wait_for 25 '.gapless' || true
    local armed="$SNAP"
    wait_for 40 '.idx == 1 and .pos > 1' || true
    local promoted="$SNAP"
    local m; m="$(jq -cn --argjson a "$armed" --argjson p "$promoted" --arg f0 "$F0" '
        {armedAt: $a.t, armedPosition: $a.pos, successorStreaming: ($a.tracks[1].s != null or $a.tracks[1].ph == false),
         promotedIndex: $p.idx, promotedPosition: $p.pos, successorWholeDownloads: ([$p.log[] | select(.kind == "whole" and (.file | startswith("g2")))] | length),
         errors: [$p.err | select(. != "")]}')"
    record "$m"
    check "the successor was armed" '.armedAt != null and .successorStreaming' "$m"
    check "promoted into the successor, one download of it" '.promotedIndex == 1 and .successorWholeDownloads == 1 and .errors == []' "$m"
}

scenario_pause-replay() {
    fixture 60 long.wav short.wav
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 3' || true
    dbg play_pause >/dev/null
    wait_for 3 '.state == "paused"' || true
    local paused="$SNAP"
    sleep 2
    snap
    local held="$SNAP"
    dbg play_pause >/dev/null
    wait_for 5 ".state == \"playing\" and .pos > $(printf '%s' "$held" | jq .pos) + 0.5" || true
    local resumed="$SNAP"
    dbg play_index 0 >/dev/null
    sleep 1
    wait_for 8 '.state == "playing" and .pos > 0.3 and .pos < 4' || true
    local replayed="$SNAP"
    local m; m="$(jq -cn --argjson p "$paused" --argjson h "$held" --argjson r "$resumed" --argjson y "$replayed" '
        {pausedAt: $p.pos, heldAt: $h.pos, resumedTo: $r.pos, resumedState: $r.state, replayedTo: $y.pos,
         streamAlive: ($h.tracks[0].s != null or $h.tracks[0].ph == false), errors: ([$y.err] | map(select(. != "")))}')"
    record "$m"
    check "a pause holds the position" '.heldAt - .pausedAt < 0.1' "$m"
    check "a pause keeps the download" '.streamAlive' "$m"
    check "resume plays on" '.resumedState == "playing" and .resumedTo > .heldAt' "$m"
    check "replay starts over" '.replayedTo < 4' "$m"
    check "no error" '.errors == []' "$m"
}

# A link slower than the bitrate, set as a rate (the WAV is 176 KB/s): holds
# and releases, the position still through each hold, one resume per hold.
scenario_buffering() {
    fixture 0 long.wav short.wav
    dbg fake_dropbox_fault rate rate=120K file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 0.3' || true
    local releases; releases="$(printf '%s' "$SNAP" | jq .br.releases)"
    wait_for 40 ".br.releases >= $releases + 5" || true
    xcrun simctl io "$VIBE_SIM_UDID" screenshot "$OUT/buffering.png" >/dev/null 2>&1 || true
    wait_for 10 '.buf' || true
    xcrun simctl io "$VIBE_SIM_UDID" screenshot "$OUT/buffering-held.png" >/dev/null 2>&1 || true
    snap
    local m; m="$(polls | jq -c --arg f0 "$F0" '
        [range(1; length) as $i | {a: .[$i - 1], b: .[$i]} | select(.a.buf and .b.buf and .a.br.holds == .b.br.holds)
         | (.b.pos - .a.pos)] as $drift |
        {holds: (last.br.holds - first.br.holds), releases: (last.br.releases - first.br.releases),
         stalls: (last.br.stalls - first.br.stalls), lastHeld: last.br.heldSeconds,
         bufferingPolls: ([.[] | select(.buf)] | length), maxDriftWhileHeld: ($drift | map(fabs) | max // 0),
         position: last.pos, state: last.state, errors: ([.[] | .err | select(. != "")] | unique)}')"
    record "$m"
    dbg fake_dropbox_fault clear >/dev/null
    check "buffering rose and cleared" '.holds >= 1 and .releases >= 1' "$m"
    check "one resume per hold" '.holds - .releases <= 1 and .stalls == 0' "$m"
    check "the position holds while buffering" '.maxDriftWhileHeld < 0.1' "$m"
    check "still playing, no error" '.state == "playing" and .errors == []' "$m"
}

# A user pause during a buffering hold, then play: the hold ends as an
# ordinary pause and playback picks up where it was.
scenario_pause-buffering() {
    fixture 0 long.wav short.wav
    dbg fake_dropbox_fault rate rate=100K file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 0.3' || true
    wait_for 30 '.buf' || true
    local held="$SNAP"
    dbg play_pause >/dev/null
    wait_for 3 '.state == "paused"' || true
    local paused="$SNAP"
    sleep 3
    snap
    local still="$SNAP"
    dbg play_pause >/dev/null
    wait_for 15 ".state == \"playing\" and .pos > $(printf '%s' "$still" | jq .pos) + 0.5" || true
    local resumed="$SNAP"
    dbg fake_dropbox_fault clear >/dev/null
    local m; m="$(jq -cn --argjson h "$held" --argjson p "$paused" --argjson s "$still" --argjson r "$resumed" '
        {heldBuffering: $h.buf, pausedState: $p.state, pausedBuffering: $p.buf, heldPosition: $h.pos,
         pausedPosition: $s.pos, resumedState: $r.state, resumedTo: $r.pos, errors: [$r.err | select(. != "")]}')"
    record "$m"
    check "a pause ends the hold in place" '.heldBuffering and .pausedState == "paused" and .pausedBuffering == false and (.pausedPosition - .heldPosition | fabs) < 0.3' "$m"
    check "play resumes from there" '.resumedState == "playing" and .resumedTo > .pausedPosition and .errors == []' "$m"
}

# Seeks in quick succession while the link is slower than the bitrate: no
# hang, no stall, and the last seek wins.
scenario_scrub-buffering() {
    fixture 0 long.wav short.wav
    dbg fake_dropbox_fault rate rate=100K file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 3' || true
    local t
    for t in 2 1 2.5 0.5 1.5 0.2 1; do dbg seek "$t" >/dev/null; sleep 0.2; done
    wait_for 20 '.state == "playing" and .pos > 1.5 and .buf == false' || true
    local m; m="$(printf '%s' "$SNAP" | jq -c '{state, pos, buf, stalls: .br.stalls, errors: [.err | select(. != "")]}')"
    dbg fake_dropbox_fault clear >/dev/null
    record "$m"
    check "plays on from the last seek, no error" '.state == "playing" and .pos > 1 and .pos < 30 and .errors == []' "$m"
}

# A download that stops: buffering, then Connection lost at the (shortened)
# no-progress deadline, paused in place; resume fetches afresh and plays on.
# Then, in a fresh folder, a stall lifted inside the deadline, which releases.
scenario_stall() {
    dbg set_audio_loading timeout-baseline=6 timeout-silence=6 >/dev/null
    fixture 20 long.wav short.wav
    dbg fake_dropbox_fault stall after=3M file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 0.3' || true
    wait_for 40 '.buf' || true
    local held="$SNAP" stalls; stalls="$(printf '%s' "$SNAP" | jq .br.stalls)"
    wait_for 20 ".state == \"paused\" and .br.stalls > $stalls" || true
    local stalled="$SNAP"
    dbg fake_dropbox_fault resume >/dev/null
    dbg play_pause >/dev/null
    wait_for 20 ".state == \"playing\" and .pos > $(printf '%s' "$stalled" | jq .pos) + 1" || true
    local resumed="$SNAP"
    fixture 20 long.wav short.wav
    dbg fake_dropbox_fault stall after=3M file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 40 '.buf' || true
    local held2="$SNAP"
    dbg fake_dropbox_fault resume >/dev/null
    wait_for 15 ".buf == false and .br.releases > $(printf '%s' "$held2" | jq .br.releases)" || true
    local released="$SNAP"
    dbg set_audio_loading defaults >/dev/null
    local m; m="$(jq -cn --argjson h "$held" --argjson s "$stalled" --argjson r "$resumed" --argjson h2 "$held2" --argjson x "$released" '
        {heldAt: $h.pos, heldBuffering: $h.buf, stalledAfterHoldSeconds: ($s.t - $h.t), stalledState: $s.state, stalledAt: $s.pos, stalledError: $s.err,
         stalls: ($s.br.stalls - $h.br.stalls), resumedState: $r.state, resumedTo: $r.pos, heldAgain: $h2.buf,
         releasedBuffering: $x.buf, releases: $x.br.releases, finalError: $x.err}')"
    record "$m"
    check "buffering before the stall" '.heldBuffering' "$m"
    check "Connection lost, paused in place" '.stalledState == "paused" and .stalls == 1 and .stalledError == "Connection lost" and (.stalledAt - .heldAt | fabs) < 0.5' "$m"
    check "resume plays on" '.resumedState == "playing" and .resumedTo > .stalledAt' "$m"
    check "a stall lifted in time releases" '.heldAgain and .releasedBuffering == false' "$m"
}

# The last whole download in the log, and the requests after it.
scenario_drop() {
    fixture 30 long.wav short.wav
    dbg fake_dropbox_fault drop after=2M file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 50 '.tracks[0].ph == false' || true
    snap
    local m; m="$(printf '%s' "$SNAP" | jq -c --arg f0 "$F0" '
        [.log[] | select(.file == $f0 and (.kind == "whole" or .kind == "resume"))] as $d |
        {requests: [$d[] | {kind, range, status, rev, delivered, outcome}], installed: (.tracks[0].ph == false),
         state, errors: [.err | select(. != "")]}')"
    record "$m"
    check "the body dropped at 2 MB" '.requests[0].outcome == "dropped" and .requests[0].delivered == 2097152' "$m"
    check "resumed with Range from the drop, same rev" '.requests[1].kind == "resume" and .requests[1].range == "bytes=2097152-" and .requests[1].status == 206 and .requests[1].rev == .requests[0].rev and .requests[1].outcome == "complete"' "$m"
    check "installed and playing, no error" '.installed and .state == "playing" and .errors == []' "$m"
}

scenario_throttle() {
    fixture 30 long.wav short.wav
    dbg fake_dropbox_fault throttle seconds=2 file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 0.3' || true
    local m; m="$(printf '%s' "$SNAP" | jq -c --arg f0 "$F0" '
        [.log[] | select(.file == $f0 and .kind == "whole")] as $d |
        {statuses: [$d[].status], retryGap: (($d[1].t // 0) - ($d[0].t // 0)), startedAt: (.t - .pos), errors: [.err | select(. != "")]}')"
    record "$m"
    check "429, then served after Retry-After" '.statuses[0:2] == [429, 200] and .retryGap >= 1.9' "$m"
    check "plays, no error" '.errors == []' "$m"
}

scenario_expired-token() {
    fixture 30 long.wav short.wav
    local tokens; tokens="$(dbg dump_fake_dropbox | jq '.requests["/oauth2/token"] // 0')"
    dbg fake_dropbox_fault expired-token file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 0.3' || true
    local m; m="$(printf '%s' "$SNAP" | jq -c --arg f0 "$F0" --argjson before "$tokens" '
        {statuses: [.log[] | select(.file == $f0 and .kind == "whole") | .status],
         refreshes: ((.requests["/oauth2/token"] // 0) - $before), errors: [.err | select(. != "")]}')"
    record "$m"
    check "401 expired, one refresh, then served" '.statuses[0:2] == [401, 200] and .refreshes == 1' "$m"
    check "plays, no error" '.errors == []' "$m"
}

# The resend names another version: FileChanged, the part deleted, the play
# failing through the failure path rather than splicing two versions.
scenario_rev-change() {
    fixture 30 long.wav short.wav
    dbg fake_dropbox_fault rev-change after=1M file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 25 '.err != ""' || true
    sleep 2
    snap
    local m; m="$(printf '%s' "$SNAP" | jq -c --arg f0 "$F0" '
        [.log[] | select(.file == $f0 and (.kind == "whole" or .kind == "resume"))] as $d |
        {requests: [$d[] | {kind, status, rev, outcome}], state, error: .err, placeholder: .tracks[0].ph,
         stream: .tracks[0].s, loadingRow: ([.rows[] | select(.i == 0)] | length), buffering: .buf}')"
    record "$m"
    check "the resend carried another rev" '.requests[1].kind == "resume" and .requests[1].rev != .requests[0].rev' "$m"
    check "the play failed, nothing left streaming" '.error != "" and .state != "playing" and .stream == null and .loadingRow == 0 and .buffering == false' "$m"
    check "the part was deleted, the file a placeholder" '.placeholder' "$m"
}

# No tail window: an MP3 (its open reads the last 128 bytes) waits for the
# whole download.
scenario_tail-fail() {
    fixture 30 long.mp3 short.wav
    dbg fake_dropbox_fault tail-fail file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 50 '.state == "playing" and .pos > 0.3' || true
    local m; m="$(printf '%s' "$SNAP" | jq -c --arg f0 "$F0" '
        {startedAt: (.t - .pos), tailStatuses: [.log[] | select(.kind == "tail" and .file == $f0) | .status], window: (.tracks[0].s.windowBytes // 0),
         installed: (.tracks[0].ph == false), errors: [.err | select(. != "")]}')"
    record "$m"
    dbg fake_dropbox_fault clear >/dev/null
    check "the tail read answered 500" '.tailStatuses == [500]' "$m"
    check "the MP3 opened only at the end of the download" '.startedAt >= 25 and .installed' "$m"
    check "no error" '.errors == []' "$m"
}

scenario_slow-tail() {
    fixture 60 long.mp3 short.wav
    dbg fake_dropbox_fault slow-tail seconds=6 file=$F0 >/dev/null
    open_folder "$FOLDER"
    wait_for 30 '.state == "playing" and .pos > 0.3' || true
    local m; m="$(printf '%s' "$SNAP" | jq -c --arg f0 "$F0" '
        {startedAt: (.t - .pos), tail: [.log[] | select(.kind == "tail" and .file == $f0) | {status, outcome}],
         window: (.tracks[0].s.windowBytes // 0), errors: [.err | select(. != "")]}')"
    record "$m"
    dbg fake_dropbox_fault clear >/dev/null
    check "the MP3 opened when the slow tail landed, not at the end" '.startedAt >= 5.5 and .startedAt < 20' "$m"
    check "no error" '.errors == []' "$m"
}

# The fake account signed out mid-stream: the mirror's playlist is cleared
# (PlaybackController's account-change rule), and nothing is left loading.
scenario_sign-out() {
    fixture 60 long.wav short.wav
    open_folder "$FOLDER"
    wait_for 20 '.state == "playing" and .pos > 2' || true
    dbg set_fake_dropbox off >/dev/null
    sleep 3
    local state rows
    state="$(dbg dump_state)"; rows="$(dbg dump_row_loading)"
    local m; m="$(jq -cn --argjson s "$state" --argjson r "$rows" '
        {state: $s.player.state, count: $s.playlist.count, buffering: $s.player.buffering,
         transfers: ($r.transfers | length), error: $s.ui.error}')"
    record "$m"
    check "the playlist cleared, nothing loading or buffering" '.count == 0 and .transfers == 0 and .buffering == false and .state != "playing"' "$m"
}

# The file changes on Dropbox between its listing and its play: the
# download's metadata names the new version (size and mtime), and the
# installed file and its cache key follow it.
scenario_reupload() {
    fixture 20 long.wav short.wav
    local fake="$FIX/$FOLDER/$F0"
    # Listed first: open, then pause straight away, before anything plays.
    open_folder "$FOLDER"
    wait_for 10 '.tracks[0].ph == true' || true
    dbg play_index 1 >/dev/null
    sleep 1
    printf 'reuploaded' >> "$fake"
    touch "$fake"
    local size; size="$(stat -f %z "$fake")"
    dbg play_index 0 >/dev/null
    wait_for 40 '.idx == 0 and .tracks[0].ph == false' || true
    wait_for 10 '.idx == 0 and .state == "playing" and .pos > 1' || true
    local local_size; local_size="$(stat -f %z "$ACCOUNT/$FOLDER/$F0" 2>/dev/null || echo 0)"
    local m; m="$(printf '%s' "$SNAP" | jq -c --arg f0 "$F0" --argjson size "$size" --argjson got "$local_size" '
        {hostSize: $size, installedSize: $got, state, pos,
         revs: ([.log[] | select(.file == $f0 and .kind != "ranged") | .rev] | unique), errors: [.err | select(. != "")]}')"
    record "$m"
    check "the new version installed and plays" '.installedSize == .hostSize and .state == "playing" and .errors == []' "$m"
}

for SCENARIO in $SCENARIOS; do
    if ! declare -F "scenario_$SCENARIO" >/dev/null; then
        echo "unknown scenario: $SCENARIO (known: $ALL)" >&2
        exit 64
    fi
    echo "== $SCENARIO"
    FOLDER=""
    "scenario_$SCENARIO"
done
dbg fake_dropbox_fault clear >/dev/null
printf '%s' "$RESULTS" | jq --argjson failed "$(printf '%s\n' "${FAILED[@]+"${FAILED[@]}"}" | jq -R . | jq -s 'map(select(. != ""))')" \
    '{scenarios: ., failed: $failed}' > "$OUT/summary.json"
echo "summary: $OUT/summary.json"
if [ "${#FAILED[@]}" -gt 0 ]; then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "PASSED"
