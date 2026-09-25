# Test audio fixtures

Generated fixtures for driving the app; see the `vibe-debug` skill for everything else.

Use the generated files in `Assets/test_audio_files/` (gitignored) rather than synthesizing your own:

```bash
.claude/skills/vibe-debug/scripts/generate-test-audio.sh   # idempotent; --force regenerates
```

| File | For |
| --- | --- |
| `tone-short-1.wav` / `-2` / `-3` | single-file and playlist/multi-file tests (8s, distinct pitches) |
| `tone-long.wav` | seek and skip tests (120s — skips reach ±60s) |
| `tone.flac` | FLAC/codec-label coverage |
| `rates/tone-44100-16.wav`, `-48000-16.wav`, `-88200-24.wav`, `-96000-24.wav`, `-96000-24.flac` | the long tone at the rates and word lengths bit-perfect output switches a DAC to — interactive rate-switch probes; use the seeded noise below for full-file sample comparisons |
| `tone-art-red.m4a` / `tone-art-blue.m4a` | tagged metadata (titles "Red Art Test"/"Blue Art Test", artist "Art Tester") with solid red/blue covers — art, header-tint, and dock-icon tests; play one then the other to exercise the art crossfade and tint animation. 180s, so scrubbing is testable (the iOS scrubber needs it) |
| `bpm-85.wav`, `bpm-120.wav`, `bpm-128.wav`, `bpm-140.wav`, `bpm-174.wav` | 30s kick+hat loops at exactly the named tempo — BPM-analyzer tests (see `scan-bpm.sh` below; compare against the filename). Atonal, so they double as the key analyzer's negative case: `scan-key.sh` must report no key |
| `key-am.wav`, `key-c.wav`, `key-fsm.wav`, `key-eb.wav` | 24s chord-progression loops in the named key (Am, C, F#m, Eb) — key-analyzer tests (see `scan-key.sh` below) |
| `tone-cbr.mp3` | 8s 192kbps CBR — the plain MP3 case |
| `tone-vbr.mp3` | 120s VBR with a Xing/LAME header — duration and seek accuracy, which a CBR file cannot prove because a constant-bitrate guess is right by construction |
| `tone-art-green.mp3` | 8s CBR, ID3v2 title "Green Art Test" / artist "Art Tester" and a green front cover (APIC type 3) — the ID3 art path, which shares no parser with the MP4 art above |

**The MP3s are the one part of the corpus that needs a non-stock tool** — `lame` or `ffmpeg`, either works — and the generator skips them with a note when neither is installed, so a machine without one has a corpus missing the app's headline format. `afconvert` cannot stand in: `afconvert -hf` advertises `'MPG3'` with data_formats `'.mp3'`, but encoding fails with `ExtAudioFileSetProperty ('cfmt') failed ('fmt?')` because macOS ships an MP3 decoder and no encoder. Don't spend a round on its flags.

The short files end after eight seconds. Pause early, or use `tone-long.wav`, when a test needs playback still running at capture time.

**Simulating a slow cloud file open.** The Loading state, the shimmer, the load-timeout error and anything else gated on `didBeginLoading:` need an open that blocks, which no local file provides. `set_fake_cloud` is the way — the same injected provider the stress harness runs on, so it needs no network, no account and no provider anywhere in reach:

```bash
# $V is the skill's binary handle: <app>/Contents/MacOS/Vibe
"$V" --debug-cmd set_fake_cloud 4 100   # base seconds, percent of the corpus that reads as cloud
"$V" --debug-cmd previous               # any play that is NOT the prefetched next track — see the trap below.
                                        # The header flips to Loading; shimmer at 0.5s, timeout error after 60s without progress (each progress movement allows another 60s)
"$V" --debug-cmd set_fake_cloud 0       # after your checks — uninstalls, real dataless test back
```

It replaces the three things the app asks about a file and leaves everything above them unchanged: `NSURLUtil.isDatalessFile:` answers YES for the chosen paths, `CloudFileMaterializer`'s coordinated read becomes a cancellable wait, and `DownloadProgressMonitor` reports that wait's progress instead of polling the (genuinely local) file. Same cloud lane, same foreground hold, same abandoned opens, same loading indicator — **including its determinate fill**, which arrives in twelfths at 1 Hz like a real provider's, and which a third of the corpus stalls partway through so the "a stall stays honest" rule has something to fail against. `VibeFakeCloud.h` is the contract; **the seconds you pass are a base, not the answer** — each file's time comes from a hash of its path, 0.5x to 2x, with one in ten at 18x and one in fifty stuck past the player's open timeout. Sending it again re-arms and puts the whole corpus back in the cloud. It is a common verb, so `debug-ios.sh set_fake_cloud` works the same.

Watch it move in the log, which names its source (`fake`, `poll`, `iCloud` or `provider`) — the fastest way to tell the fill apart from the shimmer without a screenshot:

```
Download progress (fake): 17% (1.0s) tone-long.wav
Download progress (fake): 33% (2.0s) tone-long.wav
Download progress (fake): 42% (5.0s) tone-long.wav   <- the stall, 2s of it
```

**TRAP: `next` alone often proves nothing** — `didStartPlaying:` prefetches the following track, so the next open is answered from the parked handle and starts instantly however slow the fake provider is. Aim at a track that is not the parked one: `previous`, a double-click on a distant row, or an `open`.

**A blocking file on disk is not an option, and a named pipe is the trap to avoid.** A fifo stats as `st_size == 0`, and `NSURL+AudioOpen.isEmptyOrDirectory` — a stat check the open funnel's list filters apply — drops it before anything opens it, so the command logs "dispatched" and nothing happens at all.

**One-shot BPM and key measurement.** `scan_bpm` (and its twin `scan_key`) runs in the CLI's own process with no channel round-trip: no app launch, no window, no caches. It works with no app running and leaves a running Vibe instance untouched. The script streams the file through stdin (`scan_bpm - < file`) because the direct-exec'd binary is still sandboxed and cannot read arbitrary argv paths, for the same reason argv opens fail. The client stages the bytes in its own container tmp, which keeps shell processes out of `~/Library/Containers/` and so avoids the TCC prompt described under Screenshots:

```bash
.claude/skills/vibe-debug/scripts/scan-bpm.sh <audio-file>   # {"ok":true,"bpm":120.01} — bpm 0 = no confident tempo
.claude/skills/vibe-debug/scripts/scan-key.sh <audio-file>   # {"ok":true,"key":"Am","camelot":"8A","index":21} — empty strings / index -1 = no confident key
```

`scan_key` has the same contract as `scan_bpm` throughout: it runs in the CLI process, needs no app, ignores caches and tags (it reports pure analysis — the app's own display prefers a tagged key), and streams the file via stdin for the same sandbox reasons.

## Render tests

`make test-audio` pumps PCM through the real player/FX pipeline without opening hardware and runs the comparator's corruption self-tests. `Tests/CLAUDE.md` describes the matrix, tolerances, failure WAV attachments and bounded frame clock. `make test-audio-summary` reports the results. The fixture generator's `--render-tests build/audio-fixtures` mode supplies seeded noise and analytical fixtures independently of the interactive corpus.

## Bit-perfect acceptance

Run `make test-bit-perfect` explicitly; its live matrix is excluded from regular tests and CI. It requires the three test drivers below, defaults to **VibeBlackHole 16ch**, compiles the verifier, runs its comparator self-tests, generates fixtures and drives the live acceptance matrix. `make test-audio` runs the same comparator self-tests before its device-free render suite.

The strict comparator, bounded capture and seeded fixture generator are shared with the pump-driven `VibeAudioTests` render suite (`make test-audio`); this workflow exercises the running app and CoreAudio. Run it with exclusive use of Vibe's shared debug channel. The verifier checks that exactly one Vibe instance is running and its executable matches `--play-app`. Do not run it while another worktree is using the app.

```bash
make build CONFIG=Debug
make build-test-blackhole
open build/blackhole-drivers/VibeBlackHoleTests.pkg
# Install using macOS Installer, then restart CoreAudio or reboot.
.claude/skills/vibe-debug/scripts/generate-test-audio.sh --render-tests build/audio-fixtures
VIBE_NOW_PLAYING=0 VIBE_AUDIBLE=1 .claude/skills/vibe-debug/scripts/launch.sh
V="$PWD/build/DerivedData/Build/Products/Debug/Vibe.app/Contents/MacOS/Vibe"
"$V" --debug-cmd settings_open general
"$V" --debug-cmd settings_click Output "VibeBlackHole 16ch"
"$V" --debug-cmd set_bit_perfect off
```

Enabling bit-perfect bypasses Audio FX live, including a run launched with effects enabled. Set pitch to zero. The verifier turns Declick off for its captures and restores the choice at exit: a capture is compared from its first frame, and with Declick on a bit-perfect start ramps its first 10 ms. Grant the **fixture directory** through Launch Services, then close playback. This covers temporary M3U files created beside the audio as well as the WAVs:

```bash
open -a "$PWD/build/DerivedData/Build/Products/Debug/Vibe.app" "$PWD/build/audio-fixtures"
"$V" --debug-cmd quiesce
"$V" --debug-cmd set_pitch 0
make test-bit-perfect ARGS='--force-volume' \
    > build/bit-perfect-acceptance.ndjson
```

The device-switch case uses **VibeBlackHoleBare 16ch** by default; `--switch-device` can name another output. It changes devices while stopped, then returns to the original output. The run also **quits and relaunches Vibe** to check termination restoration. It leaves playback stopped and bit-perfect off, restores the previous pause-at-end/reopen preferences, and releases any held/fake opens. It replaces the test playlist; use an idle test session.

`--force-volume` opts into temporarily setting the loopback's readable main and channel volume controls to unity (up to 64 channels). All aliases are snapshotted before any write, then restored and read back even on a failed comparison or setup error. A volume write that does not read back within one second is retried once, since a pending HAL rate change can discard an accepted write. The capture stops before playback/device teardown. SIGINT, SIGTERM and SIGHUP request the same cleanup at the next bounded wait or completed debug call. Killing the verifier itself cannot promise restoration; its intentional Vibe crash case leaves the verifier alive to recover the device. Cleanup failure is a test failure. A virtual loopback does not acquire the physical device's exclusive ownership.

The matrix asserts:

- Mode off keeps the ordinary chain — the bus at the output's format through its varispeed — no prepared device, no restore/hog obligation and neither bit-perfect listener. It must render finite, non-silent audio for at least the source duration minus the startup exclusion. Its sample comparison is diagnostic: ordinary playback is not required to preserve the samples or alignment marker.
- Stereo WAV at 44.1, 48, 88.2, 96, 176.4 and 192 kHz, each in 16-bit integer, 24-bit integer and float32, is exact after startup. Capture is armed before the measured replay. A warm-up open negotiates format before the IOProc is bound. This matrix requires a loopback offering all six rates; an unsupported rate fails rather than silently dropping coverage.
- FLAC, ALAC and big-endian AIFF at 48/24 compare against their original WAV, so a codec-specific decode error cannot affect both sides of the comparison.
- Full-scale positive/negative values, zeros and the smallest integer step are exercised in 16-bit, 24-bit and float PCM. Marked silence, an impulse and a frequency sweep check silence, timing and filtering; the first 100 ms is seeded noise so alignment stays unambiguous.
- A paused seek to 0.5 s survives the six-second idle output stop; resuming captures and compares the entire remaining file after the same 50 ms settling exclusion.
- 32-bit integer and float64 fixtures with nonzero low bits report `depthInsufficient`, AAC/MP3/MP2/QTA report `sourceLossy` (unavailable optional encoders are listed), and mono/four/eight/sixteen-channel sources through the stereo bus report `channelConversion`. These cases assert truthful reporting, not bit-perfect delivery.
- When the device has volume controls, changing gain to 0.5 updates the report to `volumeScaled`; restoring unity returns it to `active`. Virtual balance and main mute, when present, must likewise update the report and recover. Missing controls are listed in `notCovered`; original control values are restored at exit.
- An explicit stop unloads the track; replay captures the full file again.
- A same-rate 16→24-bit pair on a float32 device queues the second as the first voice's successor and compares one concatenated reference, **including every frame at the join**. There is no second fade exclusion or realignment.
- A 44.1→48 kHz boundary never queues a successor and settles on the new hardware rate. A new capture checks the destination's samples. This is not evidence of sample continuity across the physical format switch.
- `hang_open` holds the real file-open path until each mode change has been submitted. The released open must land on the latest setting's pipeline.
- Twelve live mode toggles, each following a seek, must resume advancing audio on the requested pipeline within five seconds and retain the original format for restoration.
- Mode off, a provider failure followed by mode off, quit, and an optional output-device switch restore the original nominal rate and all physical-format fields.
- BlackHole's public box-acquisition property removes/re-publishes its devices while Vibe is stopped, paused and playing a silent fixture. Vibe must disable the mode, retire device obligations/listeners, and persist System Output. Replug must keep that fallback until explicitly reselected; the mode is remembered per device UID, so the reselected loopback comes back with it on (the harness turns it off once bound, to start each case from a known state), and replay then compares exact PCM. The optional `--switch-device` case asserts both halves: the alternate device does not inherit the mode, and the loopback gets it back. AudioObjectIDs can change across reconnects and processes: discovery and cross-process assertions use the device UID. `dump_state.player.outputDeviceUID` is the actual binding; `requestedOutputDeviceId == -1` is the System Output policy.
- A temporary aggregate containing BlackHole must report ineligible, then fall back when destroyed. The harness destroys its aggregate even on failure. Aggregate drift correction is disabled, and aggregate playback is not credited as a transparent loopback.
- Killing the identified test Vibe process with SIGKILL, relaunching and replaying must recover exact PCM. The harness explicitly restores the pre-crash format: this does **not** claim that a killed app can execute its quit cleanup.

Each capture emits `exact`, `comparedFrames` (per source channel), `mismatchedSamples`, `channels`, `captureChannels`, `sourceStartFrame`, `captureStartFrame`, `maxAbsError`, `unexpectedSamples` and `passed`. `approximateAlignment` is diagnostic only; approximate samples cannot earn `exact:true`. Capture silence, missing or repeated markers, short recordings, lost source channels and overflow fail. Wider hardware must deliver each source channel in order and every unused channel must be silent for the entire recording, including startup and tail. References whose native precision exceeds the float32 decoder are rejected before comparison, since decoding both sides could hide the same lost bits. Comparison uses finite float32 bit patterns, including the sign of zero, without an error tolerance. Nonzero or nonfinite samples before the aligned source or after its EOF also fail. The first 50 ms covers the startup/resume fade; those source samples are **not** claimed bit-perfect. Nonperiodic markers and the complete remaining source are mandatory. Comparator self-tests also exercise corrupt alignment, every side of a gapless seam, one-bit changes at the inclusion and EOF boundaries, channel delay/crosstalk, sample extremes, invalid inputs, multichannel arrays and contamination of the sixteenth output channel.

### BlackHole driver fixtures

```bash
make build-test-blackhole
open build/blackhole-drivers/VibeBlackHoleTests.pkg
# Install using macOS Installer, then restart CoreAudio or reboot.
```

The fixture generator builds universal arm64/x86_64, ad-hoc-signed drivers from [BlackHole revision ffcb744](https://github.com/ExistentialAudio/BlackHole/tree/ffcb74433fbcf8c8ca5c736677c1a4864384dc09). Generated source, the upstream license, native driver checks and the installer stay under `build/blackhole-drivers`. No app source or installed stock BlackHole bundle is patched. The package installs only `VibeBlackHole16ch.driver`, `VibeBlackHoleBare16ch.driver` and `VibeBlackHole482ch.driver` under `/Library/Audio/Plug-Ins/HAL`; remove those three bundles and restart CoreAudio to uninstall. These devices cannot become the system default.

| Device | Coverage |
| --- | --- |
| VibeBlackHole 16ch | Exact stereo routing onto 16 outputs, with all 14 spare channels silent; device disappearance/replug; controllable driver failures. |
| VibeBlackHoleBare 16ch | No main/channel volume, balance, pan or mute properties; their absence must permit exact active playback. |
| VibeBlackHole48 2ch | Only 48 kHz available; 44.1 kHz must report `rateUnsupported`, then a 48-kHz capture must recover. |

After selecting **VibeBlackHole 16ch** in Vibe and completing the same fixture grant/setup above:

```bash
make test-bit-perfect ARGS='--force-volume'
# Narrow a rerun to device scenarios, preserving all their assertions and cleanup:
build/verify-bit-perfect --blackhole-check "$PWD/build/audio-fixtures" "VibeBlackHole 16ch" \
    --play-app "$V" --force-volume --require-driver-fixtures
```

The Make target always supplies `--require-driver-fixtures`, which fails preflight if the three fixtures are unavailable. For partial stock-BlackHole coverage, invoke `build/verify-bit-perfect --acceptance "$PWD/build/audio-fixtures" "BlackHole 2ch" --play-app "$V" --force-volume` directly; missing coverage remains in `notCovered`.

The test driver exposes two documented AudioServerPlugIn custom properties as CFNumbers on its box/device: `vbtf` is a fault mask; `vbth` counts injected operations. Masks are 1=volume read error, 2=NaN volume, 4=wrong returned volume size, 8=physical-format read error, 16=physical-format write rejection, 32=accepted but ignored format write, 64=nominal-rate read error, 128=dead-but-enumerated device. Each lease expires after 60 seconds if the verifier disappears; normal/error/signal cleanup clears it immediately. Injection waits for the driver's IO to stop before changing its baseline. Each supported fault requires a nonzero injected-operation count and a truthful failure report or settled open error, clears the fault, then captures exact recovered PCM. HAL may turn the malformed-size reply into a zero scalar; that case requires the matching `volumeScaled` report, not a false `active` report.

HAL can also own `DeviceIsAlive` itself: on the test Mac it returned 1 without consulting the driver's hook, despite its notification. That case is explicitly unsupported in `notCovered`; actual device disappearance is tested through box acquisition. Driver-native checks exercise all eight hooks during the build, while the installed-driver run proves propagation for the seven effective faults. Saved captures round-trip through an explicit multichannel layout in the comparator self-tests.

Two further cases change 96→48 kHz successfully, then reject or silently ignore the writes that should restore 96 kHz on mode off. Both must retain the restoration obligation after retrying; once the fault clears, a new mode cycle must restore every original physical-format field, clear the obligation/listeners and recover exact PCM.

Captures count system-default-output notifications in `defaultOutputChangeEvents`, and failed comparisons include the ending app state. macOS can rebind the output unit when an unrelated default route changes, interrupting a capture even with BlackHole explicitly selected. Setup verifies the actual binding; the full fixture suite can rebind an idle unit through the two virtual devices before playing. A binding change or interrupted recording during measurement still fails; the harness never retries it into a pass. Preserve the capture and stream the app log when investigating. Continuity across an external system-route change is not established by this matrix.

For one capture, saved files, or the device-independent oracle:

```bash
make build/verify-bit-perfect
build/verify-bit-perfect --self-test
build/verify-bit-perfect --compare reference.wav capture.wav
# App must already be idle, unmuted, routed to the named device, with bit-perfect on.
build/verify-bit-perfect "$PWD/build/audio-fixtures/noise-48000-24-2.wav" 3 "BlackHole 2ch" \
    --play-app "$V" --force-volume
# A paused seek, idle stop, and sample-exact resume:
build/verify-bit-perfect "$PWD/build/audio-fixtures/noise-48000-24-2.wav" 3 "BlackHole 2ch" \
    --play-app "$V" --force-volume --idle-resume-at 0.5
# A codec capture can use --reference <original.wav> as an independent PCM reference.
# Mode off: --set-rate temporarily matches the device to the reference.
# --ordinary asserts the dormant chain and reports, rather than rejects, sample changes.
```

The underlying `--acceptance <fixtures-directory> [device] --play-app <binary>` entry point is what Make runs. `--next-file <same-format-file>` compares a joined capture. Without `--play-app`, wait for **Capture ready** before opening the file; do not begin mid-file. `--save-capture <path.caf>` retains PCM for diagnosis; the acceptance matrix saves one capture per case beside the fixture directory. Maximum recording duration is 120 seconds and capture storage is capped at 256 MB. Microphone permission is needed for raw loopback input; zero-filled callbacks may indicate permission denial. Do not bypass that permission check.

For a physical DAC, use `build/verify-bit-perfect --device-check <fixture> "device name" --play-app "$V"` from stopped, bit-perfect-off state. It checks exact negotiated rate/depth/channels, the six-second idle release and physical-format restoration. Add `--require-exclusive` only with Exclusive output enabled and a physical device that is not the system default. This reports HAL ownership, not a PCM recording from a DAC. Physical unplug, denied hog access, integer-depth negotiation and analog output need real hardware. BlackHole remains float32; its 16-channel run proves stereo routing onto wider virtual hardware, while genuine multichannel/mono source preservation is not claimed by Vibe's stereo pipeline. The excluded startup samples and sample continuity across a hardware rate switch remain unproven. The final `notCovered` list distinguishes these limits from a passing matrix.

`make test-audio-loopback AUDIO_DEVICE="BlackHole 2ch"` wraps a single capture with bit-perfect on; use `ARGS="--set-rate --ordinary"` for the ordinary chain. `AUDIO_FILE` defaults to the two-second 48/24 seeded-noise WAV, `AUDIO_SECONDS` to 3, and `AUDIO_APP` to the worktree's Debug binary. `make test-audio-device AUDIO_DEVICE="device name"` wraps the physical-device check, with `ARGS=--require-exclusive` for exclusive ownership. Both use the setup and restoration rules above.
