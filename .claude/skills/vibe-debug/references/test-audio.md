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
                                        # The header flips to Loading; shimmer at 0.5s, timeout error at 20s
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

**A blocking file on disk is not an option, and a named pipe is the trap to avoid.** A fifo stats as `st_size == 0`, and `NSURL+AudioOpen.isEmptyOrDirectory` — the guard that stops `AVAudioFile` leaking a descriptor on an empty path — filters it out of the open funnel before anything opens it, so the command logs "dispatched" and nothing happens at all.

**One-shot BPM and key measurement.** `scan_bpm` (and its twin `scan_key`) runs in the CLI's own process with no channel round-trip: no app launch, no window, no caches. It works with no app running and leaves a running Vibe instance untouched. The script streams the file through stdin (`scan_bpm - < file`) because the direct-exec'd binary is still sandboxed and cannot read arbitrary argv paths, for the same reason argv opens fail. The client stages the bytes in its own container tmp, which keeps shell processes out of `~/Library/Containers/` and so avoids the TCC prompt described under Screenshots:

```bash
.claude/skills/vibe-debug/scripts/scan-bpm.sh <audio-file>   # {"ok":true,"bpm":120.01} — bpm 0 = no confident tempo
.claude/skills/vibe-debug/scripts/scan-key.sh <audio-file>   # {"ok":true,"key":"Am","camelot":"8A","index":21} — empty strings / index -1 = no confident key
```

`scan_key` has the same contract as `scan_bpm` throughout: it runs in the CLI process, needs no app, ignores caches and tags (it reports pure analysis — the app's own display prefers a tagged key), and streams the file via stdin for the same sandbox reasons.

