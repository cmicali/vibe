# Test audio fixtures

Use the generated files in `Assets/test_audio_files/` (gitignored), never your own synthesis:

```bash
.claude/skills/vibe-debug/scripts/generate-test-audio.sh   # idempotent; --force regenerates
```

| File | For |
| --- | --- |
| `tone-short-1.wav` / `-2` / `-3` | single-file and playlist tests (8 s, distinct pitches) |
| `tone-long.wav` | seek and skip tests (120 s; skips reach ±60 s) |
| `tone.flac` | FLAC and codec-label coverage |
| `rates/tone-44100-16.wav`, `-48000-16.wav`, `-88200-24.wav`, `-96000-24.wav`, `-96000-24.flac` | the rates and word lengths bit-perfect output switches a DAC to; for full-file sample comparisons use the seeded noise below |
| `tone-art-red.m4a` / `tone-art-blue.m4a` | tagged metadata ("Red Art Test"/"Blue Art Test", artist "Art Tester") with solid covers. Play one then the other for the art crossfade and tint animation. 180 s, long enough for the iOS scrubber |
| `bpm-85.wav`, `bpm-120.wav`, `bpm-128.wav`, `bpm-140.wav`, `bpm-174.wav` | 30 s loops at exactly the named tempo. Atonal, so `scan-key.sh` must report no key |
| `key-am.wav`, `key-c.wav`, `key-fsm.wav`, `key-eb.wav` | 24 s chord loops in the named key |
| `tone-cbr.mp3` | 8 s 192 kbps CBR, the plain MP3 case |
| `tone-vbr.mp3` | 120 s VBR with a Xing/LAME header, for duration and seek accuracy, which a CBR file cannot prove |
| `tone-art-green.mp3` | 8 s CBR with ID3v2 tags and a green front cover, the ID3 art path |

The short files end after eight seconds. Pause early, or use `tone-long.wav`, when playback must still run at capture time.

**The MP3s need `lame` or `ffmpeg`.** Without either, the generator skips them with a note. `afconvert` cannot stand in: macOS ships an MP3 decoder and no encoder.

**Every ffmpeg call is bounded and writes its output whole or not at all.** Use the generator's `ffmpeg_out` or `scripts/bench/bench.py`'s `ffmpeg()`. TRAP: ffmpeg's native `vorbis` encoder never exits once almost no audio reaches it, so a window cut from a real file clamps `-ss` to `ffprobe`'s duration (the generator's `TRAP:` comment).

## A slow cloud open

The Loading state, the shimmer and the load-timeout error need an open that blocks. `set_fake_cloud` provides one with no network or account. It is the same injected provider the stress harness uses, and a common verb, so `debug-ios.sh set_fake_cloud` works too:

```bash
"$V" --debug-cmd set_fake_cloud 4 100   # base seconds, percent of the corpus that reads as cloud
"$V" --debug-cmd previous               # any play that is NOT the prefetched next track (trap below)
                                        # header shows Loading; shimmer at 0.5 s; timeout error after 60 s without progress
"$V" --debug-cmd set_fake_cloud 0       # uninstall
```

It replaces the three things the app asks about a file. `PlaceholderFiles.isDatalessFile:` answers YES for the chosen paths. `CloudFileMaterializer`'s coordinated read becomes a cancellable wait. `DownloadProgressMonitor` reports that wait's progress, in twelfths at 1 Hz, and a third of the corpus stalls partway. Everything above them runs unchanged. `VibeFakeCloud.h` is the contract. **The seconds are a base, not the answer**: each file's time comes from a hash of its path, 0.5x to 2x, with one in ten at 18x and one in fifty stuck past the open timeout. Sending it again re-arms the whole corpus.

The log names each progress line's source (`fake`, `poll`, `iCloud` or `provider`):

```
Download progress (fake): 17% (1.0s) tone-long.wav
Download progress (fake): 42% (5.0s) tone-long.wav   <- a stall
```

**On macOS it never streams a waveform.** The fake waits for the whole file, as a real provider's download does there. On the mac only a link streams, and `set_fake_http` serves one. To watch a waveform fill in, pace the decode: `file_clear_cache <file>`, `set_waveform_decode_seconds 8`, then open it.

**TRAP: `next` alone often proves nothing.** `didStartPlaying:` prefetches the following track, so the next open is answered from the parked handle and starts instantly. Aim at a track that is not the parked one: `previous`, a distant row, or an `open`.

**A named pipe cannot stand in for a slow file.** A fifo stats as `st_size == 0`, and `NSURL+Emptiness.isEmptyOrDirectory` drops it before anything opens it.

## One-shot BPM and key

`scan_bpm` and `scan_key` run in the CLI's own process: no app, no window, no caches, no tags. They stream the file through stdin because the direct-exec'd binary is sandboxed and cannot read argv paths. The client stages the bytes in its own container tmp, so no shell touches `~/Library/Containers/`.

```bash
.claude/skills/vibe-debug/scripts/scan-bpm.sh <audio-file>   # {"ok":true,"bpm":120.01}; bpm 0 = no confident tempo
.claude/skills/vibe-debug/scripts/scan-key.sh <audio-file>   # {"ok":true,"key":"Am","camelot":"8A","index":21}; empty strings / index -1 = no confident key
```

## Render tests

`make test-audio` pumps PCM through the real player and FX pipeline without hardware and runs the comparator's self-tests. `Tests/AGENTS.md` describes the matrix. `make test-audio-summary` reports the results. `generate-test-audio.sh --render-tests build/audio-fixtures` supplies the seeded noise and analytical fixtures.

## Bit-perfect acceptance

`make test-bit-perfect` is opt-in and never runs in CI. It compiles `build/verify-bit-perfect`, runs its self-tests, generates fixtures and drives the live matrix on **VibeBlackHole 16ch**. It needs exclusive use of the debug channel: the verifier checks that exactly one Vibe is running and that its executable matches `--play-app`.

```bash
make build CONFIG=Debug
make build-test-blackhole
open build/blackhole-drivers/VibeBlackHoleTests.pkg      # install, then restart CoreAudio or reboot
.claude/skills/vibe-debug/scripts/generate-test-audio.sh --render-tests build/audio-fixtures
VIBE_NOW_PLAYING=0 VIBE_AUDIBLE=1 .claude/skills/vibe-debug/scripts/launch.sh
V="$PWD/build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe"
"$V" --debug-cmd settings_open audio
"$V" --debug-cmd dump_settings_ui | jq '.controls[] | select(.name == "Output") | .rows'   # VibeBlackHole 16ch's row
"$V" --debug-cmd settings_click Output <row>
"$V" --debug-cmd set_bit_perfect off
open -a "$PWD/build/DerivedData/Build/Products/Debug/Vibe.app" "$PWD/build/audio-fixtures"   # grant the fixture directory
"$V" --debug-cmd quiesce
"$V" --debug-cmd set_pitch 0
make test-bit-perfect ARGS='--force-volume' > build/bit-perfect-acceptance.ndjson
```

Granting the directory covers the temporary M3U files the run writes beside the WAVs. Enabling bit-perfect bypasses Audio FX live. The verifier turns Declick off for its captures and restores it at exit, since a capture is compared from its first frame.

What the run does to the machine:

- It replaces the test playlist, switches devices, and **quits, relaunches and SIGKILLs Vibe**. Use an idle test session. It leaves playback stopped and bit-perfect off, and restores the pause-at-end and reopen preferences.
- The device-switch case uses **VibeBlackHoleBare 16ch** by default. `--switch-device` names another.
- `--rate-switch-iterations N` (1–1000, default 10) repeats the 44.1 → 48 kHz boundary. Each iteration keeps its own `capture-after-rate-switch-N.caf`.
- `--force-volume` sets the loopback's volume controls to unity for the run. It snapshots every control first and restores and reads them back even on failure. Cleanup failure is a test failure.
- TRAP: **`--force-volume` fixes volume, not mute.** Another app can leave BlackHole 2ch's device mute on. The loopback then captures silence, the report honestly reads `status: muted`, and the verifier waits for `active` forever. Clear the output scope's `kAudioDevicePropertyMute` (element 0) before a loopback run. VibeBlackHole 16ch has no mute control.

The matrix covers mode off, every rate and depth, codecs against their WAV originals, sample extremes, an idle stop and resume, truthful non-active reports (`depthInsufficient`, `sourceLossy`, `channelConversion`, `volumeScaled`, `rateUnsupported`), gapless joins, rate-boundary successors, `hang_open` across mode changes, live toggles, format restoration, device disappearance and replug, aggregates, driver fault injection and crash recovery. The verifier's source is the authority on each case. Its final `notCovered` list names what the run did not prove.

Each capture reports `exact`, `comparedFrames`, `mismatchedSamples`, `channels`, `captureChannels`, `sourceStartFrame`, `captureStartFrame`, `maxAbsError`, `unexpectedSamples` and `passed`. Comparison is on float32 bit patterns with no tolerance. Unused channels must stay silent for the whole recording. The first 50 ms covers the startup fade and is not claimed bit-perfect. `defaultOutputChangeEvents` counts system default-output changes during a capture. macOS can rebind the output unit on an unrelated default change, and a rebind during measurement fails rather than retries.

### BlackHole driver fixtures

`make build-test-blackhole` builds three ad-hoc-signed drivers from a pinned BlackHole revision into `build/blackhole-drivers`. The package installs only these under `/Library/Audio/Plug-Ins/HAL`. Remove the three bundles and restart CoreAudio to uninstall. None can become the system default.

| Device | Coverage |
| --- | --- |
| VibeBlackHole 16ch | stereo onto 16 outputs with 14 silent; disappearance and replug; fault injection |
| VibeBlackHoleBare 16ch | no volume, balance, pan or mute properties |
| VibeBlackHole48 2ch | 48 kHz only; 44.1 kHz must report `rateUnsupported` |

The driver's custom properties are `vbtf`, a fault mask, and `vbth`, an injected-operation count. Each lease expires after 60 seconds if the verifier disappears. HAL can answer `DeviceIsAlive` itself without the driver's hook, so that fault is listed in `notCovered`.

The Make target always passes `--require-driver-fixtures`. To rerun only the device scenarios, or to run partial coverage on stock BlackHole:

```bash
build/verify-bit-perfect --blackhole-check "$PWD/build/audio-fixtures" "VibeBlackHole 16ch" \
    --play-app "$V" --force-volume --require-driver-fixtures
build/verify-bit-perfect --acceptance "$PWD/build/audio-fixtures" "BlackHole 2ch" --play-app "$V" --force-volume
```

### Single captures and the device check

```bash
make build/verify-bit-perfect
build/verify-bit-perfect --self-test
build/verify-bit-perfect --compare reference.wav capture.wav
# App idle, unmuted, routed to the named device, bit-perfect on:
build/verify-bit-perfect "$PWD/build/audio-fixtures/noise-48000-24-2.wav" 3 "BlackHole 2ch" --play-app "$V" --force-volume
#   --idle-resume-at 0.5   a paused seek, idle stop and sample-exact resume
#   --reference <wav>      an independent reference for a codec capture
#   --set-rate             mode off: match the device to the reference first
#   --ordinary             assert the ordinary chain; report sample changes rather than fail
#   --next-file <file>     compare a joined capture
#   --save-capture <caf>   keep the PCM
```

Without `--play-app`, wait for **Capture ready** before opening the file. Recording is capped at 120 seconds and 256 MB. Raw loopback input needs Microphone permission, and zero-filled callbacks may mean it was denied. Do not bypass that check.

For a physical DAC, run `build/verify-bit-perfect --device-check <fixture> "device name" --play-app "$V"` from a stopped, bit-perfect-off state. It checks the negotiated format, the six-second idle release and format restoration. Add `--require-exclusive` only with Exclusive output on and a device that is not the system default. It reports HAL ownership, not a PCM recording.

`make test-audio-loopback AUDIO_DEVICE="BlackHole 2ch"` wraps a single capture (`ARGS="--set-rate --ordinary"` for the ordinary chain). `AUDIO_FILE`, `AUDIO_SECONDS` and `AUDIO_APP` default to the 48/24 noise WAV, 3 and the worktree's Debug binary. `make test-audio-device AUDIO_DEVICE="device name"` wraps the device check (`ARGS=--require-exclusive`). Both use the setup and restoration rules above.
